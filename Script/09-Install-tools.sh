#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root

helm_tgz="$(artifact_get_path_by_name "base.helm.linux-amd64.tgz")"
helmfile_tgz="$(artifact_get_path_by_name "base.helmfile.linux-amd64.tgz")"

[ -f "${helm_tgz}" ] || die "缺少制品: ${helm_tgz}"
[ -f "${helmfile_tgz}" ] || die "缺少制品: ${helmfile_tgz}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if have helm; then
  backup_if_exists "$(command -v helm)"
fi
if have helmfile; then
  backup_if_exists "$(command -v helmfile)"
fi

log_command "tar -C \"$tmp\" -xzf \"${helm_tgz}\""
if [ -f "$tmp/linux-amd64/helm" ]; then
  log_command "install -m 0755 \"$tmp/linux-amd64/helm\" /usr/local/bin/helm"
else
  die "未找到 helm 二进制于解压目录"
fi

log_command "tar -C \"$tmp\" -xzf \"${helmfile_tgz}\""
if [ -f "$tmp/helmfile" ]; then
  log_command "install -m 0755 \"$tmp/helmfile\" /usr/local/bin/helmfile"
else
  die "未找到 helmfile 二进制于解压目录"
fi

log_info "工具安装完成：helm/helmfile"


