#!/usr/bin/env bash
# 02-seguridad-iam-cifrado.sh - Ejercicio 2 (partes A a C)
#
# 1. Usuario IAM sin consola y sin grupos, con una política propia de mínimo
#    privilegio adjunta directamente al usuario.
# 2. Política del bucket que obliga HTTPS (Deny con aws:SecureTransport=false).
# 3. Cifrado por defecto SSE-S3 (AES256) con Bucket Key.
# 4. CORS del bucket (orígenes de CORS_ORIGINS).
# 5. Access Key del usuario guardada directamente en el perfil APP_PROFILE;
#    nunca se imprime ni se escribe en archivos.
#
# Uso:
#   ./02-seguridad-iam-cifrado.sh [--dry-run] [--skip-iam] [-y]
#
#   --skip-iam   omite usuario, política y clave (AWS Academy / Learner Lab,
#                donde no se pueden crear usuarios IAM). Se aplican igual
#                la política HTTPS, el cifrado y el CORS.
#
# Variables: BUCKET, AWS_REGION, ADMIN_PROFILE, APP_PROFILE, IAM_USER,
#            IAM_POLICY_NAME, CORS_ORIGINS
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"

SKIP_IAM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-iam) SKIP_IAM=1 ;;
    -h | --help) mostrar_ayuda "$0"; exit 0 ;;
    *) procesar_flag_comun "$1" || fail "Opción desconocida: $1 (usa --help)" ;;
  esac
  shift
done

requerir_aws
validar_nombre_bucket "$BUCKET"
mostrar_config
requerir_bucket "$BUCKET" "$AWS_REGION"

ARN_POLITICA="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

# --- Parte A: usuario IAM y política ---
crear_usuario_y_politica() {
  local grupos documento version doc_iam

  if aws_admin_q iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    ok "El usuario IAM $IAM_USER ya existe."
  else
    info "Creando el usuario IAM $IAM_USER (sin acceso a consola y sin grupos)"
    aws_admin iam create-user --user-name "$IAM_USER"
  fi

  if aws_admin_q iam get-login-profile --user-name "$IAM_USER" >/dev/null 2>&1; then
    aviso "El usuario tiene contraseña de consola. Elimínala con: aws iam delete-login-profile --user-name $IAM_USER"
  fi
  grupos="$(aws_admin_q iam list-groups-for-user --user-name "$IAM_USER" \
    --query 'Groups[].GroupName' --output text 2>/dev/null || true)"
  if [ -n "$grupos" ]; then
    aviso "El usuario pertenece a grupos ($grupos); la política debe ir adjunta directamente, sin grupos."
  fi

  if aws_admin_q iam get-policy --policy-arn "$ARN_POLITICA" >/dev/null 2>&1; then
    ok "La política $IAM_POLICY_NAME ya existe; se reutiliza."
    version="$(aws_admin_q iam get-policy --policy-arn "$ARN_POLITICA" \
      --query 'Policy.DefaultVersionId' --output text || true)"
    documento="$(aws_admin_q iam get-policy-version --policy-arn "$ARN_POLITICA" \
      --version-id "$version" --query 'PolicyVersion.Document' --output json || true)"
    if ! printf '%s' "$documento" | grep -Fq "arn:aws:s3:::${BUCKET}/*"; then
      aviso "La política existente no menciona el bucket $BUCKET; revisa IAM_POLICY_NAME."
    fi
  else
    info "Creando la política administrada $IAM_POLICY_NAME"
    doc_iam="$(render_a_tmp "$POLICIES_DIR/iam-app-user.json.tpl")"
    aws_admin iam create-policy --policy-name "$IAM_POLICY_NAME" \
      --policy-document "file://$doc_iam" \
      --description "Acceso minimo de la aplicacion al bucket de imagenes (laboratorio 09)"
  fi

  info "Adjuntando la política directamente al usuario"
  aws_admin iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$ARN_POLITICA"
  ok "Usuario y política listos."
}

