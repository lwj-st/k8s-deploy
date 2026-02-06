#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root

ensure_kubeconfig_for_user() {
  # 初始化后自动配置 kubectl：
  # - 优先使用 /etc/kubernetes/super-admin.conf（权限更全，避免部分场景 Forbidden）
  # - 幂等：如已存在 ~/.kube/config 则先备份
  local user_home="$1"
  local owner_uid="$2"
  local owner_gid="$3"

  local src="/etc/kubernetes/admin.conf"
  if [ -f /etc/kubernetes/super-admin.conf ]; then
    src="/etc/kubernetes/super-admin.conf"
  fi

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

if [ -f /etc/kubernetes/super-admin.conf ]; then
  export KUBECONFIG=/etc/kubernetes/super-admin.conf
else
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

# 单节点：去污点（兼容 control-plane/master）
node_name="$(hostname | tr 'A-Z' 'a-z')"
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


