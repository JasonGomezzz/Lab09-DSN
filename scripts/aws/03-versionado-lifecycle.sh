#!/usr/bin/env bash
# 03-versionado-lifecycle.sh - Ejercicio 3 (partes A a C)
#
# Activa el versionado del bucket y aplica la configuración de ciclo de vida
# de policies/lifecycle.json.tpl. Con --demo ejecuta una demostración guiada:
# sube el mismo objeto 3 veces, lo elimina (delete marker) y lo restaura
# borrando el delete marker.
#
# Decisión sobre los delete markers expirados: ExpiredObjectDeleteMarker va en
# la misma regla (regla-imagenes-antiguas) porque no existe Expiration por
# Days sobre las versiones actuales; la API solo prohíbe combinarlo con
# Days/Date dentro del propio elemento Expiration. Un delete marker expira
# cuando ya no quedan versiones no actuales detrás de él (las limpia
# NoncurrentVersionExpiration a los 365 días).
# La regla abortar-multipart-incompletos es un extra de buenas prácticas.
#
# Uso:
#   ./03-versionado-lifecycle.sh [--dry-run] [--demo] [-y]
#
# Variables: BUCKET, AWS_REGION, ADMIN_PROFILE, DEMO_KEY (def. prueba.jpg)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"

DEMO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) DEMO=1 ;;
    -h | --help) mostrar_ayuda "$0"; exit 0 ;;
    *) procesar_flag_comun "$1" || fail "Opción desconocida: $1 (usa --help)" ;;
  esac
  shift
done

DEMO_KEY="${DEMO_KEY:-prueba.jpg}"

requerir_aws
validar_nombre_bucket "$BUCKET"
mostrar_config
requerir_bucket "$BUCKET" "$AWS_REGION"

# --- Parte A: versionado ---
info "Activando el versionado"
aws_admin s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

if es_dry_run; then
  aws_admin s3api get-bucket-versioning --bucket "$BUCKET"
else
  estado="$(aws_admin s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text)"
  if [ "$estado" = "Enabled" ]; then
    ok "Versionado: $estado."
  else
    fail "El versionado no quedó activo: $estado"
  fi
fi

# --- Parte B: demostración guiada (opcional) ---
demo_versionado() {
  local carpeta="$TMP_DIR/demo" i marcador cantidad_clave

  mkdir -p "$carpeta"
  info "Subiendo $DEMO_KEY tres veces con contenido distinto"
  for i in 1 2 3; do
    printf 'contenido de prueba, version %s, %s\n' "$i" "$(date +%s)" > "$carpeta/v$i.bin"
    head -c 2048 /dev/urandom >> "$carpeta/v$i.bin"
    aws_admin s3api put-object --bucket "$BUCKET" --key "$DEMO_KEY" \
      --body "$carpeta/v$i.bin" --content-type application/octet-stream
  done

  info "Versiones del objeto"
  aws_admin s3api list-object-versions --bucket "$BUCKET" --prefix "$DEMO_KEY" \
    --query 'Versions[].{VersionId:VersionId,Actual:IsLatest,Bytes:Size,Modificado:LastModified}' \
    --output table

  info "Eliminando el objeto (sin VersionId se crea un delete marker)"
  if es_dry_run; then
    aws_admin s3api delete-object --bucket "$BUCKET" --key "$DEMO_KEY"
    marcador="<VersionId-del-delete-marker>"
  else
    marcador="$(aws_admin s3api delete-object --bucket "$BUCKET" --key "$DEMO_KEY" \
      --query VersionId --output text)"
  fi

  info "Delete markers del objeto"
  aws_admin s3api list-object-versions --bucket "$BUCKET" --prefix "$DEMO_KEY" \
    --query 'DeleteMarkers[].{VersionId:VersionId,Actual:IsLatest,Modificado:LastModified}' \
    --output table

  if es_dry_run; then
    aws_admin s3api head-object --bucket "$BUCKET" --key "$DEMO_KEY"
  elif aws_admin_q s3api head-object --bucket "$BUCKET" --key "$DEMO_KEY" >/dev/null 2>&1; then
    aviso "El objeto sigue visible tras eliminarlo; se detiene la restauración."
    return 0
  else
    ok "El objeto aparece eliminado (404): solo existe el delete marker."
  fi

  # Seguridad: solo se borra la versión indicada si de verdad es un delete marker.
  if ! es_dry_run; then
    cantidad_clave="$(aws_admin s3api list-object-versions --bucket "$BUCKET" --prefix "$DEMO_KEY" \
      --query "DeleteMarkers[?VersionId=='$marcador'].Key | [0]" --output text)"
    if [ "$cantidad_clave" != "$DEMO_KEY" ]; then
      fail "La versión $marcador no es un delete marker de $DEMO_KEY; no se elimina."
    fi
  fi

  info "Restaurando: se borra el delete marker (delete-object con su VersionId)"
  aws_admin s3api delete-object --bucket "$BUCKET" --key "$DEMO_KEY" --version-id "$marcador"

  if es_dry_run; then
    aws_admin s3api head-object --bucket "$BUCKET" --key "$DEMO_KEY"
  elif aws_admin_q s3api head-object --bucket "$BUCKET" --key "$DEMO_KEY" >/dev/null 2>&1; then
    ok "Objeto restaurado: la última versión vuelve a estar disponible."
  else
    fail "El objeto no se restauró."
  fi
}

if [ "$DEMO" = "1" ]; then
  demo_versionado
else
  info "Sin --demo: se omite la demostración de versiones y delete markers."
fi

# --- Parte C: ciclo de vida ---
info "Aplicando la configuración de ciclo de vida"
doc_ciclo="$(render_a_tmp "$POLICIES_DIR/lifecycle.json.tpl")"
aws_admin s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "file://$doc_ciclo"

info "Verificando las reglas aplicadas"
aws_admin s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[].{ID:ID,Estado:Status,Prefijo:Filter.Prefix}' --output table

ok "Ejercicio 3 (A a C) aplicado."
