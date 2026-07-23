#!/usr/bin/env bash
################################################################################
## Filename:    17-Deploy-ingress.sh
## Description: 部署 ingress-nginx
## Usage:
##   bash 17-Deploy-ingress.sh
## Artifacts:
##   - ingress.manifest.ingress-nginx
## Images:
##   - ingress.image.controller.v1.12.2
##   - ingress.image.webhook-certgen.v1.5.3
## Env:
##   - INGRESS_NODE_NAME: 需要打 ingress-node=true 的节点名
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

ing="$(artifact_get_path_by_name "ingress.manifest.ingress-nginx")"
[ -f "${ing}" ] || die "缺少制品: ${ing}"

log_info "导入 ingress-nginx 镜像..."
import_image_artifacts \
  "ingress.image.controller.v1.12.2" \
  "ingress.image.webhook-certgen.v1.5.3"

# 当前控制节点提前去污点（避免 admission jobs Pending）
node_name="$(get_local_k8s_node_name)"
kubectl taint nodes "${node_name}" node-role.kubernetes.io/control-plane- --overwrite 2>/dev/null || true
kubectl taint nodes "${node_name}" node-role.kubernetes.io/master- --overwrite 2>/dev/null || true

log_info "部署 ingress-nginx..."
log_command "kubectl apply -f \"${ing}\""

INGRESS_NODE_NAME="$(normalize_k8s_node_name "${INGRESS_NODE_NAME}")"
kubectl get node "${INGRESS_NODE_NAME}" >/dev/null 2>&1 || die "无法找到 Ingress 节点对象：${INGRESS_NODE_NAME}"
log_info "给 ingress 节点打 label: ${INGRESS_NODE_NAME}"
log_command "kubectl label node \"${INGRESS_NODE_NAME}\" ingress-node=true --overwrite"

log_info "等待 ingress-nginx controller 就绪..."
if kubectl -n ingress-nginx get deployment ingress-nginx-controller >/dev/null 2>&1; then
  log_command "kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s"
elif kubectl -n ingress-nginx get daemonset ingress-nginx-controller >/dev/null 2>&1; then
  log_command "kubectl -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=300s"
else
  kubectl -n ingress-nginx get all 2>/dev/null || true
  die "未找到 ingress-nginx-controller（deployment/daemonset 均不存在）"
fi

for job in ingress-nginx-admission-create ingress-nginx-admission-patch; do
  if kubectl -n ingress-nginx get job "$job" >/dev/null 2>&1; then
    log_info "等待 admission job 完成: $job"
    log_command "kubectl -n ingress-nginx wait --for=condition=complete job/$job --timeout=300s"
  fi
done

log_info "等待 admission endpoints 就绪..."
attempt=0
while [ $attempt -lt 60 ]; do
  if kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -qE '.+'; then
    log_info "admission endpoints 已就绪"
    break
  fi
  sleep 5
  attempt=$((attempt+1))
done
if [ $attempt -ge 60 ]; then
  kubectl -n ingress-nginx get pods -o wide 2>/dev/null || true
  die "admission endpoints 未就绪（超时）"
fi

log_info "Ingress 部署完成"
