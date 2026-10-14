#!/usr/bin/env bash
# 99-limpiar.sh - Limpieza obligatoria del laboratorio
#
# Elimina, tolerando que cada recurso ya no exista:
#   - bucket BUCKET (con todas sus versiones y delete markers) y REPLICA_BUCKET
#   - rol de replicación REPLICATION_ROLE
#   - Access Keys, política y usuario IAM_USER
#   - perfil local APP_PROFILE de ~/.aws/credentials y ~/.aws/config
#     (con respaldo previo en *.bak-lab09)
# Exige escribir el nombre exacto del bucket para continuar.
#
# Uso:
#   ./99-limpiar.sh [--dry-run] [--skip-iam]
#
#   --skip-iam   no toca usuario, política ni perfil local (AWS Academy)
#
# Variables: BUCKET, AWS_REGION, REPLICA_BUCKET, REPLICA_REGION, IAM_USER,
#            IAM_POLICY_NAME, REPLICATION_ROLE, APP_PROFILE, ADMIN_PROFILE
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

requerir_python
requerir_aws
validar_nombre_bucket "$BUCKET"
mostrar_config

ARN_POLITICA="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

echo
info "Se eliminará de forma permanente:"
info "  - bucket $BUCKET ($AWS_REGION) con todas sus versiones"
info "  - bucket $REPLICA_BUCKET ($REPLICA_REGION), si existe"
info "  - rol $REPLICATION_ROLE, si existe"
if [ "$SKIP_IAM" = "0" ]; then
  info "  - usuario $IAM_USER, sus Access Keys y la política $IAM_POLICY_NAME"
  info "  - perfil local $APP_PROFILE en ~/.aws"
fi
confirmar_escribiendo "$BUCKET" "Esta acción no se puede deshacer." || fail "El nombre no coincide; no se elimina nada."

# Arma un lote de delete-objects (hasta 1000 entradas) desde el JSON de
# list-object-versions. Escribe el lote en $1 e imprime la cantidad.
PY_LOTE='
import json, sys
crudo = sys.stdin.read().strip()
datos = json.loads(crudo) if crudo else {}
objetos = [
    {"Key": o["Key"], "VersionId": o["VersionId"]}
    for o in (datos.get("Versions") or []) + (datos.get("DeleteMarkers") or [])
][:1000]
if objetos:
    with open(sys.argv[1], "w") as f:
        json.dump({"Objects": objetos, "Quiet": True}, f)
print(len(objetos))
'

vaciar_bucket() { # $1 región, $2 bucket
  local region="$1" bucket="$2" lote cantidad errores total=0 subidas k u
  lote="$TMP_DIR/lote-delete.json"

  if es_dry_run; then
    aws_admin_en "$region" s3api list-object-versions --bucket "$bucket" --max-items 1000 --output json
    aws_admin_en "$region" s3api delete-objects --bucket "$bucket" --delete "file://$lote" --query 'Errors' --output json
    return 0
  fi

  info "Vaciando $bucket (versiones y delete markers, en lotes de 1000)"
  while :; do
    if ! cantidad="$(aws_admin_en "$region" s3api list-object-versions --bucket "$bucket" \
      --max-items 1000 --output json | python3 -I -c "$PY_LOTE" "$lote")"; then
      aviso "No se pudo listar $bucket; se omite el vaciado."
      return 1
    fi
    if [ "$cantidad" = "0" ]; then
      break
    fi
    errores="$(aws_admin_en "$region" s3api delete-objects --bucket "$bucket" \
      --delete "file://$lote" --query 'Errors[].Key' --output text)"
    if [ -n "$errores" ] && [ "$errores" != "None" ]; then
      aviso "delete-objects devolvió errores en $bucket: $errores"
      return 1
    fi
    total=$((total + cantidad))
    info "  eliminados $total"
  done

  subidas="$(aws_admin_en_q "$region" s3api list-multipart-uploads --bucket "$bucket" \
    --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null || true)"
  if [ -n "$subidas" ] && [ "$subidas" != "None" ]; then
    printf '%s\n' "$subidas" | while IFS=$'\t' read -r k u; do
      if [ -n "$u" ]; then
        aws_admin_en "$region" s3api abort-multipart-upload --bucket "$bucket" \
          --key "$k" --upload-id "$u" || aviso "No se pudo abortar la carga de $k"
      fi
    done
  fi
  ok "Bucket $bucket vacío ($total objetos/versiones eliminados)."
}

