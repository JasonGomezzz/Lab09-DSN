const express = require('express');

/**
 * Rutas de la API. Cada handler delega en el servicio y deja que el
 * manejador global de errores traduzca las excepciones a códigos HTTP.
 */
function createImagesRouter({ imageService, uploadLimiter }) {
  const router = express.Router();

  const asyncHandler = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

  router.post(
    '/upload-url',
    uploadLimiter,
    asyncHandler(async (req, res) => {
      res.json(await imageService.createUploadUrl(req.body));
    }),
  );

  router.post(
    '/verify',
    asyncHandler(async (req, res) => {
      res.json(await imageService.verifyUpload(req.body && req.body.key));
    }),
  );

  router.get(
    '/images',
    asyncHandler(async (req, res) => {
      const { proyecto, cliente } = req.query;
      res.json(await imageService.listImages({ proyecto, cliente }));
    }),
  );

  // :key llega codificada (originales%2Farchivo.jpg); Express la decodifica.
  router.delete(
    '/images/:key',
    asyncHandler(async (req, res) => {
      res.json(await imageService.deleteImage(req.params.key));
    }),
  );

  return router;
}

module.exports = { createImagesRouter };
