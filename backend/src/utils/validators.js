const MAX_FILENAME_BASE = 80;
const MAX_KEY_LENGTH = 300;
const KEY_PATTERN = /^[A-Za-z0-9._\-/]+$/;

class ValidationError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.name = 'ValidationError';
    this.status = status;
  }
}

/**
 * Valida la solicitud de subida antes de firmar la URL.
 * Devuelve { contentType, sizeBytes } normalizados o lanza ValidationError.
 */
function validateUploadRequest(body, config) {
  const { filename, contentType, sizeBytes } = body || {};

  if (typeof filename !== 'string' || filename.trim() === '') {
    throw new ValidationError('El nombre del archivo es obligatorio');
  }
  if (!config.allowedTypes.includes(contentType)) {
    throw new ValidationError('Tipo de archivo no permitido');
  }
  if (!Number.isInteger(sizeBytes) || sizeBytes <= 0) {
    throw new ValidationError('El tamaño del archivo debe ser un entero positivo en bytes');
  }
  if (sizeBytes >= config.maxSizeMb * 1024 * 1024) {
    throw new ValidationError(
      `Archivo demasiado grande (debe pesar menos de ${config.maxSizeMb} MB)`,
      413,
    );
  }

  return { filename, contentType, sizeBytes };
}

/**
 * Elimina rutas y caracteres peligrosos del nombre y fuerza la extensión
 * que corresponde al tipo MIME declarado (evita "malware.exe" con image/png).
 */
function sanitizeFilename(filename, contentType, mimeToExt) {
  const ext = mimeToExt[contentType];
  const baseName = String(filename)
    .split(/[\\/]/)
    .pop()
    .replace(/\.[^.]*$/, '')
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-zA-Z0-9_-]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, MAX_FILENAME_BASE);

  return `${baseName || 'imagen'}.${ext}`;
}

/** Acepta solo claves bajo el prefijo permitido y sin recorridos de ruta. */
function assertValidKey(key, prefix) {
  const valid =
    typeof key === 'string' &&
    key.startsWith(prefix) &&
    key.length > prefix.length &&
    key.length <= MAX_KEY_LENGTH &&
    KEY_PATTERN.test(key) &&
    !key.includes('..') &&
    !key.includes('//');

  if (!valid) {
    throw new ValidationError('Clave de imagen inválida');
  }
  return key;
}

const TAG_VALUE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}$/;

/**
 * Valida las etiquetas de clasificación (proyecto, cliente). Solo se admiten
 * las claves de la lista blanca y valores cortos con caracteres seguros.
 * Los valores vacíos se descartan.
 */
function validateTags(raw, tagKeys) {
  if (raw === undefined || raw === null) return {};
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new ValidationError('Las etiquetas deben ser un objeto');
  }

  const tags = {};
  for (const [name, value] of Object.entries(raw)) {
    if (!tagKeys.includes(name)) {
      throw new ValidationError(`Etiqueta no permitida: ${name}`);
    }
    if (value === undefined || value === null || value === '') continue;
    if (typeof value !== 'string' || !TAG_VALUE_PATTERN.test(value.trim())) {
      throw new ValidationError(
        `Valor inválido para ${name}: usa letras, números, espacios, punto, guion o guion bajo (máximo 40)`,
      );
    }
    tags[name] = value.trim();
  }
  return tags;
}

/** Formato de la cabecera x-amz-tagging (consulta URL): clave=valor&clave=valor. */
function tagsToHeader(tags) {
  return Object.entries(tags)
    .map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(value)}`)
    .join('&');
}

/** Identifica el tipo real de imagen por sus magic bytes. */
function detectImageType(buffer) {
  if (!buffer || buffer.length < 12) return null;

  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) {
    return 'image/jpeg';
  }
  const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (pngSignature.every((byte, i) => buffer[i] === byte)) {
    return 'image/png';
  }
  if (
    buffer.toString('ascii', 0, 4) === 'RIFF' &&
    buffer.toString('ascii', 8, 12) === 'WEBP'
  ) {
    return 'image/webp';
  }
  return null;
}

module.exports = {
  ValidationError,
  validateUploadRequest,
  sanitizeFilename,
  assertValidKey,
  validateTags,
  tagsToHeader,
  detectImageType,
};
