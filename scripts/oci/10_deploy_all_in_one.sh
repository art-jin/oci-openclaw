#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="scripts/oci/gateway.env"
APPLY=0
CREATE_CLUSTER_IF_MISSING=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --skip-create-cluster)
      CREATE_CLUSTER_IF_MISSING=0
      shift
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      echo "Usage: $0 [--env path/to/gateway.env] [--apply] [--skip-create-cluster]" >&2
      echo "Note: This runs scripts/oci/02_deploy_gateway_oke.sh with --deploy-openclaw" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] env file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

if [[ "$CREATE_CLUSTER_IF_MISSING" -eq 1 ]]; then
  if [[ -z "${OCI_CLUSTER_OCID:-}" || "${OCI_CLUSTER_OCID:-}" == *"REPLACE_ME"* ]]; then
    echo "[INFO] OCI_CLUSTER_OCID not set. Running OKE cluster bootstrap script."
    if [[ "$APPLY" -eq 1 ]]; then
      bash scripts/oci/00_create_oke_cluster.sh --env "$ENV_FILE" --apply
    else
      bash scripts/oci/00_create_oke_cluster.sh --env "$ENV_FILE"
    fi

    echo "[INFO] After cluster is created, update OCI_CLUSTER_OCID in $ENV_FILE and rerun this command."
    exit 0
  fi
fi

if [[ "$APPLY" -eq 1 ]]; then
  bash scripts/oci/01_prepare_oke_kubeconfig.sh "$ENV_FILE" --apply
  bash scripts/oci/02_deploy_gateway_oke.sh --env $ENV_FILE --deploy-openclaw --apply
  bash scripts/oci/03_verify_gateway.sh "$ENV_FILE"
else
  bash scripts/oci/01_prepare_oke_kubeconfig.sh "$ENV_FILE"
  bash scripts/oci/02_deploy_gateway_oke.sh --env $ENV_FILE --deploy-openclaw
  bash scripts/oci/03_verify_gateway.sh "$ENV_FILE"
fi

echo "[INFO] All-in-one flow completed."
