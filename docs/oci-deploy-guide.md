# OCI OKE 部署手册（Deployment Repo）

## 快速开始（推荐）

1) 准备 gateway 配置（必须填写模型 OCID）

    cp -f config.json.template config.json
    vi config.json

2) 编辑参数

    vi scripts/oci/gateway.env

3) 一键执行（含可选建集群 + 部署 gateway/oc-app + 验证）

    bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply

## 分步执行

### A. 创建 OKE（可选）

    bash scripts/oci/00_create_oke_cluster.sh --env scripts/oci/gateway.env
    bash scripts/oci/00_create_oke_cluster.sh --env scripts/oci/gateway.env --apply

### B. 生成 kubeconfig

    bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env
    bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env --apply

### C. 部署 gateway + oc-app

    bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-oc-app
    bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-oc-app --apply

### D. 验证（含跨命名空间 /v1/messages）

    bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env

### E. 清理 gateway

    bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env
    bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
