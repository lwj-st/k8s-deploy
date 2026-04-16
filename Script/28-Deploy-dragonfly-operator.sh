#!/usr/bin/env bash
################################################################################
## Filename:    28-Deploy-dragonfly-operator.sh
## Description: 导入 Dragonfly Operator 镜像 tar，并以 Helm 安装 chart（tgz）
## Notes:
##   - 与 install.md 一致：release dragonfly-operator，命名空间 infra（--create-namespace）
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

NS="infra"
RELEASE="dragonfly-operator"

CHART_TGZ=""
VALUES=""

################################################################################
# Function: init_env
################################################################################
init_env() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  have helm || die "缺少 helm（请先执行 09-Install-tools.sh）"
  have kubectl || die "缺少 kubectl"
  have ctr || die "缺少 ctr（请先安装 containerd）"

  CHART_TGZ="$(artifact_get_path_by_name "dragonfly.chart.operator.v1.1.8")"
  VALUES="$(artifact_get_path_by_name "dragonfly.values.operator.yaml")"

  [ -f "${CHART_TGZ}" ] || die "缺少制品: ${CHART_TGZ}"
  [ -f "${VALUES}" ] || die "缺少制品: ${VALUES}"
}

################################################################################
# Function: import_dragonfly_images
################################################################################
import_dragonfly_images() {
  local f
  f="$(artifact_get_path_by_name "dragonfly.image.kube-rbac-proxy.v0.16.0")"
  [ -f "${f}" ] || die "缺少制品: ${f}"
  log_info "导入 kube-rbac-proxy 镜像..."
  log_command "ctr -n k8s.io images import \"${f}\""

  f="$(artifact_get_path_by_name "dragonfly.image.operator.v1.1.8")"
  [ -f "${f}" ] || die "缺少制品: ${f}"
  log_info "导入 dragonfly-operator 镜像..."
  log_command "ctr -n k8s.io images import \"${f}\""
}

################################################################################
# Function: helm_install_or_upgrade
################################################################################
helm_install_or_upgrade() {
  log_info "Helm 安装/升级 ${RELEASE}（命名空间 ${NS}）..."
  log_command "helm -n \"${NS}\" upgrade --install \"${RELEASE}\" \"${CHART_TGZ}\" -f \"${VALUES}\" --create-namespace"
}

################################################################################
# Function: main
################################################################################
main() {
  init_env
  import_dragonfly_images
  helm_install_or_upgrade
  log_info "Dragonfly Operator 部署完成（命名空间 ${NS}，release ${RELEASE}）"
}

main "$@"
