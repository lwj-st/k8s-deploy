#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root
load_state

log_warn "开始清理：仅回滚 k8s-deploy 记录过的备份 + 移除 k8s-deploy 写入的独立配置文件。"

# 1) 清理 K8s 集群资源（不卸载软件包）
if [ -x "${SCRIPT_DIR}/90-Shovel-k8s.sh" ]; then
  bash "${SCRIPT_DIR}/90-Shovel-k8s.sh" || true
fi

# 2) 移除我们写入的独立文件
rm -f /etc/sysctl.d/99-k8s-deploy-k8s.conf 2>/dev/null || true
rm -f /etc/modules-load.d/k8s-deploy.conf 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true

# 3) 尝试恢复备份（按记录顺序逆序恢复：最后备份的优先）
if [ -f "${K8S_DEPLOY_BACKUPS_FILE}" ]; then
  tac "${K8S_DEPLOY_BACKUPS_FILE}" | while IFS=$'\t' read -r orig bak; do
    [ -n "${orig}" ] || continue
    [ -n "${bak}" ] || continue
    if [ -e "${bak}" ] && [ ! -e "${orig}" ]; then
      log_info "RESTORE: ${bak} -> ${orig}"
      mv -f "${bak}" "${orig}" || true
    fi
  done
else
  log_warn "未找到备份记录文件：${K8S_DEPLOY_BACKUPS_FILE}"
fi

# 4) 尝试恢复防火墙服务状态（仅当脚本曾记录为 active）
if have systemctl; then
  if [ "${UFW_WAS_ACTIVE:-no}" = "yes" ]; then
    systemctl enable ufw >/dev/null 2>&1 || true
    systemctl start ufw >/dev/null 2>&1 || true
  fi
  if [ "${FIREWALLD_WAS_ACTIVE:-no}" = "yes" ]; then
    systemctl enable firewalld >/dev/null 2>&1 || true
    systemctl start firewalld >/dev/null 2>&1 || true
  fi
fi

log_info "Cleanup 完成"


