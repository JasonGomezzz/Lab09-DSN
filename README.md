# Lab09-DSN · Galería de imágenes sobre Amazon S3

Laboratorio 09 de Desarrollo de Soluciones en la Nube (TECSUP): almacenamiento
de objetos con Amazon S3, seguridad con IAM y cifrado, versionado con ciclo de
vida, y una aplicación web que sube, lista y elimina imágenes **sin exponer
credenciales de AWS** al navegador, usando presigned URLs.

## Arquitectura

```
Navegador ── 1) POST /api/upload-url ──▶ Backend (Express + AWS SDK v3)
    ▲                                       │ firma URL (5 min)
    │ ◀── 2) URL prefirmada + encabezados ──┘
    │
    ├── 3) PUT de la imagen ───────────────▶ Amazon S3 (bucket privado)
    ├── 4) POST /api/verify ───────────────▶ Backend: lee magic bytes, borra si no es imagen
    └── 5) GET /api/images ────────────────▶ Backend: lista y firma URLs de vista (15 min)
```

El archivo viaja directo del navegador a S3. El backend solo emite URLs de corta
duración y nunca entrega credenciales.

## Requisitos

- Node.js 18 o superior y npm.
- AWS CLI v2 configurada (`aws configure`) para los scripts de `scripts/aws/`.
- Una cuenta de AWS (Free Tier o AWS Academy / Learner Lab).

## Estructura

```
backend/
  server.js                 punto de entrada
  .env.example              variables de entorno de ejemplo
  src/
    config.js               carga y validación de variables
    s3Client.js             cliente S3 (cadena de credenciales del SDK)
    services/imageService.js presigned URLs, listado, borrado y verificación
    routes/images.js        endpoints de la API
    utils/validators.js     tipo, tamaño, nombre, clave y magic bytes
    app.js                  Express: CORS, rate limiting, errores, estáticos
  test/                     pruebas con node --test
frontend/                   index.html, app.js, styles.css (sin dependencias)
lambda/miniaturas/          función Lambda que genera miniaturas (reto opcional)
scripts/
  pruebas-api.sh            pruebas obligatorias del ejercicio 4 contra la API
  aws/                      automatización de los ejercicios 1 a 3 y de los retos con AWS CLI
```

## Puesta en marcha

### 1. Infraestructura en AWS (ejercicios 1 a 3)

Los scripts de `scripts/aws/` replican los pasos de la consola y aceptan
`--dry-run` para revisar los comandos antes de ejecutarlos. Detalle de
variables, costos y orden en [scripts/aws/README.md](scripts/aws/README.md).

```bash
scripts/aws/01-crear-bucket.sh              # ejercicio 1: bucket privado y carpetas
scripts/aws/02-seguridad-iam-cifrado.sh     # ejercicio 2: IAM mínimo, HTTPS, SSE-S3, CORS
scripts/aws/04-validar-politicas.sh         # ejercicio 2D: validación con el perfil app-user
scripts/aws/03-versionado-lifecycle.sh      # ejercicio 3: versionado y ciclo de vida (--demo)
scripts/aws/05-replicacion-opcional.sh      # ejercicio 3D (opcional): replicación entre regiones
scripts/aws/06-object-tags.sh               # reto opcional: política y validación de Object Tags
scripts/aws/07-miniaturas-lambda.sh         # reto opcional: función Lambda de miniaturas
```

### 2. Backend y frontend (ejercicio 4)

```bash
cd backend
cp .env.example .env     # completar S3_BUCKET y credenciales o AWS_PROFILE
npm install
npm start                # http://localhost:3000 (API y frontend)
```

El mismo servidor entrega `frontend/`, de modo que navegador, API y la regla
CORS del bucket (`http://localhost:3000`) comparten origen.

### Variables de entorno

Referencia completa en [backend/.env.example](backend/.env.example).

| Variable | Descripción | Por defecto |
|---|---|---|
| `S3_BUCKET` | Nombre del bucket (obligatoria) | — |
| `AWS_REGION` | Región del bucket | `us-east-1` |
| `AWS_PROFILE` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Credenciales locales; en EC2 se usa el rol | cadena del SDK |
| `PORT` | Puerto de la API | `3000` |
| `CORS_ORIGINS` | Orígenes permitidos, separados por coma | `localhost:3000,localhost:8080` |
| `UPLOAD_URL_EXPIRES` / `VIEW_URL_EXPIRES` | Vigencia de las URL en segundos | `300` / `900` |
| `MAX_SIZE_MB` | Tamaño máximo por imagen | `5` |
| `RATE_LIMIT_PER_MINUTE` | Solicitudes de URL de subida por IP y minuto | `30` |

## API

| Método y ruta | Descripción | Respuestas |
|---|---|---|
| `POST /api/upload-url` | Recibe `{filename, contentType, sizeBytes, tags?}` y devuelve `{uploadUrl, key, expiresIn, headers, tags}` (válida 5 min) | 200, 400 tipo, cuerpo o etiquetas inválidas, 413 tamaño, 429 límite |
| `POST /api/verify` | Recibe `{key}`; comprueba tamaño y magic bytes del objeto subido y lo elimina si no es una imagen | 200, 404, 422 |
| `GET /api/images?proyecto=&cliente=` | Lista las imágenes de `originales/` con `tags`, `url` de vista (15 min) y `thumbUrl` si existe la miniatura; admite filtro por etiquetas | 200, 400 filtro inválido |
| `DELETE /api/images/:key` | Elimina la imagen y su miniatura; `:key` va con `encodeURIComponent` | 200, 400, 404 |
| `GET /health` | Estado del servicio | 200 |

