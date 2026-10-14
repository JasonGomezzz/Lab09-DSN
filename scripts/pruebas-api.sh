#!/usr/bin/env bash
# Pruebas obligatorias del Ejercicio 4 contra la API en ejecución.
#
# Requisitos: backend arrancado (cd backend && npm start) con el bucket y las
# credenciales del usuario app-imagenes-user ya configurados.
#
# Uso:  scripts/pruebas-api.sh [URL_API]      (por defecto http://localhost:3000)
#
# Sube objetos de prueba al bucket y los elimina al terminar. La salida se
# guarda fuera del repo, sin firmas ni claves, en:
#   ~/Downloads/Lab09-DSN-evidencias/pruebas-api.txt
set -uo pipefail

API="${1:-http://localhost:3000}"
SALIDA_DIR="${HOME}/Downloads/Lab09-DSN-evidencias"
SALIDA="${SALIDA_DIR}/pruebas-api.txt"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$SALIDA_DIR"
: > "$SALIDA"

FALLAS=0
CLAVES_CREADAS=()

registrar() { printf '%s\n' "$*" | tee -a "$SALIDA"; }
# Oculta firma y credencial de las URL prefirmadas antes de guardarlas.
ocultar() { sed -E 's/(X-Amz-Signature=)[0-9a-f]+/\1<oculta>/g; s/(X-Amz-Credential=)[^&]+/\1<oculta>/g; s/(X-Amz-Security-Token=)[^&]+/\1<oculta>/g'; }
pass() { registrar "  [PASS] $1"; }
fail() { registrar "  [FAIL] $1"; FALLAS=$((FALLAS + 1)); }

json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], ""))' "$1"; }

# POST JSON -> imprime "<status> <cuerpo>"
post_json() {
  curl -s -o "$TMP/resp.json" -w '%{http_code}' -X POST "$API$1" \
    -H 'Content-Type: application/json' -d "$2"
}

# --- Archivos de prueba (bytes sintéticos, no son imágenes reales de nadie) ---
# JPEG mínimo válido (SOI + APP0 + EOI)
printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9' > "$TMP/valida.jpg"
# Ejecutable falso (cabecera MZ) que se hará pasar por PNG
printf 'MZ\x90\x00\x03\x00\x00\x00\x04\x00\x00\x00\xff\xff\x00\x00padding-de-prueba' > "$TMP/falso.png"
# 5000 bytes para probar que el tamaño firmado se respeta
head -c 5000 /dev/zero > "$TMP/mas-grande.jpg"
printf '\xff\xd8\xff\xe0' | dd of="$TMP/mas-grande.jpg" conv=notrunc 2>/dev/null

TAM_VALIDA=$(wc -c < "$TMP/valida.jpg" | tr -d ' ')
TAM_FALSO=$(wc -c < "$TMP/falso.png" | tr -d ' ')

registrar "Pruebas del Ejercicio 4 - $(date '+%Y-%m-%d %H:%M:%S')"
registrar "API: $API"
registrar ""

# --- Prueba 0: la API responde ---
registrar "0) Salud de la API"
if [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/health")" = "200" ]; then
  pass "GET /health responde 200"
else
  fail "La API no responde en $API. Arranca el backend con: cd backend && npm start"
  exit 1
fi

