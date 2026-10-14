import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { before, beforeEach, describe, it, mock } from 'node:test';
import { GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import sharp from 'sharp';

import {
  claveMiniatura,
  crearHandler,
  decodificarClave,
  esExtensionValida,
  obtenerAncho,
  procesarRegistro,
} from '../index.mjs';

const BUCKET = 'bucket-ejemplo';
const DIEZ_MB = 10 * 1024 * 1024;

const fondo = { r: 30, g: 120, b: 200 };
const crear = (formato, ancho = 800, alto = 600) =>
  sharp({ create: { width: ancho, height: alto, channels: 3, background: fondo } })
    [formato]()
    .toBuffer();

function registro(claveCodificada, size = 1000, bucket = BUCKET) {
  return { s3: { bucket: { name: bucket }, object: { key: claveCodificada, size } } };
}

// Cliente S3 falso: sirve objetos desde un mapa y registra lo que se escribe.
function crearS3Falso({ objetos = {}, fallosGet = [], cuerpoComoStream = false } = {}) {
  const gets = [];
  const puts = [];
  return {
    gets,
    puts,
    async send(comando) {
      if (comando instanceof GetObjectCommand) {
        const { Bucket, Key } = comando.input;
        gets.push({ Bucket, Key });
        if (fallosGet.includes(Key)) throw new Error('AccessDenied simulado');
        const datos = objetos[Key];
        if (!datos) throw new Error(`NoSuchKey: ${Key}`);
        const Body = cuerpoComoStream
          ? Readable.from([datos.subarray(0, 100), datos.subarray(100)])
          : { transformToByteArray: async () => new Uint8Array(datos) };
        return { Body };
      }
      if (comando instanceof PutObjectCommand) {
        puts.push(comando.input);
        return {};
      }
      throw new Error('comando no soportado por el cliente falso');
    },
  };
}

// Se silencia el log de la función para no ensuciar la salida de las pruebas.
mock.method(console, 'log', () => {});
mock.method(console, 'error', () => {});
const limpiarRegistros = () => console.error.mock.resetCalls();

describe('funciones puras', () => {
  it('claveMiniatura cambia el prefijo y conserva el resto de la ruta', () => {
    assert.equal(claveMiniatura('originales/foto.png'), 'miniaturas/foto.png');
    assert.equal(claveMiniatura('originales/2024/viaje/a b.jpg'), 'miniaturas/2024/viaje/a b.jpg');
  });

  it('decodificarClave convierte "+" en espacio y decodifica %XX', () => {
    assert.equal(decodificarClave('originales/mi+foto%20nueva.png'), 'originales/mi foto nueva.png');
    assert.equal(decodificarClave('originales/a%2Bb.png'), 'originales/a+b.png');
    assert.equal(decodificarClave('originales/ni%C3%B1o.jpg'), 'originales/niño.jpg');
  });

  it('esExtensionValida acepta jpg, jpeg, png y webp sin distinguir mayúsculas', () => {
    for (const clave of ['a.jpg', 'a.jpeg', 'a.png', 'a.webp', 'a.JPG', 'dir.v2/a.PNG']) {
      assert.equal(esExtensionValida(clave), true, clave);
    }
    for (const clave of ['a.gif', 'a.txt', 'a', 'a.jpg.bak', 'originales.png/', 'dir.jpg/archivo']) {
      assert.equal(esExtensionValida(clave), false, clave);
    }
  });

  it('obtenerAncho usa 300 por defecto y valida el rango', () => {
    assert.equal(obtenerAncho({}), 300);
    assert.equal(obtenerAncho({ THUMB_WIDTH: '' }), 300);
    assert.equal(obtenerAncho({ THUMB_WIDTH: '16' }), 16);
    assert.equal(obtenerAncho({ THUMB_WIDTH: ' 2000 ' }), 2000);
    for (const invalido of ['15', '2001', '0', '-5', 'abc', '300.5', '1e3']) {
      assert.throws(() => obtenerAncho({ THUMB_WIDTH: invalido }), /THUMB_WIDTH/, invalido);
    }
  });
});

describe('procesarRegistro', () => {
  let png;
  let jpeg;
  let webp;

  before(async () => {
    png = await crear('png');
    jpeg = await crear('jpeg');
    webp = await crear('webp');
  });

  beforeEach(limpiarRegistros);

  it('genera la miniatura PNG con clave, tipo y cifrado correctos', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/foto.png': png } });
    const resultado = await procesarRegistro(registro('originales/foto.png', png.length), s3);

    assert.equal(resultado.estado, 'procesada');
    assert.equal(s3.gets.length, 1);
    assert.deepEqual(s3.gets[0], { Bucket: BUCKET, Key: 'originales/foto.png' });
    assert.equal(s3.puts.length, 1);

    const put = s3.puts[0];
    assert.equal(put.Bucket, BUCKET);
    assert.equal(put.Key, 'miniaturas/foto.png');
    assert.equal(put.ContentType, 'image/png');
    assert.equal(put.ServerSideEncryption, 'AES256');
    assert.deepEqual(put.Metadata, { origen: 'originales/foto.png' });

    const meta = await sharp(put.Body).metadata();
    assert.equal(meta.format, 'png');
    assert.equal(meta.width, 300);
    assert.equal(meta.height, 225);
  });

  it('conserva el formato JPEG', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/a/foto.jpg': jpeg } });
    await procesarRegistro(registro('originales/a/foto.jpg', jpeg.length), s3);

    const put = s3.puts[0];
    assert.equal(put.Key, 'miniaturas/a/foto.jpg');
    assert.equal(put.ContentType, 'image/jpeg');
    const meta = await sharp(put.Body).metadata();
    assert.equal(meta.format, 'jpeg');
    assert.ok(meta.width <= 300);
  });

  it('trata .jpeg como JPEG y conserva WebP', async () => {
    const s3 = crearS3Falso({
      objetos: { 'originales/b.jpeg': jpeg, 'originales/c.webp': webp },
    });
    await procesarRegistro(registro('originales/b.jpeg'), s3);
    await procesarRegistro(registro('originales/c.webp'), s3);

    const [jpegPut, webpPut] = s3.puts;
    assert.equal(jpegPut.ContentType, 'image/jpeg');
    assert.equal((await sharp(jpegPut.Body).metadata()).format, 'jpeg');
    assert.equal(webpPut.ContentType, 'image/webp');
    assert.equal(webpPut.Key, 'miniaturas/c.webp');
    const metaWebp = await sharp(webpPut.Body).metadata();
    assert.equal(metaWebp.format, 'webp');
    assert.ok(metaWebp.width <= 300);
  });

  it('no agranda las imágenes más pequeñas que el ancho', async () => {
    const pequena = await crear('png', 100, 80);
    const s3 = crearS3Falso({ objetos: { 'originales/pequena.png': pequena } });
    await procesarRegistro(registro('originales/pequena.png'), s3);

    const meta = await sharp(s3.puts[0].Body).metadata();
    assert.equal(meta.width, 100);
    assert.equal(meta.height, 80);
  });

  it('respeta la orientación EXIF', async () => {
    // 800x400 almacenado con orientación 6: se muestra girada, como 400x800.
    const girada = await sharp({
      create: { width: 800, height: 400, channels: 3, background: fondo },
    })
      .jpeg()
      .withMetadata({ orientation: 6 })
      .toBuffer();
    const s3 = crearS3Falso({ objetos: { 'originales/girada.jpg': girada } });
    await procesarRegistro(registro('originales/girada.jpg'), s3);

    const meta = await sharp(s3.puts[0].Body).metadata();
    assert.equal(meta.width, 300);
    assert.equal(meta.height, 600);
  });

  it('usa el ancho recibido como opción', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/foto.png': png } });
    await procesarRegistro(registro('originales/foto.png'), s3, { ancho: 120 });
    assert.equal((await sharp(s3.puts[0].Body).metadata()).width, 120);
  });

  it('decodifica "+" y %XX en la clave del evento', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/mi foto nueva 2.png': png } });
    const resultado = await procesarRegistro(
      registro('originales/mi+foto%20nueva+2.png', png.length),
      s3,
    );

    assert.equal(resultado.estado, 'procesada');
    assert.equal(s3.gets[0].Key, 'originales/mi foto nueva 2.png');
    assert.equal(s3.puts[0].Key, 'miniaturas/mi foto nueva 2.png');
    assert.equal(s3.puts[0].Metadata.origen, 'originales/mi foto nueva 2.png');
  });

  it('codifica en los metadatos las claves con caracteres no ASCII', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/año nuevo.png': png } });
    await procesarRegistro(registro('originales/a%C3%B1o+nuevo.png'), s3);

    assert.equal(s3.gets[0].Key, 'originales/año nuevo.png');
    assert.equal(s3.puts[0].Key, 'miniaturas/año nuevo.png');
    assert.equal(s3.puts[0].Metadata.origen, 'originales/a%C3%B1o%20nuevo.png');
  });

  it('lee cuerpos que vienen como stream', async () => {
    const s3 = crearS3Falso({
      objetos: { 'originales/foto.png': png },
      cuerpoComoStream: true,
    });
    await procesarRegistro(registro('originales/foto.png'), s3);
    assert.equal((await sharp(s3.puts[0].Body).metadata()).width, 300);
  });

  it('omite claves fuera de originales/ sin tocar S3', async () => {
    const s3 = crearS3Falso();
    for (const clave of ['miniaturas/foto.png', 'otra/foto.png', 'foto.png', 'xoriginales/foto.png']) {
      const resultado = await procesarRegistro(registro(clave), s3);
      assert.equal(resultado.estado, 'omitida', clave);
    }
    assert.equal(s3.gets.length, 0);
    assert.equal(s3.puts.length, 0);
  });

  it('omite el directorio vacío originales/', async () => {
    const s3 = crearS3Falso();
    const resultado = await procesarRegistro(registro('originales/', 0), s3);
    assert.equal(resultado.estado, 'omitida');
    assert.match(resultado.motivo, /directorio/);
    assert.equal((await procesarRegistro(registro('originales/sub.png/', 0), s3)).estado, 'omitida');
    assert.equal(s3.gets.length, 0);
  });

  it('omite extensiones no válidas', async () => {
    const s3 = crearS3Falso();
    for (const clave of [
      'originales/animacion.gif',
      'originales/notas.txt',
      'originales/documento.pdf',
      'originales/sin_extension',
    ]) {
      const resultado = await procesarRegistro(registro(clave), s3);
      assert.equal(resultado.estado, 'omitida', clave);
      assert.match(resultado.motivo, /extensión/);
    }
    assert.equal(s3.gets.length, 0);
    assert.equal(s3.puts.length, 0);
  });

  it('omite objetos de más de 10 MB y acepta exactamente 10 MB', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/justo.png': png } });

    const grande = await procesarRegistro(registro('originales/enorme.png', DIEZ_MB + 1), s3);
    assert.equal(grande.estado, 'omitida');
    assert.match(grande.motivo, /10 MB/);
    assert.equal(s3.gets.length, 0);

    const justo = await procesarRegistro(registro('originales/justo.png', DIEZ_MB), s3);
    assert.equal(justo.estado, 'procesada');
    assert.equal(s3.puts.length, 1);
  });

  it('propaga el error si el objeto no es una imagen válida', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/rota.png': Buffer.from('no es una imagen') } });
    await assert.rejects(procesarRegistro(registro('originales/rota.png'), s3));
    assert.equal(s3.puts.length, 0);
  });
});

