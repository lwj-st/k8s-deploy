#!/usr/bin/env bash
################################################################################
## Filename:    15-Deploy-nvidia.sh
## Description: 离线部署 NVIDIA GPU 相关组件
## Usage:
##   bash 15-Deploy-nvidia.sh
## Artifacts:
##   - nvidia.dir.toolkit.<os_id>.<os_version>
##   - nvidia.manifest.device-plugin.v0.17.2
## Images:
##   - nvidia.image.device-plugin.v0.17.2
## Env:
##   - ALLOW_ONLINE: yes 时允许使用系统源补齐依赖，默认 no
## Notes:
##   - 仅做“装包 + 配置 containerd runtime + 部署 device plugin”
##   - 不负责安装驱动本身（nvidia-smi / 内核驱动需提前就绪）
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

################################################################################
# Function: collect_nvidia_pkgs
# Description: toolkit 目录来自 artifacts.yaml，按当前 OS 选择对应条目
################################################################################
collect_nvidia_pkgs() {
  nvidia_pkgs=()

  local nvidia_pkg_dir=""
  local suffix
  local os_key=""

  case "${OS_ID}" in
    ubuntu)
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
    kylin)
      os_key="kylin"
      suffix=".rpm"
      ;;
    *)
      die "不支持的 OS_ID=${OS_ID}，请在 collect_nvidia_pkgs 中增加 os_id 映射"
      ;;
  esac
  nvidia_pkg_dir="$(artifact_get_nvidia_toolkit_dir "${os_key}" "${TARGET_OS_VERSION}")"
  log_info "NVIDIA toolkit 离线目录: ${nvidia_pkg_dir}"

  [ -d "${nvidia_pkg_dir}" ] || die "缺少 NVIDIA 离线包目录: ${nvidia_pkg_dir}"
  nvidia_pkg_dir="$(cd "${nvidia_pkg_dir}" && pwd -P)"

  shopt -s nullglob
  local files=("${nvidia_pkg_dir}"/*"${suffix}")
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
  if [ "${ALLOW_ONLINE:-no}" != "yes" ]; then
    log_info "严格离线：使用 dpkg --unpack 安装本地 deb"
    dpkg --unpack "${nvidia_pkgs[@]}" || \
      log_warn "部分 deb 暂未配置，继续执行 dpkg --configure -a"
    dpkg --configure -a
  elif have apt-get; then
    local -a apt_args=(install -y)

    log_info "执行命令: apt-get ${apt_args[*]} <${#nvidia_pkgs[@]} 个本地 deb>"
    if apt-get "${apt_args[@]}" "${nvidia_pkgs[@]}"; then
      :
    else
      # APT 在目标机已有半配置/版本冲突时，可能在解包前直接拒绝本地包。
      log_warn "APT 安装失败，回退到 dpkg --unpack 后统一配置"
      dpkg --unpack "${nvidia_pkgs[@]}" || \
        log_warn "部分 deb 暂未配置，继续执行 dpkg --configure -a"
      if ! dpkg --configure -a; then
        log_warn "dpkg 配置仍未完成，ALLOW_ONLINE=yes，尝试在线修复依赖"
        log_command "apt-get -y -f install"
      fi
    fi
  else
    log_info "执行命令: dpkg --unpack <${#nvidia_pkgs[@]} 个本地 deb>"
    dpkg --unpack "${nvidia_pkgs[@]}" || \
      log_warn "部分 deb 暂未配置，继续执行 dpkg --configure -a"
    dpkg --configure -a
  fi

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
    if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      log_command "${installer} -y localinstall ${nvidia_pkgs[*]}"
    elif [ "${installer}" = "dnf" ]; then
      log_command "${installer} -y localinstall --disablerepo='*' --setopt=install_weak_deps=False ${nvidia_pkgs[*]}"
    else
      log_command "${installer} -y localinstall --disablerepo='*' ${nvidia_pkgs[*]}"
    fi
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
    ubuntu)
      install_nvidia_toolkit_deb
      ;;
    centos|rocky|openeuler|kylin)
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

  log_info "导入 NVIDIA device plugin 镜像..."
  import_image_artifact "nvidia.image.device-plugin.v0.17.2"

  log_info "部署 NVIDIA device plugin..."
  # 该 YAML 自带 nodeSelector: nvidia.com/gpu.present=true
  # 为避免 DS desired=0（节点没标签），在检测到 GPU 的节点上自动打 label
  if have nvidia-smi || [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ]; then
    node_name="$(get_local_k8s_node_name)"
    kubectl get node "${node_name}" >/dev/null 2>&1 || die "无法找到当前节点对象：${node_name}"
    log_command "kubectl label node \"${node_name}\" nvidia.com/gpu.present=true --overwrite"
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
