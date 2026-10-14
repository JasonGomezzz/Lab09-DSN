#!/usr/bin/env bash
# 07-miniaturas-lambda.sh - Reto opcional: miniaturas con AWS Lambda
#
# Cada objeto nuevo bajo originales/ genera su miniatura bajo miniaturas/:
#   1. Empaqueta LAMBDA_SRC_DIR (def. lambda/miniaturas) con npm para linux
#      x64, porque sharp trae binarios nativos, y lo comprime en un .zip
#      temporal.
#   2. Rol IAM LAMBDA_ROLE: confianza lambda.amazonaws.com, política
#      administrada AWSLambdaBasicExecutionRole (logs) y política en línea
#      mínima (s3:GetObject sobre originales/* y s3:PutObject sobre
#      miniaturas/*).
#   3. Función LAMBDA_NAME (x86_64, handler index.handler): se crea o se
#      actualiza código y configuración.
#   4. Permiso para que S3 invoque la función (solo desde BUCKET y esta cuenta).
#   5. Notificación del bucket: s3:ObjectCreated:* con prefijo originales/.
#   6. Verificación (omitible con --sin-prueba): sube un PNG de 64x64 con
#      ADMIN_PROFILE, espera la miniatura hasta 5 min (S3 puede tardar unos
#      minutos en aplicar una notificación recién configurada), compara
#      tamaños y borra ambos objetos. Resumen en $EVIDENCIAS_DIR/validacion-miniaturas.txt.
#
# AVISO: put-bucket-notification-configuration REEMPLAZA toda la configuración
# de notificaciones del bucket (SNS, SQS, otras funciones y EventBridge). Si el
# bucket ya tiene otras, el script las muestra y pide confirmación.
# Es idempotente. Lambda tiene capa gratuita (centavos como máximo); elimina
# todo con ./99-limpiar.sh al terminar.
#
# Uso:
#   ./07-miniaturas-lambda.sh [--dry-run] [--sin-prueba] [-y]
#
#   --sin-prueba   no sube el PNG de verificación
#
# Requiere aws, python3, zip y npm (>= 10 para --os/--cpu/--libc).
#
# Variables: BUCKET, AWS_REGION, ADMIN_PROFILE, EVIDENCIAS_DIR, LAMBDA_NAME,
#            LAMBDA_ROLE, LAMBDA_RUNTIME, LAMBDA_MEMORY, LAMBDA_TIMEOUT,
#            THUMB_WIDTH, LAMBDA_SRC_DIR
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"

SIN_PRUEBA=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sin-prueba) SIN_PRUEBA=1 ;;
    -h | --help) mostrar_ayuda "$0"; exit 0 ;;
    *) procesar_flag_comun "$1" || fail "Opción desconocida: $1 (usa --help)" ;;
  esac
  shift
done

validar_entero() { # $1 nombre, $2 valor, $3 mínimo, $4 máximo
  printf '%s' "$2" | grep -Eq '^[0-9]{1,5}$' && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] ||
    fail "$1 debe ser un entero entre $3 y $4 (valor: $2)."
}

requerir_python
requerir_aws
requerir_comando zip "crear el paquete .zip de la función"
requerir_comando npm "instalar las dependencias de la función"
validar_nombre_bucket "$BUCKET"
printf '%s' "$LAMBDA_NAME" | grep -Eq '^[A-Za-z0-9_-]{1,64}$' ||
  fail "LAMBDA_NAME inválido: $LAMBDA_NAME (1 a 64 letras, números, guiones y guiones bajos)."
printf '%s' "$LAMBDA_ROLE" | grep -Eq '^[A-Za-z0-9+=,.@_-]{1,64}$' ||
  fail "LAMBDA_ROLE inválido: $LAMBDA_ROLE (1 a 64 caracteres de nombre de rol IAM)."
printf '%s' "$LAMBDA_RUNTIME" | grep -Eq '^nodejs[0-9]+\.x$' ||
  fail "LAMBDA_RUNTIME inválido: $LAMBDA_RUNTIME (se espera p. ej. nodejs22.x)."
