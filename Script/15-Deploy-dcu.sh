#!/usr/bin/env bash
################################################################################
## Filename:    15-Deploy-dcu.sh
## Description: 部署/卸载 Hygon DCU device-plugin（mixed/mig/hami）
## Notes:
##   - 复用 k8s-deploy 的 framework.sh 日志与错误处理
##   - 默认从 /data/download/dcu 读取 YAML
##   - 可通过环境变量覆盖路径和行为
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

DCU_PLUGIN_DIR_DEFAULT="/data/download/dcu"
DCU_PLUGIN_DIR="${DCU_PLUGIN_DIR:-${DCU_PLUGIN_DIR_DEFAULT}}"

DCU_MODE="${DCU_MODE:-mixed}"                # mixed|mig|hami
DCU_ACTION="${DCU_ACTION:-install}"          # install|uninstall
DCU_AUTO_LABEL_NODE="${DCU_AUTO_LABEL_NODE:-true}"
DCU_NODE_NAME="${DCU_NODE_NAME:-}"

dcu_manifest_by_mode() {
  local mode="$1"
  case "${mode}" in
    mixed) printf '%s\n' "${DCU_PLUGIN_DIR}/k8s-dcu-plugin.yaml" ;;
    mig) printf '%s\n' "${DCU_PLUGIN_DIR}/k8s-dcu-plugin-mig.yaml" ;;
    hami) printf '%s\n' "${DCU_PLUGIN_DIR}/k8s-dcu-plugin-hami.yaml" ;;
    *) die "不支持的 DCU_MODE=${mode}，仅支持 mixed|mig|hami" ;;
  esac
}

resolve_node_name() {
  if [ -n "${DCU_NODE_NAME}" ]; then
    printf '%s\n' "${DCU_NODE_NAME}"
    return 0
  fi

  local n=""
  n="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  n="${n%%.*}"
  [ -n "${n}" ] || die "无法推断当前节点名，请设置 DCU_NODE_NAME"
  printf '%s\n' "${n}"
}

label_current_node_if_needed() {
  local mode="$1"
  [ "${DCU_AUTO_LABEL_NODE}" = "true" ] || {
    log_info "已设置 DCU_AUTO_LABEL_NODE=${DCU_AUTO_LABEL_NODE}，跳过自动打标签"
    return 0
  }

  local node=""
  node="$(resolve_node_name)"

  kubectl get node "${node}" >/dev/null 2>&1 || die "无法找到当前节点对象：${node}"
  log_info "为当前节点自动打 DCU 标签：node=${node} mode=${mode}"

  # 所有模式都要求 hygon.com/dcu=true
  log_command "kubectl label node \"${node}\" hygon.com/dcu=true --overwrite"

  case "${mode}" in
    mixed)
      # mixed DaemonSet 通过 affinity 过滤 dcu-mode!=mig 且 dcu!=on
      log_command "kubectl label node \"${node}\" dcu-mode- dcu-"
      ;;
    mig)
      log_command "kubectl label node \"${node}\" dcu-mode=mig --overwrite"
      log_command "kubectl label node \"${node}\" dcu-"
      ;;
    hami)
      log_command "kubectl label node \"${node}\" dcu=on --overwrite"
      ;;
    *)
      die "不支持的 DCU_MODE=${mode}"
      ;;
  esac
}

install_dcu_device_plugin() {
  local mode="$1"
  local yaml=""
  yaml="$(dcu_manifest_by_mode "${mode}")"
  [ -f "${yaml}" ] || die "缺少 DCU device-plugin 清单: ${yaml}"

  label_current_node_if_needed "${mode}"
  log_info "部署 DCU device-plugin（mode=${mode}）..."
  log_command "kubectl apply -f \"${yaml}\""
}

uninstall_dcu_device_plugin() {
  local mode="$1"
  local yaml=""
  yaml="$(dcu_manifest_by_mode "${mode}")"
  [ -f "${yaml}" ] || die "缺少 DCU device-plugin 清单: ${yaml}"

  log_info "卸载 DCU device-plugin（mode=${mode}）..."
  log_command "kubectl delete -f \"${yaml}\" --ignore-not-found=true"
}

validate_inputs() {
  case "${DCU_MODE}" in
    mixed|mig|hami) ;;
    *) die "DCU_MODE 仅支持 mixed|mig|hami，当前=${DCU_MODE}" ;;
  esac

  case "${DCU_ACTION}" in
    install|uninstall) ;;
    *) die "DCU_ACTION 仅支持 install|uninstall，当前=${DCU_ACTION}" ;;
  esac
}

main() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  validate_inputs

  [ -d "${DCU_PLUGIN_DIR}" ] || die "DCU_PLUGIN_DIR 不存在: ${DCU_PLUGIN_DIR}"
  log_info "DCU_PLUGIN_DIR=${DCU_PLUGIN_DIR}"
  log_info "DCU_MODE=${DCU_MODE} DCU_ACTION=${DCU_ACTION}"

  case "${DCU_ACTION}" in
    install) install_dcu_device_plugin "${DCU_MODE}" ;;
    uninstall) uninstall_dcu_device_plugin "${DCU_MODE}" ;;
    *) die "不支持的 DCU_ACTION=${DCU_ACTION}" ;;
  esac

  log_info "dcu device-plugin ${DCU_ACTION} 完成（mode=${DCU_MODE}）"
}

main "$@"
