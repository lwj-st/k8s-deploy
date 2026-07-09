#!/usr/bin/env bash
################################################################################
## Filename:    20-Deploy-local-path.sh
## Description: 部署 local-path-provisioner
## Usage:
##   bash 20-Deploy-local-path.sh
## Images:
##   - local-path.image.provisioner.master-head
##   - local-path.image.busybox.1.33.1
## Notes:
##   - 默认创建 PV 路径在 /data/local-path-provisioner
################################################################################
set -euo pipefail

# 默认创建pv路径在 /data/local-path-provisioner

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

f1="$(artifact_get_path_by_name "local-path.manifest.storage")"
# f2="$(artifact_get_path_by_name "local-path.manifest.dynamic")"
[ -f "${f1}" ] || die "缺少制品: ${f1}"
# [ -f "${f2}" ] || die "缺少制品: ${f2}"

log_info "导入 local-path-provisioner 镜像..."
import_image_artifacts \
  "local-path.image.provisioner.master-head" \
  "local-path.image.busybox.1.33.1"

log_info "部署 local-path..."
log_command "kubectl apply -f \"${f1}\""
# log_command "kubectl apply -f \"${f2}\""

kubectl get storageclass 2>/dev/null || true
log_info "local-path 部署完成"
