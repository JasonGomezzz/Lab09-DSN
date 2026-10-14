# Automatización AWS CLI - Laboratorio 09 (Cloud Storage S3)

Scripts en bash que automatizan los ejercicios 1, 2 y 3 y los retos opcionales
(etiquetas de objetos y miniaturas con Lambda) con la AWS CLI v2.
Todos aceptan `--dry-run` (o `DRY_RUN=1`): imprimen los comandos `aws` en lugar
de ejecutarlos y no consultan la cuenta.

## Requisitos

- AWS CLI v2 y credenciales de administración en el perfil `ADMIN_PROFILE`.
- `python3` (plantillas, vaciado del bucket y limpieza del perfil local).
- `curl` (solo para la prueba HTTPS de `04`).
- `zip` y `npm` >= 10 con Node.js (solo para `07`: empaqueta `lambda/miniaturas`
  con `--os=linux --cpu=x64`; necesita acceso al registro de npm).
- bash 3.2 o superior (compatible con macOS).

## Orden de ejecución

| Paso | Script | Ejercicio |
|------|--------|-----------|
| 1 | `./01-crear-bucket.sh` | 1 A/B: bucket privado, Block all public access, prefijos, ARN vs URL |
| 2 | `./02-seguridad-iam-cifrado.sh` | 2 A-C: usuario IAM, política mínima, solo HTTPS, SSE-S3, CORS, Access Key |
| 3 | `./04-validar-politicas.sh` | 2 D: pruebas PASS/FAIL con el perfil de la app |
| 4 | `./03-versionado-lifecycle.sh [--demo]` | 3 A-C: versionado, delete markers, ciclo de vida |
| 5 | `./05-replicacion-opcional.sh` | 3 D (opcional): replicación entre regiones |
| 6 | `./06-object-tags.sh` | Reto opcional: política de etiquetas y validación con `x-amz-tagging` |
| 7 | `./07-miniaturas-lambda.sh` | Reto opcional: Lambda que genera miniaturas en `miniaturas/` |
| 8 | `./99-limpiar.sh` | Limpieza obligatoria (incluye los retos) |

`validar-plantillas.sh` renderiza y valida las plantillas de `policies/` sin
usar la AWS CLI ni la red.

Banderas comunes: `--dry-run`, `-y/--yes` (omite la confirmación `si`),
`-h/--help`. Banderas propias: `--sin-fotos` (01), `--skip-iam` (02, 06 y 99),
`--demo` (03), `--sin-prueba` (07).

## Variables

Prioridad: entorno, luego `scripts/aws/.env` (copia `.env.example`; está
ignorado por git y no admite credenciales), luego el valor por defecto.

| Variable | Defecto | Uso |
|----------|---------|-----|
| `BUCKET` | `lab-imagenes-gomez-20261014` | Bucket principal |
| `AWS_REGION` | `us-east-1` | Región del bucket (en `us-east-1` no se envía `LocationConstraint`) |
| `ADMIN_PROFILE` | `default` | Perfil con permisos de administración (vacío = credenciales del entorno) |
| `APP_PROFILE` | `app-user` | Perfil local de la aplicación (recibe la Access Key) |
| `IAM_USER` | `app-imagenes-user` | Usuario IAM de la aplicación |
| `IAM_POLICY_NAME` | `app-imagenes-s3-minimo` | Política administrada propia |
| `REPLICA_BUCKET` | `${BUCKET}-replica` | Bucket destino de la replicación |
| `REPLICA_REGION` | `us-west-2` | Región del bucket réplica |
| `CORS_ORIGINS` | `http://localhost:3000,http://localhost:8080` | Lista separada por comas o arreglo JSON |
| `REPLICATION_ROLE` | `s3-replicacion-lab09` | Rol IAM de replicación |
| `FOTOS_DIR` | `./fotos` | Carpeta opcional para la demo de `cp/sync/ls` |
| `DEMO_KEY` | `prueba.jpg` | Clave del objeto de la demo de versionado |
| `EVIDENCIAS_DIR` | `~/Downloads/Lab09-DSN-evidencias` | Salida de `04`, `06` y `07` (fuera del repositorio) |
| `IAM_TAGS_POLICY_NAME` | `app-imagenes-s3-tags` | Política adicional de etiquetas (06) |
| `LAMBDA_NAME` | `miniaturas-lab09` | Nombre de la función Lambda (07) |
| `LAMBDA_ROLE` | `lambda-miniaturas-lab09` | Rol de ejecución de la función (07) |
| `LAMBDA_RUNTIME` | `nodejs22.x` | Runtime de la función |
| `LAMBDA_MEMORY` | `512` | Memoria en MB (128 a 10240) |
| `LAMBDA_TIMEOUT` | `30` | Tiempo máximo en segundos (1 a 900) |
| `THUMB_WIDTH` | `300` | Ancho máximo de la miniatura en px (16 a 2000); va como variable de entorno de la función |
| `LAMBDA_SRC_DIR` | `<repo>/lambda/miniaturas` | Código de la función (`index.mjs`, `package.json`, `package-lock.json`) |

