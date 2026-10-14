#!/usr/bin/env bash
# Configuración y utilidades comunes del laboratorio. Se carga con `source`.
#
# Prioridad de valores: variables de entorno > scripts/aws/.env > valores por defecto.
# Banderas comunes de los scripts: --dry-run, -y/--yes, -h/--help.

AWS_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="$AWS_SCRIPTS_DIR/policies"

# Solo estas variables se leen desde .env (no se evalúa código ni se aceptan credenciales).
_VARS_ENV=" BUCKET AWS_REGION ADMIN_PROFILE APP_PROFILE IAM_USER IAM_POLICY_NAME REPLICA_BUCKET REPLICA_REGION CORS_ORIGINS REPLICATION_ROLE EVIDENCIAS_DIR FOTOS_DIR DEMO_KEY "

_cargar_env() {
  local archivo="$1" linea clave valor
  [ -f "$archivo" ] || return 0
  while IFS= read -r linea || [ -n "$linea" ]; do
    linea="${linea%$'\r'}"
    linea="${linea#"${linea%%[![:space:]]*}"}"
    case "$linea" in '' | '#'*) continue ;; esac
    linea="${linea#export }"
    clave="${linea%%=*}"
    valor="${linea#*=}"
    [ "$clave" != "$linea" ] || continue
    case "$_VARS_ENV" in *" $clave "*) ;; *) continue ;; esac
    case "$valor" in
      \"*\") valor="${valor#\"}"; valor="${valor%\"}" ;;
      \'*\') valor="${valor#\'}"; valor="${valor%\'}" ;;
    esac
    if [ -z "${!clave+x}" ]; then
      export "$clave=$valor"
    fi
  done < "$archivo"
}

_cargar_env "$AWS_SCRIPTS_DIR/.env"

# --- valores por defecto ---
: "${BUCKET:=lab-imagenes-gomez-20261014}"
: "${AWS_REGION:=us-east-1}"
: "${ADMIN_PROFILE=default}"   # vacío = credenciales del entorno (p. ej. temporales)
: "${APP_PROFILE:=app-user}"
: "${IAM_USER:=app-imagenes-user}"
: "${IAM_POLICY_NAME:=app-imagenes-s3-minimo}"
: "${REPLICA_BUCKET:=${BUCKET}-replica}"
: "${REPLICA_REGION:=us-west-2}"
: "${REPLICATION_ROLE:=s3-replicacion-lab09}"
: "${CORS_ORIGINS:=http://localhost:3000,http://localhost:8080}"
: "${EVIDENCIAS_DIR:=$HOME/Downloads/Lab09-DSN-evidencias}"

REPLICATION_POLICY_NAME="${REPLICATION_ROLE}-permisos"

# CORS_ORIGINS acepta un arreglo JSON o una lista separada por comas/espacios.
_cors_a_json() {
  local crudo="$1" item salida="" lista=()
  case "$crudo" in
    '['*) printf '%s' "$crudo"; return 0 ;;
  esac
  crudo="${crudo//,/ }"
  read -r -a lista <<< "$crudo"
  if [ "${#lista[@]}" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  for item in "${lista[@]}"; do
    salida="${salida:+$salida, }\"$item\""
  done
  printf '[%s]' "$salida"
}
CORS_ORIGINS_JSON="$(_cors_a_json "$CORS_ORIGINS")"

case "${DRY_RUN:-0}" in 1 | true | TRUE | si | yes) DRY_RUN=1 ;; *) DRY_RUN=0 ;; esac
case "${ASSUME_YES:-0}" in 1 | true | TRUE | si | yes) ASSUME_YES=1 ;; *) ASSUME_YES=0 ;; esac
ACCOUNT_ID="${ACCOUNT_ID:-}"

# La AWS CLI v2 abre un paginador interactivo; en scripts se desactiva.
export AWS_PAGER=""

# Directorio temporal propio (plantillas renderizadas, archivos de prueba).
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lab09-aws.XXXXXX")"
_limpiar_tmp() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap _limpiar_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- mensajes ---
info()  { printf '[info] %s\n' "$*"; }
ok() {
  if es_dry_run; then
    printf '[ ok ] (simulado) %s\n' "$*"
  else
    printf '[ ok ] %s\n' "$*"
  fi
}
aviso() { printf '[aviso] %s\n' "$*" >&2; }
fail()  { printf '[error] %s\n' "$*" >&2; exit 1; }

