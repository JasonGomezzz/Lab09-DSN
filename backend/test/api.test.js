const test = require('node:test');
const assert = require('node:assert/strict');
const {
  ListObjectsV2Command,
  HeadObjectCommand,
  GetObjectCommand,
} = require('@aws-sdk/client-s3');
const { loadConfig } = require('../src/config');
const { createS3Client } = require('../src/s3Client');
const { createImageService } = require('../src/services/imageService');
const { createApp } = require('../src/app');

const MB = 1024 * 1024;
const EXE = Uint8Array.from([0x4d, 0x5a, 0x90, 0, 3, 0, 0, 0, 4, 0, 0, 0, 0xff, 0xff, 0, 0]);
const silentLogger = { error() {} };

/** Levanta la API real sobre un puerto efímero con un S3 simulado. */
async function startServer(envOverrides = {}, handler) {
  const config = loadConfig({ S3_BUCKET: 'lab-imagenes-prueba-20260101', ...envOverrides });
  const s3 = createS3Client(config, {
    credentials: { accessKeyId: 'TESTKEYID', secretAccessKey: 'testsecret' },
  });
  s3.send = handler || (async (cmd) => {
    if (cmd instanceof ListObjectsV2Command) {
      return {
        Contents: [{ Key: 'originales/1-ab-foto.jpg', Size: 1234, LastModified: new Date('2026-01-01') }],
      };
    }
    if (cmd instanceof HeadObjectCommand) {
      if (cmd.input.Key.endsWith('fantasma.jpg')) {
        const err = new Error('NotFound');
        err.name = 'NotFound';
        throw err;
      }
      return { ContentLength: 1000, ContentType: 'image/png' };
    }
    if (cmd instanceof GetObjectCommand) {
      return { Body: { transformToByteArray: async () => EXE } };
    }
    return {};
  });

  const app = createApp({ imageService: createImageService({ s3, config }), config, logger: silentLogger });
  const server = await new Promise((resolve) => {
    const s = app.listen(0, () => resolve(s));
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, close: () => new Promise((resolve) => server.close(resolve)) };
}

const postJson = (url, body, headers = {}) =>
  fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });

test('POST /api/upload-url devuelve URL prefirmada, clave y encabezados', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const res = await postJson(`${base}/api/upload-url`, {
    filename: 'foto.jpg',
    contentType: 'image/jpeg',
    sizeBytes: 1 * MB,
  });
  const body = await res.json();

  assert.equal(res.status, 200);
  assert.match(body.key, /^originales\//);
  assert.match(body.uploadUrl, /^https:\/\/lab-imagenes-prueba-20260101\.s3\./);
  assert.equal(body.headers['x-amz-server-side-encryption'], 'AES256');
});

test('POST /api/upload-url rechaza pdf (400), 10 MB (413) y JSON roto (400)', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const pdf = await postJson(`${base}/api/upload-url`, {
    filename: 'doc.pdf',
    contentType: 'application/pdf',
    sizeBytes: 1000,
  });
  assert.equal(pdf.status, 400);
  assert.match((await pdf.json()).error, /no permitido/);

  const big = await postJson(`${base}/api/upload-url`, {
    filename: 'grande.jpg',
    contentType: 'image/jpeg',
    sizeBytes: 10 * MB,
  });
  assert.equal(big.status, 413);

  const broken = await fetch(`${base}/api/upload-url`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: '{no es json',
  });
  assert.equal(broken.status, 400);
});

test('GET /api/images lista imágenes con URL de visualización', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const res = await fetch(`${base}/api/images`);
  const items = await res.json();

  assert.equal(res.status, 200);
  assert.equal(items.length, 1);
  assert.equal(items[0].key, 'originales/1-ab-foto.jpg');
  assert.match(items[0].url, /X-Amz-Expires=900/);
});