validar_entero LAMBDA_MEMORY "$LAMBDA_MEMORY" 128 10240
validar_entero LAMBDA_TIMEOUT "$LAMBDA_TIMEOUT" 1 900
validar_entero THUMB_WIDTH "$THUMB_WIDTH" 16 2000
mostrar_config
info "Función:      $LAMBDA_NAME ($LAMBDA_RUNTIME, ${LAMBDA_MEMORY} MB, ${LAMBDA_TIMEOUT} s, ancho ${THUMB_WIDTH}px)"
info "Rol:          $LAMBDA_ROLE"
info "Código:       $LAMBDA_SRC_DIR"
requerir_bucket "$BUCKET" "$AWS_REGION"

ARN_ROL="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}"
ZIP_FUNCION="$TMP_DIR/${LAMBDA_NAME}.zip"

# PNG RGB mínimo de 64x64 sin dependencias (zlib + struct de la biblioteca estándar).
PY_PNG='
import struct, sys, zlib

ancho = alto = 64
filas = b"".join(
    b"\x00" + b"".join(bytes((x * 4 % 256, y * 4 % 256, 128)) for x in range(ancho))
    for y in range(alto)
)


def bloque(tipo, datos):
    crc = zlib.crc32(tipo + datos) & 0xFFFFFFFF
    return struct.pack(">I", len(datos)) + tipo + datos + struct.pack(">I", crc)


png = (
    b"\x89PNG\r\n\x1a\n"
    + bloque(b"IHDR", struct.pack(">IIBBBBB", ancho, alto, 8, 2, 0, 0, 0))
    + bloque(b"IDAT", zlib.compress(filas))
    + bloque(b"IEND", b"")
)
with open(sys.argv[1], "wb") as f:
    f.write(png)
'

# --- 0. Notificaciones previas (antes de cambiar nada) ---
revisar_notificaciones_previas() {
  local actual otras
  actual="$(aws_admin_q s3api get-bucket-notification-configuration --bucket "$BUCKET" \
    --output json 2>/dev/null || true)"
  otras="$(printf '%s' "$actual" | grep -Eo '"(LambdaFunction|Topic|Queue)Arn": *"[^"]*"' |
    grep -Fv ":function:${LAMBDA_NAME}\"" || true)"
  if printf '%s' "$actual" | grep -q '"EventBridgeConfiguration"'; then
    otras="${otras:+$otras
}EventBridgeConfiguration"
  fi
  if [ -n "$otras" ]; then
    aviso "El bucket ya tiene otras notificaciones; se reemplazarán por la de la función:"
    printf '%s\n' "$otras" | sed 's/^/    /' >&2
    confirmar "Se reemplazará la configuración de notificaciones de $BUCKET. ¿Continuar?" || {
      info "Operación cancelada."
      exit 0
    }
  fi
}

# --- 1. Paquete ---
verificar_fuentes() {
  local f
  for f in index.mjs package.json; do
    if [ ! -f "$LAMBDA_SRC_DIR/$f" ]; then
      if es_dry_run; then
        aviso "No existe $LAMBDA_SRC_DIR/$f (en --dry-run solo se simula)."
      else
        fail "No existe $LAMBDA_SRC_DIR/$f. Revisa LAMBDA_SRC_DIR."
      fi
    fi
  done
}

