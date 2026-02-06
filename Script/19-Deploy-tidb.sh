#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

have helm || die "缺少 helm（请先执行 09-Install-tools.sh）"

chart="$(artifact_get_path_by_name "tidb.chart.operator.v1.6.1")"
crd="$(artifact_get_path_by_name "tidb.crd.yaml")"
values="$(artifact_get_path_by_name "tidb.values.operator.yaml")"

[ -f "${chart}" ] || die "缺少制品: ${chart}"
[ -f "${crd}" ] || die "缺少制品: ${crd}"
[ -f "${values}" ] || die "缺少制品: ${values}"

ns="tidb-admin"
kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -

log_info "应用 TiDB CRD..."
# 重要：TiDB CRD 文件很大，client-side `kubectl apply` 会写入 last-applied 注解，
# 可能触发 apiserver 的 annotations 256KiB 限制（metadata.annotations too long）。
# 这里改用 server-side apply，避免写入 last-applied 注解，同时保持幂等。
log_command "kubectl apply --server-side --force-conflicts --field-manager=k8s-deploy -f \"${crd}\""

if helm -n "${ns}" status tidb-operator >/dev/null 2>&1; then
  log_warn "检测到 tidb-operator 已存在，将先卸载再重装"
  helm -n "${ns}" uninstall tidb-operator || true
fi

log_info "安装 TiDB Operator..."
log_command "helm -n \"${ns}\" upgrade --install tidb-operator \"${chart}\" -f \"${values}\""

log_warn "TiDB 集群实例部署（tidb-cluster.yaml 等）需要按你的实际资源/存储做定制，这里不默认自动 apply。"
log_info "如需部署 TiDB 集群，可手动执行：kubectl apply -f ${DOWNLOAD_DIR}/tidb/tidb-cluster.yaml"


