#!/usr/bin/env bash
################################################################################
## Filename:    16-Deploy-cni.sh
## Description: 部署 Calico CNI
## Usage:
##   bash 16-Deploy-cni.sh
## Artifacts:
##   - cni.manifest.calico
## Images:
##   - cni.image.calico-cni.v3.30
##   - cni.image.kube-controllers.v3.30
##   - cni.image.calico-node.v3.30
## Env:
##   - CALICO_IP_AUTODETECTION_METHOD: 可选，设置 calico-node IP 探测方式
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

calico="$(artifact_get_path_by_name "cni.manifest.calico")"
[ -f "${calico}" ] || die "缺少制品: ${calico}"

log_info "导入 Calico CNI 镜像..."
import_image_artifacts \
  "cni.image.calico-cni.v3.30" \
  "cni.image.kube-controllers.v3.30" \
  "cni.image.calico-node.v3.30"

log_info "部署 Calico CNI..."
log_command "kubectl apply -f \"${calico}\""

if [ -n "${CALICO_IP_AUTODETECTION_METHOD:-}" ]; then
  autodetect_method="${CALICO_IP_AUTODETECTION_METHOD}"
  # 自动补全为 interface=<name>
  if [[ "${autodetect_method}" != *=* ]]; then
    autodetect_method="interface=${autodetect_method}"
  fi
  log_info "为 calico-node 设置 IP_AUTODETECTION_METHOD=${autodetect_method}"
  log_command "kubectl -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD=\"${autodetect_method}\""
else
  log_info "未设置 CALICO_IP_AUTODETECTION_METHOD，保留 Calico 默认 IP 探测方式"
fi

log_info "CNI 部署完成"
