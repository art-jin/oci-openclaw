#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="scripts/oci/gateway.env"
APPLY=0
CREATE_CLUSTER_IF_MISSING=1
APPLY_IAM_POLICY=0
APPLY_INSTANCE_PRINCIPAL_POLICY=0
CREATE_INSTANCE_PRINCIPAL_DYNAMIC_GROUP=0

TOTAL_STEPS=7
CURRENT_STEP=0
CURRENT_LABEL=""
STEP_START_TS=0
ALL_START_TS=0

now_ts() {
  date +%s
}

fmt_elapsed() {
  local s="$1"
  local h=$((s / 3600))
  local m=$(((s % 3600) / 60))
  local sec=$((s % 60))

  if [[ "$h" -gt 0 ]]; then
    printf "%dh%02dm%02ds" "$h" "$m" "$sec"
  elif [[ "$m" -gt 0 ]]; then
    printf "%dm%02ds" "$m" "$sec"
  else
    printf "%ds" "$sec"
  fi
}

step_begin() {
  local n="$1"
  local label="$2"
  CURRENT_STEP="$n"
  CURRENT_LABEL="$label"
  STEP_START_TS="$(now_ts)"
  echo
  echo "[STEP ${CURRENT_STEP}/${TOTAL_STEPS}] ${CURRENT_LABEL}"
}

step_ok() {
  local end_ts
  end_ts="$(now_ts)"
  echo "[STEP ${CURRENT_STEP}/${TOTAL_STEPS}] OK (elapsed $(fmt_elapsed $((end_ts - STEP_START_TS))))"
}

on_err() {
  local end_ts
  end_ts="$(now_ts)"
  echo >&2
  echo "[FAILED] Step ${CURRENT_STEP}/${TOTAL_STEPS} failed: ${CURRENT_LABEL} (elapsed $(fmt_elapsed $((end_ts - STEP_START_TS))))" >&2
  echo "[FAILED] Last command: ${BASH_COMMAND}" >&2
}

trap on_err ERR

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
    --apply-iam-policy)
      APPLY_IAM_POLICY=1
      shift
      ;;
    --apply-instance-principal-policy)
      APPLY_INSTANCE_PRINCIPAL_POLICY=1
      shift
      ;;
    --create-instance-principal-dynamic-group)
      CREATE_INSTANCE_PRINCIPAL_DYNAMIC_GROUP=1
      shift
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      echo "Usage: $0 [--env path/to/gateway.env] [--apply] [--skip-create-cluster] [--apply-iam-policy] [--create-instance-principal-dynamic-group] [--apply-instance-principal-policy]" >&2
      echo "Note: This runs scripts/oci/02_deploy_gateway_oke.sh with --deploy-openclaw" >&2
      echo "Note: --apply-iam-policy runs scripts/oci/11_workload_identity_policy.sh create-or-update (default mode: all)" >&2
      echo "Note: --create-instance-principal-dynamic-group runs scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create-or-update" >&2
      echo "Note: --apply-instance-principal-policy runs scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] env file not found: $ENV_FILE" >&2
  exit 1
fi

ALL_START_TS="$(now_ts)"

echo "[PLAN] All-in-one deployment (${TOTAL_STEPS} steps)"
echo "[PLAN] Workload identity policy default mode: all (gateway GenAI + OpenClaw Object Storage)"

set -a
source "$ENV_FILE"
set +a

step_begin 1 "Ensure OKE cluster is available"
if [[ "$CREATE_CLUSTER_IF_MISSING" -eq 0 ]]; then
  echo "[STEP 1/7] Skip cluster bootstrap (--skip-create-cluster)"
  step_ok
else
  if [[ -z "${OCI_CLUSTER_OCID:-}" || "${OCI_CLUSTER_OCID:-}" == *"REPLACE_ME"* ]]; then
    echo "[STEP 1/7] OCI_CLUSTER_OCID not set. Running: scripts/oci/00_create_oke_cluster.sh"
    if [[ "$APPLY" -eq 1 ]]; then
      bash scripts/oci/00_create_oke_cluster.sh --env "$ENV_FILE" --apply
    else
      bash scripts/oci/00_create_oke_cluster.sh --env "$ENV_FILE"
    fi

    step_ok
    echo "[DONE] Stopped after step 1/7. After cluster is created, update OCI_CLUSTER_OCID in $ENV_FILE and rerun this command."
    echo "[DONE] Total elapsed: $(fmt_elapsed $(( $(now_ts) - ALL_START_TS )))"
    exit 0
  fi
  step_ok
fi

step_begin 2 "Prepare kubeconfig"
if [[ "$APPLY" -eq 1 ]]; then
  bash scripts/oci/01_prepare_oke_kubeconfig.sh "$ENV_FILE" --apply
else
  bash scripts/oci/01_prepare_oke_kubeconfig.sh "$ENV_FILE"
fi
step_ok

step_begin 3 "(Optional) Apply IAM policy for workload identity"
if [[ "$APPLY_IAM_POLICY" -eq 1 ]]; then
  bash scripts/oci/11_workload_identity_policy.sh create-or-update --env "$ENV_FILE"
else
  echo "[STEP 3/${TOTAL_STEPS}] Skip IAM policy (--apply-iam-policy not set)"
fi
step_ok

step_begin 4 "(Optional) Create Dynamic Group for openclaw instance principal"
if [[ "$CREATE_INSTANCE_PRINCIPAL_DYNAMIC_GROUP" -eq 1 ]]; then
  bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create-or-update --env "$ENV_FILE"
else
  echo "[STEP 4/${TOTAL_STEPS}] Skip instance principal Dynamic Group (--create-instance-principal-dynamic-group not set)"
fi
step_ok

step_begin 5 "(Optional) Apply IAM policy for openclaw instance principal"
if [[ "$APPLY_INSTANCE_PRINCIPAL_POLICY" -eq 1 ]]; then
  bash scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update --env "$ENV_FILE"
else
  echo "[STEP 5/${TOTAL_STEPS}] Skip instance principal IAM policy (--apply-instance-principal-policy not set)"
fi
step_ok

step_begin 6 "Deploy gateway (+ openclaw)"
if [[ "$APPLY" -eq 1 ]]; then
  bash scripts/oci/02_deploy_gateway_oke.sh --env "$ENV_FILE" --deploy-openclaw --apply
else
  bash scripts/oci/02_deploy_gateway_oke.sh --env "$ENV_FILE" --deploy-openclaw
fi
step_ok

step_begin 7 "Verify"
bash scripts/oci/03_verify_gateway.sh "$ENV_FILE"
step_ok

echo
echo "[DONE] All-in-one flow completed (total elapsed $(fmt_elapsed $(( $(now_ts) - ALL_START_TS ))))"