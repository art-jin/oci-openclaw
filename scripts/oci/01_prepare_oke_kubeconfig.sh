#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-scripts/oci/gateway.env.example}"
APPLY=0
if [[ "${2:-}" == "--apply" || "${1:-}" == "--apply" ]]; then
  APPLY=1
fi
if [[ "${2:-}" == "--apply" ]]; then
  ENV_FILE="${1}"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] env file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

: "${OCI_REGION:?OCI_REGION is required}"
: "${OCI_CLUSTER_OCID:?OCI_CLUSTER_OCID is required}"
: "${KUBECONFIG_PATH:?KUBECONFIG_PATH is required}"

run_cmd() {
  local cmd="$1"
  echo "+ $cmd"
  if [[ "$APPLY" -eq 1 ]]; then
    bash -lc "$cmd"
  fi
}

echo "[INFO] Purpose: generate/update kubeconfig for OKE cluster ${OCI_CLUSTER_OCID}."
KUBECONFIG_DIR="$(dirname "$KUBECONFIG_PATH")"
run_cmd "mkdir -p \"$KUBECONFIG_DIR\""
run_cmd "oci ce cluster create-kubeconfig \\
  --cluster-id \"$OCI_CLUSTER_OCID\" \\
  --file \"$KUBECONFIG_PATH\" \\
  --region \"$OCI_REGION\" \\
  --token-version 2.0.0 \\
  --kube-endpoint "${OKE_KUBE_ENDPOINT:-PRIVATE_ENDPOINT}" \\
  --profile \"${OCI_CLI_PROFILE:-DEFAULT}\" \\
  --overwrite"
run_cmd "kubectl --kubeconfig \"$KUBECONFIG_PATH\" get nodes -o wide"

if [[ "$APPLY" -eq 0 ]]; then
  echo "[INFO] Dry run only. Add --apply to execute commands."
fi
