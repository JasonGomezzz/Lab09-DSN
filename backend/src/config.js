require('dotenv').config({ quiet: true });

const MIME_TO_EXT = Object.freeze({
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
});

function toPositiveInt(value, fallback, name) {
  if (value === undefined || value === '') return fallback;
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`La variable ${name} debe ser un entero positivo (valor: "${value}")`);
  }
  return n;
}

function loadConfig(env = process.env) {
  const bucket = (env.S3_BUCKET || '').trim();
  if (!bucket || bucket.includes('<')) {
    throw new Error('Falta S3_BUCKET: define el nombre real del bucket en backend/.env');
  }

  return Object.freeze({
    region: env.AWS_REGION || 'us-east-1',
    bucket,
    port: toPositiveInt(env.PORT, 3000, 'PORT'),
    corsOrigins: (env.CORS_ORIGINS || 'http://localhost:3000,http://localhost:8080')
      .split(',')
      .map((o) => o.trim())
      .filter(Boolean),
    uploadUrlExpires: toPositiveInt(env.UPLOAD_URL_EXPIRES, 300, 'UPLOAD_URL_EXPIRES'),
    viewUrlExpires: toPositiveInt(env.VIEW_URL_EXPIRES, 900, 'VIEW_URL_EXPIRES'),
    maxSizeMb: toPositiveInt(env.MAX_SIZE_MB, 5, 'MAX_SIZE_MB'),
    rateLimitPerMinute: toPositiveInt(env.RATE_LIMIT_PER_MINUTE, 30, 'RATE_LIMIT_PER_MINUTE'),
    allowedTypes: Object.freeze(Object.keys(MIME_TO_EXT)),
    mimeToExt: MIME_TO_EXT,
    prefix: 'originales/',
    thumbPrefix: 'miniaturas/',
    tagKeys: Object.freeze(['proyecto', 'cliente']),
  });
}

module.exports = { loadConfig, MIME_TO_EXT };