es_dry_run() { [ "$DRY_RUN" = "1" ]; }

mostrar_ayuda() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}

# Procesa --dry-run y -y/--yes. Devuelve 1 si la bandera no es común.
procesar_flag_comun() {
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    *) return 1 ;;
  esac
}

# Pide escribir "si". Con ASSUME_YES=1 no pregunta. Devuelve 1 si se rechaza.
confirmar() {
  local resp
  if [ "$ASSUME_YES" = "1" ]; then
    info "$1 (confirmado con --yes)"
    return 0
  fi
  if es_dry_run; then
    info "[dry-run] se pediría confirmación: $1"
    return 0
  fi
  printf '%s\nEscribe "si" para continuar: ' "$1" >&2
  read -r resp || resp=""
  [ "$resp" = "si" ]
}

# Pide escribir un texto exacto (no se omite con --yes). Devuelve 1 si no coincide.
confirmar_escribiendo() {
  local esperado="$1" resp
  if es_dry_run; then
    info "[dry-run] se pediría escribir exactamente: $esperado"
    return 0
  fi
  printf '%s\nEscribe exactamente "%s" para confirmar: ' "$2" "$esperado" >&2
  read -r resp || resp=""
  [ "$resp" = "$esperado" ]
}

# --- ejecución de comandos ---
_citar() {
  case "$1" in
    *"'"*) printf '%q' "$1" ;;
    '' | *[!A-Za-z0-9_@%+=:,./-]*) printf "'%s'" "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# run: ejecuta el comando; con --dry-run solo lo imprime.
run() {
  if es_dry_run; then
    local arg linea="[dry-run]"
    for arg in "$@"; do
      linea="$linea $(_citar "$arg")"
    done
    printf '%s\n' "$linea"
    return 0
  fi
  "$@"
}

# consulta: como run, pero para capturas. En --dry-run imprime a stderr y
# devuelve 1 (se asume "no existe / sin datos").
consulta() {
  if es_dry_run; then
    local arg linea="[dry-run]"
    for arg in "$@"; do
      linea="$linea $(_citar "$arg")"
    done
    printf '%s\n' "$linea" >&2
    return 1
  fi
  "$@"
}

_aws_base() { # $1 perfil, $2 región -> AWS_CMD
  AWS_CMD=(aws)
  if [ -n "$1" ]; then
    AWS_CMD+=(--profile "$1")
  fi
  AWS_CMD+=(--region "$2")
}

aws_admin()      { _aws_base "$ADMIN_PROFILE" "$AWS_REGION"; run "${AWS_CMD[@]}" "$@"; }
aws_admin_q()    { _aws_base "$ADMIN_PROFILE" "$AWS_REGION"; consulta "${AWS_CMD[@]}" "$@"; }
aws_admin_en()   { local r="$1"; shift; _aws_base "$ADMIN_PROFILE" "$r"; run "${AWS_CMD[@]}" "$@"; }
aws_admin_en_q() { local r="$1"; shift; _aws_base "$ADMIN_PROFILE" "$r"; consulta "${AWS_CMD[@]}" "$@"; }
aws_app()        { _aws_base "$APP_PROFILE" "$AWS_REGION"; run "${AWS_CMD[@]}" "$@"; }
aws_app_q()      { _aws_base "$APP_PROFILE" "$AWS_REGION"; consulta "${AWS_CMD[@]}" "$@"; }

# --- verificaciones ---
validar_nombre_bucket() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' ||
    fail "Nombre de bucket inválido: $1 (3 a 63 caracteres: minúsculas, números, puntos y guiones)."
}

requerir_python() {
  command -v python3 >/dev/null 2>&1 || fail "Se necesita python3 para este paso."
}