borrar_bucket() { # $1 región, $2 bucket
  if ! es_dry_run && ! aws_admin_en_q "$1" s3api head-bucket --bucket "$2" >/dev/null 2>&1; then
    info "El bucket $2 no existe; nada que borrar."
    return 0
  fi
  if vaciar_bucket "$1" "$2"; then
    aws_admin_en "$1" s3api delete-bucket --bucket "$2" || aviso "No se pudo borrar el bucket $2."
    ok "Bucket $2 eliminado."
  fi
}

# --- Buckets ---
borrar_bucket "$AWS_REGION" "$BUCKET"
borrar_bucket "$REPLICA_REGION" "$REPLICA_BUCKET"

# --- Rol de replicación ---
borrar_rol_replicacion() {
  local politicas p
  if ! es_dry_run && ! aws_admin_q iam get-role --role-name "$REPLICATION_ROLE" >/dev/null 2>&1; then
    info "El rol $REPLICATION_ROLE no existe."
    return 0
  fi
  politicas="$(aws_admin_q iam list-role-policies --role-name "$REPLICATION_ROLE" \
    --query 'PolicyNames[]' --output text 2>/dev/null || true)"
  if es_dry_run; then
    politicas="$REPLICATION_POLICY_NAME"
  fi
  for p in $politicas; do
    aws_admin iam delete-role-policy --role-name "$REPLICATION_ROLE" --policy-name "$p" ||
      aviso "No se pudo borrar la política en línea $p"
  done
  aws_admin iam delete-role --role-name "$REPLICATION_ROLE" ||
    aviso "No se pudo borrar el rol $REPLICATION_ROLE"
  ok "Rol $REPLICATION_ROLE eliminado."
}

# --- Usuario IAM ---
borrar_usuario_iam() {
  local claves c adjuntas a en_linea e grupos g
  if ! es_dry_run && ! aws_admin_q iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    info "El usuario $IAM_USER no existe."
  else
    claves="$(aws_admin_q iam list-access-keys --user-name "$IAM_USER" \
      --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true)"
    adjuntas="$(aws_admin_q iam list-attached-user-policies --user-name "$IAM_USER" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)"
    en_linea="$(aws_admin_q iam list-user-policies --user-name "$IAM_USER" \
      --query 'PolicyNames[]' --output text 2>/dev/null || true)"
    grupos="$(aws_admin_q iam list-groups-for-user --user-name "$IAM_USER" \
      --query 'Groups[].GroupName' --output text 2>/dev/null || true)"
    if es_dry_run; then
      claves="<ACCESS_KEY_ID>"
      adjuntas="$ARN_POLITICA"
    fi
    for c in $claves; do
      aws_admin iam delete-access-key --user-name "$IAM_USER" --access-key-id "$c" ||
        aviso "No se pudo borrar la Access Key $c"
    done
    for a in $adjuntas; do
      aws_admin iam detach-user-policy --user-name "$IAM_USER" --policy-arn "$a" ||
        aviso "No se pudo desadjuntar $a"
    done
    for e in $en_linea; do
      aws_admin iam delete-user-policy --user-name "$IAM_USER" --policy-name "$e" ||
        aviso "No se pudo borrar la política en línea $e"
    done
    for g in $grupos; do
      aws_admin iam remove-user-from-group --user-name "$IAM_USER" --group-name "$g" ||
        aviso "No se pudo quitar al usuario del grupo $g"
    done
    if aws_admin_q iam get-login-profile --user-name "$IAM_USER" >/dev/null 2>&1; then
      aws_admin iam delete-login-profile --user-name "$IAM_USER" ||
        aviso "No se pudo borrar el acceso a consola"
    fi
  fi

  borrar_politica_propia

  if es_dry_run || aws_admin_q iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    aws_admin iam delete-user --user-name "$IAM_USER" || aviso "No se pudo borrar el usuario $IAM_USER"
    ok "Usuario $IAM_USER eliminado."
  fi
}

