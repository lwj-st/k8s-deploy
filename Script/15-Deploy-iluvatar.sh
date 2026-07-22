#!/usr/bin/env bash
################################################################################
## Filename:    15-Deploy-iluvatar.sh
## Description: 部署/卸载 天数智芯（Iluvatar CoreX）ix-device-plugin
## Usage:
##   bash 15-Deploy-iluvatar.sh [install|uninstall|status]
## Artifacts:
##   - iluvatar.image.device-plugin.v4.4.0
## Images:
##   - iluvatar.image.device-plugin.v4.4.0
## Env:
##   - ILUVATAR_PLUGIN_YAML: 可选，覆盖 device-plugin YAML 路径
##   - ILUVATAR_ACTION: install|uninstall|status，默认 install；也可作为第 1 个位置参数
##   - ILUVATAR_AUTO_LABEL_NODE: 默认 true；检测到设备时给当前节点打 iluvatar.com/gpu.present=true
##   - ILUVATAR_NODE_NAME: 可选，覆盖当前节点名
## Notes:
##   - 复用 k8s-deploy 的 framework.sh 日志与错误处理
##   - 默认直接 apply config/ix-device-plugin-v4.4.0.yaml（本地定制，不走 artifacts 下载）
##   - 镜像固定为 registry.iluvatar.com.cn:10443/k8s/ix-device-plugin:4.4.0，imagePullPolicy=Never
##   - 不负责安装驱动本身（ixsmi / /sys/bus/pci/drivers/iluvatar 需提前就绪）
##   - 默认 YAML 无 nodeSelector，会在所有节点调度；自动 label 便于后续筛选 GPU 节点
##   - 节点名统一走 get_local_k8s_node_name / normalize_k8s_node_name（小写）
##   - 暂不支持 Volcano 模式清单
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

K8S_DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ILUVATAR_DEFAULT_YAML="${K8S_DEPLOY_ROOT}/config/ix-device-plugin-v4.4.0.yaml"

ILUVATAR_PLUGIN_YAML="${ILUVATAR_PLUGIN_YAML:-}"
ILUVATAR_ACTION="${ILUVATAR_ACTION:-install}"      # install|uninstall|status
ILUVATAR_AUTO_LABEL_NODE="${ILUVATAR_AUTO_LABEL_NODE:-true}"
ILUVATAR_NODE_NAME="${ILUVATAR_NODE_NAME:-}"

resolve_iluvatar_manifest() {
  if [ -n "${ILUVATAR_PLUGIN_YAML}" ]; then
    printf '%s\n' "${ILUVATAR_PLUGIN_YAML}"
    return 0
  fi
  printf '%s\n' "${ILUVATAR_DEFAULT_YAML}"
}

resolve_node_name() {
  if [ -n "${ILUVATAR_NODE_NAME}" ]; then
    normalize_k8s_node_name "${ILUVATAR_NODE_NAME}"
    return 0
  fi

  get_local_k8s_node_name
}

detect_iluvatar_device() {
  if have ixsmi; then
    return 0
  fi
  if [ -d /sys/bus/pci/drivers/iluvatar ]; then
    return 0
  fi
  shopt -s nullglob
  local devs=(/dev/iluvatar*)
  shopt -u nullglob
  [ "${#devs[@]}" -gt 0 ]
}

label_current_node_if_needed() {
  [ "${ILUVATAR_AUTO_LABEL_NODE}" = "true" ] || {
    log_info "已设置 ILUVATAR_AUTO_LABEL_NODE=${ILUVATAR_AUTO_LABEL_NODE}，跳过自动打标签"
    return 0
  }

  if ! detect_iluvatar_device; then
    log_warn "未检测到天数设备（ixsmi / /sys/bus/pci/drivers/iluvatar / /dev/iluvatar*），跳过自动打 label"
    return 0
  fi

  local node=""
  node="$(resolve_node_name)"
  kubectl get node "${node}" >/dev/null 2>&1 || die "无法找到当前节点对象：${node}"
  log_info "为当前节点自动打天数标签：node=${node} iluvatar.com/gpu.present=true"
  log_command "kubectl label node \"${node}\" iluvatar.com/gpu.present=true --overwrite"
}

install_iluvatar_device_plugin() {
  local yaml=""
  yaml="$(resolve_iluvatar_manifest)"
  [ -f "${yaml}" ] || die "缺少 Iluvatar device-plugin 清单: ${yaml}"

  log_info "导入 Iluvatar device-plugin 镜像..."
  import_image_artifact "iluvatar.image.device-plugin.v4.4.0"

  label_current_node_if_needed
  log_info "部署 Iluvatar device-plugin（yaml=${yaml}）..."
  log_command "kubectl apply -f \"${yaml}\""
}

uninstall_iluvatar_device_plugin() {
  local yaml=""
  yaml="$(resolve_iluvatar_manifest)"
  [ -f "${yaml}" ] || die "缺少 Iluvatar device-plugin 清单: ${yaml}"

  log_info "卸载 Iluvatar device-plugin（yaml=${yaml}）..."
  log_command "kubectl delete -f \"${yaml}\" --ignore-not-found=true"
}

status_iluvatar_device_plugin() {
  log_info "查看 Iluvatar device-plugin 状态..."
  log_command "kubectl get ds -n kube-system iluvatar-device-plugin -o wide || true"
  log_command "kubectl get pods -n kube-system -l app.kubernetes.io/name=iluvatar-device-plugin -o wide || true"
  log_command "kubectl get nodes -o custom-columns=NAME:.metadata.name,ILUVATAR:.status.allocatable.iluvatar\\.com/gpu --no-headers || true"
}

validate_inputs() {
  case "${ILUVATAR_ACTION}" in
    install|uninstall|status) ;;
    *) die "ILUVATAR_ACTION 仅支持 install|uninstall|status，当前=${ILUVATAR_ACTION}" ;;
  esac
}

main() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  if [ "${#}" -ge 1 ]; then
    ILUVATAR_ACTION="$1"
  fi

  validate_inputs

  if [ -n "${ILUVATAR_PLUGIN_YAML}" ]; then
    [ -f "${ILUVATAR_PLUGIN_YAML}" ] || die "ILUVATAR_PLUGIN_YAML 不存在: ${ILUVATAR_PLUGIN_YAML}"
    log_info "ILUVATAR_PLUGIN_YAML=${ILUVATAR_PLUGIN_YAML}"
  else
    log_info "Iluvatar 清单: ${ILUVATAR_DEFAULT_YAML}"
  fi
  log_info "ILUVATAR_ACTION=${ILUVATAR_ACTION}"

  case "${ILUVATAR_ACTION}" in
    install) install_iluvatar_device_plugin ;;
    uninstall) uninstall_iluvatar_device_plugin ;;
    status) status_iluvatar_device_plugin ;;
    *) die "不支持的 ILUVATAR_ACTION=${ILUVATAR_ACTION}" ;;
  esac

  log_info "iluvatar device-plugin ${ILUVATAR_ACTION} 完成"
}

main "$@"