Ejemplo:

```bash
BUCKET=lab-imagenes-gomez-20261014 ./01-crear-bucket.sh --dry-run
./01-crear-bucket.sh
```

## Notas de diseño

- La política de la aplicación es exactamente la del enunciado (`GetObject`,
  `PutObject`, `DeleteObject`, `ListBucket` sobre el bucket y `bucket/*`). Con
  ella `aws s3 ls` sin ruta se deniega (no incluye `s3:ListAllMyBuckets`);
  `04` lo comprueba junto con `aws s3 ls s3://BUCKET/`.
- `02` guarda la Access Key directamente en `APP_PROFILE` con
  `aws configure set`; nunca la imprime ni la escribe en archivos. Si el
  usuario ya tiene 2 claves no crea otra.
- Ciclo de vida (`policies/lifecycle.json.tpl`): `ExpiredObjectDeleteMarker`
  va en la misma regla `regla-imagenes-antiguas`, porque no existe una
  expiración por días de las versiones actuales (la API solo prohíbe
  combinarlo con `Days`/`Date` en `Expiration`). La regla
  `abortar-multipart-incompletos` (7 días) es un extra de buenas prácticas.
  Por defecto S3 no transiciona objetos menores de 128 KB.
- La replicación (`05`) cubre solo objetos nuevos bajo `originales/` y no
  replica delete markers.
- Etiquetas (`06`): la política del enunciado no cambia y sigue con sus 4
  acciones. `06` crea una segunda política administrada,
  `app-imagenes-s3-tags`, con solo `s3:PutObjectTagging` y
  `s3:GetObjectTagging` sobre `BUCKET/*`, y la adjunta directamente al
  usuario (se reutiliza si existe y no duplica la adjunción). Con el perfil
  de la app sube un objeto temporal con
  `--tagging "proyecto=lab09&cliente=demo"`, lo lee con `get-object-tagging` y
  lo borra; el resumen queda en `validacion-tags.txt`. En una URL prefirmada
  la cabecera `x-amz-tagging` va firmada: el cliente debe enviarla igual.
- Miniaturas (`07`): empaqueta con `npm install --omit=dev --os=linux
  --cpu=x64 --libc=glibc --ignore-scripts` (sharp >= 0.33 trae sus binarios
  como paquetes opcionales, así que no necesita scripts de instalación) y
  comprueba que existan `@img/sharp-linux-x64` y `@img/sharp-libvips-linux-x64`
  antes de comprimir. El rol de la función tiene `AWSLambdaBasicExecutionRole`
  (logs) y una política en línea con `s3:GetObject` sobre `originales/*` y
  `s3:PutObject` sobre `miniaturas/*`. S3 solo puede invocar la función desde
  `BUCKET` y la cuenta actual (`--source-arn` y `--source-account`). Al
  terminar sube un PNG de 64x64, espera hasta 5 min la miniatura, muestra
  ambos tamaños y borra los dos objetos (`validacion-miniaturas.txt`).