borrar_politica_propia() {
  local versiones v
  if ! es_dry_run && ! aws_admin_q iam get-policy --policy-arn "$ARN_POLITICA" >/dev/null 2>&1; then
    info "La política $IAM_POLICY_NAME no existe."
    return 0
  fi
  versiones="$(aws_admin_q iam list-policy-versions --policy-arn "$ARN_POLITICA" \
    --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null || true)"
  for v in $versiones; do
    aws_admin iam delete-policy-version --policy-arn "$ARN_POLITICA" --version-id "$v" ||
      aviso "No se pudo borrar la versión $v de la política"
  done
  aws_admin iam delete-policy --policy-arn "$ARN_POLITICA" ||
    aviso "No se pudo borrar la política $IAM_POLICY_NAME (¿sigue adjunta a otra entidad?)"
  ok "Política $IAM_POLICY_NAME eliminada."
}

# --- Perfil local del CLI ---
# aws configure no puede borrar perfiles: se quitan solo las secciones
# [APP_PROFILE] y [profile APP_PROFILE] con respaldo previo.
PY_PERFIL='
import os, re, shutil, sys

perfil = sys.argv[1]


def normalizar(texto):
    return re.sub(r"\s+", " ", texto.strip())


def quitar(ruta, titulo):
    ruta = os.path.expanduser(ruta)
    if not os.path.isfile(ruta):
        return ruta + ": no existe, sin cambios"
    with open(ruta, encoding="utf-8") as f:
        lineas = f.readlines()
    salida, omitir, hallado = [], False, False
    for linea in lineas:
        m = re.match(r"^\s*\[(.*)\]\s*(?:[#;].*)?$", linea)
        if m:
            omitir = normalizar(m.group(1)) == titulo
            hallado = hallado or omitir
        if not omitir:
            salida.append(linea)
    if not hallado:
        return ruta + ": sin la sección [" + titulo + "], sin cambios"
    respaldo = ruta + ".bak-lab09"
    shutil.copy2(ruta, respaldo)
    os.chmod(respaldo, 0o600)
    with open(ruta, "w", encoding="utf-8") as f:
        f.writelines(salida)
    return ruta + ": sección [" + titulo + "] eliminada (respaldo " + respaldo + ")"


credenciales = os.environ.get("AWS_SHARED_CREDENTIALS_FILE", "~/.aws/credentials")
configuracion = os.environ.get("AWS_CONFIG_FILE", "~/.aws/config")
print(quitar(credenciales, perfil))
print(quitar(configuracion, "profile " + perfil))
'

borrar_perfil_local() {
  if [ -z "$APP_PROFILE" ] || [ "$APP_PROFILE" = "default" ] || [ "$APP_PROFILE" = "$ADMIN_PROFILE" ]; then
    aviso "APP_PROFILE ('$APP_PROFILE') es vacío, 'default' o el perfil de administración; no se borra."
    return 0
  fi
  if es_dry_run; then
    info "[dry-run] se quitarían [$APP_PROFILE] de ~/.aws/credentials y [profile $APP_PROFILE] de ~/.aws/config (respaldo *.bak-lab09)"
    return 0
  fi
  python3 -I -c "$PY_PERFIL" "$APP_PROFILE"
}

borrar_rol_replicacion

if [ "$SKIP_IAM" = "1" ]; then
  info "--skip-iam: no se elimina usuario, política ni perfil local."
else
  borrar_usuario_iam
  borrar_perfil_local
fi

echo
ok "Limpieza terminada. Revisa en la consola de AWS que no queden buckets, usuarios ni roles del laboratorio."
