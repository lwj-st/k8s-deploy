#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

f1="$(artifact_get_path_by_name "local-path.manifest.storage")"
f2="$(artifact_get_path_by_name "local-path.manifest.dynamic")"
[ -f "${f1}" ] || die "缺少制品: ${f1}"
[ -f "${f2}" ] || die "缺少制品: ${f2}"

log_info "部署 local-path..."
log_command "kubectl apply -f \"${f1}\""
log_command "kubectl apply -f \"${f2}\""

kubectl get storageclass 2>/dev/null || true
log_info "local-path 部署完成"


