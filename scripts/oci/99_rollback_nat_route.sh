#!/usr/bin/env bash
set -euo pipefail

# Roll back NAT gateway + worker subnet default route.
#
# What this does:
#  1) Update the worker subnet route table default route (0.0.0.0/0) back to the original Internet Gateway.
#  2) Delete the NAT Gateway.
#
# Usage:
#   bash scripts/oci/99_rollback_nat_route.sh --env scripts/oci/gateway.env --apply
# Dry-run:
#   bash scripts/oci/99_rollback_nat_route.sh --env scripts/oci/gateway.env

ENV_FILE="scripts/oci/gateway.env"
APPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="$2"; shift 2 ;;
    --apply)
      APPLY=1; shift ;;
    *)
      echo "[ERROR] Unknown arg: $1" >&2
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

: "${OCI_REGION:?OCI_REGION is required}"
OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"
: "${OKE_WORKER_SUBNET_OCID:?OKE_WORKER_SUBNET_OCID is required}"

# Values captured from our session (2026-03-15)
NAT_NAME="oke-nat-gw-openclaw"
NAT_ID="ocid1.natgateway.oc1.us-chicago-1.aaaaaaaaqbgn76kwugo3zq4vdjpx36lxaox25e4n3iajfvgnhidouu35xxya"
ORIGINAL_IGW_ID="ocid1.internetgateway.oc1.us-chicago-1.aaaaaaaabflcczls3pouwm3k3hnncayxm5m3mfabkia46u4ylnonudbchiiq"

run() {
  echo "+ $*"
  if [[ "$APPLY" -eq 1 ]]; then
    "$@"
  fi
}

RT_ID=$(oci network subnet get \
  --subnet-id "$OKE_WORKER_SUBNET_OCID" \
  --region "$OCI_REGION" \
  --profile "$OCI_CLI_PROFILE" \
  --query 'data."route-table-id"' \
  --raw-output)

if [[ -z "$RT_ID" || "$RT_ID" == "null" ]]; then
  echo "[ERROR] Could not determine route table id from worker subnet" >&2
  exit 1
fi

echo "[INFO] Using env: $ENV_FILE"
echo "[INFO] Region: $OCI_REGION  Profile: $OCI_CLI_PROFILE"
echo "[INFO] Worker subnet: $OKE_WORKER_SUBNET_OCID"
echo "[INFO] Route table: $RT_ID"
echo "[INFO] NAT gateway: $NAT_ID (name: $NAT_NAME)"
echo "[INFO] Restore default route target (IGW): $ORIGINAL_IGW_ID"

echo "[INFO] Fetching current route table rules..."
oci network route-table get --rt-id "$RT_ID" --region "$OCI_REGION" --profile "$OCI_CLI_PROFILE" --output json > /tmp/rt-rollback.json

NEW_RULES=$(python3 - <<'PY'
import json
rt=json.load(open('/tmp/rt-rollback.json'))['data']
rules=rt.get('route-rules') or []
IGW_ID="""__IGW__"""

out=[]
replaced=False
for r in rules:
    if r.get('destination')=='0.0.0.0/0' and r.get('destination-type')=='CIDR_BLOCK':
        nr=dict(r)
        nr['network-entity-id']=IGW_ID
        out.append(nr)
        replaced=True
    else:
        out.append(r)

if not replaced:
    out.append({'destination':'0.0.0.0/0','destination-type':'CIDR_BLOCK','network-entity-id':IGW_ID,'description':'traffic to/from internet'})

print(json.dumps(out))
PY
)
NEW_RULES=${NEW_RULES//__IGW__/$ORIGINAL_IGW_ID}

echo "[INFO] Updating route table default route back to IGW"
run oci network route-table update \
  --rt-id "$RT_ID" \
  --route-rules "$NEW_RULES" \
  --region "$OCI_REGION" \
  --profile "$OCI_CLI_PROFILE" \
  --force \
  --wait-for-state AVAILABLE >/dev/null

echo "[INFO] Deleting NAT gateway (will fail if still referenced by any route table)"
run oci network nat-gateway delete \
  --nat-gateway-id "$NAT_ID" \
  --region "$OCI_REGION" \
  --profile "$OCI_CLI_PROFILE" \
  --force

echo "[INFO] Done."
if [[ "$APPLY" -eq 0 ]]; then
  echo "[INFO] Dry run only. Re-run with --apply to execute."
fi
