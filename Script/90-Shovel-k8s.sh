#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root

log_info "清理 kubeadm 集群（kubeadm reset + 清理 KUBE/CALI 链 + 清理目录）"

# 1) 停 kubelet
if have systemctl; then
  log_command "systemctl stop kubelet 2>/dev/null || true"
fi

# 2) kubeadm reset（存在才执行）
if have kubeadm; then
  log_command "kubeadm reset -f || true"
else
  log_warn "未安装 kubeadm，跳过 kubeadm reset"
fi

# 3) 清理目录（kubeadm reset 不会完全清干净）
log_command "rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /var/lib/cni /run/flannel /etc/cni/net.d || true"
log_command "rm -rf /root/.kube 2>/dev/null || true"

# 4) 清理常见 CNI 网卡
if have ip; then
  for i in cni0 flannel.1 kube-ipvs0 tunl0; do
    log_command "ip link delete \"$i\" 2>/dev/null || true"
  done
  # calico 网卡（cali*）
  while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    log_command "ip link delete \"$dev\" 2>/dev/null || true"
  done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^cali' || true)
fi

# 5) iptables：默认只清 KUBE/CALI 链（不 flush 全表）
cleanup_kube_iptables iptables
cleanup_kube_iptables ip6tables

# 6) IPVS（如存在）
if have ipvsadm; then
  log_command "ipvsadm --clear || true"
fi

# 7) 重启 containerd（如果存在）
if have systemctl; then
  log_command "systemctl restart containerd 2>/dev/null || true"
fi

log_info "集群清理完成"