test('DELETE /api/images/:key elimina, y valida clave y existencia', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const ok = await fetch(`${base}/api/images/${encodeURIComponent('originales/1-ab-foto.jpg')}`, {
    method: 'DELETE',
  });
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { deleted: true, key: 'originales/1-ab-foto.jpg' });

  const missing = await fetch(`${base}/api/images/${encodeURIComponent('originales/fantasma.jpg')}`, {
    method: 'DELETE',
  });
  assert.equal(missing.status, 404);

  const outside = await fetch(`${base}/api/images/${encodeURIComponent('miniaturas/foto.jpg')}`, {
    method: 'DELETE',
  });
  assert.equal(outside.status, 400);

  const traversal = await fetch(`${base}/api/images/${encodeURIComponent('originales/../secreto')}`, {
    method: 'DELETE',
  });
  assert.equal(traversal.status, 400);
});

test('POST /api/verify borra y rechaza (422) un ejecutable subido como png', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const res = await postJson(`${base}/api/verify`, { key: 'originales/1-ab-virus.png' });
  const body = await res.json();

  assert.equal(res.status, 422);
  assert.match(body.error, /eliminado/);
});

test('POST /api/verify exige una clave', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const res = await postJson(`${base}/api/verify`, {});
  assert.equal(res.status, 400);
});

test('CORS acepta orígenes de la lista blanca y rechaza el resto', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const allowed = await fetch(`${base}/api/images`, { headers: { Origin: 'http://localhost:3000' } });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'http://localhost:3000');

  const denied = await fetch(`${base}/api/images`, { headers: { Origin: 'https://sitio-malicioso.example' } });
  assert.equal(denied.status, 403);
});

test('rate limiting corta las solicitudes de URL de subida con 429', async (t) => {
  const { base, close } = await startServer({ RATE_LIMIT_PER_MINUTE: '2' });
  t.after(close);

  const body = { filename: 'a.jpg', contentType: 'image/jpeg', sizeBytes: 1000 };
  const statuses = [];
  for (let i = 0; i < 3; i += 1) {
    statuses.push((await postJson(`${base}/api/upload-url`, body)).status);
  }

  assert.deepEqual(statuses, [200, 200, 429]);
});

test('errores inesperados de S3 responden 500 sin filtrar detalles', async (t) => {
  const { base, close } = await startServer({}, async () => {
    throw new Error('AccessDenied: arn:aws:iam::123456789012:user/secreto');
  });
  t.after(close);

  const res = await fetch(`${base}/api/images`);
  const body = await res.json();

  assert.equal(res.status, 500);
  assert.equal(body.error, 'Error interno del servidor');
});

test('rutas /api desconocidas responden 404 en JSON', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const res = await fetch(`${base}/api/no-existe`);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: 'Ruta no encontrada' });
});

test('POST /api/upload-url acepta etiquetas y rechaza claves no permitidas', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const ok = await postJson(`${base}/api/upload-url`, {
    filename: 'foto.jpg',
    contentType: 'image/jpeg',
    sizeBytes: 1000,
    tags: { proyecto: 'lab09', cliente: 'acme' },
  });
  const body = await ok.json();
  assert.equal(ok.status, 200);
  assert.deepEqual(body.tags, { proyecto: 'lab09', cliente: 'acme' });
  assert.match(body.uploadUrl, /x-amz-tagging=/);

  const mal = await postJson(`${base}/api/upload-url`, {
    filename: 'foto.jpg',
    contentType: 'image/jpeg',
    sizeBytes: 1000,
    tags: { admin: 'si' },
  });
  assert.equal(mal.status, 400);
});

test('GET /api/images valida los filtros de la consulta', async (t) => {
  const { base, close } = await startServer();
  t.after(close);

  const filtrado = await fetch(`${base}/api/images?proyecto=lab09`);
  assert.equal(filtrado.status, 200);
  assert.deepEqual(await filtrado.json(), []);

  const invalido = await fetch(`${base}/api/images?proyecto=a%26cliente%3Db`);
  assert.equal(invalido.status, 400);
});
