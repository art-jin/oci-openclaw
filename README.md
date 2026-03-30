# OCI OKE Deployment (openclaw + oci-anthropic-gateway)

This repository is used to deploy the following components to OCI OKE:
- `oci-anthropic-gateway`: In-cluster gateway (integrates with OCI GenAI)
- `openclaw`: Upstream Anthropic-compatible application (calls gateway via in-cluster DNS)

## 1. Architecture (OKE)

### 1.1 Target Call Chain and Auth Boundaries

```text
User -> openclaw (openclaw-prod) -> gateway (gateway-prod/ClusterIP) -> OCI GenAI (HTTPS)
Admin -> VPN/Bastion -> gateway /debug (Bearer Token)

OCI auth boundaries:
- openclaw pod:
  - primary: OKE Workload Identity for pod-local OCI CLI
  - fallback: Instance Principal for pod-local OCI CLI
  - explicit mode: caller provides --auth per OCI CLI command
- gateway pod:
  - primary: OKE Workload Identity for OCI SDK calls to OCI GenAI
  - fallback documented here: oci_config_secret
```

### 1.2 Implementation Architecture (ASCII Diagram with Port Forwarding, Auth, and IAM Paths)

```text
Mac Browser/Terminal
  |  http://127.0.0.1:18789
  |
  +-- ssh -L 18789:127.0.0.1:18789 <user>@<oci-vm>                       (2.4-2)
  |
OCI VM (bastion/admin)
  |  kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789      (2.4-1)
  |
  +-- forwards to ClusterIP svc/openclaw:18789 -> openclaw Pod

                               (Cluster: OCI OKE)
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                              │
│  Namespace: openclaw-prod                               Namespace: gateway-prod              │
│                                                                                              │
│  ┌────────────────────────────────────┐               ┌───────────────────────────────────┐ │
│  │ Pod: openclaw-0                    │               │ Pod: oci-anthropic-gateway        │ │
│  │  containers: openclaw gateway + cli│               │                                   │ │
│  │  serviceAccount: openclaw-sa       │               │  serviceAccount: oci-gateway-sa   │ │
│  │                                    │               │                                   │ │
│  │  User/UI traffic                   │               │  In-cluster API                    │ │
│  │  - UI/Gateway :18789               │               │  - Anthropic-compatible API :8000 │ │
│  │                                    │               │                                   │ │
│  │  OCI CLI auth inside pod           │               │  OCI SDK auth inside pod          │ │
│  │  - preferred: oke_workload_identity│               │  - preferred: workload_identity   │ │
│  │  - fallback: instance_principal    │               │  - fallback here: oci_config_secret│ │
│  │  - explicit: caller passes --auth  │               │                                   │ │
│  │                                    │               │                                   │ │
│  │  Injection / runtime helpers       │               │  Injection / runtime helpers      │ │
│  │  - OCI_RESOURCE_PRINCIPAL_*        │               │  - OCI_RESOURCE_PRINCIPAL_*       │ │
│  │  - OCI_CLI_AUTH                    │               │  - gateway config.json            │ │
│  │  - /home/node/.openclaw/bin/oci    │               │  - DEBUG_UI_AUTH_TOKEN            │ │
│  │    wrapper auto-adds --auth        │               │                                   │ │
│  │                                    │               │                                   │ │
│  │  Network egress                    │               │  Network egress                    │ │
│  │  - DNS                             │               │  - DNS                            │ │
│  │  - gateway service :8000           │               │  - OCI GenAI HTTPS :443          │ │
│  └───────────────┬────────────────────┘               └──────────────────┬────────────────┘ │
│                  │   HTTP via Cluster DNS / Service                      │                  │
│                  │   http://oci-anthropic-gateway...:8000                │                  │
│                  v                                                       v                  │
│          ┌─────────────────────┐                                 ┌──────────────────────┐  │
│          │ SVC openclaw        │                                 │ OCI Generative AI    │  │
│          │ ClusterIP :18789    │                                 │ inference endpoint   │  │
│          └──────────┬──────────┘                                 └──────────────────────┘  │
│                     │                                                                        │
│          ┌──────────v──────────┐                                                             │
│          │ SVC oci-anthropic   │                                                             │
│          │ -gateway ClusterIP  │                                                             │
│          │ :8000               │                                                             │
│          └─────────────────────┘                                                             │
│                                                                                              │
└──────────────────────────────────────────────────────────────────────────────────────────────┘

IAM / authorization model:
- Gateway Workload Identity policy:
  - subject = workload principal constrained by namespace + service account + cluster_id
  - grants = inspect generative-ai-model, use generative-ai-chat
- OpenClaw Workload Identity policy:
  - subject = workload principal constrained by namespace + service account + cluster_id
  - grants = manage buckets, manage objects
- OpenClaw Instance Principal fallback policy:
  - subject = worker-node Dynamic Group
  - grants = manage buckets, manage objects
```

