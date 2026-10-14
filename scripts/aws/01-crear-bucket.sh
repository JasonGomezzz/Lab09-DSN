#!/usr/bin/env bash
# 01-crear-bucket.sh - Ejercicio 1 (partes A y B)
#
# Crea el bucket privado, activa Block all public access (los 4 indicadores),
# crea los prefijos originales/, miniaturas/ y temporal/ y, si existe ./fotos/,
# sube y lista archivos de demostración con aws s3 cp/sync/ls.
# Es idempotente: si el bucket ya existe se reutiliza.
#
# Uso:
#   ./01-crear-bucket.sh [--dry-run] [--sin-fotos] [-y]
#
# Variables: BUCKET, AWS_REGION, ADMIN_PROFILE, FOTOS_DIR (def. ./fotos)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"

SIN_FOTOS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sin-fotos) SIN_FOTOS=1 ;;
    -h | --help) mostrar_ayuda "$0"; exit 0 ;;
    *) procesar_flag_comun "$1" || fail "Opción desconocida: $1 (usa --help)" ;;
  esac
  shift
done

FOTOS_DIR="${FOTOS_DIR:-./fotos}"

requerir_aws
validar_nombre_bucket "$BUCKET"
mostrar_config

# A. Bucket
if aws_admin_q s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  ok "El bucket $BUCKET ya existe; se reutiliza."
else
  info "Creando el bucket $BUCKET en $AWS_REGION"
  crear_bucket "$AWS_REGION" "$BUCKET" ||
    fail "No se pudo crear el bucket. El nombre debe ser único en todo AWS; cambia BUCKET."
  aws_admin s3api wait bucket-exists --bucket "$BUCKET"
  ok "Bucket creado."
fi

# Block all public access
info "Activando Block all public access"
bloquear_acceso_publico "$AWS_REGION" "$BUCKET"

# Prefijos (objetos vacíos cuya clave termina en "/")
for prefijo in originales miniaturas temporal; do
  info "Creando el prefijo $prefijo/"
  aws_admin s3api put-object --bucket "$BUCKET" --key "$prefijo/"
done

# B. Demostración opcional con archivos locales
EJEMPLO="originales/foto-ejemplo.jpg"
if [ "$SIN_FOTOS" = "0" ] && [ -d "$FOTOS_DIR" ]; then
  primera="$(find "$FOTOS_DIR" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sed -n '1p')"
  if [ -n "$primera" ]; then
    EJEMPLO="originales/$(basename "$primera")"
    info "Subiendo un archivo con aws s3 cp"
    aws_admin s3 cp "$primera" "s3://$BUCKET/$EJEMPLO"
    info "Sincronizando $FOTOS_DIR con aws s3 sync"
    aws_admin s3 sync "$FOTOS_DIR" "s3://$BUCKET/originales/" \
      --exclude '*' --include '*.jpg' --include '*.jpeg' --include '*.png'
    info "Listando con aws s3 ls"
    aws_admin s3 ls "s3://$BUCKET/originales/" --human-readable --summarize
  else
    info "$FOTOS_DIR no contiene imágenes (.jpg, .jpeg, .png); se omite la demostración."
  fi
else
  info "No hay carpeta $FOTOS_DIR (o --sin-fotos); se omite la demostración de cp/sync/ls."
fi

# Verificación del bloqueo
info "Verificando Block all public access"
if es_dry_run; then
  aws_admin s3api get-public-access-block --bucket "$BUCKET"
else
  estado="$(aws_admin s3api get-public-access-block --bucket "$BUCKET" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text | tr '\t' ' ')"
  if [ "$estado" = "True True True True" ]; then
    ok "BlockPublicAcls, IgnorePublicAcls, BlockPublicPolicy y RestrictPublicBuckets: todos en true."
  else
    fail "El bloqueo de acceso público no está completo: $estado"
  fi
fi

# ARN vs URL
echo
info "ARN del bucket:   arn:aws:s3:::$BUCKET"
info "ARN del objeto:   arn:aws:s3:::$BUCKET/$EJEMPLO"
info "URL del objeto:   https://$BUCKET.s3.$AWS_REGION.amazonaws.com/$EJEMPLO"
info "El ARN identifica el recurso en políticas IAM; la URL es la dirección de acceso y"
info "responde 403 sin firma porque el bucket es privado."
