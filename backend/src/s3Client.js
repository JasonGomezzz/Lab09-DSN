const { S3Client } = require('@aws-sdk/client-s3');

/**
 * Cliente S3 con la cadena de credenciales por defecto del SDK: variables de
 * entorno, perfil (AWS_PROFILE), SSO o IAM Role del recurso. Las claves nunca
 * se leen ni se pasan manualmente desde este código.
 *
 * requestChecksumCalculation WHEN_REQUIRED evita que el SDK (>= 3.729) agregue
 * a la URL prefirmada el checksum CRC32 de un cuerpo vacío, que S3 rechazaría
 * al recibir la imagen real.
 */
function createS3Client(config, overrides = {}) {
  return new S3Client({
    region: config.region,
    requestChecksumCalculation: 'WHEN_REQUIRED',
    ...overrides,
  });
}

module.exports = { createS3Client };
