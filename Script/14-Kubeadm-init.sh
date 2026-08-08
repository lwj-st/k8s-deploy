#!/usr/bin/env bash
################################################################################
## Filename:    14-Kubeadm-init.sh
## Description: 使用 kubeadm 初始化 Kubernetes 控制平面
## Usage:
##   bash 14-Kubeadm-init.sh
## Images:
##   - k8s.image.kube-apiserver.v1.31.11
##   - k8s.image.kube-controller-manager.v1.31.11
##   - k8s.image.kube-scheduler.v1.31.11
##   - k8s.image.kube-proxy.v1.31.11
##   - k8s.image.coredns.v1.11.3
##   - k8s.image.pause.3.10
##   - k8s.image.etcd.3.5.15-0
################################################################################
set -euo pipefail

# kubeadm 使用本地已导入镜像初始化，避免离线环境或本机 API 请求误走代理。
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
unset all_proxy ALL_PROXY
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root

ensure_kubeconfig_for_user() {
  # 初始化后自动配置 kubectl：使用 admin.conf，与常见集群 context 名 kubernetes-admin@kubernetes 保持一致
  # 幂等：如已存在 ~/.kube/config 则先备份
  local user_home="$1"
  local owner_uid="$2"
  local owner_gid="$3"

  local src="/etc/kubernetes/admin.conf"

  local kube_dir="${user_home}/.kube"
  local kube_cfg="${kube_dir}/config"

  mkdir -p "${kube_dir}"
  if [ -e "${kube_cfg}" ]; then
    backup_if_exists "${kube_cfg}"
  fi
  cp -f "${src}" "${kube_cfg}"
  chown "${owner_uid}:${owner_gid}" "${kube_cfg}" || true
  chmod 600 "${kube_cfg}" || true
  log_info "已配置 kubectl kubeconfig: ${kube_cfg} (source=${src})"
}

if [ -f /etc/kubernetes/admin.conf ] && have ss && ss -lntp 2>/dev/null | grep -q ':6443'; then
  log_info "检测到集群已初始化（admin.conf 存在且 6443 监听），跳过 kubeadm init"
  # 即便跳过 init，也尽量确保 kubeconfig 已配置
  ensure_kubeconfig_for_user "/root" "0" "0" || true
  exit 0
fi

have kubeadm || die "缺少 kubeadm（请先执行 13-Install-k8s-packages.sh）"
have kubelet || die "缺少 kubelet（请先执行 13-Install-k8s-packages.sh）"
node_name="$(get_local_k8s_node_name)"
log_info "当前 Kubernetes 节点名: ${node_name}"

log_info "导入 kubeadm init 所需 Kubernetes 镜像..."
import_image_artifacts \
  "k8s.image.kube-apiserver.v1.31.11" \
  "k8s.image.kube-controller-manager.v1.31.11" \
  "k8s.image.kube-scheduler.v1.31.11" \
  "k8s.image.kube-proxy.v1.31.11" \
  "k8s.image.coredns.v1.11.3" \
  "k8s.image.pause.3.10" \
  "k8s.image.etcd.3.5.15-0"

mkdir -p /etc/kubernetes

cfg="/etc/kubernetes/kubeadm-config.yaml"
backup_if_exists "${cfg}"

cat >"${cfg}" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${API_ADVERTISE_ADDRESS}
  bindPort: 6443
nodeRegistration:
  name: ${node_name}
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
imageRepository: ${IMAGE_REPOSITORY}
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
EOF

log_info "开始 kubeadm init ..."
log_command "kubeadm init --config \"${cfg}\""

if [ ! -f /etc/kubernetes/admin.conf ]; then
  die "kubeadm init 完成但未生成 /etc/kubernetes/admin.conf"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

# 当前控制节点去污点（兼容 control-plane/master）
kubectl taint nodes "${node_name}" node-role.kubernetes.io/control-plane- --overwrite 2>/dev/null || true
kubectl taint nodes "${node_name}" node-role.kubernetes.io/master- --overwrite 2>/dev/null || true

log_info "kubeadm init 完成"

# 自动写入 kubeconfig（root + sudo 的原始用户）
ensure_kubeconfig_for_user "/root" "0" "0"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  sudo_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  sudo_uid="$(id -u "${SUDO_USER}" 2>/dev/null || true)"
  sudo_gid="$(id -g "${SUDO_USER}" 2>/dev/null || true)"
  if [ -n "${sudo_home}" ] && [ -d "${sudo_home}" ] && [ -n "${sudo_uid}" ] && [ -n "${sudo_gid}" ]; then
    ensure_kubeconfig_for_user "${sudo_home}" "${sudo_uid}" "${sudo_gid}" || true
  fi
fi
