#!/usr/bin/env bash
################################################################################
## Filename:    13-Install-k8s-packages.sh
## Description: 按当前 OS 安装 Kubernetes 离线 deb/rpm 包
## Usage:
##   bash 13-Install-k8s-packages.sh
## Artifacts:
##   - os.dir.kubernetes.<os_id>.<os_version>
## Env:
##   - ALLOW_ONLINE: yes 时允许部分在线兜底
################################################################################
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
  local -a apt_args=(install -y)
  if [ "${ALLOW_ONLINE:-no}" != "yes" ]; then
    apt_args+=(--no-download)
  fi

  log_info "执行命令: apt-get ${apt_args[*]} \"${dir}\"/*.deb"
  if apt-get "${apt_args[@]}" "${pkgs[@]}"; then
    return 0
  fi

  # APT 在目标机已有半配置/版本冲突时，可能在解包前直接拒绝整批本地包。
  # 先统一解包，再配置全部包，避免离线安装卡在 resolver 阶段。
  log_warn "APT 安装失败，回退到 dpkg --unpack 后统一配置"
  dpkg --unpack "${pkgs[@]}" || \
    log_warn "部分 deb 暂未配置，继续执行 dpkg --configure -a"
  if dpkg --configure -a; then
    return 0
  fi

  if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
    log_warn "dpkg 配置仍未完成，ALLOW_ONLINE=yes，尝试在线修复依赖"
    log_command "apt-get -y -f install"
  else
    die "严格离线 dpkg 配置失败，请补齐依赖 .deb 后重试"
  fi
}

install_offline_rpms() {
  local dir="$1"
  [ -d "$dir" ] || die "离线 rpm 目录不存在: $dir"
  shopt -s nullglob
  local pkgs=("$dir"/*.rpm)
  shopt -u nullglob
  [ ${#pkgs[@]} -gt 0 ] || die "离线 rpm 目录为空: $dir"
  if have dnf; then
    if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      log_command "dnf -y install --allowerasing \"$dir\"/*.rpm"
    else
      log_command "dnf -y install --disablerepo='*' --setopt=install_weak_deps=False --allowerasing \"$dir\"/*.rpm"
    fi
  else
    if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      log_command "yum -y localinstall \"$dir\"/*.rpm"
    else
      log_command "yum -y localinstall --disablerepo='*' \"$dir\"/*.rpm"
    fi
  fi
}

if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
  log_warn "ALLOW_ONLINE=yes：允许在线安装（若你希望严格离线，请把 ALLOW_ONLINE 设为 no）"
fi

case "${OS_ID}" in
  ubuntu)
    deb_dir="$(artifact_get_os_kubernetes_dir "${OS_ID}" "${TARGET_OS_VERSION}")"
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
  centos|rocky|openeuler|kylin)
    rpm_dir="$(artifact_get_os_kubernetes_dir "${OS_ID}" "${TARGET_OS_VERSION}")"

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
    die "不支持的 OS_ID=${OS_ID}，请补充 manifests/artifacts.yaml 中的 OS 离线包目录并扩展脚本"
    ;;
esac

if have systemctl; then
  log_command "systemctl enable kubelet"
  log_command "systemctl restart kubelet || true"
fi

log_info "k8s 包安装完成"
