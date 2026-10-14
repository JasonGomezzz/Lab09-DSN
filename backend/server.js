const { loadConfig } = require('./src/config');
const { createS3Client } = require('./src/s3Client');
const { createImageService } = require('./src/services/imageService');
const { createApp } = require('./src/app');

let config;
try {
  config = loadConfig();
} catch (err) {
  console.error(`Configuración inválida: ${err.message}`);
  process.exit(1);
}

const s3 = createS3Client(config);
const imageService = createImageService({ s3, config });
const app = createApp({ imageService, config });

app.listen(config.port, () => {
  console.log(`API escuchando en http://localhost:${config.port} (bucket: ${config.bucket})`);
});