- Riesgo de las notificaciones: `put-bucket-notification-configuration`
  reemplaza toda la configuración del bucket (SNS, SQS, otras funciones,
  EventBridge). `07` revisa lo existente, lo muestra y pide confirmación
  (`-y` la omite). Los scripts `01` a `06` no configuran otras notificaciones.
- Cada objeto nuevo en `originales/` (incluidos los temporales de `04` y `06`)
  invoca la función; la función omite claves terminadas en `/` y extensiones
  que no sean jpg, jpeg, png o webp.

## Costos aproximados (us-east-1; verifica en la calculadora de precios de AWS)

| Concepto | Costo aproximado |
|----------|------------------|
| S3 Standard con pocos MB | US$ 0.023 por GB-mes: centavos o menos |
| Solicitudes PUT / GET | US$ 0.005 / 0.0004 por 1000 |
| Transiciones de ciclo de vida | Se cobran por solicitud: ~US$ 0.01 (IA), 0.02 (Glacier IR), 0.05 (Deep Archive) por 1000 objetos |
| Versionado | Cada versión cuenta como almacenamiento |
| Replicación entre regiones | Duplica el almacenamiento y cobra transferencia entre regiones (~US$ 0.02 por GB) y solicitudes |
| IAM, SSE-S3, Block Public Access | Sin costo |
| Lambda (07) | Capa gratuita mensual de 1 millón de solicitudes y 400,000 GB-s; un laboratorio queda en centavos o en cero |
| CloudWatch Logs (07) | ~US$ 0.50 por GB ingerido (primeros 5 GB gratis) y almacenamiento de logs; unos KB por invocación |
| Etiquetas de objetos (06) | Sin costo adicional; solo las solicitudes PUT/GET normales |

## AWS Academy / Learner Lab

El Learner Lab no permite crear usuarios IAM ni Access Keys permanentes.

- Exporta las credenciales temporales (`AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) y usa `ADMIN_PROFILE=` (vacío),
  o guarda las tres claves en un perfil y apunta `ADMIN_PROFILE` a él.
- Ejecuta `./02-seguridad-iam-cifrado.sh --skip-iam`: aplica HTTPS-only,
  cifrado y CORS, pero no crea usuario, política ni clave.
- La política `iam-app-user.json.tpl` queda disponible para adjuntarla desde
  la consola si el laboratorio lo permite.
- En `04`, define `APP_PROFILE` con el perfil que quieras probar; si coincide
  con `ADMIN_PROFILE` se omite la prueba de `delete-bucket`.
- `06 --skip-iam` omite la política de etiquetas y la validación; la plantilla
  `iam-app-user-tags.json.tpl` queda para adjuntarla desde la consola.
- `07` crea un rol IAM para la función; si el laboratorio no permite crear
  roles, el script falla en ese paso (no se automatiza el uso de un rol
  existente).
- Las credenciales temporales caducan: vuelve a exportarlas antes de continuar.

## Limpieza

Ejecuta siempre al terminar:

```bash
./99-limpiar.sh --dry-run   # revisa qué se eliminará
./99-limpiar.sh             # pide escribir el nombre exacto del bucket
```

Elimina la configuración de notificaciones del bucket, la función Lambda, su
grupo de logs `/aws/lambda/LAMBDA_NAME` y su rol, el bucket y la réplica
(incluidas versiones y delete markers), el rol de replicación, las Access
Keys, las dos políticas (`IAM_POLICY_NAME` e `IAM_TAGS_POLICY_NAME`) y el
usuario IAM, y las secciones `[app-user]` / `[profile app-user]` de
`~/.aws/credentials` y `~/.aws/config` (con respaldo en `*.bak-lab09`; borra
esos respaldos cuando ya no los necesites). Con `--skip-iam` no se tocan
usuario, políticas ni perfil local; los roles de Lambda y de replicación se
intentan siempre. Cada paso tolera que el recurso ya no exista. Después
revisa en la consola de AWS que no queden recursos ni cargos.
