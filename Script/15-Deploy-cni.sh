#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

calico="$(artifact_get_path_by_name "cni.manifest.calico")"
[ -f "${calico}" ] || die "缺少制品: ${calico}"

log_info "部署 Calico CNI..."
log_command "kubectl apply -f \"${calico}\""

log_info "CNI 部署完成"


