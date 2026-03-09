#!/usr/bin/env bash
# =============================================================================
# OCI OpenClaw Local Docker 部署脚本
# =============================================================================
#
# 使用方法:
#   ./deploy.sh              # 预览模式（不执行）
#   ./deploy.sh --apply      # 执行部署
#   ./deploy.sh --stop       # 停止服务
#   ./deploy.sh --logs       # 查看日志
#   ./deploy.sh --status     # 查看状态
#   ./deploy.sh --clean      # 清理所有资源
#
# 前置条件:
#   1. Docker Desktop 已启动
#   2. 已复制并配置 .env 文件
#   3. 已复制并配置 openclaw-config/openclaw.json
#   4. 已复制并配置 gateway-config.json
#   5. 已准备 OCI 凭证文件
#   6. 已构建 openclaw 镜像
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APPLY=0
ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --stop)
      ACTION="stop"
      shift
      ;;
    --logs)
      ACTION="logs"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --clean)
      ACTION="clean"
      shift
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      echo "Usage: $0 [--apply | --stop | --logs | --status | --clean]" >&2
      exit 1
      ;;
  esac
done

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 Docker 是否运行
check_docker() {
  if ! docker info &> /dev/null; then
    log_error "Docker 未运行，请先启动 Docker Desktop"
    exit 1
  fi
  log_success "Docker 已运行"
}

# 检查配置文件
check_config() {
  log_info "检查配置文件..."

  local missing=0

  if [[ ! -f ".env" ]]; then
    log_warn ".env 文件不存在"
    log_info "  请复制 .env.example 到 .env 并填写配置"
    missing=1
  fi

  if [[ ! -f "gateway-config.json" ]]; then
    log_warn "gateway-config.json 文件不存在"
    log_info "  请复制 gateway-config.json.example 并填写 OCI 配置"
    missing=1
  fi

  if [[ ! -d "openclaw-config" ]]; then
    log_warn "openclaw-config/ 目录不存在"
    log_info "  请创建目录并配置 openclaw.json"
    missing=1
  elif [[ ! -f "openclaw-config/openclaw.json" ]]; then
    log_warn "openclaw-config/openclaw.json 文件不存在"
    log_info "  请复制 openclaw.json.example 并修改配置"
    missing=1
  fi

  if [[ ! -d "oci-credentials" ]]; then
    log_warn "oci-credentials/ 目录不存在"
    log_info "  请创建目录并复制 OCI 凭证文件 (config, oci_api_key.pem)"
    missing=1
  elif [[ ! -f "oci-credentials/config" ]]; then
    log_warn "oci-credentials/config 文件不存在"
    missing=1
  fi

  if [[ $missing -eq 1 ]]; then
    return 1
  fi

  log_success "配置文件检查通过"
  return 0
}

# 检查 openclaw 镜像
check_openclaw_image() {
  log_info "检查 openclaw 镜像..."

  if ! docker image inspect openclaw:local &> /dev/null; then
    log_warn "openclaw:local 镜像不存在"
    log_info "请先构建镜像:"
    log_info "  cd /Users/arthurjin/PycharmProjects/openclaw0226"
    log_info "  docker build -t openclaw:local ."
    return 1
  fi

  log_success "openclaw:local 镜像已存在"
  return 0
}

# 检查 gateway 镜像
check_gateway_image() {
  log_info "检查 gateway 镜像..."

  if ! docker image inspect oci-anthropic-gateway:latest &> /dev/null; then
    log_warn "oci-anthropic-gateway:latest 镜像不存在"
    log_info "请先构建镜像或修改 .env 中的 GATEWAY_IMAGE"
    return 1
  fi

  log_success "oci-anthropic-gateway:latest 镜像已存在"
  return 0
}

# 创建必要目录
create_directories() {
  log_info "创建必要目录..."

  mkdir -p debug_dumps
  mkdir -p workspace

  log_success "目录创建完成"
}

# 部署服务
deploy() {
  log_info "开始部署..."

  if [[ $APPLY -eq 0 ]]; then
    log_warn "预览模式 - 不会执行实际部署"
    log_info "添加 --apply 参数执行实际部署"
    echo ""
    docker-compose config
    return 0
  fi

  create_directories

  log_info "启动服务..."
  docker-compose up -d

  log_info "等待服务健康检查..."
  sleep 5

  log_info "服务状态:"
  docker-compose ps

  echo ""
  log_success "部署完成!"
  echo ""
  log_info "访问地址:"
  echo "  OpenClaw Gateway: http://localhost:18789"
  echo "  OCI Gateway:      http://localhost:8000"
  echo "  Gateway Debug:    http://localhost:8000/debug/"
  echo ""
  log_info "常用命令:"
  echo "  查看日志: ./deploy.sh --logs"
  echo "  查看状态: ./deploy.sh --status"
  echo "  停止服务: ./deploy.sh --stop"
}

# 停止服务
stop_services() {
  log_info "停止服务..."
  docker-compose down
  log_success "服务已停止"
}

# 查看日志
view_logs() {
  docker-compose logs -f
}

# 查看状态
view_status() {
  log_info "服务状态:"
  docker-compose ps

  echo ""
  log_info "网络信息:"
  docker network inspect gateway-network --format '{{.Name}}: {{.Driver}}' 2>/dev/null || log_warn "网络不存在"

  echo ""
  log_info "容器健康状态:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=openclaw\|oci-anthropic-gateway"
}

# 清理资源
clean_all() {
  log_warn "将清理所有容器、网络和数据目录"
  read -p "确认清理? (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_info "已取消"
    exit 0
  fi

  log_info "停止并移除容器..."
  docker-compose down -v --remove-orphans

  log_info "清理数据目录..."
  rm -rf debug_dumps/*

  log_success "清理完成"
}

# 主流程
main() {
  echo "========================================"
  echo "  OCI OpenClaw Local Docker 部署"
  echo "========================================"
  echo ""

  check_docker

  case "$ACTION" in
    stop)
      stop_services
      ;;
    logs)
      view_logs
      ;;
    status)
      view_status
      ;;
    clean)
      clean_all
      ;;
    *)
      # 部署前检查
      check_config || {
        log_error "配置检查失败，请先完成配置"
        exit 1
      }

      check_openclaw_image || {
        log_error "请先构建 openclaw 镜像"
        exit 1
      }

      check_gateway_image || {
        log_warn "gateway 镜像不存在，将尝试从 .env 配置拉取"
      }

      deploy
      ;;
  esac
}

main
