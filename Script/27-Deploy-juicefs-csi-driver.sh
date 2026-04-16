#!/usr/bin/env bash
################################################################################
## Filename:    27-Deploy-juicefs-csi-driver.sh
## Description: 导入 JuiceFS CSI 相关镜像 tar，解压 chart 后以 Helm 安装/升级
## Notes:
##   - 与 install.md 一致：chart 解压目录名为 juicefs-csi-driver
##   - release: juicefs-csi-driver，命名空间: juicefs-csi
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

NS="juicefs-csi"
RELEASE="juicefs-csi-driver"
CHART_DIR_NAME="juicefs-csi-driver"

CHART_TGZ=""
VALUES=""
JUICE_DIR=""

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

  CHART_TGZ="$(artifact_get_path_by_name "juicefs.chart.csi-driver.v0.28.1")"
  VALUES="$(artifact_get_path_by_name "juicefs.values.csi-driver.yaml")"
  JUICE_DIR="$(dirname "${CHART_TGZ}")"

  [ -f "${CHART_TGZ}" ] || die "缺少制品: ${CHART_TGZ}"
  [ -f "${VALUES}" ] || die "缺少制品: ${VALUES}"
}

################################################################################
# Function: import_juicefs_images
################################################################################
import_juicefs_images() {
  local names=(
    juicefs.image.csi-dashboard.v0.28.1
    juicefs.image.csi-node-driver-registrar.v2.13.0
    juicefs.image.csi-provisioner.v2.2.2
    juicefs.image.csi-resizer.v1.9.0
    juicefs.image.juicefs-csi-driver.v0.28.1
    juicefs.image.livenessprobe.v2.12.0
    juicefs.image.mount-ce.v1.2.3
  )
  local n f
  for n in "${names[@]}"; do
    f="$(artifact_get_path_by_name "${n}")"
    [ -f "${f}" ] || die "缺少制品: ${f} (name=${n})"
    log_info "导入镜像 tar: ${n}"
    log_command "ctr -n k8s.io images import \"${f}\""
  done
}

################################################################################
# Function: ensure_namespace
################################################################################
ensure_namespace() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
}

################################################################################
# Function: unpack_chart
################################################################################
unpack_chart() {
  local chart_path="${JUICE_DIR}/${CHART_DIR_NAME}"
  if [ ! -f "${chart_path}/Chart.yaml" ]; then
    log_info "解压 Helm chart 到 ${JUICE_DIR}..."
    log_command "tar xzf \"${CHART_TGZ}\" -C \"${JUICE_DIR}\""
  else
    log_info "已存在 chart 目录，跳过解压: ${chart_path}"
  fi
  [ -f "${chart_path}/Chart.yaml" ] || die "解压后未找到 Chart.yaml: ${chart_path}/Chart.yaml"
}

################################################################################
# Function: helm_install_or_upgrade
################################################################################
helm_install_or_upgrade() {
  local chart_path="${JUICE_DIR}/${CHART_DIR_NAME}"
  log_info "Helm 安装/升级 ${RELEASE}..."
  log_command "helm -n \"${NS}\" upgrade --install \"${RELEASE}\" \"${chart_path}\" -f \"${VALUES}\""
}

################################################################################
# Function: main
################################################################################
main() {
  init_env
  import_juicefs_images
  ensure_namespace
  unpack_chart
  helm_install_or_upgrade
  log_info "JuiceFS CSI Driver 部署完成（命名空间 ${NS}，release ${RELEASE}）"
}

main "$@"