empaquetar() {
  local carpeta="$TMP_DIR/paquete" f bytes

  info "Empaquetando la función (dependencias para linux x64)"
  if es_dry_run; then
    printf '[dry-run] copiar index.mjs, package.json y package-lock.json de %s a un directorio temporal\n' "$LAMBDA_SRC_DIR"
    printf '[dry-run] (cd <temporal> && npm install --omit=dev --os=linux --cpu=x64 --libc=glibc --ignore-scripts)\n'
    printf '[dry-run] comprobar node_modules/@img/sharp-linux-x64 y node_modules/@img/sharp-libvips-linux-x64\n'
    printf '[dry-run] (cd <temporal> && zip -qr %s index.mjs package.json node_modules -x "node_modules/.bin/*")\n' "$ZIP_FUNCION"
    return 0
  fi

  mkdir -p "$carpeta"
  cp "$LAMBDA_SRC_DIR/index.mjs" "$LAMBDA_SRC_DIR/package.json" "$carpeta/"
  if [ -f "$LAMBDA_SRC_DIR/package-lock.json" ]; then
    cp "$LAMBDA_SRC_DIR/package-lock.json" "$carpeta/"
  else
    aviso "No hay package-lock.json en $LAMBDA_SRC_DIR; npm resolverá las versiones al instalar."
  fi

  # sharp >= 0.33 publica binarios prebuilt como paquetes opcionales: no hacen
  # falta scripts de instalación (--ignore-scripts).
  (cd "$carpeta" && npm install --omit=dev --os=linux --cpu=x64 --libc=glibc \
    --ignore-scripts --no-audit --no-fund) ||
    fail "npm install falló en el paquete de la función."
  for f in node_modules/@img/sharp-linux-x64 node_modules/@img/sharp-libvips-linux-x64; do
    [ -d "$carpeta/$f" ] ||
      fail "Falta $f: sharp no instaló sus binarios linux x64. Usa sharp >= 0.33 y npm >= 10 (--os/--cpu/--libc)."
  done
  # Lambda (Amazon Linux) usa glibc: los binarios musl solo agregan peso.
  rm -rf "$carpeta"/node_modules/@img/sharp-linuxmusl-* "$carpeta"/node_modules/@img/sharp-libvips-linuxmusl-*

  (cd "$carpeta" && zip -qr "$ZIP_FUNCION" index.mjs package.json node_modules -x "node_modules/.bin/*")
  bytes="$(wc -c < "$ZIP_FUNCION" | tr -d ' ')"
  [ "$bytes" -le 52428800 ] ||
    fail "El paquete pesa $bytes bytes y supera los 50 MB permitidos para subida directa."
  ok "Paquete listo: $((bytes / 1024)) KB."
}

# --- 2. Rol IAM ---
preparar_rol() {
  local doc_confianza doc_permisos nuevo=0

  if aws_admin_q iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
    ok "El rol $LAMBDA_ROLE ya existe."
  else
    info "Creando el rol $LAMBDA_ROLE"
    doc_confianza="$(render_a_tmp "$POLICIES_DIR/lambda-trust.json.tpl")"
    aws_admin iam create-role --role-name "$LAMBDA_ROLE" \
      --assume-role-policy-document "file://$doc_confianza" \
      --description "Rol de la funcion de miniaturas del laboratorio 09"
    nuevo=1
  fi
  aws_admin iam attach-role-policy --role-name "$LAMBDA_ROLE" --policy-arn "$LAMBDA_BASIC_POLICY_ARN"
  doc_permisos="$(render_a_tmp "$POLICIES_DIR/lambda-s3-policy.json.tpl")"
  aws_admin iam put-role-policy --role-name "$LAMBDA_ROLE" \
    --policy-name "$LAMBDA_POLICY_NAME" --policy-document "file://$doc_permisos"

  if [ "$nuevo" = "1" ] && ! es_dry_run; then
    info "Esperando 10 s a que el rol se propague"
    sleep 10
  fi
}

# --- 3. Función ---
ENTORNO_LAMBDA="Variables={THUMB_WIDTH=$THUMB_WIDTH}"

crear_funcion() {
  local intento=1 maximo=6 salida
  local args=(lambda create-function --function-name "$LAMBDA_NAME"
    --runtime "$LAMBDA_RUNTIME" --role "$ARN_ROL" --handler index.handler
    --architectures x86_64 --memory-size "$LAMBDA_MEMORY" --timeout "$LAMBDA_TIMEOUT"
    --environment "$ENTORNO_LAMBDA" --zip-file "fileb://$ZIP_FUNCION"
    --description "Genera miniaturas de originales/ en miniaturas/ (laboratorio 09)"
    --query FunctionArn --output text)

  info "Creando la función $LAMBDA_NAME"
  if es_dry_run; then
    aws_admin "${args[@]}"
    return 0
  fi
  while :; do
    if salida="$(aws_admin "${args[@]}" 2>&1)"; then
      ok "Función creada."
      return 0
    fi
    if [ "$intento" -lt "$maximo" ] && printf '%s' "$salida" | grep -q 'cannot be assumed by Lambda'; then
      info "El rol aún no es asumible por Lambda; reintento $intento de $maximo en 5 s"
      sleep 5
      intento=$((intento + 1))
      continue
    fi
    printf '%s\n' "$salida" >&2
    fail "No se pudo crear la función $LAMBDA_NAME."
  done
}

