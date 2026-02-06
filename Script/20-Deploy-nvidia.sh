#!/usr/bin/env bash
################################################################################
## Filename:    20-Deploy-nvidia.sh
## Description: 离线部署 NVIDIA GPU 相关组件
## Notes:
##   - 仅做“装包 + 配置 containerd runtime + 部署 device plugin”
##   - 不负责安装驱动本身（nvidia-smi / 内核驱动需提前就绪）
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

################################################################################
# Function: load_manifest
# Description: 加载 manifests/artifacts.yaml，准备后续使用
################################################################################
load_manifest() {
  manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  [ -f "${manifest}" ] || die "未找到制品清单: ${manifest}"
}

################################################################################
# Function: collect_nvidia_debs
# Description: 从清单中收集所有 nvidia deb 路径
################################################################################
collect_nvidia_debs() {
  deb_list=()
  while IFS=$'\x1f' read -r module type name path url md5 desc os_id; do
    [ "${module}" = "nvidia" ] || continue
    [ "${type}" = "file" ] || continue
    [[ "${path}" == *.deb ]] || continue
    deb_list+=("${path}")
  done < <(parse_artifacts_yaml "${manifest}")

  [ "${#deb_list[@]}" -gt 0 ] || die "制品清单中未找到 nvidia deb（module=nvidia,type=file,*.deb）"

  local f
  for f in "${deb_list[@]}"; do
    [ -f "$f" ] || die "缺少制品: $f"
  done
}

################################################################################
# Function: install_nvidia_toolkit
# Description: 离线安装 NVIDIA container toolkit 相关 deb
################################################################################
install_nvidia_toolkit() {
  if ! have dpkg; then
    die "当前系统不支持 dpkg，nvidia 离线包请准备 rpm 并扩展脚本"
  fi

  log_info "安装 NVIDIA container toolkit（离线 deb）..."
  log_command "dpkg -i ${deb_list[*]}"

  have nvidia-ctk || die "未找到 nvidia-ctk（deb 安装失败或依赖缺失）"
}

################################################################################
# Function: configure_containerd_runtime
# Description: 使用 nvidia-ctk 为 containerd 配置 NVIDIA runtime 并重启
################################################################################
configure_containerd_runtime() {
  log_info "配置 nvidia runtime for containerd..."
  log_command "nvidia-ctk runtime configure --runtime=containerd"
  log_command "systemctl restart containerd"
}

################################################################################
# Function: deploy_nvidia_device_plugin
# Description: 打 label（如有 GPU）并部署 device plugin DaemonSet
################################################################################
deploy_nvidia_device_plugin() {
  local yaml
  yaml="$(artifact_get_path_by_name "nvidia.manifest.device-plugin.v0.17.2")"
  [ -f "${yaml}" ] || die "缺少制品: ${yaml}"

  log_info "部署 NVIDIA device plugin..."
  # 该 YAML 自带 nodeSelector: nvidia.com/gpu.present=true
  # 为避免 DS desired=0（节点没标签），在检测到 GPU 的节点上自动打 label
  if have nvidia-smi || [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ]; then
    node_name="$(hostname | tr 'A-Z' 'a-z')"
    if kubectl get node "${node_name}" >/dev/null 2>&1; then
      log_command "kubectl label node \"${node_name}\" nvidia.com/gpu.present=true --overwrite"
    else
      log_warn "未能用 hostname 匹配到 node（${node_name}），跳过自动打 GPU label；你可手动执行：kubectl label node <nodeName> nvidia.com/gpu.present=true --overwrite"
    fi
  else
    log_warn "未检测到 GPU 设备（nvidia-smi 或 /dev/nvidia*），仅部署 device plugin，不自动打 label"
  fi

  log_command "kubectl apply -f \"${yaml}\""
}

################################################################################
# Function: main
# Description: 主流程
################################################################################
main() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  load_manifest
  collect_nvidia_debs
  install_nvidia_toolkit
  configure_containerd_runtime
  deploy_nvidia_device_plugin

  log_info "nvidia 部署完成"
}

main "$@"