# --- Parte A (continuación): Access Key directo al perfil local ---
crear_clave_en_perfil() {
  local actual existentes n k id secreto salida

  case $- in *x*) set +x ;; esac

  existentes="$(aws_admin_q iam list-access-keys --user-name "$IAM_USER" \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true)"
  n=0
  for k in $existentes; do
    n=$((n + 1))
  done

  if ! es_dry_run; then
    actual="$(aws configure get aws_access_key_id --profile "$APP_PROFILE" 2>/dev/null || true)"
    if [ -n "$actual" ]; then
      for k in $existentes; do
        if [ "$k" = "$actual" ]; then
          ok "El perfil $APP_PROFILE ya usa una clave vigente de $IAM_USER; no se crea otra."
          return 0
        fi
      done
      aviso "El perfil $APP_PROFILE tenía otra clave configurada; se reemplazará."
    fi
  fi

  if [ "$n" -ge 2 ]; then
    aviso "El usuario $IAM_USER ya tiene 2 Access Keys (límite de IAM). No se crea otra."
    aviso "Elimina una con: aws iam delete-access-key --user-name $IAM_USER --access-key-id <ID>"
    return 0
  fi

  info "Creando la Access Key y guardándola en el perfil $APP_PROFILE"
  if es_dry_run; then
    aws_admin iam create-access-key --user-name "$IAM_USER" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
    id="AKIAXXXXXXXXXXXXXXXX"
    secreto="<secreto-no-se-muestra>"
  else
    salida="$(aws_admin iam create-access-key --user-name "$IAM_USER" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
    id="${salida%%[[:space:]]*}"
    secreto="${salida##*[[:space:]]}"
    unset salida
  fi

  run aws configure set aws_access_key_id "$id" --profile "$APP_PROFILE"
  run aws configure set aws_secret_access_key "$secreto" --profile "$APP_PROFILE"
  run aws configure set region "$AWS_REGION" --profile "$APP_PROFILE"
  run aws configure set output json --profile "$APP_PROFILE"

  ok "Access Key ${id%????}**** guardada en el perfil $APP_PROFILE."
  unset id secreto
}

if [ "$SKIP_IAM" = "1" ]; then
  info "--skip-iam: se omiten usuario IAM, política y Access Key."
else
  if [ -z "$APP_PROFILE" ] || [ "$APP_PROFILE" = "default" ] || [ "$APP_PROFILE" = "$ADMIN_PROFILE" ]; then
    fail "APP_PROFILE ('$APP_PROFILE') no puede ser vacío, 'default' ni igual a ADMIN_PROFILE."
  fi
  crear_usuario_y_politica
  crear_clave_en_perfil
fi

# --- Parte B: solo HTTPS ---
info "Aplicando la política del bucket que exige HTTPS"
doc_https="$(render_a_tmp "$POLICIES_DIR/bucket-https-only.json.tpl")"
aws_admin s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$doc_https"

# --- Parte C: cifrado por defecto SSE-S3 ---
info "Configurando cifrado por defecto SSE-S3 (AES256) con Bucket Key"
aws_admin s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

if es_dry_run; then
  aws_admin s3api get-bucket-encryption --bucket "$BUCKET"
else
  algoritmo="$(aws_admin s3api get-bucket-encryption --bucket "$BUCKET" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text)"
  if [ "$algoritmo" = "AES256" ]; then
    ok "Cifrado por defecto verificado: $algoritmo."
  else
    fail "El cifrado por defecto no es AES256: $algoritmo"
  fi
fi

# --- CORS ---
info "Aplicando CORS (orígenes: $CORS_ORIGINS_JSON)"
doc_cors="$(render_a_tmp "$POLICIES_DIR/cors.json.tpl")"
aws_admin s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration "file://$doc_cors"

ok "Ejercicio 2 (A a C) aplicado. Valida con ./04-validar-politicas.sh"
