#!/usr/bin/env bash
################################################################################
## Filename:    10-Env.sh
## Description: 宿主机预置（防火墙/swap/modules/sysctl/iptables KUBE+CALI 链）
## Notes:
##   - 只做脚本需要的宿主机变更；默认不修改 /etc/fstab（避免误伤挂载）
##   - iptables 默认只清理 KUBE-*/CALI-* 链（不 flush 全表）
################################################################################
set -euo pipefail

# ---------------------------------------------------------------------------- #
# Global variables / init
# ---------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

SYS_MODULES_FILE="/etc/modules-load.d/k8s-deploy.conf"
SYSCTL_FILE="/etc/sysctl.d/99-k8s-deploy-k8s.conf"

################################################################################
# Function: disable_firewall
# Description: 记录并关闭 ufw/firewalld（按你要求：可强改）
################################################################################
disable_firewall() {
  if ! have systemctl; then
    return 0
  fi
  if systemctl is-active ufw >/dev/null 2>&1; then record_kv "UFW_WAS_ACTIVE" "yes"; else record_kv "UFW_WAS_ACTIVE" "no"; fi
  log_command "systemctl stop ufw || true"
  log_command "systemctl disable ufw || true"

  if systemctl is-active firewalld >/dev/null 2>&1; then record_kv "FIREWALLD_WAS_ACTIVE" "yes"; else record_kv "FIREWALLD_WAS_ACTIVE" "no"; fi
  log_command "systemctl stop firewalld || true"
  log_command "systemctl disable firewalld || true"
}

################################################################################
# Function: configure_selinux
# Description: 若存在 SELinux，则设为 permissive（幂等）
################################################################################
configure_selinux() {
  if ! have getenforce; then
    return 0
  fi
  local cur
  cur="$(getenforce || true)"
  record_kv "SELINUX_WAS" "${cur}"
  if [ "${cur}" = "Enforcing" ]; then
    log_command "setenforce 0 || true"
  fi
  if [ -f /etc/selinux/config ]; then
    backup_if_exists /etc/selinux/config
    cat >/etc/selinux/config <<'EOF'
SELINUX=permissive
SELINUXTYPE=targeted
EOF
  fi
}

################################################################################
# Function: disable_swap
# Description: 关闭运行时 swap（默认不改 /etc/fstab）
################################################################################
disable_swap() {
  log_command "swapoff -a || true"
  log_warn "已执行 swapoff。为避免误改宿主机挂载配置，本脚本默认不修改 /etc/fstab；如需永久禁用 swap，请自行处理。"
}

################################################################################
# Function: configure_kernel_modules
# Description: 写入并加载 K8s 常用内核模块（overlay/br_netfilter/nf_conntrack）
################################################################################
configure_kernel_modules() {
  backup_if_exists "${SYS_MODULES_FILE}"
  cat >"${SYS_MODULES_FILE}" <<'EOF'
overlay
br_netfilter
nf_conntrack
EOF
  log_command "modprobe overlay || true"
  log_command "modprobe br_netfilter || true"
  log_command "modprobe nf_conntrack || true"
}

################################################################################
# Function: configure_sysctl
# Description: 写入 sysctl 配置并应用（容错：sysctl --system 失败不致命）
################################################################################
configure_sysctl() {
  backup_if_exists "${SYSCTL_FILE}"
  cat >"${SYSCTL_FILE}" <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
EOF
  log_command "sysctl --system || true"
}

################################################################################
# Function: cleanup_iptables
# Description: 默认只清理 KUBE-*/CALI-* 链（不 flush 全表）
################################################################################
cleanup_iptables() {
  cleanup_kube_iptables iptables
  cleanup_kube_iptables ip6tables
}

################################################################################
# Function: main
# Description: 主逻辑
################################################################################
main() {
  init_framework
  require_root

  log_warn "将对宿主机做预置：关闭防火墙、关闭 swap、写入 sysctl/modules 配置、清理 KUBE/CALI iptables 链。"
  disable_firewall
  configure_selinux
  disable_swap
  configure_kernel_modules
  configure_sysctl
  cleanup_iptables
  log_info "Env 预置完成"
}

main "$@"


