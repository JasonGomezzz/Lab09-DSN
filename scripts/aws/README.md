# Automatización AWS CLI - Laboratorio 09 (Cloud Storage S3)

Scripts en bash que automatizan los ejercicios 1, 2 y 3 con la AWS CLI v2.
Todos aceptan `--dry-run` (o `DRY_RUN=1`): imprimen los comandos `aws` en lugar
de ejecutarlos y no consultan la cuenta.

## Requisitos

- AWS CLI v2 y credenciales de administración en el perfil `ADMIN_PROFILE`.
- `python3` (plantillas, vaciado del bucket y limpieza del perfil local).
- `curl` (solo para la prueba HTTPS de `04`).
- bash 3.2 o superior (compatible con macOS).

## Orden de ejecución

| Paso | Script | Ejercicio |
|------|--------|-----------|
| 1 | `./01-crear-bucket.sh` | 1 A/B: bucket privado, Block all public access, prefijos, ARN vs URL |
| 2 | `./02-seguridad-iam-cifrado.sh` | 2 A-C: usuario IAM, política mínima, solo HTTPS, SSE-S3, CORS, Access Key |
| 3 | `./04-validar-politicas.sh` | 2 D: pruebas PASS/FAIL con el perfil de la app |
| 4 | `./03-versionado-lifecycle.sh [--demo]` | 3 A-C: versionado, delete markers, ciclo de vida |
| 5 | `./05-replicacion-opcional.sh` | 3 D (opcional): replicación entre regiones |
| 6 | `./99-limpiar.sh` | Limpieza obligatoria |

`validar-plantillas.sh` renderiza y valida las plantillas de `policies/` sin
usar la AWS CLI ni la red.

Banderas comunes: `--dry-run`, `-y/--yes` (omite la confirmación `si`),
`-h/--help`. Banderas propias: `--sin-fotos` (01), `--skip-iam` (02 y 99),
`--demo` (03).

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
| `EVIDENCIAS_DIR` | `~/Downloads/Lab09-DSN-evidencias` | Salida de `04` (fuera del repositorio) |

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

## Costos aproximados (us-east-1; verifica en la calculadora de precios de AWS)

| Concepto | Costo aproximado |
|----------|------------------|
| S3 Standard con pocos MB | US$ 0.023 por GB-mes: centavos o menos |
| Solicitudes PUT / GET | US$ 0.005 / 0.0004 por 1000 |
| Transiciones de ciclo de vida | Se cobran por solicitud: ~US$ 0.01 (IA), 0.02 (Glacier IR), 0.05 (Deep Archive) por 1000 objetos |
| Versionado | Cada versión cuenta como almacenamiento |
| Replicación entre regiones | Duplica el almacenamiento y cobra transferencia entre regiones (~US$ 0.02 por GB) y solicitudes |
| IAM, SSE-S3, Block Public Access | Sin costo |

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
- Las credenciales temporales caducan: vuelve a exportarlas antes de continuar.

## Limpieza

Ejecuta siempre al terminar:

```bash
./99-limpiar.sh --dry-run   # revisa qué se eliminará
./99-limpiar.sh             # pide escribir el nombre exacto del bucket
```

Elimina el bucket y la réplica (incluidas versiones y delete markers), el rol
de replicación, las Access Keys, la política y el usuario IAM, y las secciones
`[app-user]` / `[profile app-user]` de `~/.aws/credentials` y `~/.aws/config`
(con respaldo en `*.bak-lab09`; borra esos respaldos cuando ya no los
necesites). Cada paso tolera que el recurso ya no exista. Después revisa en la
consola de AWS que no queden recursos ni cargos.
