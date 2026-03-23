#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root

install_offline_debs() {
  local dir="$1"
  [ -d "$dir" ] || die "离线 deb 目录不存在: $dir"
  shopt -s nullglob
  local pkgs=("$dir"/*.deb)
  shopt -u nullglob
  [ ${#pkgs[@]} -gt 0 ] || die "离线 deb 目录为空: $dir"
  log_command "dpkg -i \"$dir\"/*.deb"
}

install_offline_rpms() {
  local dir="$1"
  [ -d "$dir" ] || die "离线 rpm 目录不存在: $dir"
  shopt -s nullglob
  local pkgs=("$dir"/*.rpm)
  shopt -u nullglob
  [ ${#pkgs[@]} -gt 0 ] || die "离线 rpm 目录为空: $dir"
  if have dnf; then
    log_command "dnf -y install \"$dir\"/*.rpm"
  else
    log_command "yum -y localinstall \"$dir\"/*.rpm"
  fi
}

if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
  log_warn "ALLOW_ONLINE=yes：允许在线安装（若你希望严格离线，请把 ALLOW_ONLINE 设为 no）"
fi

case "${OS_ID}" in
  ubuntu|debian)
    deb_dir="$(artifact_get_os_kubernetes_dir "ubuntu")"
    if [ -d "${deb_dir}" ]; then
      install_offline_debs "${deb_dir}"
    elif [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      log_command "apt-get update"
      # 兼容已被 hold 的包（重复执行/系统预装场景）
      log_command "apt-get install -y --allow-change-held-packages kubelet kubeadm kubectl"
      log_command "apt-mark hold kubelet kubeadm kubectl || true"
    else
      die "缺少离线包目录：${deb_dir}（并且 ALLOW_ONLINE=no）"
    fi
    ;;
  centos|rocky|openeuler|kylin*)
    # 统一走 rpm 目录（从清单中按 os_id 取）
    rpm_dir=""
    if [ "${OS_ID}" = "openeuler" ]; then
      rpm_dir="$(artifact_get_os_kubernetes_dir "openeuler")"
    elif [[ "${OS_ID}" == kylin* ]]; then
      rpm_dir="$(artifact_get_os_kubernetes_dir "kylin")"
    elif [ "${OS_ID}" = "rocky" ]; then
      rpm_dir="$(artifact_get_os_kubernetes_dir "rocky")"
    else
      rpm_dir="$(artifact_get_os_kubernetes_dir "centos")"
    fi

    if [ -d "${rpm_dir}" ]; then
      install_offline_rpms "${rpm_dir}"
    elif [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      # 在线安装包名可能因发行版差异而不同，这里只给出兜底提示
      die "在线安装 rpm 系发行版尚未内置（请先准备离线 rpm：${rpm_dir}）"
    else
      die "缺少离线包目录：${rpm_dir}（并且 ALLOW_ONLINE=no）"
    fi
    ;;
  *)
    die "不支持的 OS_ID=${OS_ID}，请完善 /data/download/packages/kubernetes/<os> 离线包目录并扩展脚本"
    ;;
esac

if have systemctl; then
  log_command "systemctl enable kubelet"
  log_command "systemctl restart kubelet || true"
fi

log_info "k8s 包安装完成"


