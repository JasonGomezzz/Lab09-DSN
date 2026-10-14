#!/usr/bin/env bash
# 06-object-tags.sh - Reto opcional: Object Tags
#
# La aplicación etiqueta los objetos al subirlos (parámetro x-amz-tagging
# firmado en la propia URL prefirmada) y los lee con GetObjectTagging. La política del
# enunciado no incluye esos permisos y no se modifica; este script agrega una
# segunda política:
#   1. Política administrada propia IAM_TAGS_POLICY_NAME con solo
#      s3:PutObjectTagging y s3:GetObjectTagging sobre BUCKET/*, adjunta
#      directamente al usuario IAM_USER (se reutiliza si ya existe y no se
#      duplica la adjunción).
#   2. Prueba con el perfil APP_PROFILE: sube un objeto temporal a originales/
#      con --tagging "proyecto=lab09&cliente=demo", lee las etiquetas con
#      get-object-tagging, comprueba que coinciden y borra el objeto.
# El resumen se guarda en $EVIDENCIAS_DIR/validacion-tags.txt
# (def. ~/Downloads/Lab09-DSN-evidencias), sin credenciales.
#
# Uso:
#   ./06-object-tags.sh [--dry-run] [--skip-iam] [-y]
#
#   --skip-iam   omite la política, su adjunción y la validación con
#                APP_PROFILE (AWS Academy / Learner Lab). La plantilla
#                policies/iam-app-user-tags.json.tpl queda para la consola.
#
# Requiere el usuario IAM y el bucket (./01 y ./02).
#
# Variables: BUCKET, AWS_REGION, ADMIN_PROFILE, APP_PROFILE, IAM_USER,
#            IAM_TAGS_POLICY_NAME, EVIDENCIAS_DIR
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

ARN_POLITICA_TAGS="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_TAGS_POLICY_NAME}"
ETIQUETAS="proyecto=lab09&cliente=demo"
CAMBIO_IAM=0

# --- Política de etiquetas adjunta al usuario ---
adjuntar_politica_tags() {
  local doc_tags adjunta version documento

  if ! es_dry_run && ! aws_admin_q iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    fail "El usuario IAM $IAM_USER no existe. Ejecuta antes ./02-seguridad-iam-cifrado.sh."
  fi

  if aws_admin_q iam get-policy --policy-arn "$ARN_POLITICA_TAGS" >/dev/null 2>&1; then
    ok "La política $IAM_TAGS_POLICY_NAME ya existe; se reutiliza."
    version="$(aws_admin_q iam get-policy --policy-arn "$ARN_POLITICA_TAGS" \
      --query 'Policy.DefaultVersionId' --output text || true)"
    documento="$(aws_admin_q iam get-policy-version --policy-arn "$ARN_POLITICA_TAGS" \
      --version-id "$version" --query 'PolicyVersion.Document' --output json || true)"
    if ! printf '%s' "$documento" | grep -Fq "arn:aws:s3:::${BUCKET}/*" ||
      ! printf '%s' "$documento" | grep -Fq "s3:PutObjectTagging" ||
      ! printf '%s' "$documento" | grep -Fq "s3:GetObjectTagging"; then
      aviso "La política existente no coincide con $BUCKET y las dos acciones de etiquetas; revisa IAM_TAGS_POLICY_NAME."
    fi
  else
    info "Creando la política administrada $IAM_TAGS_POLICY_NAME (solo s3:PutObjectTagging y s3:GetObjectTagging)"
    doc_tags="$(render_a_tmp "$POLICIES_DIR/iam-app-user-tags.json.tpl")"
    aws_admin iam create-policy --policy-name "$IAM_TAGS_POLICY_NAME" \
      --policy-document "file://$doc_tags" \
      --description "Etiquetas de objetos de la aplicacion en el bucket de imagenes (laboratorio 09)"
    CAMBIO_IAM=1
  fi

  adjunta="$(aws_admin_q iam list-attached-user-policies --user-name "$IAM_USER" \
    --query "AttachedPolicies[?PolicyArn=='${ARN_POLITICA_TAGS}'].PolicyArn" \
    --output text 2>/dev/null || true)"
  if [ -n "$adjunta" ] && [ "$adjunta" != "None" ]; then
    ok "La política $IAM_TAGS_POLICY_NAME ya está adjunta a $IAM_USER."
  else
    info "Adjuntando la política directamente al usuario"
    aws_admin iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$ARN_POLITICA_TAGS"
    CAMBIO_IAM=1
  fi
  ok "Política de etiquetas lista (la del enunciado, $IAM_POLICY_NAME, no se modifica)."
}

# --- Validación con el perfil de la aplicación ---
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

codigo_error() { # solo el código de error de AWS (sin ARN ni cuenta)
  printf '%s' "$SALIDA" | grep -Eo 'An error occurred \([A-Za-z0-9]+\)' | sed -n '1p' || true
}