# --- Prueba 1: subir una imagen JPG válida ---
registrar ""
registrar "1) Subir una imagen JPG válida y verla en la galería"
CUERPO="{\"filename\":\"valida.jpg\",\"contentType\":\"image/jpeg\",\"sizeBytes\":${TAM_VALIDA}}"
CODIGO=$(post_json /api/upload-url "$CUERPO")
if [ "$CODIGO" = "200" ]; then
  UPLOAD_URL=$(json_get uploadUrl < "$TMP/resp.json")
  CLAVE=$(json_get key < "$TMP/resp.json")
  CLAVES_CREADAS+=("$CLAVE")
  pass "POST /api/upload-url -> 200, clave ${CLAVE}"
  registrar "      URL (sin firma): $(printf '%s' "$UPLOAD_URL" | cut -d'?' -f1)"
  registrar "      Vigencia solicitada: $(printf '%s' "$UPLOAD_URL" | grep -o 'X-Amz-Expires=[0-9]*')"

  CODIGO_PUT=$(curl -s -o "$TMP/put.out" -w '%{http_code}' -X PUT "$UPLOAD_URL" \
    -H 'Content-Type: image/jpeg' -H 'x-amz-server-side-encryption: AES256' \
    --data-binary "@$TMP/valida.jpg")
  if [ "$CODIGO_PUT" = "200" ]; then
    pass "PUT directo a S3 -> 200 (el archivo no pasó por el backend)"
  else
    fail "PUT a S3 devolvió $CODIGO_PUT: $(head -c 300 "$TMP/put.out")"
  fi

  CODIGO_V=$(post_json /api/verify "{\"key\":\"${CLAVE}\"}")
  [ "$CODIGO_V" = "200" ] && pass "POST /api/verify -> 200 (magic bytes válidos)" || fail "verify devolvió $CODIGO_V: $(cat "$TMP/resp.json")"

  if curl -s "$API/api/images" | grep -q "$CLAVE"; then
    pass "GET /api/images incluye la imagen subida"
  else
    fail "La imagen no aparece en GET /api/images"
  fi
else
  fail "upload-url devolvió $CODIGO: $(cat "$TMP/resp.json")"
fi

# --- Prueba 2: tipos no permitidos ---
registrar ""
registrar "2) Archivo .exe / .pdf bloqueado"
for TIPO in application/pdf application/x-msdownload; do
  CODIGO=$(post_json /api/upload-url "{\"filename\":\"archivo\",\"contentType\":\"${TIPO}\",\"sizeBytes\":1000}")
  [ "$CODIGO" = "400" ] && pass "${TIPO} -> 400 $(cat "$TMP/resp.json")" || fail "${TIPO} devolvió $CODIGO"
done

# --- Prueba 3: archivo de 10 MB ---
registrar ""
registrar "3) Archivo de 10 MB rechazado por el backend"
CODIGO=$(post_json /api/upload-url '{"filename":"grande.jpg","contentType":"image/jpeg","sizeBytes":10485760}')
[ "$CODIGO" = "413" ] && pass "10 MB -> 413 $(cat "$TMP/resp.json")" || fail "10 MB devolvió $CODIGO"

# --- Prueba extra: el tamaño declarado queda firmado ---
registrar ""
registrar "3b) Declarar 1 KB y subir 5 KB: S3 debe rechazarlo (content-length firmado)"
CODIGO=$(post_json /api/upload-url '{"filename":"mas-grande.jpg","contentType":"image/jpeg","sizeBytes":1000}')
if [ "$CODIGO" = "200" ]; then
  URL_TRUCADA=$(json_get uploadUrl < "$TMP/resp.json")
  CLAVES_CREADAS+=("$(json_get key < "$TMP/resp.json")")
  CODIGO_PUT=$(curl -s -o "$TMP/put.out" -w '%{http_code}' -X PUT "$URL_TRUCADA" \
    -H 'Content-Type: image/jpeg' -H 'x-amz-server-side-encryption: AES256' \
    --data-binary "@$TMP/mas-grande.jpg")
  case "$CODIGO_PUT" in
    4*) pass "S3 rechazó el PUT con $CODIGO_PUT (tamaño distinto al firmado)" ;;
    *)  fail "S3 aceptó un cuerpo de tamaño distinto al firmado (código $CODIGO_PUT)" ;;
  esac
else
  fail "No se pudo obtener la URL para la prueba (código $CODIGO)"
fi