publicar_funcion() {
  if aws_admin_q lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
    info "La función $LAMBDA_NAME ya existe; se actualizan código y configuración"
    aws_admin lambda wait function-updated-v2 --function-name "$LAMBDA_NAME"
    aws_admin lambda update-function-code --function-name "$LAMBDA_NAME" \
      --zip-file "fileb://$ZIP_FUNCION" --architectures x86_64 \
      --query FunctionArn --output text
    aws_admin lambda wait function-updated-v2 --function-name "$LAMBDA_NAME"
    aws_admin lambda update-function-configuration --function-name "$LAMBDA_NAME" \
      --role "$ARN_ROL" --handler index.handler --runtime "$LAMBDA_RUNTIME" \
      --memory-size "$LAMBDA_MEMORY" --timeout "$LAMBDA_TIMEOUT" \
      --environment "$ENTORNO_LAMBDA" --query FunctionArn --output text
    aws_admin lambda wait function-updated-v2 --function-name "$LAMBDA_NAME"
  else
    crear_funcion
    aws_admin lambda wait function-active-v2 --function-name "$LAMBDA_NAME"
  fi
  ok "Función $LAMBDA_NAME lista."
}

# --- 4. Permiso para que S3 invoque la función ---
permitir_s3() {
  local id_permiso="s3-invoca-${BUCKET//./-}" salida
  local args=(lambda add-permission --function-name "$LAMBDA_NAME"
    --statement-id "$id_permiso" --action lambda:InvokeFunction
    --principal s3.amazonaws.com --source-arn "arn:aws:s3:::$BUCKET"
    --source-account "$ACCOUNT_ID" --query Statement --output text)

  info "Autorizando a S3 (solo $BUCKET) a invocar la función"
  if es_dry_run; then
    aws_admin "${args[@]}"
    return 0
  fi
  if salida="$(aws_admin "${args[@]}" 2>&1)"; then
    ok "Permiso de invocación creado."
  elif printf '%s' "$salida" | grep -q 'ResourceConflictException'; then
    ok "El permiso de invocación ya existía."
  else
    printf '%s\n' "$salida" >&2
    fail "No se pudo agregar el permiso de invocación."
  fi
}

# --- 5. Notificación del bucket ---
aplicar_notificacion() {
  local doc intento=1 maximo=4 salida
  local args

  info "Aplicando la notificación s3:ObjectCreated:* con prefijo originales/ en $BUCKET"
  doc="$(render_a_tmp "$POLICIES_DIR/s3-notification.json.tpl")"
  args=(s3api put-bucket-notification-configuration --bucket "$BUCKET"
    --notification-configuration "file://$doc")

  if es_dry_run; then
    aws_admin "${args[@]}"
  else
    while :; do
      if salida="$(aws_admin "${args[@]}" 2>&1)"; then
        break
      fi
      if [ "$intento" -lt "$maximo" ] && printf '%s' "$salida" | grep -q 'Unable to validate'; then
        info "S3 aún no valida el destino; reintento $intento de $maximo en 5 s"
        sleep 5
        intento=$((intento + 1))
        continue
      fi
      printf '%s\n' "$salida" >&2
      fail "No se pudo aplicar la notificación del bucket."
    done
  fi

  aws_admin s3api get-bucket-notification-configuration --bucket "$BUCKET" \
    --query 'LambdaFunctionConfigurations[].{ID:Id,Eventos:Events,Funcion:LambdaFunctionArn}' \
    --output table
  ok "Notificación aplicada."
}

