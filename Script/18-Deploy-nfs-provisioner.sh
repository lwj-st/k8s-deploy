#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root
export KUBECONFIG=/etc/kubernetes/admin.conf

have helm || die "缺少 helm（请先执行 09-Install-tools.sh）"

chart="$(artifact_get_path_by_name "nfs-provisioner.chart.v4.0.18")"
[ -f "${chart}" ] || die "缺少制品: ${chart}"

ns="nfs-provisioner"
kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -

# 如果 release 已存在，按你要求：停下 -> 备份(逻辑上等价于卸载) -> 重装
if helm -n "${ns}" status nfs-provisioner >/dev/null 2>&1; then
  log_warn "检测到 nfs-provisioner 已存在，将先卸载再重装"
  helm -n "${ns}" uninstall nfs-provisioner || true
fi

if [ -z "${NFS_SERVER:-}" ] || [ -z "${NFS_PATH:-}" ]; then
  die "缺少 NFS_SERVER/NFS_PATH（请先运行 01-Cluster-host.sh 填写）"
fi

# 离线镜像对齐：
# 我们默认导入的是 docker.io/eipwork/nfs-subdir-external-provisioner:v4.0.2
# chart 默认是 registry.k8s.io/sig-storage/...，不改会触发在线拉取导致 ImagePullBackOff
img_repo="${NFS_IMAGE_REPOSITORY:-docker.io/eipwork/nfs-subdir-external-provisioner}"
img_tag="${NFS_IMAGE_TAG:-v4.0.2}"

log_command "helm -n \"${ns}\" upgrade --install nfs-provisioner \"${chart}\" \
  --set nfs.server=\"${NFS_SERVER}\" \
  --set nfs.path=\"${NFS_PATH}\" \
  --set image.repository=\"${img_repo}\" \
  --set image.tag=\"${img_tag}\" \
  --set image.pullPolicy=IfNotPresent"

log_info "nfs-provisioner 部署完成"


