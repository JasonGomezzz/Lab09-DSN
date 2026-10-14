const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig } = require('../src/config');
const {
  ValidationError,
  validateUploadRequest,
  sanitizeFilename,
  assertValidKey,
  detectImageType,
} = require('../src/utils/validators');

const config = loadConfig({ S3_BUCKET: 'lab-imagenes-prueba-20260101' });
const MB = 1024 * 1024;

test('acepta jpeg, png y webp dentro del límite', () => {
  for (const contentType of ['image/jpeg', 'image/png', 'image/webp']) {
    const r = validateUploadRequest({ filename: 'a.img', contentType, sizeBytes: 1 * MB }, config);
    assert.equal(r.contentType, contentType);
  }
});

test('rechaza tipos no permitidos (pdf, exe, svg)', () => {
  for (const contentType of ['application/pdf', 'application/x-msdownload', 'image/svg+xml']) {
    assert.throws(
      () => validateUploadRequest({ filename: 'a', contentType, sizeBytes: 10 }, config),
      (e) => e instanceof ValidationError && e.status === 400,
    );
  }
});

test('rechaza archivos de 10 MB con 413', () => {
  assert.throws(
    () => validateUploadRequest({ filename: 'a.jpg', contentType: 'image/jpeg', sizeBytes: 10 * MB }, config),
    (e) => e.status === 413,
  );
});

test('el límite es estricto: exactamente 5 MB se rechaza y un byte menos se acepta', () => {
  const limite = 5 * MB;
  assert.throws(
    () => validateUploadRequest({ filename: 'a.jpg', contentType: 'image/jpeg', sizeBytes: limite }, config),
    (e) => e.status === 413,
  );
  const r = validateUploadRequest(
    { filename: 'a.jpg', contentType: 'image/jpeg', sizeBytes: limite - 1 },
    config,
  );
  assert.equal(r.sizeBytes, limite - 1);
});

test('rechaza tamaños ausentes, negativos o no numéricos', () => {
  for (const sizeBytes of [undefined, 0, -5, '100', 1.5, NaN]) {
    assert.throws(
      () => validateUploadRequest({ filename: 'a.jpg', contentType: 'image/jpeg', sizeBytes }, config),
      ValidationError,
    );
  }
});

test('rechaza filename ausente o vacío', () => {
  assert.throws(
    () => validateUploadRequest({ contentType: 'image/jpeg', sizeBytes: 10 }, config),
    ValidationError,
  );
  assert.throws(
    () => validateUploadRequest({ filename: '  ', contentType: 'image/jpeg', sizeBytes: 10 }, config),
    ValidationError,
  );
});

test('sanitizeFilename quita rutas, caracteres raros y fuerza la extensión del MIME', () => {
  const ext = config.mimeToExt;
  assert.equal(sanitizeFilename('../../etc/passwd', 'image/png', ext), 'passwd.png');
  assert.equal(sanitizeFilename('C:\\fotos\\mi foto (1).JPG', 'image/jpeg', ext), 'mi_foto_1.jpg');
  assert.equal(sanitizeFilename('virus.exe', 'image/png', ext), 'virus.png');
  assert.equal(sanitizeFilename('niño café.webp', 'image/webp', ext), 'nino_cafe.webp');
  assert.equal(sanitizeFilename('***', 'image/png', ext), 'imagen.png');
  assert.ok(sanitizeFilename('a'.repeat(500) + '.jpg', 'image/jpeg', ext).length <= 84);
});

test('assertValidKey solo admite claves dentro de originales/', () => {
  assert.equal(assertValidKey('originales/1-ab-foto.jpg', 'originales/'), 'originales/1-ab-foto.jpg');
  for (const bad of [
    'miniaturas/foto.jpg',
    'originales/../secreto.txt',
    '/originales/foto.jpg',
    'originales/',
    'originales//foto.jpg',
    'originales/foto con espacio.jpg',
    'originales/<script>.jpg',
    undefined,
    42,
  ]) {
    assert.throws(() => assertValidKey(bad, 'originales/'), ValidationError, String(bad));
  }
});

test('detectImageType reconoce magic bytes y rechaza ejecutables', () => {
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1]);
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]);
  const webp = Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WEBP')]);
  const exe = Buffer.from('MZ\x90\x00\x03\x00\x00\x00\x04\x00\x00\x00', 'binary');

  assert.equal(detectImageType(jpeg), 'image/jpeg');
  assert.equal(detectImageType(png), 'image/png');
  assert.equal(detectImageType(webp), 'image/webp');
  assert.equal(detectImageType(exe), null);
  assert.equal(detectImageType(Buffer.alloc(3)), null);
  assert.equal(detectImageType(null), null);
});