### 1.3 Architecture Notes

- `openclaw` and `oci-anthropic-gateway` are separate pods with separate service accounts, separate IAM subjects, and separate OCI access paths.
- `openclaw` does not call OCI GenAI directly for model inference. It calls the in-cluster gateway service over ClusterIP.
- `gateway` is the component that talks to OCI Generative AI.
- `openclaw` OCI access is for pod-local OCI CLI use cases, such as agent exec tools or interactive operations.
- Preferred auth model:
  - gateway -> OKE Workload Identity
  - openclaw OCI CLI -> OKE Workload Identity
- Fallback auth model documented in this repo:
  - openclaw OCI CLI -> Instance Principal
  - gateway -> `oci_config_secret` if Workload Identity cannot be used
- `explicit` is not a separate IAM model. It means the caller must explicitly pass `--auth` for each OCI CLI command.
- No public LoadBalancer is required for the default architecture. Admin access to OpenClaw UI is through port-forwarding and optional SSH local forwarding.

## 2. Quick Start

### 2.1 Prepare Configuration Files

```bash
cp scripts/oci/gateway.env.example scripts/oci/gateway.env
cp -f config.json.template config.json

vi scripts/oci/gateway.env
vi config.json
```

Required fields:
- `scripts/oci/gateway.env`: `OCI_REGION`, `OCI_COMPARTMENT_OCID`, `OCI_CLUSTER_OCID` (or leave empty to trigger cluster creation), `GATEWAY_IMAGE*`, `OCI_USERNAME`, `OCI_AUTH_TOKEN`, `DEBUG_UI_AUTH_TOKEN`
- `config.json`: `compartment_id`, `model_definitions.*.ocid`

> Note: If `OCI_AUTH_TOKEN` contains special characters, it must be enclosed in double quotes.

### 2.2 One-Click Deployment

Recommended path: use OKE Workload Identity as the primary auth mode.

```bash
# Recommended: deploy and also create/update IAM Policy for Workload Identity
# Default mode is "all": gateway GenAI + OpenClaw workload-identity Object Storage policy
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy

# Use existing OKE (skip cluster creation)
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy --skip-create-cluster

# Deploy only (does not modify IAM)
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply

# Fallback option: create/update the worker-node Dynamic Group and apply
# the separate OpenClaw instance principal Object Storage policy
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply \
  --create-instance-principal-dynamic-group \
  --apply-instance-principal-policy
```

### 2.3 Verification

```bash
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

### 2.4 Access OpenClaw UI (SSH Scenario / Mac Access)

1) Start port-forward on OCI VM (bastion/admin) (recommended to run in foreground or use tmux/screen):
```bash
kubectl -n openclaw-prod port-forward svc/openclaw 18789:18789
```
Access on the VM: `http://127.0.0.1:18789`

2) Access from Mac (SSH local port forwarding):
```bash
ssh -N -L 18789:127.0.0.1:18789 ubuntu@<VM_PUBLIC_IP_OR_REACHABLE_ADDRESS>
```
Then open in Mac browser: `http://127.0.0.1:18789`

### 2.5 Get OpenClaw UI Token (for UI Login/Control)

```bash
kubectl -n openclaw-prod exec openclaw-0 -c cli -- cat /home/node/.openclaw/gateway-token
```

> Security Note: This token is equivalent to UI session credentials. Use only in controlled terminals and rotate when necessary.

## 3. Common Commands