# Verifica aws y, solo fuera de --dry-run, la identidad con ADMIN_PROFILE.
requerir_aws() {
  local salida version
  if es_dry_run; then
    if ! command -v aws >/dev/null 2>&1; then
      aviso "aws no está instalado (solo se simulan los comandos)."
    fi
    : "${ACCOUNT_ID:=123456789012}"
    info "Simulación (--dry-run): no se ejecuta ningún comando aws."
    return 0
  fi
  command -v aws >/dev/null 2>&1 ||
    fail "No se encontró la AWS CLI. Instálala (v2) y vuelve a ejecutar."
  version="$(aws --version 2>&1 || true)"
  case "$version" in
    aws-cli/2.*) ;;
    *) aviso "Se esperaba AWS CLI v2 y se encontró: $version" ;;
  esac
  _aws_base "$ADMIN_PROFILE" "$AWS_REGION"
  if ! salida="$("${AWS_CMD[@]}" sts get-caller-identity --query '[Account,Arn]' --output text 2>&1)"; then
    printf '%s\n' "$salida" >&2
    fail "No se pudo validar la identidad con el perfil '${ADMIN_PROFILE:-<entorno>}'. Revisa tus credenciales (aws configure, aws sso login o credenciales temporales exportadas con AWS_SESSION_TOKEN)."
  fi
  ACCOUNT_ID="${salida%%[[:space:]]*}"
  info "Cuenta AWS: $ACCOUNT_ID"
  info "Identidad:  ${salida#*[[:space:]]}"
}

# Con --dry-run se asume que el bucket existe para poder mostrar el plan.
requerir_bucket() { # $1 bucket, $2 región
  if es_dry_run; then
    return 0
  fi
  aws_admin_en_q "$2" s3api head-bucket --bucket "$1" >/dev/null 2>&1 ||
    fail "El bucket $1 no existe o no es accesible. Ejecuta antes el script que lo crea."
}

crear_bucket() { # $1 región, $2 nombre
  if [ "$1" = "us-east-1" ]; then
    aws_admin_en "$1" s3api create-bucket --bucket "$2"
  else
    aws_admin_en "$1" s3api create-bucket --bucket "$2" \
      --create-bucket-configuration "LocationConstraint=$1"
  fi
}

bloquear_acceso_publico() { # $1 región, $2 bucket
  aws_admin_en "$1" s3api put-public-access-block --bucket "$2" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
}

# --- plantillas ---
_escapar_sed() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Imprime la plantilla con los marcadores __X__ sustituidos.
render_plantilla() {
  local archivo="$1" salida
  [ -f "$archivo" ] || fail "No existe la plantilla: $archivo"
  salida="$(sed \
    -e "s|__BUCKET__|$(_escapar_sed "$BUCKET")|g" \
    -e "s|__REPLICA_BUCKET__|$(_escapar_sed "$REPLICA_BUCKET")|g" \
    -e "s|__ACCOUNT_ID__|$(_escapar_sed "$ACCOUNT_ID")|g" \
    -e "s|__REPLICATION_ROLE__|$(_escapar_sed "$REPLICATION_ROLE")|g" \
    -e "s|__CORS_ORIGINS__|$(_escapar_sed "$CORS_ORIGINS_JSON")|g" \
    "$archivo")"
  if printf '%s' "$salida" | grep -Eq '__[A-Z_]+__'; then
    fail "La plantilla $archivo conserva marcadores sin sustituir."
  fi
  printf '%s\n' "$salida"
}

# Renderiza a un archivo temporal, valida el JSON y devuelve la ruta.
render_a_tmp() {
  local destino
  destino="$TMP_DIR/$(basename "${1%.tpl}")"
  render_plantilla "$1" > "$destino"
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$destino" >/dev/null 2>&1 ||
      fail "El JSON renderizado de $(basename "$1") no es válido (revisa CORS_ORIGINS y las variables)."
  fi
  if es_dry_run; then
    printf '[dry-run] %s renderizado:\n' "$(basename "$destino")" >&2
    sed 's/^/    /' "$destino" >&2
  fi
  printf '%s' "$destino"
}

mostrar_config() {
  info "Bucket:       $BUCKET"
  info "Región:       $AWS_REGION"
  info "Perfil admin: ${ADMIN_PROFILE:-<credenciales del entorno>}"
}