validar_etiquetas() {
  local clave archivo perfiles intento=1 maximo=1 subido=0
  local n_subir="T1 put-object con --tagging \"$ETIQUETAS\" en originales/ (permitido)"
  local n_leer="T2 get-object-tagging devuelve proyecto=lab09 y cliente=demo"
  local n_borrar="T3 eliminar el objeto temporal (permitido)"

  clave="originales/validacion-tags-$(date +%s).txt"
  archivo="$TMP_DIR/validacion-tags.txt"
  printf 'archivo temporal de validacion de etiquetas\n' > "$archivo"

  if es_dry_run; then
    aws_app s3api put-object --bucket "$BUCKET" --key "$clave" --body "$archivo" --tagging "$ETIQUETAS"
    aws_app s3api get-object-tagging --bucket "$BUCKET" --key "$clave" \
      --query 'TagSet[].[Key,Value]' --output text
    aws_app s3api delete-object --bucket "$BUCKET" --key "$clave"
    registrar OMITIDO "$n_subir" ""
    registrar OMITIDO "$n_leer" ""
    registrar OMITIDO "$n_borrar" ""
    return 0
  fi

  perfiles="$(aws configure list-profiles 2>/dev/null || true)"
  if [ -n "$APP_PROFILE" ] && ! printf '%s\n' "$perfiles" | grep -qx -- "$APP_PROFILE"; then
    aviso "El perfil '$APP_PROFILE' no existe; se omite la validación. Ejecuta ./02-seguridad-iam-cifrado.sh o configúralo."
    return 0
  fi

  # Un permiso IAM recién adjunto puede tardar unos segundos en propagarse.
  if [ "$CAMBIO_IAM" = "1" ]; then
    maximo=5
  fi
  while :; do
    capturar aws_app_q s3api put-object --bucket "$BUCKET" --key "$clave" \
      --body "$archivo" --tagging "$ETIQUETAS"
    if [ "$CODIGO" -eq 0 ] || [ "$intento" -ge "$maximo" ]; then
      break
    fi
    info "Esperando 5 s a que IAM propague el permiso (intento $intento de $maximo)"
    sleep 5
    intento=$((intento + 1))
  done
  if [ "$CODIGO" -eq 0 ]; then
    subido=1
    registrar PASS "$n_subir" ""
  else
    registrar FAIL "$n_subir" "$(codigo_error)"
  fi

  if [ "$subido" = "1" ]; then
    capturar aws_app_q s3api get-object-tagging --bucket "$BUCKET" --key "$clave" \
      --query 'TagSet[].[Key,Value]' --output text
    if [ "$CODIGO" -eq 0 ] &&
      printf '%s\n' "$SALIDA" | tr '\t' '=' | grep -qx 'proyecto=lab09' &&
      printf '%s\n' "$SALIDA" | tr '\t' '=' | grep -qx 'cliente=demo'; then
      registrar PASS "$n_leer" "proyecto=lab09, cliente=demo"
    else
      registrar FAIL "$n_leer" "$(codigo_error) ${SALIDA:0:80}"
    fi

    capturar aws_app_q s3api delete-object --bucket "$BUCKET" --key "$clave"
    if [ "$CODIGO" -eq 0 ]; then
      registrar PASS "$n_borrar" ""
    else
      registrar FAIL "$n_borrar" "$(codigo_error)"
    fi
  else
    registrar OMITIDO "$n_leer" "no se subió el objeto de prueba"
    registrar OMITIDO "$n_borrar" "no se subió el objeto de prueba"
  fi
}

escribir_evidencias() {
  local destino fila estado resto detalle
  if es_dry_run; then
    info "[dry-run] se escribiría $EVIDENCIAS_DIR/validacion-tags.txt"
    return 0
  fi
  mkdir -p "$EVIDENCIAS_DIR"
  destino="$EVIDENCIAS_DIR/validacion-tags.txt"
  {
    echo "Validación de Object Tags - Lab09-DSN"
    echo "Fecha:    $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Bucket:   $BUCKET"
    echo "Región:   $AWS_REGION"
    echo "Perfil:   ${APP_PROFILE:-<entorno>}"
    echo "Política: $IAM_TAGS_POLICY_NAME (s3:PutObjectTagging, s3:GetObjectTagging)"
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
}

if [ "$SKIP_IAM" = "1" ]; then
  info "--skip-iam: se omiten la política de etiquetas y su adjunción."
  aviso "Se omite la validación con el perfil de la app. Adjunta s3:PutObjectTagging y s3:GetObjectTagging con policies/iam-app-user-tags.json.tpl si tu laboratorio lo permite."
else
  if [ -z "$APP_PROFILE" ] || [ "$APP_PROFILE" = "default" ] || [ "$APP_PROFILE" = "$ADMIN_PROFILE" ]; then
    fail "APP_PROFILE ('$APP_PROFILE') no puede ser vacío, 'default' ni igual a ADMIN_PROFILE."
  fi
  adjuntar_politica_tags
  validar_etiquetas
  if [ "${#RESULTADOS[@]}" -gt 0 ]; then
    echo
    info "Resumen: $PASS PASS, $FAIL FAIL, $OMITIDO OMITIDO"
    escribir_evidencias
  fi
fi

echo
info "La app firma x-amz-tagging dentro de la URL prefirmada de subida; el navegador no envía cabeceras extra."

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
