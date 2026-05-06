#!/usr/bin/env bash
################################################################################
## Filename:    15-Deploy-nvidia.sh
## Description: 离线部署 NVIDIA GPU 相关组件
## Notes:
##   - 仅做“装包 + 配置 containerd runtime + 部署 device plugin”
##   - 不负责安装驱动本身（nvidia-smi / 内核驱动需提前就绪）
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

################################################################################
# Function: collect_nvidia_pkgs
# Description: toolkit 基目录来自 artifacts.yaml（nvidia.dir.toolkit）；本脚本仅拼接 /<os>/ 再找包
#              可选 NVIDIA_TOOLKIT_DIR 覆盖为单一目录（非空则直接使用）
################################################################################
collect_nvidia_pkgs() {
  nvidia_pkgs=()

  local nvidia_pkg_dir=""
  local suffix
  local os_key=""

  if [ -n "${NVIDIA_TOOLKIT_DIR:-}" ]; then
    nvidia_pkg_dir="${NVIDIA_TOOLKIT_DIR}"
    case "${OS_ID}" in
      ubuntu|debian) suffix=".deb" ;;
      centos|rocky|openeuler|kylin*) suffix=".rpm" ;;
      *) die "不支持的 OS_ID=${OS_ID}（使用 NVIDIA_TOOLKIT_DIR 时仍需合法 OS 以选择 deb/rpm）" ;;
    esac
    log_info "使用 NVIDIA_TOOLKIT_DIR=${nvidia_pkg_dir}"
  else
    case "${OS_ID}" in
      ubuntu|debian)
        os_key="ubuntu"
        suffix=".deb"
        ;;
      centos)
        os_key="centos"
        suffix=".rpm"
        ;;
      rocky)
        os_key="rocky"
        suffix=".rpm"
        ;;
      openeuler)
        os_key="openeuler"
        suffix=".rpm"
        ;;
      kylin*)
        os_key="kylin"
        suffix=".rpm"
        ;;
      *)
        die "不支持的 OS_ID=${OS_ID}，请在 collect_nvidia_pkgs 中增加 os_id 映射或设置 NVIDIA_TOOLKIT_DIR"
        ;;
    esac
    nvidia_pkg_dir="$(artifact_get_nvidia_toolkit_base_dir)/${os_key}"
    log_info "NVIDIA toolkit 离线目录: ${nvidia_pkg_dir}（基目录来自清单 + os=${os_key}）"
  fi

  [ -d "${nvidia_pkg_dir}" ] || die "缺少 NVIDIA 离线包目录: ${nvidia_pkg_dir}"

  shopt -s nullglob
  local pat="${nvidia_pkg_dir}/*${suffix}"
  local files=(${pat})
  shopt -u nullglob

  [ "${#files[@]}" -gt 0 ] || die "目录为空，未找到 *${suffix}: ${nvidia_pkg_dir}"

  nvidia_pkgs=("${files[@]}")

  local f
  for f in "${nvidia_pkgs[@]}"; do
    [ -f "$f" ] || die "缺少制品: $f"
  done
}

################################################################################
# Function: install_nvidia_toolkit_deb
# Description: 离线安装 NVIDIA container toolkit 相关 deb
################################################################################
install_nvidia_toolkit_deb() {
  if ! have dpkg; then
    die "当前系统不支持 dpkg，请确认系统为 Debian/Ubuntu 或改用 rpm 流程"
  fi

  log_info "安装 NVIDIA container toolkit（离线 deb）..."
  log_command "dpkg -i ${nvidia_pkgs[*]}"

  have nvidia-ctk || die "未找到 nvidia-ctk（deb 安装失败或依赖缺失）"
}

################################################################################
# Function: install_nvidia_toolkit_rpm
# Description: 离线安装 NVIDIA container toolkit 相关 rpm
################################################################################
install_nvidia_toolkit_rpm() {
  # 这里只做最小假设：节点上至少有 rpm，优先使用 dnf/yum localinstall
  if ! have rpm; then
    die "当前系统未找到 rpm，无法安装 NVIDIA rpm 包"
  fi

  local installer=""
  if have dnf; then
    installer="dnf"
  elif have yum; then
    installer="yum"
  fi

  log_info "安装 NVIDIA container toolkit（离线 rpm）..."

  if [ -n "${installer}" ]; then
    # dnf/yum 会自动处理依赖关系，比裸 rpm -ivh 更安全
    log_command "${installer} -y localinstall ${nvidia_pkgs[*]}"
  else
    # 兜底：仅在没有 dnf/yum 的极简环境使用 rpm -ivh
    log_warn "未检测到 dnf/yum，改用 rpm -ivh 安装，可能需要你手动解决依赖"
    log_command "rpm -ivh ${nvidia_pkgs[*]}"
  fi

  have nvidia-ctk || die "未找到 nvidia-ctk（rpm 安装失败或依赖缺失）"
}

################################################################################
# Function: install_nvidia_toolkit
# Description: 根据 OS_ID 自动选择 deb/rpm 安装流程
################################################################################
install_nvidia_toolkit() {
  case "${OS_ID}" in
    ubuntu|debian)
      install_nvidia_toolkit_deb
      ;;
    centos|rocky|openeuler|kylin*)
      install_nvidia_toolkit_rpm
      ;;
    *)
      die "不支持的 OS_ID=${OS_ID}，请在 install_nvidia_toolkit 中增加对应分支"
      ;;
  esac
}

################################################################################
# Function: configure_containerd_runtime
# Description: 使用 nvidia-ctk 为 containerd 配置 NVIDIA runtime 并重启
################################################################################
configure_containerd_runtime() {
  log_info "配置 nvidia runtime for containerd..."
  log_command "nvidia-ctk runtime configure --runtime=containerd --set-as-default"
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

  collect_nvidia_pkgs
  install_nvidia_toolkit
  configure_containerd_runtime
  deploy_nvidia_device_plugin

  log_info "nvidia 部署完成"
}

main "$@"