describe('handler', () => {
  let png;
  let jpeg;

  before(async () => {
    png = await crear('png');
    jpeg = await crear('jpeg');
  });

  beforeEach(limpiarRegistros);

  it('devuelve el resumen con procesadas y omitidas', async () => {
    const s3 = crearS3Falso({
      objetos: { 'originales/uno.png': png, 'originales/dos.jpg': jpeg },
    });
    const handler = crearHandler(s3);
    const resumen = await handler({
      Records: [
        registro('originales/uno.png'),
        registro('originales/dos.jpg'),
        registro('originales/', 0),
        registro('originales/nota.txt'),
        registro('miniaturas/uno.png'),
      ],
    });

    assert.deepEqual(resumen, { procesadas: 2, omitidas: 3, errores: 0 });
    assert.deepEqual(
      s3.puts.map((p) => p.Key),
      ['miniaturas/uno.png', 'miniaturas/dos.jpg'],
    );
  });

  it('un evento sin registros no hace nada', async () => {
    const s3 = crearS3Falso();
    const handler = crearHandler(s3);
    assert.deepEqual(await handler({ Event: 's3:TestEvent' }), {
      procesadas: 0,
      omitidas: 0,
      errores: 0,
    });
    assert.equal(s3.gets.length, 0);
  });

  it('un error en un registro no impide los demás, pero el handler lanza al final', async () => {
    const s3 = crearS3Falso({
      objetos: { 'originales/primero.png': png, 'originales/tercero.jpg': jpeg },
      fallosGet: ['originales/segundo.png'],
    });
    const handler = crearHandler(s3);

    await assert.rejects(
      handler({
        Records: [
          registro('originales/primero.png'),
          registro('originales/segundo.png'),
          registro('originales/tercero.jpg'),
        ],
      }),
      (error) => {
        assert.match(error.message, /1 de 3/);
        assert.deepEqual(error.resumen, { procesadas: 2, omitidas: 0, errores: 1 });
        return true;
      },
    );

    assert.deepEqual(
      s3.puts.map((p) => p.Key),
      ['miniaturas/primero.png', 'miniaturas/tercero.jpg'],
    );
    assert.equal(console.error.mock.callCount(), 1);
    assert.match(console.error.mock.calls[0].arguments[0], /originales\/segundo\.png/);
  });

  it('un registro con clave mal codificada cuenta como error y sigue con el resto', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/bien.png': png } });
    const handler = crearHandler(s3);

    await assert.rejects(
      handler({ Records: [registro('originales/mal%E0%A4%A.png'), registro('originales/bien.png')] }),
    );
    assert.deepEqual(
      s3.puts.map((p) => p.Key),
      ['miniaturas/bien.png'],
    );
  });

  it('toma el ancho de THUMB_WIDTH', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/foto.png': png } });
    const handler = crearHandler(s3);
    const anterior = process.env.THUMB_WIDTH;
    process.env.THUMB_WIDTH = '150';
    try {
      await handler({ Records: [registro('originales/foto.png')] });
    } finally {
      if (anterior === undefined) delete process.env.THUMB_WIDTH;
      else process.env.THUMB_WIDTH = anterior;
    }
    assert.equal((await sharp(s3.puts[0].Body).metadata()).width, 150);
  });

  it('rechaza un THUMB_WIDTH inválido sin procesar nada', async () => {
    const s3 = crearS3Falso({ objetos: { 'originales/foto.png': png } });
    const handler = crearHandler(s3);
    const anterior = process.env.THUMB_WIDTH;
    process.env.THUMB_WIDTH = '5000';
    try {
      await assert.rejects(handler({ Records: [registro('originales/foto.png')] }), /THUMB_WIDTH/);
    } finally {
      if (anterior === undefined) delete process.env.THUMB_WIDTH;
      else process.env.THUMB_WIDTH = anterior;
    }
    assert.equal(s3.gets.length, 0);
  });
});
