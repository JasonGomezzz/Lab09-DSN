const crypto = require('crypto');
const {
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  DeleteObjectCommand,
  ListObjectsV2Command,
  GetObjectTaggingCommand,
} = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const {
  ValidationError,
  validateUploadRequest,
  sanitizeFilename,
  assertValidKey,
  validateTags,
  tagsToHeader,
  detectImageType,
} = require('../utils/validators');

/**
 * Lógica de negocio sobre S3. Recibe el cliente y la configuración para
 * poder probarla sin credenciales ni red.
 */
function createImageService({ s3, config }) {
  const { bucket, prefix, thumbPrefix } = config;

  async function createUploadUrl(body) {
    const { filename, contentType, sizeBytes } = validateUploadRequest(body, config);
    const tags = validateTags(body.tags, config.tagKeys);
    const tagging = tagsToHeader(tags);

    const safeName = sanitizeFilename(filename, contentType, config.mimeToExt);
    const key = `${prefix}${Date.now()}-${crypto.randomBytes(6).toString('hex')}-${safeName}`;

    // ContentLength y Content-Type quedan firmados: S3 rechaza el PUT si el
    // cuerpo no pesa lo declarado o si cambia el tipo. El cifrado SSE-S3 también
    // se firma, por lo que el cliente debe reenviar los encabezados devueltos.
    // Las etiquetas viajan firmadas en la propia URL (parámetro x-amz-tagging).
    const command = new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      ContentType: contentType,
      ContentLength: sizeBytes,
      ServerSideEncryption: 'AES256',
      ...(tagging && { Tagging: tagging }),
    });

    const uploadUrl = await getSignedUrl(s3, command, {
      expiresIn: config.uploadUrlExpires,
      signableHeaders: new Set(['content-type']),
    });

    return {
      uploadUrl,
      key,
      expiresIn: config.uploadUrlExpires,
      tags,
      headers: {
        'Content-Type': contentType,
        'x-amz-server-side-encryption': 'AES256',
      },
    };
  }

  async function listAll(listPrefix) {
    const objects = [];
    let ContinuationToken;

    do {
      const page = await s3.send(
        new ListObjectsV2Command({ Bucket: bucket, Prefix: listPrefix, ContinuationToken }),
      );
      objects.push(...(page.Contents || []));
      ContinuationToken = page.IsTruncated ? page.NextContinuationToken : undefined;
    } while (ContinuationToken);

    return objects.filter((obj) => obj.Key !== listPrefix && obj.Size > 0);
  }

  // Sin permiso s3:GetObjectTagging (política base del enunciado) la galería
  // sigue funcionando, solo que sin etiquetas.
  async function readTags(key) {
    try {
      const res = await s3.send(new GetObjectTaggingCommand({ Bucket: bucket, Key: key }));
      return Object.fromEntries((res.TagSet || []).map(({ Key, Value }) => [Key, Value]));
    } catch (err) {
      if (err.name === 'AccessDenied' || err.$metadata?.httpStatusCode === 403) return {};
      throw err;
    }
  }

  const thumbKeyFor = (key) => `${thumbPrefix}${key.slice(prefix.length)}`;

  async function listImages(rawFilter = {}) {
    const filter = validateTags(rawFilter, config.tagKeys);
    const [images, thumbs] = await Promise.all([listAll(prefix), listAll(thumbPrefix)]);
    const thumbKeys = new Set(thumbs.map((t) => t.Key));

    const items = await Promise.all(
      images.map(async (obj) => {
        const thumbKey = thumbKeyFor(obj.Key);
        const [tags, url, thumbUrl] = await Promise.all([
          readTags(obj.Key),
          getSignedUrl(s3, new GetObjectCommand({ Bucket: bucket, Key: obj.Key }), {
            expiresIn: config.viewUrlExpires,
          }),
          thumbKeys.has(thumbKey)
            ? getSignedUrl(s3, new GetObjectCommand({ Bucket: bucket, Key: thumbKey }), {
                expiresIn: config.viewUrlExpires,
              })
            : null,
        ]);
        return { key: obj.Key, size: obj.Size, lastModified: obj.LastModified, tags, url, thumbUrl };
      }),
    );

    return items
      .filter((item) => Object.entries(filter).every(([name, value]) => item.tags[name] === value))
      .sort((a, b) => new Date(b.lastModified) - new Date(a.lastModified));
  }

  async function exists(key) {
    try {
      await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
      return true;
    } catch (err) {
      if (err.name === 'NotFound' || err.$metadata?.httpStatusCode === 404) return false;
      throw err;
    }
  }

  async function deleteImage(rawKey) {
    const key = assertValidKey(rawKey, prefix);
    if (!(await exists(key))) {
      throw new ValidationError('La imagen no existe', 404);
    }
    await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
    // La miniatura (si existe) se elimina junto con el original; borrar una
    // clave inexistente no es un error en S3.
    await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: thumbKeyFor(key) }));
    return { deleted: true, key };
  }

  /**
   * Validación posterior a la carga: el navegador puede mentir sobre el tipo,
   * así que se comprueban tamaño y magic bytes del objeto ya almacenado.
   * Si no pasa, el objeto se elimina del bucket.
   */
  async function verifyUpload(rawKey) {
    const key = assertValidKey(rawKey, prefix);

    let head;
    try {
      head = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    } catch (err) {
      if (err.name === 'NotFound' || err.$metadata?.httpStatusCode === 404) {
        throw new ValidationError('La imagen no existe', 404);
      }
      throw err;
    }

    const maxBytes = config.maxSizeMb * 1024 * 1024;
    let reason = null;

    if (head.ContentLength >= maxBytes) {
      reason = 'El archivo almacenado supera el tamaño permitido';
    } else {
      const partial = await s3.send(
        new GetObjectCommand({ Bucket: bucket, Key: key, Range: 'bytes=0-15' }),
      );
      const bytes = Buffer.from(await partial.Body.transformToByteArray());
      const realType = detectImageType(bytes);

      if (!realType || !config.allowedTypes.includes(realType)) {
        reason = 'El contenido del archivo no es una imagen válida (jpeg, png o webp)';
      } else if (head.ContentType && head.ContentType !== realType) {
        reason = 'El tipo declarado no coincide con el contenido real del archivo';
      }
    }

    if (reason) {
      await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
      throw new ValidationError(`${reason}. El archivo fue eliminado.`, 422);
    }

    return { verified: true, key, size: head.ContentLength, contentType: head.ContentType };
  }

  return { createUploadUrl, listImages, deleteImage, verifyUpload };
}

module.exports = { createImageService };
