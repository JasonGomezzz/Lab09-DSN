#!/usr/bin/env bash
# 05-replicacion-opcional.sh - Ejercicio 3 (parte D, opcional)
#
# Replicación entre regiones (CRR) del prefijo originales/:
#   1. Bucket réplica en REPLICA_REGION con Block all public access y versionado.
#   2. Rol IAM s3-replicacion-lab09 (confianza s3.amazonaws.com) con permisos mínimos.
#   3. Configuración de replicación en el bucket origen.
# Requiere que el origen tenga versionado (ejecuta antes 03-versionado-lifecycle.sh).
# Solo se replican los objetos nuevos; los delete markers no se replican.
# La replicación tiene costo: elimina todo con ./99-limpiar.sh al terminar.
#
# Uso:
#   ./05-replicacion-opcional.sh [--dry-run] [-y]
#
# Variables: BUCKET, AWS_REGION, REPLICA_BUCKET, REPLICA_REGION,
#            REPLICATION_ROLE, ADMIN_PROFILE
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

requerir_aws
validar_nombre_bucket "$BUCKET"
validar_nombre_bucket "$REPLICA_BUCKET"
mostrar_config
info "Réplica:      $REPLICA_BUCKET ($REPLICA_REGION)"
info "Rol:          $REPLICATION_ROLE"

[ "$BUCKET" != "$REPLICA_BUCKET" ] || fail "REPLICA_BUCKET debe ser distinto de BUCKET."
if [ "$REPLICA_REGION" = "$AWS_REGION" ]; then
  aviso "REPLICA_REGION es igual a AWS_REGION: sería replicación en la misma región (SRR), no entre regiones."
fi

confirmar "La replicación duplica el almacenamiento y cobra transferencia entre regiones y solicitudes. Recuerda ejecutar ./99-limpiar.sh al terminar. ¿Continuar?" || {
  info "Operación cancelada."
  exit 0
}

requerir_bucket "$BUCKET" "$AWS_REGION"

if ! es_dry_run; then
  estado="$(aws_admin s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null || true)"
  if [ "$estado" != "Enabled" ]; then
    fail "El bucket origen no tiene versionado activo (estado: ${estado:-ninguno}). Ejecuta ./03-versionado-lifecycle.sh."
  fi
fi

# 1. Bucket réplica
if aws_admin_en_q "$REPLICA_REGION" s3api head-bucket --bucket "$REPLICA_BUCKET" >/dev/null 2>&1; then
  ok "El bucket réplica $REPLICA_BUCKET ya existe."
else
  info "Creando el bucket réplica en $REPLICA_REGION"
  crear_bucket "$REPLICA_REGION" "$REPLICA_BUCKET" ||
    fail "No se pudo crear el bucket réplica. Cambia REPLICA_BUCKET."
  aws_admin_en "$REPLICA_REGION" s3api wait bucket-exists --bucket "$REPLICA_BUCKET"
fi
bloquear_acceso_publico "$REPLICA_REGION" "$REPLICA_BUCKET"
aws_admin_en "$REPLICA_REGION" s3api put-bucket-versioning --bucket "$REPLICA_BUCKET" \
  --versioning-configuration Status=Enabled

# 2. Rol IAM de replicación
ROL_NUEVO=0
if aws_admin_q iam get-role --role-name "$REPLICATION_ROLE" >/dev/null 2>&1; then
  ok "El rol $REPLICATION_ROLE ya existe."
else
  info "Creando el rol $REPLICATION_ROLE"
  doc_confianza="$(render_a_tmp "$POLICIES_DIR/replication-trust.json.tpl")"
  aws_admin iam create-role --role-name "$REPLICATION_ROLE" \
    --assume-role-policy-document "file://$doc_confianza" \
    --description "Rol de replicacion S3 del laboratorio 09"
  ROL_NUEVO=1
fi
doc_permisos="$(render_a_tmp "$POLICIES_DIR/replication-policy.json.tpl")"
aws_admin iam put-role-policy --role-name "$REPLICATION_ROLE" \
  --policy-name "$REPLICATION_POLICY_NAME" --policy-document "file://$doc_permisos"

if [ "$ROL_NUEVO" = "1" ] && ! es_dry_run; then
  info "Esperando 10 s a que el rol se propague"
  sleep 10
fi

# 3. Configuración de replicación en el origen
info "Aplicando la replicación en $BUCKET"
doc_replicacion="$(render_a_tmp "$POLICIES_DIR/replication-config.json.tpl")"
aws_admin s3api put-bucket-replication --bucket "$BUCKET" \
  --replication-configuration "file://$doc_replicacion"

aws_admin s3api get-bucket-replication --bucket "$BUCKET" \
  --query 'ReplicationConfiguration.Rules[].{ID:ID,Estado:Status,Prefijo:Filter.Prefix,Destino:Destination.Bucket}' \
  --output table

ok "Replicación configurada (solo objetos nuevos bajo originales/)."
info "Prueba: aws s3 cp <archivo> s3://$BUCKET/originales/ y revisa s3://$REPLICA_BUCKET/originales/ en unos minutos."
info "Al terminar: ./99-limpiar.sh"
