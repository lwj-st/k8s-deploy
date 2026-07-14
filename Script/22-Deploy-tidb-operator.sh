#!/usr/bin/env bash
################################################################################
## Filename:    22-Deploy-tidb-operator.sh
## Description: 部署 TiDB Operator（不自动部署具体 TiDB 集群实例）
## Usage:
##   bash 22-Deploy-tidb-operator.sh
## Artifacts:
##   - tidb.chart.operator.v1.6.1
##   - tidb.crd.yaml
##   - tidb.values.operator.yaml
## Images:
##   - tidb.image.operator.v1.6.1
## Notes:
##   - 仅安装 CRD + Operator，tidb-cluster.yaml 等由用户按需手动 apply
##   - 使用 server-side apply 避免 CRD annotations 过大问题
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

NS="tidb-admin"
CHART=""
CRD=""
VALUES=""

################################################################################
# Function: init_env
# Description: 初始化基础环境与变量
################################################################################
init_env() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  have helm || die "缺少 helm（请先执行 09-Install-tools.sh）"

  CHART="$(artifact_get_path_by_name "tidb.chart.operator.v1.6.1")"
  CRD="$(artifact_get_path_by_name "tidb.crd.yaml")"
  VALUES="$(artifact_get_path_by_name "tidb.values.operator.yaml")"

  [ -f "${CHART}" ] || die "缺少制品: ${CHART}"
  [ -f "${CRD}" ] || die "缺少制品: ${CRD}"
  [ -f "${VALUES}" ] || die "缺少制品: ${VALUES}"
}

################################################################################
# Function: import_tidb_operator_image
# Description: 导入 TiDB Operator 离线镜像
################################################################################
import_tidb_operator_image() {
  log_info "导入 TiDB Operator 镜像..."
  import_image_artifact "tidb.image.operator.v1.6.1"
}

################################################################################
# Function: ensure_namespace
# Description: 确保 TiDB Operator 命名空间存在（幂等）
################################################################################
ensure_namespace() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
}

################################################################################
# Function: apply_tidb_crd
# Description: 以 server-side apply 方式应用 TiDB CRD
################################################################################
apply_tidb_crd() {
  log_info "应用 TiDB CRD..."
  # 重要：TiDB CRD 文件很大，client-side `kubectl apply` 会写入 last-applied 注解，
  # 可能触发 apiserver 的 annotations 256KiB 限制（metadata.annotations too long）。
  # 这里改用 server-side apply，避免写入 last-applied 注解，同时保持幂等。
  log_command "kubectl apply --server-side --force-conflicts --field-manager=k8s-deploy -f \"${CRD}\""
}

################################################################################
# Function: install_tidb_operator
# Description: 安装或重装 TiDB Operator
################################################################################
install_tidb_operator() {
  if helm -n "${NS}" status tidb-operator >/dev/null 2>&1; then
    log_warn "检测到 tidb-operator 已存在，将先卸载再重装"
    helm -n "${NS}" uninstall tidb-operator || true
  fi

  log_info "安装 TiDB Operator..."
  log_command "helm -n \"${NS}\" upgrade --install tidb-operator \"${CHART}\" -f \"${VALUES}\""
}

################################################################################
# Function: main
# Description: 主流程
################################################################################
main() {
  init_env
  import_tidb_operator_image
  ensure_namespace
  apply_tidb_crd
  install_tidb_operator

  log_warn "TiDB 集群实例部署（tidb-cluster.yaml 等）需要按你的实际资源/存储做定制，这里不默认自动 apply。"
  log_info "如需部署 TiDB 集群，请将实例清单补入 manifests/artifacts.yaml 后再手动 apply。"
}

main "$@"