# --- Prueba 4: ejecutable disfrazado de imagen (validación posterior) ---
registrar ""
registrar "4) Ejecutable disfrazado de PNG: la verificación posterior lo elimina"
CODIGO=$(post_json /api/upload-url "{\"filename\":\"falso.png\",\"contentType\":\"image/png\",\"sizeBytes\":${TAM_FALSO}}")
if [ "$CODIGO" = "200" ]; then
  URL_FALSA=$(json_get uploadUrl < "$TMP/resp.json")
  CLAVE_FALSA=$(json_get key < "$TMP/resp.json")
  CLAVES_CREADAS+=("$CLAVE_FALSA")
  curl -s -o /dev/null -X PUT "$URL_FALSA" \
    -H 'Content-Type: image/png' -H 'x-amz-server-side-encryption: AES256' \
    --data-binary "@$TMP/falso.png"
  CODIGO_V=$(post_json /api/verify "{\"key\":\"${CLAVE_FALSA}\"}")
  if [ "$CODIGO_V" = "422" ]; then
    pass "verify -> 422 $(cat "$TMP/resp.json")"
  else
    fail "verify devolvió $CODIGO_V (se esperaba 422)"
  fi
  if curl -s "$API/api/images" | grep -q "$CLAVE_FALSA"; then
    fail "El archivo falso sigue en el bucket"
  else
    pass "El archivo falso ya no aparece en la galería"
  fi
else
  fail "No se pudo obtener la URL para la prueba (código $CODIGO)"
fi

# --- Prueba 5: expiración de la URL de visualización ---
registrar ""
registrar "5) Vigencia de las URL de visualización"
VIEW_URL=$(curl -s "$API/api/images" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["url"] if d else "")')
if [ -n "$VIEW_URL" ]; then
  EXPIRES=$(printf '%s' "$VIEW_URL" | grep -o 'X-Amz-Expires=[0-9]*' | cut -d= -f2)
  [ "$EXPIRES" = "900" ] && pass "X-Amz-Expires=900 (15 minutos)" || fail "Vigencia inesperada: ${EXPIRES}"
  registrar "      Para la prueba manual, abre esta URL ahora y otra vez 16 minutos después (debe dar AccessDenied/Request has expired):"
  registrar "      $(printf '%s' "$VIEW_URL" | ocultar)"
  registrar "      (la URL completa con firma se imprime solo en la terminal)"
  printf '      %s\n' "$VIEW_URL"
else
  fail "No hay imágenes para probar la expiración"
fi

# --- Prueba 6: el frontend no contiene credenciales ---
registrar ""
registrar "6) El frontend no contiene credenciales de AWS"
if [ -d "$RAIZ/frontend" ]; then
  if grep -RIEn 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|aws_secret_access_key|SecretAccessKey|AWS_SECRET' "$RAIZ/frontend" >/dev/null; then
    fail "Se encontraron patrones de credenciales en frontend/"
  else
    pass "Sin patrones AKIA/ASIA/secret en frontend/"
  fi
else
  fail "No existe la carpeta frontend/"
fi

# --- Limpieza de objetos de prueba ---
registrar ""
registrar "Limpieza de objetos de prueba"
for CLAVE in "${CLAVES_CREADAS[@]:-}"; do
  [ -z "$CLAVE" ] && continue
  CLAVE_ENC=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CLAVE")
  CODIGO=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$API/api/images/${CLAVE_ENC}")
  case "$CODIGO" in
    200) registrar "  eliminado: $CLAVE" ;;
    404) registrar "  ya no existía: $CLAVE" ;;
    *)   registrar "  no se pudo eliminar $CLAVE (código $CODIGO)" ;;
  esac
done

registrar ""
if [ "$FALLAS" -eq 0 ]; then
  registrar "Resultado: todas las pruebas pasaron."
else
  registrar "Resultado: ${FALLAS} prueba(s) fallaron."
fi
registrar "Salida guardada en: $SALIDA"
exit "$FALLAS"