Los errores responden `{ "error": "mensaje" }`.

## Retos opcionales

### Object Tags (proyecto y cliente)

- El formulario envía `tags: { proyecto, cliente }` (valores cortos con caracteres seguros; claves en lista blanca).
- La etiqueta viaja **firmada dentro de la URL prefirmada** (`x-amz-tagging`), de modo que el navegador no puede cambiarla ni añadir otras.
- La galería lee las etiquetas con `GetObjectTagging`, las muestra como insignias y permite filtrar por proyecto o cliente.
- Requiere `s3:PutObjectTagging` y `s3:GetObjectTagging`: `scripts/aws/06-object-tags.sh` crea una **segunda** política (`app-imagenes-s3-tags`) y no modifica la del enunciado. Sin ese permiso la galería sigue funcionando, solo que sin etiquetas.

### Miniaturas con AWS Lambda

- Cada objeto nuevo bajo `originales/` dispara la función `miniaturas-lab09` (Node 22, `sharp`), que escribe una miniatura de 300 px bajo `miniaturas/` conservando el formato.
- La salida va a otro prefijo (no hay recursión) y se omiten extensiones no válidas y archivos de más de 10 MB.
- El rol de la función solo puede leer `originales/*` y escribir `miniaturas/*`; S3 solo puede invocarla desde este bucket y esta cuenta.
- `scripts/aws/07-miniaturas-lambda.sh` empaqueta para linux x64, crea el rol y la función, autoriza a S3, aplica la notificación y verifica con un PNG de prueba. S3 puede tardar unos minutos en aplicar una notificación nueva.
- La API devuelve `thumbUrl` y la galería usa la miniatura (con el original disponible en "Ver original"); al eliminar una imagen se borra también su miniatura.

## Pruebas

```bash
cd backend && npm test          # pruebas unitarias y de API, sin red ni credenciales
cd lambda/miniaturas && npm test  # pruebas de la función de miniaturas (imágenes reales con sharp)
```

Con el backend y el bucket reales en marcha, las pruebas obligatorias del
ejercicio 4 (imagen válida, `.exe`/`.pdf`, 10 MB, ejecutable disfrazado,
vigencia de URL, frontend sin credenciales) se ejecutan con:

```bash
scripts/pruebas-api.sh
```

La salida se guarda en `~/Downloads/Lab09-DSN-evidencias/` (fuera del repo y sin
firmas de las URL).

## Decisiones de seguridad

- Bucket privado con *Block all public access*; el navegador nunca recibe credenciales.
- Presigned URLs de 5 minutos para subir y 15 para ver; `Content-Length`, `Content-Type` y el cifrado SSE-S3 van firmados.
- Validación de tipo y tamaño en frontend y backend, y verificación posterior con magic bytes (el objeto se elimina si no es imagen).
- Nombres de archivo saneados y extensión forzada según el tipo MIME; claves restringidas a `originales/`.
- CORS con lista blanca, rate limiting en la emisión de URL y mensajes de error sin detalles internos.
- Credenciales fuera del repositorio (`.env` ignorado); en AWS se recomienda un IAM Role en lugar de Access Keys.

## Desviaciones respecto al enunciado

| Punto del enunciado | Problema | Solución aplicada |
|---|---|---|
| Nombre del bucket | La parte A usa `lab-09-<apellido>-<fecha>` y el resto `lab-imagenes-<apellido>-<fecha>` | Se usa `lab-imagenes-<apellido>-<fecha>` en todo el repositorio |
| URL de subida del código de referencia | Con el SDK actual la URL incluye un checksum CRC32 de cuerpo vacío y S3 rechaza la imagen real; además el cifrado va firmado como encabezado | Cliente con `requestChecksumCalculation: 'WHEN_REQUIRED'` y la API devuelve los `headers` que el navegador debe reenviar |
| `DELETE /api/images/:key(*)` | Sintaxis válida solo en Express 4 | Ruta `/api/images/:key` con la clave codificada |
| `sizeBytes` | Sin validar tipo; un valor ausente pasa la comparación | Entero positivo obligatorio y `Content-Length` firmado |
| `DELETE` | Permitía borrar cualquier objeto del bucket | Solo claves `originales/…` con patrón estricto, 404 si no existe |
| `cors()` abierto | Cualquier origen puede llamar a la API | Lista blanca en `CORS_ORIGINS` |
| Galería con `innerHTML` y `onclick` | Inyección de HTML por nombres de archivo | DOM con `textContent` y delegación de eventos |
| Validación "antes y después de la carga" | El ejemplo solo valida antes | Endpoint `/api/verify` con magic bytes |
| Cifrado por defecto | Desde 2023 S3 aplica SSE-S3 automáticamente | El script lo declara explícitamente y lo verifica |
| AWS Academy / Learner Lab | No permite crear usuarios IAM ni claves permanentes | `--skip-iam` en el script 02 y credenciales temporales con `AWS_SESSION_TOKEN` |
| Política del usuario de la app | Solo incluye 4 acciones; las etiquetas exigen más | Segunda política `app-imagenes-s3-tags` con solo `PutObjectTagging` y `GetObjectTagging` |

## Limpieza de recursos

Al terminar, eliminar todo lo creado para evitar costos:

```bash
scripts/aws/99-limpiar.sh
```

Vacía el bucket (incluidas versiones y delete markers), lo elimina junto con la
réplica opcional, borra la función Lambda con su rol y sus logs, la notificación,
las claves, las políticas y el usuario IAM, y quita el perfil local `app-user`.

## Repositorio

<https://github.com/JasonGomezzz/Lab09-DSN>
