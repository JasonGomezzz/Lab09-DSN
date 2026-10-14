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
[ "$total" -ge 7 ] || fail "Se esperaban al menos 7 plantillas y hay $total."

# Formatos admitidos para CORS_ORIGINS
[ "$(_cors_a_json '["https://a.example"]')" = '["https://a.example"]' ] || fail "CORS_ORIGINS en JSON"
[ "$(_cors_a_json 'https://a.example, https://b.example')" = '["https://a.example", "https://b.example"]' ] ||
  fail "CORS_ORIGINS en lista"
ok "Formatos de CORS_ORIGINS"

python3 -I - "$TMP_DIR" "$BUCKET" "$REPLICA_BUCKET" "$ACCOUNT_ID" <<'PY'
import json, os, sys

carpeta, bucket, replica, cuenta = sys.argv[1:5]
errores = []


def cargar(nombre):
    with open(os.path.join(carpeta, nombre), encoding="utf-8") as f:
        return json.load(f)


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

if errores:
    for e in errores:
        print("[error] " + e, file=sys.stderr)
    sys.exit(1)
print("[ ok ] Propiedades de las plantillas verificadas")
PY

ok "Plantillas validadas: $total"
