#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="scripts/oci/gateway.env"
APPLY=0

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
: "${OKE_ENDPOINT_SUBNET_OCID:?OKE_ENDPOINT_SUBNET_OCID is required}"
OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"

ADMIN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
if [[ -z "${ADMIN_IP:-}" ]]; then
  echo "[ERROR] Could not detect admin host IP" >&2
  exit 1
fi
ADMIN_CIDR="${ADMIN_IP}/32"

echo "[INFO] Using env: $ENV_FILE"
echo "[INFO] Region: $OCI_REGION  Profile: $OCI_CLI_PROFILE"
echo "[INFO] Endpoint subnet OCID: $OKE_ENDPOINT_SUBNET_OCID"
echo "[INFO] Admin host IP/CIDR: $ADMIN_IP / $ADMIN_CIDR"
echo

# Get full subnet JSON to a temp file (use $HOME to avoid /tmp permission issues) and parse IDs from it.
SUBNET_JSON_FILE="$(mktemp -p "$HOME" oci-subnet.XXXXXX.json)"
if ! oci network subnet get \
  --subnet-id "$OKE_ENDPOINT_SUBNET_OCID" \
  --region "$OCI_REGION" \
  --profile "$OCI_CLI_PROFILE" \
  --output json >"$SUBNET_JSON_FILE"; then
  echo "[ERROR] Failed to fetch subnet details via OCI CLI" >&2
  rm -f "$SUBNET_JSON_FILE"
  exit 1
fi

NSG_IDS="$(python3 - "$SUBNET_JSON_FILE" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
ids=d.get('data',{}).get('network-security-group-ids') or []
for x in ids:
    if isinstance(x,str) and x.strip():
        print(x.strip())
PY
)"

SECLIST_IDS="$(python3 - "$SUBNET_JSON_FILE" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
ids=d.get('data',{}).get('security-list-ids') or []
for x in ids:
    if isinstance(x,str) and x.strip():
        print(x.strip())
PY
)"

rm -f "$SUBNET_JSON_FILE"

echo "[INFO] Subnet NSGs:"
if [[ -n "$NSG_IDS" ]]; then echo "$NSG_IDS"; else echo "(none)"; fi
echo
echo "[INFO] Subnet Security Lists:"
if [[ -n "$SECLIST_IDS" ]]; then echo "$SECLIST_IDS"; else echo "(none)"; fi
echo

RULE_JSON="$(python3 - <<PY
import json
admin_cidr="${ADMIN_CIDR}"
rule={
  "protocol":"6",
  "source": admin_cidr,
  "sourceType":"CIDR_BLOCK",
  "tcpOptions":{"destinationPortRange":{"min":6443,"max":6443}},
  "isStateless": False,
  "description": "Allow admin host subnet to reach OKE private API (6443)"
}
print(json.dumps(rule))
PY
)"

add_to_nsg() {
  local nsg_id="$1"
  echo "[INFO] Target: NSG $nsg_id"
  echo "[INFO] Adding ingress rule: $RULE_JSON"
  oci network nsg add-security-rules \
    --network-security-group-id "$nsg_id" \
    --security-rules "[${RULE_JSON}]" \
    --region "$OCI_REGION" \
    --profile "$OCI_CLI_PROFILE"
  echo "[INFO] NSG rule added."
}

add_to_seclist() {
  local seclist_id="$1"
  echo "[INFO] Target: Security List $seclist_id"
  echo "[INFO] Fetching existing ingress rules..."

  local seclist_json_file
  seclist_json_file="$(mktemp -p "$HOME" oci-seclist.XXXXXX.json)"

  if ! oci network security-list get \
    --security-list-id "$seclist_id" \
    --region "$OCI_REGION" \
    --profile "$OCI_CLI_PROFILE" \
    --output json >"$seclist_json_file"; then
    echo "[ERROR] Failed to fetch security list via OCI CLI: $seclist_id" >&2
    rm -f "$seclist_json_file"
    exit 1
  fi

  local merged
  merged="$(SECLIST_JSON_FILE="$seclist_json_file" RULE_JSON="$RULE_JSON" python3 - <<'PY'
import json
import os
p=os.environ["SECLIST_JSON_FILE"]
seclist=json.load(open(p))
existing=seclist.get('data', {}).get('ingress-security-rules')
if not isinstance(existing, list):
    existing=[]
new_rule=json.loads(os.environ["RULE_JSON"])
existing.append(new_rule)
print(json.dumps(existing))
PY
)"

  rm -f "$seclist_json_file"

  echo "[INFO] Updating Security List ingress rules (append 6443 allow from $ADMIN_CIDR)"
  oci network security-list update \
    --security-list-id "$seclist_id" \
    --ingress-security-rules "$merged" \
    --region "$OCI_REGION" \
    --profile "$OCI_CLI_PROFILE" \
    --force
  echo "[INFO] Security List updated."
}

if [[ "$APPLY" -ne 1 ]]; then
  echo "[INFO] Dry-run. Re-run with --apply to modify NSG/Security List."
  if [[ -n "$NSG_IDS" ]]; then
    echo "[INFO] Would add rule to first NSG: $(echo "$NSG_IDS" | head -n 1)"
  elif [[ -n "$SECLIST_IDS" ]]; then
    echo "[INFO] Would add rule to first Security List: $(echo "$SECLIST_IDS" | head -n 1)"
  else
    echo "[ERROR] Subnet has neither NSG nor Security List IDs? Unexpected." >&2
    exit 1
  fi
  exit 0
fi

# Prefer NSG if subnet has any
if [[ -n "$NSG_IDS" ]]; then
  FIRST_NSG="$(echo "$NSG_IDS" | head -n 1)"
  add_to_nsg "$FIRST_NSG"
  exit 0
fi

if [[ -n "$SECLIST_IDS" ]]; then
  FIRST_SECLIST="$(echo "$SECLIST_IDS" | head -n 1)"
  add_to_seclist "$FIRST_SECLIST"
  exit 0
fi

echo "[ERROR] Subnet has neither NSG nor Security List IDs? Unexpected." >&2
exit 1
