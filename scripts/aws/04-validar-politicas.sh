#!/usr/bin/env bash
# 04-validar-politicas.sh - Ejercicio 2 (parte D)
#
# Prueba con el perfil APP_PROFILE que la política de mínimo privilegio, el
# cifrado por defecto y la política HTTPS funcionan:
#   T1 listar el bucket                       -> permitido
#   T2 listar todos los buckets (aws s3 ls)   -> denegado (sin s3:ListAllMyBuckets)
#   T3 subir un archivo temporal a originales/ -> permitido
#   T4 head-object                            -> ServerSideEncryption AES256
#   T5 delete-bucket                          -> denegado (AccessDenied)
#   T6 URL prefirmada por HTTPS               -> 200 (control)
#   T7 la misma URL por HTTP                  -> 403 (Deny aws:SecureTransport=false)
#   T8 eliminar el objeto temporal            -> permitido
# El resumen se guarda en $EVIDENCIAS_DIR/validacion-politicas.txt
# (def. ~/Downloads/Lab09-DSN-evidencias), sin credenciales ni URL firmadas.
#
# Uso:
#   ./04-validar-politicas.sh [--dry-run]
#
# Variables: BUCKET, AWS_REGION, APP_PROFILE, ADMIN_PROFILE, EVIDENCIAS_DIR
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) mostrar_ayuda "$0"; exit 0 ;;
    *) procesar_flag_comun "$1" || fail "Opción desconocida: $1 (usa --help)" ;;
  esac
  shift
done

validar_nombre_bucket "$BUCKET"
if es_dry_run; then
  info "Simulación (--dry-run): no se ejecuta ningún comando aws ni curl."
else
  command -v aws >/dev/null 2>&1 || fail "No se encontró la AWS CLI."
  perfiles="$(aws configure list-profiles 2>/dev/null || true)"
  if [ -n "$APP_PROFILE" ] && ! printf '%s\n' "$perfiles" | grep -qx -- "$APP_PROFILE"; then
    fail "El perfil '$APP_PROFILE' no existe. Ejecuta ./02-seguridad-iam-cifrado.sh o configúralo."
  fi
fi
info "Bucket:         $BUCKET"
info "Perfil de app:  ${APP_PROFILE:-<credenciales del entorno>}"

RESULTADOS=()
PASS=0
FAIL=0
OMITIDO=0
SALIDA=""
CODIGO=0

registrar() { # estado nombre detalle
  RESULTADOS+=("$1|$2|$3")
  case "$1" in
    PASS) PASS=$((PASS + 1)); ok "PASS  $2" ;;
    FAIL) FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$2" >&2 ;;
    *) OMITIDO=$((OMITIDO + 1)); info "OMITIDO  $2" ;;
  esac
  if [ -n "$3" ]; then
    info "      $3"
  fi
}

# Ejecuta "$@" y deja la salida en SALIDA y el código de salida en CODIGO.
capturar() {
  set +e
  SALIDA="$("$@" 2>&1)"
  CODIGO=$?
  set -e
}

codigo_error() { # extrae solo el código de error de AWS (sin ARN ni cuenta)
  printf '%s' "$SALIDA" | grep -Eo 'An error occurred \([A-Za-z0-9]+\)' | sed -n '1p' || true
}

CLAVE="originales/validacion-$(date +%Y%m%d%H%M%S).txt"
ARCHIVO="$TMP_DIR/validacion.txt"
printf 'archivo temporal de validacion de politicas\n' > "$ARCHIVO"

t1_listar_bucket() {
  local nombre="T1 aws s3 ls s3://$BUCKET/ (permitido)"
  if es_dry_run; then
    aws_app s3 ls "s3://$BUCKET/"
    registrar OMITIDO "$nombre" ""
    return 0
  fi
  capturar aws_app_q s3 ls "s3://$BUCKET/"
  if [ "$CODIGO" -eq 0 ]; then
    registrar PASS "$nombre" ""
  else
    registrar FAIL "$nombre" "$(codigo_error)"
  fi
}

t2_listar_todos() {
  local nombre="T2 aws s3 ls sin ruta (denegado: la política no incluye s3:ListAllMyBuckets)"
  if es_dry_run; then
    aws_app s3 ls
    registrar OMITIDO "$nombre" ""
    return 0
  fi
  capturar aws_app_q s3 ls
  if [ "$CODIGO" -ne 0 ]; then
    registrar PASS "$nombre" "$(codigo_error)"
  else
    registrar FAIL "$nombre" "El perfil puede listar todos los buckets: permisos mayores al mínimo."
  fi
}

t3_subir() {
  local nombre="T3 subir archivo temporal a originales/ (permitido)"
  if es_dry_run; then
    aws_app s3 cp "$ARCHIVO" "s3://$BUCKET/$CLAVE"
    registrar OMITIDO "$nombre" ""
    return 0
  fi
  capturar aws_app_q s3 cp "$ARCHIVO" "s3://$BUCKET/$CLAVE"
  if [ "$CODIGO" -eq 0 ]; then
    registrar PASS "$nombre" ""
  else
    registrar FAIL "$nombre" "$(codigo_error)"
  fi
}