```bash
# Gateway deployment (can be run independently)
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --apply

# OpenClaw deployment (optional)
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply

# Preferred IAM policy path: Workload Identity (default mode: all)
bash scripts/oci/11_workload_identity_policy.sh create-or-update --env scripts/oci/gateway.env

# Fallback IAM policy path: OpenClaw instance principal Object Storage
# Requires an existing Dynamic Group
bash scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update --env scripts/oci/gateway.env

# Dynamic Group helper for quick experiments (requires IAM permission; default matching rule uses OCI_COMPARTMENT_OCID)
bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create-or-update --env scripts/oci/gateway.env

# Cleanup gateway (optional)
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

## 4. OCI auth modes for gateway and openclaw

Gateway and OpenClaw are deployed as two separate pods, and they use two separate OCI access paths:
- `oci-anthropic-gateway` pod: OCI SDK path for OCI Generative AI
- `openclaw` pod: OCI CLI path used by agent exec tools or interactive `kubectl exec`

They can be authorized and configured independently.

### 4.1 Preferred path: OKE Workload Identity

#### 4.1.1 Gateway with Workload Identity

Recommended configuration:
- `AUTH_MODE=workload_identity`
- `OCI_RESOURCE_PRINCIPAL_REGION` in `scripts/oci/gateway.env`

Pod-side injection:
- `k8s/04-deployment.yaml` sets:
  - `serviceAccountName: oci-gateway-sa`
  - `OCI_RESOURCE_PRINCIPAL_VERSION`
  - `OCI_RESOURCE_PRINCIPAL_REGION`

Authorization:
- Primary script: `scripts/oci/11_workload_identity_policy.sh`
- Typical one-click flow:
  ```bash
  bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply --apply-iam-policy
  ```
- The policy binds access by:
  - namespace
  - service account
  - cluster OCID
- For gateway-only GenAI access:
  ```bash
  bash scripts/oci/11_workload_identity_policy.sh create-or-update \
    --env scripts/oci/gateway.env \
    --mode gateway-genai
  ```

What it grants:
- `inspect generative-ai-model`
- `use generative-ai-chat`

Why this is preferred:
- No OCI API key needs to be mounted into the pod
- Pod-scoped identity is narrower than node-scoped identity
- IAM conditions can be constrained to namespace + service account + cluster
- Best fit for least-privilege OCI access from the gateway pod

#### 4.1.2 OpenClaw with Workload Identity

Recommended configuration:
- `OPENCLAW_OCI_CLI_AUTH_MODE=oke_workload_identity` (default)

Pod-side injection:
- `k8s/openclaw/05-statefulset.yaml` sets:
  - `serviceAccountName: openclaw-sa`
  - `OCI_RESOURCE_PRINCIPAL_VERSION`
  - `OCI_RESOURCE_PRINCIPAL_REGION`
  - `OCI_CLI_AUTH=oke_workload_identity`
- The same manifest also creates an OCI CLI wrapper at `/home/node/.openclaw/bin/oci`
- That wrapper automatically adds `--auth oke_workload_identity` unless the mode is `explicit`

Authorization:
- Primary script: `scripts/oci/11_workload_identity_policy.sh`
- OpenClaw-only Object Storage policy:
  ```bash
  bash scripts/oci/11_workload_identity_policy.sh create-or-update \
    --env scripts/oci/gateway.env \
    --mode openclaw-objectstorage \
    --namespace openclaw-prod \
    --service-account openclaw-sa
  ```
- The default `--apply-iam-policy` path uses mode `all`, which includes both:
  - gateway GenAI permissions
  - OpenClaw workload-identity Object Storage permissions

What it grants by default for OpenClaw:
- `manage buckets`
- `manage objects`

Why this is preferred:
- Pod-level identity instead of node-level identity
- Cleaner security boundary for agent-driven OCI CLI calls
- No need for OCI config/key secrets in the pod
- Best match for OpenClaw exec tools that should act as the workload itself

Validated result in the current cluster state:
- `OCI_CLI_AUTH=oke_workload_identity` is injected into the openclaw containers
- `/home/node/.openclaw/bin/oci os ns get --debug` shows `auth: oke_workload_identity`
- OpenClaw agent OCI CLI calls using OKE workload identity succeeded, including Object Storage bucket creation
- A verified test bucket (`test-bucket-20260329-1119z`) shows `created-by=ocid1.workload...`, confirming the creator is the OKE workload principal rather than a personal user or instance principal

### 4.2 Fallback path: Instance Principal

#### 4.2.1 OpenClaw with Instance Principal

Fallback configuration:
- `OPENCLAW_OCI_CLI_AUTH_MODE=instance_principal`

Pod-side behavior:
- The OCI CLI wrapper in `k8s/openclaw/05-statefulset.yaml` automatically adds:
  - `--auth instance_principal`

Authorization prerequisites:
1. An OCI Dynamic Group that matches the worker nodes
2. An IAM policy that grants the Dynamic Group access

Related scripts:
- Dynamic Group helper:
  ```bash
  bash scripts/oci/12a_openclaw_instance_principal_dynamic_group.sh create-or-update --env scripts/oci/gateway.env
  ```
- Instance principal policy:
  ```bash
  bash scripts/oci/12_openclaw_instance_principal_policy.sh create-or-update --env scripts/oci/gateway.env
  ```
- One-click fallback options:
  ```bash
  bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply \
    --create-instance-principal-dynamic-group \
    --apply-instance-principal-policy
  ```

Default instance principal grants for OpenClaw:
- `manage buckets`
- `manage objects`

Why this exists:
- Useful when OKE Workload Identity is unavailable or not functioning in the current cluster
- Can be easier to enable in some environments where node identity is already accepted

Tradeoffs:
- Node-scoped identity is broader than pod-scoped identity
- Requires Dynamic Group management in OCI IAM
- Multiple pods on the same node may share the same node identity boundary
- Should be treated as a fallback path, not the primary recommendation

#### 4.2.2 Gateway and Instance Principal

Gateway instance principal is not documented in this repository as a primary scripted deployment path.

For the gateway pod, the documented auth modes are:
- `AUTH_MODE=workload_identity` (preferred)
- `AUTH_MODE=oci_config_secret` (legacy explicit credentials path)

So for gateway, the practical guidance in this repository is:
- prefer Workload Identity
- if Workload Identity cannot be used, fall back to `oci_config_secret`
- do not treat gateway instance principal as the standard documented path here

### 4.3 Explicit mode for OpenClaw OCI CLI

Supported configuration:
- `OPENCLAW_OCI_CLI_AUTH_MODE=explicit`

Behavior:
- The OpenClaw OCI wrapper does **not** auto-add `--auth`
- Every OCI CLI call must specify the auth mode explicitly, for example:
  ```bash
  /home/node/.openclaw/bin/oci os ns get --auth oke_workload_identity
  /home/node/.openclaw/bin/oci os ns get --auth instance_principal
  ```

When to use it:
- debugging
- controlled experiments
- verifying multiple auth paths intentionally

Important cautions:
- If you forget `--auth`, OCI CLI may fall back to its default config-file behavior
- That can produce misleading errors such as missing `~/.oci/config`
- Interactive `kubectl exec ... sh -lc` shells may reset `PATH` and resolve `oci` to `/usr/local/bin/oci` instead of the wrapper
- The safest form is:
  - `/home/node/.openclaw/bin/oci ... --auth <mode>`

Summary guidance:
- use `oke_workload_identity` by default
- use `instance_principal` only as fallback
- use `explicit` only when you intentionally want to control `--auth` per command

## 5. Optional kubeconfig mount for agent-driven kubectl

- `scripts/oci/gateway.env` also supports mounting a kubeconfig into the openclaw pod:
  - `OPENCLAW_MOUNT_KUBECONFIG=1`
  - `OPENCLAW_KUBECONFIG_FILE=/path/to/kubeconfig`
  - `OPENCLAW_KUBECONFIG_SECRET_NAME=openclaw-kubeconfig`
- When enabled, the deployment script creates and populates a Secret that is exposed in the pod at `/home/node/.kube/config` with `KUBECONFIG=/home/node/.kube/config`.
- This is optional and is intended as a supporting capability for agent-driven `kubectl` workflows. It is not required for OpenClaw OCI access to Object Storage via `oke_workload_identity`.
- The mounted kubeconfig must be valid for use from inside the pod runtime. A host-generated kubeconfig may still depend on external credentials or exec-based login flows and may not be directly usable inside the container.
- If you do not need pod-local `kubectl`, set `OPENCLAW_MOUNT_KUBECONFIG=0`.
- Best practice: use a dedicated least-privilege kubeconfig instead of a personal admin kubeconfig.

## 6. Documentation
- Troubleshooting: `docs/troubleshooting.md`
- IAM / Workload Identity: `docs/iam-workload-identity.md`
- Go-Live checklist: `docs/go-live-checklist.md`
- Local Docker: `docs/local-docker.md` (detailed steps in `local-docker/README.md`)
- Archive (historical records/planning drafts): `docs/archive/`

## 7. Related Files
- `scripts/oci/gateway.env.example` / `scripts/oci/gateway.env`
- `config.json.template` / `config.json`
- `k8s/` (Kubernetes manifests)
- `local-docker/`

## License

This project is licensed under the [Apache License 2.0](LICENSE).

```
Copyright 2024 Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
