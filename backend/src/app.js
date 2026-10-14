const path = require('path');
const express = require('express');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const { createImagesRouter } = require('./routes/images');
const { ValidationError } = require('./utils/validators');

const FRONTEND_DIR = path.join(__dirname, '..', '..', 'frontend');

function createApp({ imageService, config, logger = console }) {
  const app = express();
  app.disable('x-powered-by');

  app.use(
    cors({
      origin(origin, callback) {
        // Sin Origin: curl, pruebas o misma-origen. Con Origin: lista blanca.
        if (!origin || config.corsOrigins.includes(origin)) return callback(null, true);
        return callback(new ValidationError('Origen no permitido por CORS', 403));
      },
    }),
  );
  app.use(express.json({ limit: '10kb' }));

  const uploadLimiter = rateLimit({
    windowMs: 60 * 1000,
    limit: config.rateLimitPerMinute,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: { error: 'Demasiadas solicitudes de subida, intenta de nuevo en un minuto' },
  });

  app.get('/health', (req, res) => res.json({ status: 'ok' }));
  app.use('/api', createImagesRouter({ imageService, uploadLimiter }));

  // Frontend estático: mismo origen que la API (http://localhost:PORT).
  app.use(express.static(FRONTEND_DIR));

  app.use('/api', (req, res) => res.status(404).json({ error: 'Ruta no encontrada' }));

  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    if (err instanceof ValidationError) {
      return res.status(err.status).json({ error: err.message });
    }
    if (err.type === 'entity.parse.failed') {
      return res.status(400).json({ error: 'El cuerpo de la solicitud no es JSON válido' });
    }
    if (err.type === 'entity.too.large') {
      return res.status(413).json({ error: 'El cuerpo de la solicitud es demasiado grande' });
    }
    logger.error('Error no controlado:', err.name, err.message);
    return res.status(500).json({ error: 'Error interno del servidor' });
  });

  return app;
}

module.exports = { createApp };
