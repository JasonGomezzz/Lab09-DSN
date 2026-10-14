const test = require('node:test');
const assert = require('node:assert/strict');
const {
  ListObjectsV2Command,
  HeadObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand,
} = require('@aws-sdk/client-s3');
const { loadConfig } = require('../src/config');
const { createImageService } = require('../src/services/imageService');
const { createS3Client } = require('../src/s3Client');

const config = loadConfig({ S3_BUCKET: 'lab-imagenes-prueba-20260101' });
const MB = 1024 * 1024;
const JPEG = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 0, 0, 0, 0]);
const EXE = Uint8Array.from([0x4d, 0x5a, 0x90, 0, 3, 0, 0, 0, 4, 0, 0, 0, 0xff, 0xff, 0, 0]);

/** Cliente real con credenciales falsas: firmar URLs no hace llamadas de red. */
function fakeS3(handler = async () => ({})) {
  const s3 = createS3Client(config, {
    credentials: { accessKeyId: 'TESTKEYID', secretAccessKey: 'testsecret' },
  });
  const calls = [];
  s3.send = async (command) => {
    calls.push(command);
    return handler(command);
  };
  return { s3, calls };
}

test('createUploadUrl firma un PUT de 5 minutos con cifrado y tamaño fijados', async () => {
  const { s3 } = fakeS3();
  const service = createImageService({ s3, config });

  const result = await service.createUploadUrl({
    filename: '../mi foto.PNG',
    contentType: 'image/png',
    sizeBytes: 2 * MB,
  });
  const url = new URL(result.uploadUrl);

  assert.match(result.key, /^originales\/\d+-[0-9a-f]{12}-mi_foto\.png$/);
  assert.equal(url.hostname, 'lab-imagenes-prueba-20260101.s3.us-east-1.amazonaws.com');
  assert.equal(url.searchParams.get('X-Amz-Expires'), '300');
  assert.equal(
    url.searchParams.get('X-Amz-SignedHeaders'),
    'content-length;content-type;host;x-amz-server-side-encryption',
  );
  assert.equal(url.searchParams.has('x-amz-checksum-crc32'), false);
  assert.deepEqual(result.headers, {
    'Content-Type': 'image/png',
    'x-amz-server-side-encryption': 'AES256',
  });
  assert.equal(result.expiresIn, 300);
});

test('createUploadUrl no firma nada si el tipo o el tamaño son inválidos', async () => {
  const { s3, calls } = fakeS3();
  const service = createImageService({ s3, config });

  await assert.rejects(
    service.createUploadUrl({ filename: 'a.pdf', contentType: 'application/pdf', sizeBytes: 10 }),
    { status: 400 },
  );
  await assert.rejects(
    service.createUploadUrl({ filename: 'a.jpg', contentType: 'image/jpeg', sizeBytes: 10 * MB }),
    { status: 413 },
  );
  assert.equal(calls.length, 0);
});

test('listImages pagina, omite el prefijo vacío y firma URLs de 15 minutos', async () => {
  const pages = [
    {
      IsTruncated: true,
      NextContinuationToken: 'p2',
      Contents: [
        { Key: 'originales/', Size: 0, LastModified: new Date('2026-01-01') },
        { Key: 'originales/a.jpg', Size: 100, LastModified: new Date('2026-01-02') },
      ],
    },
    { IsTruncated: false, Contents: [{ Key: 'originales/b.png', Size: 200, LastModified: new Date('2026-01-03') }] },
  ];
  const { s3, calls } = fakeS3(async (cmd) => {
    assert.ok(cmd instanceof ListObjectsV2Command);
    return pages.shift();
  });
  const service = createImageService({ s3, config });

  const items = await service.listImages();

  assert.deepEqual(items.map((i) => i.key), ['originales/b.png', 'originales/a.jpg']);
  assert.equal(new URL(items[0].url).searchParams.get('X-Amz-Expires'), '900');
  assert.equal(calls[1].input.ContinuationToken, 'p2');
});

test('deleteImage elimina la clave válida y responde 404 si no existe', async () => {
  const { s3, calls } = fakeS3(async (cmd) => {
    if (cmd instanceof HeadObjectCommand) {
      if (cmd.input.Key.endsWith('fantasma.jpg')) {
        const err = new Error('NotFound');
        err.name = 'NotFound';
        throw err;
      }
      return {};
    }
    return {};
  });
  const service = createImageService({ s3, config });

  assert.deepEqual(await service.deleteImage('originales/1-ab-foto.jpg'), {
    deleted: true,
    key: 'originales/1-ab-foto.jpg',
  });
  assert.ok(calls.some((c) => c instanceof DeleteObjectCommand));

  await assert.rejects(service.deleteImage('originales/fantasma.jpg'), { status: 404 });
  await assert.rejects(service.deleteImage('../otro-bucket/secreto'), { status: 400 });
  await assert.rejects(service.deleteImage('miniaturas/foto.jpg'), { status: 400 });
});

test('verifyUpload acepta una imagen real y conserva el objeto', async () => {
  const { s3, calls } = fakeS3(async (cmd) => {
    if (cmd instanceof HeadObjectCommand) return { ContentLength: 1 * MB, ContentType: 'image/jpeg' };
    if (cmd instanceof GetObjectCommand) return { Body: { transformToByteArray: async () => JPEG } };
    return {};
  });
  const service = createImageService({ s3, config });

  const result = await service.verifyUpload('originales/1-ab-foto.jpg');

  assert.equal(result.verified, true);
  assert.equal(calls.some((c) => c instanceof DeleteObjectCommand), false);
});

test('verifyUpload elimina un ejecutable disfrazado de imagen', async () => {
  const { s3, calls } = fakeS3(async (cmd) => {
    if (cmd instanceof HeadObjectCommand) return { ContentLength: 1000, ContentType: 'image/png' };
    if (cmd instanceof GetObjectCommand) return { Body: { transformToByteArray: async () => EXE } };
    return {};
  });
  const service = createImageService({ s3, config });

  await assert.rejects(service.verifyUpload('originales/1-ab-virus.png'), { status: 422 });
  assert.equal(calls.some((c) => c instanceof DeleteObjectCommand), true);
});

test('verifyUpload elimina objetos que superan el tamaño máximo', async () => {
  const { s3, calls } = fakeS3(async (cmd) => {
    if (cmd instanceof HeadObjectCommand) return { ContentLength: 10 * MB, ContentType: 'image/jpeg' };
    return {};
  });
  const service = createImageService({ s3, config });

  await assert.rejects(service.verifyUpload('originales/1-ab-grande.jpg'), { status: 422 });
  assert.equal(calls.some((c) => c instanceof DeleteObjectCommand), true);
});
