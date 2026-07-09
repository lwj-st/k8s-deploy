#!/usr/bin/env bash
################################################################################
## Filename:    11-Install-containerd.sh
## Description: 安装/重装 containerd（离线制品）并修正关键配置（cgroup v2/runc.v2）
## Usage:
##   bash 11-Install-containerd.sh
## Notes:
##   - 幂等：发现已安装则 stop -> 备份 -> 重装
##   - 兼容 unit ExecStart=/usr/bin/containerd 与 /usr/local/bin/containerd 的差异
################################################################################
set -euo pipefail

# ---------------------------------------------------------------------------- #
# Global variables / init
# ---------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

containerd_tar=""
containerd_svc=""
runc_bin=""
cni_tgz=""
cfg_tpl=""

################################################################################
# Function: init_vars
# Description: 初始化制品路径变量
################################################################################
init_vars() {
  containerd_tar="$(artifact_get_path_by_name "containerd.tarball.1.7.4.linux-amd64")"
  containerd_svc="$(artifact_get_path_by_name "containerd.systemd.unit")"
  runc_bin="$(artifact_get_path_by_name "containerd.runc.binary.amd64")"
  cni_tgz="$(artifact_get_path_by_name "containerd.cni-plugins.tgz.linux-amd64.v1.7.1")"
  cfg_tpl="$(artifact_get_path_by_name "containerd.config.template.toml")"
}

################################################################################
# Function: require_artifacts
# Description: 校验离线制品存在
################################################################################
require_artifacts() {
  [ -f "${containerd_tar}" ] || die "缺少制品: ${containerd_tar}"
  [ -f "${containerd_svc}" ] || die "缺少制品: ${containerd_svc}"
  [ -f "${runc_bin}" ] || die "缺少制品: ${runc_bin}"
  [ -f "${cni_tgz}" ] || die "缺少制品: ${cni_tgz}"
  [ -f "${cfg_tpl}" ] || die "缺少制品: ${cfg_tpl}"
}

################################################################################
# Function: stop_containerd
# Description: 停止 containerd（如存在）
################################################################################
stop_containerd() {
  if have systemctl && systemctl list-unit-files | grep -q '^containerd\.service'; then
    log_command "systemctl stop containerd || true"
  fi
}

################################################################################
# Function: backup_existing
# Description: 若已安装 containerd，则按“停下 -> 备份 -> 重装”的要求备份
################################################################################
backup_existing() {
  if ! have containerd; then
    return 0
  fi
  log_warn "检测到 containerd 已存在，将备份并重装"
  backup_if_exists /etc/containerd
  for p in /usr/local/bin/containerd /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-shim /usr/local/bin/ctr /usr/bin/containerd /usr/bin/ctr; do
    [ -e "$p" ] && backup_if_exists "$p"
  done
  for p in /usr/local/sbin/runc /usr/bin/runc; do
    [ -e "$p" ] && backup_if_exists "$p"
  done
  [ -e /etc/systemd/system/containerd.service ] && backup_if_exists /etc/systemd/system/containerd.service
}

################################################################################
# Function: install_config
# Description: 安装 config.toml 并修正关键项（imports/runtime_type/platforms）
#              若设置 CONTAINERD_ROOT，则使用该路径为数据根目录（替代默认 /var/lib/containerd）
################################################################################
install_config() {
  log_command "mkdir -p /etc/containerd"
  log_command "cp -f \"${cfg_tpl}\" /etc/containerd/config.toml"
  log_command "sed -i -E 's@^imports = \\[\"/etc/containerd/config\\.toml\"\\]@imports = []@' /etc/containerd/config.toml || true"
  log_command "sed -i -E 's@runtime_type = \"io\\.containerd\\.runtime\\.v1\\.linux\"@runtime_type = \"io.containerd.runc.v2\"@g' /etc/containerd/config.toml || true"
  log_command "sed -i -E 's@platforms = \\[\"linux/arm64/v8\"\\]@platforms = [\"linux/amd64\"]@' /etc/containerd/config.toml || true"

  # 可选：自定义 containerd 数据根目录（镜像与元数据存储）
  if [ -n "${CONTAINERD_ROOT:-}" ]; then
    log_info "设置 containerd root = ${CONTAINERD_ROOT}"
    CONTAINERD_STATE="${CONTAINERD_STATE:-/run/containerd}"
    # 去掉已有 root/state 行，再在文件开头插入
    sed -i -E '/^root = /d;/^state = /d' /etc/containerd/config.toml
    { echo "root = \"${CONTAINERD_ROOT}\""; echo "state = \"${CONTAINERD_STATE}\""; cat /etc/containerd/config.toml; } > /etc/containerd/config.toml.tmp
    mv /etc/containerd/config.toml.tmp /etc/containerd/config.toml
    log_command "mkdir -p \"${CONTAINERD_ROOT}\""
    mkdir -p "${CONTAINERD_ROOT}"
  fi
}

################################################################################
# Function: install_binaries
# Description: 安装 containerd/runc/cni plugins
################################################################################
install_binaries() {
  log_command "tar -C /usr/local -xzf \"${containerd_tar}\""
  log_command "install -m 0755 \"${runc_bin}\" /usr/local/sbin/runc"
  log_command "mkdir -p /opt/cni/bin"
  log_command "tar -C /opt/cni/bin -xzf \"${cni_tgz}\""
}

################################################################################
# Function: install_service
# Description: 安装 systemd unit，并修正 ExecStart 路径不匹配的问题
################################################################################
install_service() {
  log_command "cp -f \"${containerd_svc}\" /etc/systemd/system/containerd.service"

  local exec_start
  exec_start="$(awk -F= '/^ExecStart=/{print $2; exit}' /etc/systemd/system/containerd.service | awk '{print $1}')"
  if [ -n "${exec_start}" ] && [ ! -x "${exec_start}" ] && [ -x /usr/local/bin/containerd ]; then
    log_warn "containerd unit ExecStart=${exec_start} 不存在，自动创建软链 -> /usr/local/bin/containerd"
    log_command "mkdir -p \"$(dirname "${exec_start}")\""
    log_command "ln -sf /usr/local/bin/containerd \"${exec_start}\""
  fi
}

################################################################################
# Function: enable_and_restart
# Description: daemon-reload + enable + restart
################################################################################
enable_and_restart() {
  log_command "systemctl daemon-reload"
  log_command "systemctl enable containerd"
  log_command "systemctl restart containerd"
}

################################################################################
# Function: main
# Description: 主逻辑
################################################################################
main() {
  init_framework
  require_root

  init_vars
  require_artifacts
  stop_containerd
  backup_existing
  install_config
  install_binaries
  install_service
  enable_and_restart

  log_info "containerd 安装完成"
}

main "$@"

