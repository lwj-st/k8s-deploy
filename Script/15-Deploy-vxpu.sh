#!/usr/bin/env bash
################################################################################
## Filename:    15-Deploy-vxpu.sh
## Description: 部署/卸载昆仑芯（Kunlunxin）vxpu-device-plugin
## Usage:
##   bash 15-Deploy-vxpu.sh [install|uninstall|status]
## Artifacts:
##   - vxpu.manifest.device-plugin.v1.0.0
## Images:
##   - vxpu.image.device-plugin.v1.0.0
## Env:
##   - VXPU_PLUGIN_YAML: 可选，覆盖 device-plugin YAML 路径
##   - VXPU_ACTION: install|uninstall|status，默认 install；也可作为第 1 个位置参数
##   - VXPU_AUTO_LABEL_NODE: 默认 true；给当前节点打 xpu=on
##   - VXPU_NODE_NAME: 可选，覆盖当前节点名
## Notes:
##   - 复用 k8s-deploy 的 framework.sh 日志与错误处理
##   - 默认从 manifests/artifacts.yaml 读取 vxpu device-plugin YAML
##   - 镜像 tar 需事先放到 download/vxpu/vxpu-device-plugin-v1.0.0.tar（tag: projecthami/vxpu-device-plugin:v1.0.0）
##   - 不负责安装驱动 / XRE / xpu-container-toolkit（xpu-smi、/usr/local/xpu 需提前就绪）
##   - DaemonSet 使用 nodeSelector: xpu=on；未打标签则 Desired=0
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

VXPU_PLUGIN_YAML="${VXPU_PLUGIN_YAML:-}"
VXPU_ACTION="${VXPU_ACTION:-install}"          # install|uninstall|status
VXPU_AUTO_LABEL_NODE="${VXPU_AUTO_LABEL_NODE:-true}"
VXPU_NODE_NAME="${VXPU_NODE_NAME:-}"

resolve_vxpu_manifest() {
  if [ -n "${VXPU_PLUGIN_YAML}" ]; then
    printf '%s\n' "${VXPU_PLUGIN_YAML}"
    return 0
  fi
  artifact_get_path_by_name "vxpu.manifest.device-plugin.v1.0.0"
}

resolve_node_name() {
  if [ -n "${VXPU_NODE_NAME}" ]; then
    normalize_k8s_node_name "${VXPU_NODE_NAME}"
    return 0
  fi

  get_local_k8s_node_name
}

detect_vxpu_device() {
  if have xpu-smi; then
    return 0
  fi
  if have xpumcli; then
    return 0
  fi
  if [ -d /usr/local/xpu ]; then
    return 0
  fi
  if [ -e /dev/xpuctl ] || [ -e /dev/xpu0 ]; then
    return 0
  fi
  shopt -s nullglob
  local devs=(/dev/xpu*)
  shopt -u nullglob
  [ "${#devs[@]}" -gt 0 ]
}

label_current_node_if_needed() {
  [ "${VXPU_AUTO_LABEL_NODE}" = "true" ] || {
    log_info "已设置 VXPU_AUTO_LABEL_NODE=${VXPU_AUTO_LABEL_NODE}，跳过自动打标签"
    return 0
  }

  if ! detect_vxpu_device; then
    log_warn "未检测到昆仑芯设备（xpu-smi / xpumcli / /usr/local/xpu / /dev/xpu*），仍按当前节点打 xpu=on"
  fi

  local node=""
  node="$(resolve_node_name)"
  kubectl get node "${node}" >/dev/null 2>&1 || die "无法找到当前节点对象：${node}"
  log_info "为当前节点自动打昆仑芯标签：node=${node} xpu=on"
  log_command "kubectl label node \"${node}\" xpu=on --overwrite"
}

install_vxpu_device_plugin() {
  local yaml=""
  yaml="$(resolve_vxpu_manifest)"
  [ -f "${yaml}" ] || die "缺少昆仑芯 device-plugin 清单: ${yaml}"

  log_info "导入昆仑芯 vxpu-device-plugin 镜像..."
  import_image_artifact "vxpu.image.device-plugin.v1.0.0"

  label_current_node_if_needed
  log_info "部署昆仑芯 vxpu-device-plugin（yaml=${yaml}）..."
  log_command "kubectl apply -f \"${yaml}\""
}

uninstall_vxpu_device_plugin() {
  local yaml=""
  yaml="$(resolve_vxpu_manifest)"
  [ -f "${yaml}" ] || die "缺少昆仑芯 device-plugin 清单: ${yaml}"

  log_info "卸载昆仑芯 vxpu-device-plugin（yaml=${yaml}）..."
  log_command "kubectl delete -f \"${yaml}\" --ignore-not-found=true"
}

status_vxpu_device_plugin() {
  log_info "查看昆仑芯 vxpu-device-plugin 状态..."
  log_command "kubectl get ds -n kube-system vxpu-device-plugin -o wide || true"
  log_command "kubectl get pods -n kube-system -l app.kubernetes.io/component=vxpu-device-plugin -o wide || true"
  log_command "kubectl get nodes -o custom-columns=NAME:.metadata.name,XPU_LABEL:.metadata.labels.xpu,VXPU:.status.allocatable.kunlunxin\\.com/vxpu,VXPU_MEM:.status.allocatable.kunlunxin\\.com/vxpu-memory --no-headers || true"
}

validate_inputs() {
  case "${VXPU_ACTION}" in
    install|uninstall|status) ;;
    *) die "VXPU_ACTION 仅支持 install|uninstall|status，当前=${VXPU_ACTION}" ;;
  esac
}

main() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  if [ "${#}" -ge 1 ]; then
    VXPU_ACTION="$1"
  fi

  validate_inputs

  if [ -n "${VXPU_PLUGIN_YAML}" ]; then
    [ -f "${VXPU_PLUGIN_YAML}" ] || die "VXPU_PLUGIN_YAML 不存在: ${VXPU_PLUGIN_YAML}"
    log_info "VXPU_PLUGIN_YAML=${VXPU_PLUGIN_YAML}"
  else
    log_info "vxpu 清单路径来源: manifests/artifacts.yaml"
  fi
  log_info "VXPU_ACTION=${VXPU_ACTION}"

  case "${VXPU_ACTION}" in
    install) install_vxpu_device_plugin ;;
    uninstall) uninstall_vxpu_device_plugin ;;
    status) status_vxpu_device_plugin ;;
    *) die "不支持的 VXPU_ACTION=${VXPU_ACTION}" ;;
  esac

  log_info "vxpu device-plugin ${VXPU_ACTION} 完成"
}

main "$@"
