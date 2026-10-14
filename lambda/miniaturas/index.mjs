import { GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import sharp from 'sharp';

const PREFIJO_ORIGEN = 'originales/';
const PREFIJO_DESTINO = 'miniaturas/';
const TAMANO_MAXIMO = 10 * 1024 * 1024;
const ANCHO_POR_DEFECTO = 300;
const ANCHO_MINIMO = 16;
const ANCHO_MAXIMO = 2000;
const CALIDAD_JPEG = 80;

const FORMATOS = new Map([
  ['jpg', { formato: 'jpeg', contentType: 'image/jpeg' }],
  ['jpeg', { formato: 'jpeg', contentType: 'image/jpeg' }],
  ['png', { formato: 'png', contentType: 'image/png' }],
  ['webp', { formato: 'webp', contentType: 'image/webp' }],
]);

// Cliente único por contenedor: se reutiliza entre invocaciones.
const clienteS3 = new S3Client({});

export function decodificarClave(clave) {
  return decodeURIComponent(clave.replace(/\+/g, ' '));
}

export function claveMiniatura(claveOriginal) {
  return PREFIJO_DESTINO + claveOriginal.slice(PREFIJO_ORIGEN.length);
}

function extensionDe(clave) {
  const nombre = clave.slice(clave.lastIndexOf('/') + 1);
  const punto = nombre.lastIndexOf('.');
  return punto >= 0 ? nombre.slice(punto + 1).toLowerCase() : '';
}

export function esExtensionValida(clave) {
  return FORMATOS.has(extensionDe(clave));
}

export function obtenerAncho(env = process.env) {
  const texto = (env.THUMB_WIDTH ?? '').trim();
  if (texto === '') return ANCHO_POR_DEFECTO;
  const valor = Number(texto);
  if (!/^\d+$/.test(texto) || valor < ANCHO_MINIMO || valor > ANCHO_MAXIMO) {
    throw new Error(
      `THUMB_WIDTH inválido ("${texto}"): debe ser un entero entre ${ANCHO_MINIMO} y ${ANCHO_MAXIMO}`,
    );
  }
  return valor;
}

// Los metadatos de S3 viajan en cabeceras HTTP y solo admiten ASCII imprimible.
function valorMetadato(clave) {
  return /^[\x20-\x7E]*$/.test(clave) ? clave : encodeURI(clave);
}

async function leerCuerpo(cuerpo) {
  if (!cuerpo) throw new Error('la respuesta de S3 no incluye cuerpo');
  if (typeof cuerpo.transformToByteArray === 'function') {
    return Buffer.from(await cuerpo.transformToByteArray());
  }
  const partes = [];
  for await (const parte of cuerpo) partes.push(Buffer.from(parte));
  return Buffer.concat(partes);
}

function generarMiniatura(buffer, formato, ancho) {
  const imagen = sharp(buffer).rotate().resize({ width: ancho, withoutEnlargement: true });
  switch (formato) {
    case 'jpeg':
      return imagen.jpeg({ quality: CALIDAD_JPEG }).toBuffer();
    case 'png':
      return imagen.png().toBuffer();
    case 'webp':
      return imagen.webp().toBuffer();
    default:
      throw new Error(`formato no soportado: ${formato}`);
  }
}

export async function procesarRegistro(registro, s3 = clienteS3, { ancho = obtenerAncho() } = {}) {
  const bucket = registro?.s3?.bucket?.name;
  const claveCodificada = registro?.s3?.object?.key;
  if (!bucket || typeof claveCodificada !== 'string') {
    throw new Error('el registro no incluye bucket o clave de S3');
  }

  const clave = decodificarClave(claveCodificada);
  const omitir = (motivo) => {
    console.log(`Omitida "${clave}": ${motivo}`);
    return { estado: 'omitida', clave, motivo };
  };

  // La salida va a miniaturas/, pero esta guarda evita recursión si el filtro del evento se amplía.
  if (!clave.startsWith(PREFIJO_ORIGEN)) {
    return omitir(`no empieza con ${PREFIJO_ORIGEN}`);
  }
  if (clave.endsWith('/')) {
    return omitir('es un directorio vacío');
  }
  if (!esExtensionValida(clave)) {
    return omitir('extensión no admitida (solo jpg, jpeg, png y webp)');
  }
  const tamano = registro.s3.object.size;
  if (tamano > TAMANO_MAXIMO) {
    return omitir(`supera el límite de 10 MB (${tamano} bytes)`);
  }

  const { formato, contentType } = FORMATOS.get(extensionDe(clave));
  const original = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: clave }));
  const buffer = await leerCuerpo(original.Body);
  const miniatura = await generarMiniatura(buffer, formato, ancho);

  const destino = claveMiniatura(clave);
  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: destino,
      Body: miniatura,
      ContentType: contentType,
      ServerSideEncryption: 'AES256',
      Metadata: { origen: valorMetadato(clave) },
    }),
  );

  console.log(`Miniatura generada: "${clave}" -> "${destino}" (${miniatura.length} bytes, ancho máximo ${ancho})`);
  return { estado: 'procesada', clave, destino, bytes: miniatura.length };
}

function claveParaLog(registro) {
  const clave = registro?.s3?.object?.key;
  if (typeof clave !== 'string') return '(sin clave)';
  try {
    return decodificarClave(clave);
  } catch {
    return clave;
  }
}

export function crearHandler(s3 = clienteS3) {
  return async function handler(event) {
    const registros = event?.Records ?? [];
    const resumen = { procesadas: 0, omitidas: 0, errores: 0 };
    if (registros.length === 0) {
      console.log('El evento no contiene registros; no hay nada que procesar');
      return resumen;
    }

    const ancho = obtenerAncho();
    for (const registro of registros) {
      try {
        const resultado = await procesarRegistro(registro, s3, { ancho });
        if (resultado.estado === 'procesada') resumen.procesadas += 1;
        else resumen.omitidas += 1;
      } catch (error) {
        resumen.errores += 1;
        console.error(`Error al procesar "${claveParaLog(registro)}": ${error?.message ?? error}`);
      }
    }

    console.log(`Resumen: ${JSON.stringify(resumen)}`);
    if (resumen.errores > 0) {
      const fallo = new Error(
        `fallaron ${resumen.errores} de ${registros.length} registros; se reintentará la invocación`,
      );
      fallo.resumen = resumen;
      throw fallo;
    }
    return resumen;
  };
}

export const handler = crearHandler();
