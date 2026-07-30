#!/usr/bin/env bash
################################################################################
## Filename:    09-Install-tools.sh
## Description: 安装 Helm / Helmfile 等基础工具
## Usage:
##   bash 09-Install-tools.sh
## Artifacts:
##   - base.helm.linux-<TARGET_ARCH>.tgz
##   - base.helmfile.linux-<TARGET_ARCH>.tgz
## Env:
##   - TARGET_ARCH: amd64/arm64，由 01-Cluster-host.sh 生成；未设置时按当前机器架构识别
## Notes:
##   - 仅使用离线 tar 包安装，不做在线下载
##   - 重复执行会先备份已有二进制，再覆盖安装
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

################################################################################
# Function: init_env
# Description: 初始化环境并解析制品路径
################################################################################
init_env() {
  init_framework
  require_root

  HELM_PLATFORM="linux-${TARGET_ARCH}"
  HELM_TGZ="$(artifact_get_path_by_name "base.helm.${HELM_PLATFORM}.tgz")"
  HELMFILE_TGZ="$(artifact_get_path_by_name "base.helmfile.${HELM_PLATFORM}.tgz")"

  [ -f "${HELM_TGZ}" ] || die "缺少制品: ${HELM_TGZ}"
  [ -f "${HELMFILE_TGZ}" ] || die "缺少制品: ${HELMFILE_TGZ}"
}

################################################################################
# Function: backup_existing_tools
# Description: 若已存在 helm/helmfile，则先备份
################################################################################
backup_existing_tools() {
  if have helm; then
    backup_if_exists "$(command -v helm)"
  fi
  if have helmfile; then
    backup_if_exists "$(command -v helmfile)"
  fi
}

################################################################################
# Function: install_helm
# Description: 从 tar 包中安装 helm
################################################################################
install_helm() {
  local tmp_dir="$1"
  log_command "tar -C \"${tmp_dir}\" -xzf \"${HELM_TGZ}\""
  if [ -f "${tmp_dir}/${HELM_PLATFORM}/helm" ]; then
    log_command "install -m 0755 \"${tmp_dir}/${HELM_PLATFORM}/helm\" /usr/local/bin/helm"
  else
    die "未找到 helm 二进制于解压目录"
  fi
}

################################################################################
# Function: install_helmfile
# Description: 从 tar 包中安装 helmfile
################################################################################
install_helmfile() {
  local tmp_dir="$1"
  log_command "tar -C \"${tmp_dir}\" -xzf \"${HELMFILE_TGZ}\""
  if [ -f "${tmp_dir}/helmfile" ]; then
    log_command "install -m 0755 \"${tmp_dir}/helmfile\" /usr/local/bin/helmfile"
  else
    die "未找到 helmfile 二进制于解压目录"
  fi
}

################################################################################
# Function: main
# Description: 主流程
################################################################################
main() {
  init_env

  # 使用全局变量，否则 EXIT trap 在脚本顶层执行时无法访问 local 变量
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT

  backup_existing_tools
  install_helm "${tmp}"
  install_helmfile "${tmp}"

  log_info "工具安装完成：helm/helmfile"
}

main "$@"