t4_cifrado() {
  local nombre="T4 head-object: ServerSideEncryption = AES256"
  if es_dry_run; then
    aws_app s3api head-object --bucket "$BUCKET" --key "$CLAVE" --query ServerSideEncryption --output text
    registrar OMITIDO "$nombre" ""
    return 0
  fi
  capturar aws_app_q s3api head-object --bucket "$BUCKET" --key "$CLAVE" \
    --query ServerSideEncryption --output text
  if [ "$CODIGO" -eq 0 ] && [ "$SALIDA" = "AES256" ]; then
    registrar PASS "$nombre" "ServerSideEncryption=$SALIDA"
  else
    registrar FAIL "$nombre" "$(codigo_error) ${SALIDA:0:40}"
  fi
}

t5_borrar_bucket() {
  local nombre="T5 aws s3api delete-bucket (debe fallar)"
  if es_dry_run; then
    aws_app s3api delete-bucket --bucket "$BUCKET"
    registrar OMITIDO "$nombre" ""
    return 0
  fi
  if [ -z "$APP_PROFILE" ] || [ "$APP_PROFILE" = "$ADMIN_PROFILE" ]; then
    registrar OMITIDO "$nombre" "el perfil de la app coincide con el de administración; no se prueba."
    return 0
  fi
  capturar aws_app_q s3api delete-bucket --bucket "$BUCKET"
  if [ "$CODIGO" -ne 0 ]; then
    registrar PASS "$nombre" "$(codigo_error)"
  else
    registrar FAIL "$nombre" "El perfil pudo borrar el bucket."
  fi
}

t6_t7_https() {
  local nombre_https="T6 GET por HTTPS con URL prefirmada (control, 200)"
  local nombre_http="T7 GET por HTTP con la misma URL (403 por aws:SecureTransport)"
  local url url_http codigo

  if es_dry_run; then
    aws_app s3 presign "s3://$BUCKET/$CLAVE" --expires-in 300
    printf '[dry-run] curl -sS -o /dev/null -w %%{http_code} <url https>\n'
    printf '[dry-run] curl -sS -o /dev/null -w %%{http_code} <url http>\n'
    registrar OMITIDO "$nombre_https" ""
    registrar OMITIDO "$nombre_http" ""
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    registrar OMITIDO "$nombre_https" "curl no está instalado"
    registrar OMITIDO "$nombre_http" "curl no está instalado"
    return 0
  fi

  if ! url="$(aws_app_q s3 presign "s3://$BUCKET/$CLAVE" --expires-in 300 2>/dev/null)" || [ -z "$url" ]; then
    registrar FAIL "$nombre_https" "No se pudo generar la URL prefirmada."
    registrar FAIL "$nombre_http" "No se pudo generar la URL prefirmada."
    return 0
  fi

  # La URL se pasa por stdin a curl para que no aparezca en la lista de procesos.
  codigo="$(printf 'url = "%s"\n' "$url" | curl -sS -K - -o /dev/null -w '%{http_code}' --max-time 20 2>/dev/null || true)"
  if [ "$codigo" = "200" ]; then
    registrar PASS "$nombre_https" "HTTP $codigo"
  else
    registrar FAIL "$nombre_https" "HTTP ${codigo:-000}"
  fi

  url_http="http://${url#https://}"
  codigo="$(printf 'url = "%s"\n' "$url_http" | curl -sS -K - -o /dev/null -w '%{http_code}' --max-time 20 2>/dev/null || true)"
  if [ "$codigo" = "403" ]; then
    registrar PASS "$nombre_http" "HTTP $codigo: la política Deny con aws:SecureTransport=false bloquea HTTP."
  else
    registrar FAIL "$nombre_http" "HTTP ${codigo:-000} (se esperaba 403)"
  fi
  unset url url_http
}

t8_eliminar() {
  local nombre="T8 eliminar el objeto temporal (permitido)"
  if es_dry_run; then
    aws_app s3 rm "s3://$BUCKET/$CLAVE"
    registrar OMITIDO "$nombre" ""
    return 0
  fi
  capturar aws_app_q s3 rm "s3://$BUCKET/$CLAVE"
  if [ "$CODIGO" -eq 0 ]; then
    registrar PASS "$nombre" ""
  else
    registrar FAIL "$nombre" "$(codigo_error)"
  fi
}

t1_listar_bucket
t2_listar_todos
t3_subir
t4_cifrado
t5_borrar_bucket
t6_t7_https
t8_eliminar

echo
info "Resumen: $PASS PASS, $FAIL FAIL, $OMITIDO OMITIDO"

# Archivo de evidencias (fuera del repositorio; sin credenciales).
if es_dry_run; then
  info "[dry-run] se escribiría $EVIDENCIAS_DIR/validacion-politicas.txt"
else
  mkdir -p "$EVIDENCIAS_DIR"
  destino="$EVIDENCIAS_DIR/validacion-politicas.txt"
  {
    echo "Validación de políticas - Lab09-DSN"
    echo "Fecha:    $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Bucket:   $BUCKET"
    echo "Región:   $AWS_REGION"
    echo "Perfil:   ${APP_PROFILE:-<entorno>}"
    echo
    for fila in "${RESULTADOS[@]}"; do
      estado="${fila%%|*}"
      resto="${fila#*|}"
      printf '[%s] %s\n' "$estado" "${resto%%|*}"
      detalle="${resto#*|}"
      if [ -n "$detalle" ]; then
        printf '       %s\n' "$detalle"
      fi
    done
    echo
    echo "Resumen: $PASS PASS, $FAIL FAIL, $OMITIDO OMITIDO"
  } > "$destino"
  ok "Evidencias guardadas en $destino"
fi

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
