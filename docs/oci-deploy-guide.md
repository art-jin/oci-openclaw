# OCI OKE 部署手册（Deployment Repo）

## 快速开始（推荐）

1) 准备 gateway 配置（必须填写模型 OCID）：
```bash
cp -f config.json.template config.json
vi config.json
```

2) 编辑参数：
```bash
vi scripts/oci/gateway.env
```

3) 一键执行（含可选建集群 + 部署 gateway/openclaw + 验证）：
```bash
bash scripts/oci/10_deploy_all_in_one.sh --env scripts/oci/gateway.env --apply
```

## 分步执行

### A. 创建 OKE（可选）
```bash
bash scripts/oci/00_create_oke_cluster.sh --env scripts/oci/gateway.env
bash scripts/oci/00_create_oke_cluster.sh --env scripts/oci/gateway.env --apply
```

### B. 生成 kubeconfig
```bash
bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env
bash scripts/oci/01_prepare_oke_kubeconfig.sh scripts/oci/gateway.env --apply
```

### C. 部署 gateway
```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --apply
```

### D. 部署 openclaw 并公网暴露
```bash
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw
bash scripts/oci/02_deploy_gateway_oke.sh --env scripts/oci/gateway.env --deploy-openclaw --apply
```

### E. 验证
```bash
bash scripts/oci/03_verify_gateway.sh scripts/oci/gateway.env
```

### F. 清理 gateway
```bash
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env
bash scripts/oci/04_cleanup_gateway_oke.sh --env scripts/oci/gateway.env --apply
```