# --- 6. Verificación ---
probar_miniatura() {
  local epoch nombre clave_o clave_m png tam_o tam_m="" espera=0 resultado detalle destino

  epoch="$(date +%s)"
  nombre="prueba-miniatura-$epoch.png"
  clave_o="originales/$nombre"
  clave_m="miniaturas/$nombre"
  png="$TMP_DIR/$nombre"

  if es_dry_run; then
    info "[dry-run] se generaría un PNG de 64x64 y se esperaría hasta 5 min la miniatura"
    aws_admin s3api put-object --bucket "$BUCKET" --key "$clave_o" --body "$png" --content-type image/png
    aws_admin s3api head-object --bucket "$BUCKET" --key "$clave_m" --query ContentLength --output text
    aws_admin s3api delete-object --bucket "$BUCKET" --key "$clave_o"
    aws_admin s3api delete-object --bucket "$BUCKET" --key "$clave_m"
    info "[dry-run] se escribiría $EVIDENCIAS_DIR/validacion-miniaturas.txt"
    return 0
  fi

  python3 -I -c "$PY_PNG" "$png" || fail "No se pudo generar el PNG de prueba."
  tam_o="$(wc -c < "$png" | tr -d ' ')"

  info "Subiendo $clave_o ($tam_o bytes) y esperando la miniatura (hasta 5 min)"
  aws_admin s3api put-object --bucket "$BUCKET" --key "$clave_o" --body "$png" \
    --content-type image/png --query ETag --output text >/dev/null ||
    fail "No se pudo subir $clave_o."
  while [ "$espera" -lt 300 ]; do
    if tam_m="$(aws_admin_q s3api head-object --bucket "$BUCKET" --key "$clave_m" \
      --query ContentLength --output text 2>/dev/null)"; then
      break
    fi
    tam_m=""
    sleep 5
    espera=$((espera + 5))
    if [ $((espera % 30)) -eq 0 ]; then
      info "Sigo esperando la miniatura (${espera} s)"
    fi
  done

  if [ -n "$tam_m" ]; then
    resultado="PASS"
    detalle="original $tam_o bytes, miniatura $tam_m bytes (generada en ~${espera} s)"
    ok "PASS  $detalle"
  else
    resultado="FAIL"
    detalle="la miniatura no apareció en 5 min; revisa: aws logs tail /aws/lambda/$LAMBDA_NAME --since 10m"
    printf '[FAIL] %s\n' "$detalle" >&2
  fi

  aws_admin s3api delete-object --bucket "$BUCKET" --key "$clave_o" ||
    aviso "No se pudo borrar $clave_o"
  aws_admin s3api delete-object --bucket "$BUCKET" --key "$clave_m" ||
    aviso "No se pudo borrar $clave_m"

  mkdir -p "$EVIDENCIAS_DIR"
  destino="$EVIDENCIAS_DIR/validacion-miniaturas.txt"
  {
    echo "Validación de miniaturas con Lambda - Lab09-DSN"
    echo "Fecha:      $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Bucket:     $BUCKET"
    echo "Región:     $AWS_REGION"
    echo "Función:    $LAMBDA_NAME ($LAMBDA_RUNTIME, ${LAMBDA_MEMORY} MB, ancho ${THUMB_WIDTH}px)"
    echo "Original:   $clave_o ($tam_o bytes)"
    if [ -n "$tam_m" ]; then
      echo "Miniatura:  $clave_m ($tam_m bytes)"
    else
      echo "Miniatura:  $clave_m (no generada)"
    fi
    echo
    echo "[$resultado] $detalle"
  } > "$destino"
  ok "Evidencias guardadas en $destino"

  [ "$resultado" = "PASS" ] || return 1
}

verificar_fuentes
revisar_notificaciones_previas
empaquetar
preparar_rol
publicar_funcion
permitir_s3
aplicar_notificacion

if [ "$SIN_PRUEBA" = "1" ]; then
  info "--sin-prueba: se omite la verificación con un PNG de prueba."
else
  probar_miniatura
fi

echo
ok "Miniaturas con Lambda configuradas: originales/ -> miniaturas/."
info "Los logs de la función están en CloudWatch: /aws/lambda/$LAMBDA_NAME"
info "Al terminar: ./99-limpiar.sh"
