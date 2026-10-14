#!/usr/bin/env bash
# validar-plantillas.sh - Prueba offline de las plantillas de policies/
#
# Renderiza cada *.json.tpl con valores de ejemplo en un directorio temporal
# (mktemp), valida que sea JSON y comprueba las propiedades clave.
# No usa la AWS CLI ni la red.
#
# Uso:
#   ./validar-plantillas.sh
set -euo pipefail

# Valores de ejemplo: al estar en el entorno tienen prioridad sobre .env.
export BUCKET="lab-imagenes-prueba-20260101"
export REPLICA_BUCKET="lab-imagenes-prueba-20260101-replica"
export ACCOUNT_ID="123456789012"
export REPLICATION_ROLE="s3-replicacion-lab09"
export AWS_REGION="us-east-1"
export LAMBDA_NAME="miniaturas-lab09"
export CORS_ORIGINS="http://localhost:3000,http://localhost:8080"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"

case "${1:-}" in
  -h | --help) mostrar_ayuda "$0"; exit 0 ;;
esac

requerir_python

total=0
for tpl in "$POLICIES_DIR"/*.json.tpl; do
  nombre="$(basename "${tpl%.tpl}")"
  render_plantilla "$tpl" > "$TMP_DIR/$nombre"
  if python3 -m json.tool "$TMP_DIR/$nombre" >/dev/null; then
    ok "JSON válido: $nombre"
  else
    fail "JSON inválido: $nombre"
  fi
  total=$((total + 1))
done
[ "$total" -ge 11 ] || fail "Se esperaban al menos 11 plantillas y hay $total."

# Formatos admitidos para CORS_ORIGINS
[ "$(_cors_a_json '["https://a.example"]')" = '["https://a.example"]' ] || fail "CORS_ORIGINS en JSON"
[ "$(_cors_a_json 'https://a.example, https://b.example')" = '["https://a.example", "https://b.example"]' ] ||
  fail "CORS_ORIGINS en lista"
ok "Formatos de CORS_ORIGINS"

python3 -I - "$TMP_DIR" "$BUCKET" "$REPLICA_BUCKET" "$ACCOUNT_ID" "$AWS_REGION" "$LAMBDA_NAME" <<'PY'
import json, os, sys

carpeta, bucket, replica, cuenta, region, funcion = sys.argv[1:7]
errores = []


def cargar(nombre):
    with open(os.path.join(carpeta, nombre), encoding="utf-8") as f:
        return json.load(f)


def texto(nombre):
    with open(os.path.join(carpeta, nombre), encoding="utf-8") as f:
        return f.read()


def acciones(declaracion):
    accion = declaracion["Action"]
    return [accion] if isinstance(accion, str) else list(accion)


def verificar(condicion, mensaje):
    if not condicion:
        errores.append(mensaje)


arn = "arn:aws:s3:::" + bucket

iam = cargar("iam-app-user.json")
s = iam["Statement"]
verificar(len(s) == 1, "iam-app-user: debe tener una sola declaración")
verificar(s[0]["Sid"] == "AccesoLecturaEscrituraBucket", "iam-app-user: Sid")
verificar(s[0]["Effect"] == "Allow", "iam-app-user: Effect")
verificar(sorted(s[0]["Action"]) == ["s3:DeleteObject", "s3:GetObject", "s3:ListBucket", "s3:PutObject"],
          "iam-app-user: acciones")
verificar(s[0]["Resource"] == [arn, arn + "/*"], "iam-app-user: recursos")

https = cargar("bucket-https-only.json")["Statement"][0]
verificar(https["Sid"] == "DenyInsecureConnections" and https["Effect"] == "Deny", "https-only: Sid/Effect")
verificar(https["Principal"] == "*" and https["Action"] == "s3:*", "https-only: Principal/Action")
verificar(https["Resource"] == [arn, arn + "/*"], "https-only: recursos")
verificar(https["Condition"] == {"Bool": {"aws:SecureTransport": "false"}}, "https-only: condición")

cors = cargar("cors.json")["CORSRules"][0]
verificar(cors["AllowedMethods"] == ["PUT", "GET"], "cors: métodos")
verificar(cors["AllowedOrigins"] == ["http://localhost:3000", "http://localhost:8080"], "cors: orígenes")
verificar(cors["AllowedHeaders"] == ["*"] and cors["ExposeHeaders"] == ["ETag"], "cors: cabeceras")
verificar(cors["MaxAgeSeconds"] == 3000, "cors: MaxAgeSeconds")

reglas = {r["ID"]: r for r in cargar("lifecycle.json")["Rules"]}
r1 = reglas.get("regla-imagenes-antiguas", {})
verificar(r1.get("Status") == "Enabled" and r1.get("Filter") == {"Prefix": "originales/"}, "lifecycle: regla 1 filtro/estado")
verificar([(t["Days"], t["StorageClass"]) for t in r1.get("Transitions", [])]
          == [(30, "STANDARD_IA"), (90, "GLACIER_IR")], "lifecycle: transiciones")
verificar(r1.get("NoncurrentVersionTransitions") == [{"NoncurrentDays": 60, "StorageClass": "DEEP_ARCHIVE"}],
          "lifecycle: transición de versiones no actuales")
verificar(r1.get("NoncurrentVersionExpiration") == {"NoncurrentDays": 365}, "lifecycle: expiración no actual")
verificar(r1.get("Expiration") == {"ExpiredObjectDeleteMarker": True}, "lifecycle: delete markers expirados")
r2 = reglas.get("abortar-multipart-incompletos", {})
verificar(r2.get("AbortIncompleteMultipartUpload") == {"DaysAfterInitiation": 7}, "lifecycle: multipart")

confianza = cargar("replication-trust.json")["Statement"][0]
verificar(confianza["Principal"] == {"Service": "s3.amazonaws.com"} and confianza["Action"] == "sts:AssumeRole",
          "replication-trust: principal/acción")

permisos = cargar("replication-policy.json")["Statement"]
verificar(len(permisos) == 3, "replication-policy: tres declaraciones")
destinos = {tuple(sorted([p["Action"]] if isinstance(p["Action"], str) else p["Action"])): p["Resource"] for p in permisos}
verificar(destinos.get(("s3:GetReplicationConfiguration", "s3:ListBucket")) == arn, "replication-policy: origen")
verificar(destinos.get(("s3:GetObjectVersionAcl", "s3:GetObjectVersionForReplication", "s3:GetObjectVersionTagging")) == arn + "/*",
          "replication-policy: versiones del origen")
verificar(destinos.get(("s3:ReplicateDelete", "s3:ReplicateObject", "s3:ReplicateTags")) == "arn:aws:s3:::" + replica + "/*",
          "replication-policy: destino")

config = cargar("replication-config.json")
verificar(config["Role"] == "arn:aws:iam::" + cuenta + ":role/s3-replicacion-lab09", "replication-config: rol")
regla = config["Rules"][0]
verificar(regla["Status"] == "Enabled" and regla["Priority"] == 1, "replication-config: estado/prioridad")
verificar(regla["Filter"] == {"Prefix": "originales/"}, "replication-config: filtro")
verificar(regla["DeleteMarkerReplication"] == {"Status": "Disabled"}, "replication-config: delete markers")
verificar(regla["Destination"] == {"Bucket": "arn:aws:s3:::" + replica, "StorageClass": "STANDARD"},
          "replication-config: destino")

# Política adicional de etiquetas (la del enunciado no cambia).
tags = cargar("iam-app-user-tags.json")["Statement"]
verificar(len(tags) == 1 and tags[0]["Effect"] == "Allow", "iam-app-user-tags: una declaración Allow")
verificar(sorted(acciones(tags[0])) == ["s3:GetObjectTagging", "s3:PutObjectTagging"], "iam-app-user-tags: acciones")
verificar(tags[0]["Resource"] == arn + "/*", "iam-app-user-tags: recurso")

lambda_confianza = cargar("lambda-trust.json")["Statement"]
verificar(len(lambda_confianza) == 1 and lambda_confianza[0]["Effect"] == "Allow", "lambda-trust: una declaración Allow")
verificar(lambda_confianza[0]["Principal"] == {"Service": "lambda.amazonaws.com"}
          and lambda_confianza[0]["Action"] == "sts:AssumeRole", "lambda-trust: principal/acción")

lambda_s3 = cargar("lambda-s3-policy.json")["Statement"]
permisos_lambda = {tuple(acciones(p)): p["Resource"] for p in lambda_s3}
verificar(len(lambda_s3) == 2 and all(p["Effect"] == "Allow" for p in lambda_s3), "lambda-s3-policy: dos declaraciones Allow")
verificar(permisos_lambda.get(("s3:GetObject",)) == arn + "/originales/*", "lambda-s3-policy: GetObject sobre originales/*")
verificar(permisos_lambda.get(("s3:PutObject",)) == arn + "/miniaturas/*", "lambda-s3-policy: PutObject sobre miniaturas/*")

notificacion = cargar("s3-notification.json")
verificar(list(notificacion) == ["LambdaFunctionConfigurations"], "s3-notification: solo LambdaFunctionConfigurations")
destinos = notificacion["LambdaFunctionConfigurations"]
verificar(len(destinos) == 1, "s3-notification: una configuración")
destino = destinos[0]
verificar(destino["LambdaFunctionArn"] == "arn:aws:lambda:" + region + ":" + cuenta + ":function:" + funcion,
          "s3-notification: ARN de la función")
verificar(destino["Events"] == ["s3:ObjectCreated:*"], "s3-notification: evento")
verificar(destino["Filter"] == {"Key": {"FilterRules": [{"Name": "prefix", "Value": "originales/"}]}},
          "s3-notification: filtro por prefijo originales/")

# Ninguna política nueva usa comodines de acción.
for nombre in ("iam-app-user-tags.json", "lambda-trust.json", "lambda-s3-policy.json"):
    verificar('"s3:*"' not in texto(nombre), nombre + ": no debe usar s3:*")
    for declaracion in cargar(nombre)["Statement"]:
        verificar(all("*" not in a for a in acciones(declaracion)), nombre + ": acción con comodín")

if errores:
    for e in errores:
        print("[error] " + e, file=sys.stderr)
    sys.exit(1)
print("[ ok ] Propiedades de las plantillas verificadas")
PY

ok "Plantillas validadas: $total"
