#!/usr/bin/env bash
set -euo pipefail

# 校验顺序（GPU 节点才执行）
# 0) fabricmanager check
# 1) NVIDIA container toolkit 包是否已安装
# 2) containerd 配置文件是否存在
# 3) runtime_type 是否为 io.containerd.runc.v2
# 4) default_runtime_name 是否为 nvidia
# 5) Kubernetes 层面：Node 是否出现 nvidia.com/gpu
# 6) device-plugin DaemonSet 调度约束（常见坑：nodeSelector 要求 nvidia.com/gpu.present=true）

CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DEPLOY_ROOT="$(cd "${CHECK_DIR}/.." && pwd)"

# 复用现有日志/工具函数（但不调用 init_framework，避免强依赖 environment.sh）
# shellcheck disable=SC1091
source "${K8S_DEPLOY_ROOT}/Script/framework.sh"

get_cur_path
init_logging
detect_os

CFG_CONTAINERD="/etc/containerd/config.toml"
DS_NAMESPACE="kube-system"
DS_NAME="nvidia-device-plugin-daemonset"

EXPECTED_RUNTIME_TYPE="io.containerd.runc.v2"
EXPECTED_DEFAULT_RUNTIME_NAME="nvidia"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# is_gpu_node
# 返回 0 表示“认为这是 NVIDIA GPU 节点”；返回 1 表示不是（跳过后续检查）
is_gpu_node() {
  if have_cmd nvidia-smi; then
    return 0
  fi
  if [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ]; then
    return 0
  fi
  if have_cmd lspci && lspci 2>/dev/null | grep -qi nvidia; then
    return 0
  fi
  if [ -r /proc/driver/nvidia/version ]; then
    return 0
  fi
  return 1
}

# check_dpkg_installed <pkgName>
# 仅用于 Debian/Ubuntu，返回 0 表示已安装，非 0 表示未安装或无法检查
check_dpkg_installed() {
  local pkg="$1"
  if ! have_cmd dpkg-query; then
    log_warn "未找到 dpkg-query，跳过 deb 包安装检查（OS=${OS_ID}）"
    return 1
  fi
  dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

# check_rpm_installed <pkgName>
# 仅用于 CentOS/Rocky 等 rpm 系，返回 0 表示已安装，非 0 表示未安装或无法检查
check_rpm_installed() {
  local pkg="$1"
  if ! have_cmd rpm; then
    log_warn "未找到 rpm，跳过 rpm 包安装检查（OS=${OS_ID}）"
    return 1
  fi
  rpm -q "$pkg" >/dev/null 2>&1
}

# check_pkg_installed <pkgName>
# 根据 OS_ID 自动选择 dpkg 或 rpm 进行检测
check_pkg_installed() {
  local pkg="$1"
  case "${OS_ID}" in
    ubuntu|debian)
      check_dpkg_installed "$pkg"
      ;;
    centos|rocky|openeuler|kylin*)
      check_rpm_installed "$pkg"
      ;;
    *)
      log_warn "未知发行版（OS_ID=${OS_ID}），无法自动检查包 ${pkg} 是否已安装"
      return 1
      ;;
  esac
}

# toml_get_value_in_block <file> <block> <key>
# 从指定 TOML block 中读取 key 的值（第一处匹配）
toml_get_value_in_block() {
  local file="$1" block="$2" key="$3"
  awk -v blk="$block" -v key="$key" '
    function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function stripq(s){ s=trim(s); gsub(/^["\047]|["\047]$/, "", s); return s }
    BEGIN{inblk=0}
    /^[[:space:]]*\[/{ line=trim($0); inblk = (line == blk) ? 1 : 0 }
    inblk && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      v=$0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", v)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      print stripq(v)
      exit 0
    }
  ' "$file"
}

kubectl_ok() {
  have_cmd kubectl || return 1
  kubectl version --request-timeout=3s >/dev/null 2>&1
}

check_fabric_manager() {
  # 仅在 systemd 存在且 nvidia-fabricmanager 服务已安装时进行检查
  # https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/nvidia-fabricmanager-dev-570_570.195.03-1_amd64.deb
  # https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/nvidia-fabricmanager-570_570.195.03-1_amd64.deb

  # https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/nvidia-fabric-manager-570.195.03-1.x86_64.rpm
  # https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/nvidia-fabric-manager-devel-570.195.03-1.x86_64.rpm
  if ! have_cmd systemctl; then
    return 0
  fi

  if ! systemctl list-unit-files "nvidia-fabricmanager.service" >/dev/null 2>&1; then
    return 0
  fi

  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查：NVIDIA Fabric Manager 服务状态（NVSwitch 机型必需组件）"

  local fm_state
  fm_state="$(systemctl is-active nvidia-fabricmanager || true)"

  if [ "${fm_state}" = "active" ]; then
    log_info "  ✓ nvidia-fabricmanager.service 处于运行状态"
    return 0
  fi

  log_error "  ✗ nvidia-fabricmanager.service 状态异常：${fm_state:-unknown}"

  local msg
  case "${OS_ID}" in
    ubuntu|debian)
      msg="在升级 GPU 驱动后，需要同步升级 Fabric Manager 并保持版本一致，否则可能导致：
  - 仅识别部分 GPU（nvidia-smi -L 只显示一张卡）
  - CUDA 初始化失败（cudaGetDeviceCount Error 802 等），大模型服务无法启动

请在当前机器上安装/升级以下 deb 包（版本需与当前驱动 570.195.03 一致）：
  cd /data/download/nvidia
  sudo dpkg -i nvidia-fabricmanager-570_570.195.03-1_amd64.deb nvidia-fabricmanager-dev-570_570.195.03-1_amd64.deb
安装完成后执行：
  sudo systemctl enable nvidia-fabricmanager
  sudo systemctl restart nvidia-fabricmanager
并重新验证：
  nvidia-smi -L
  python -c 'import torch; print(torch.cuda.device_count())'"
      ;;
    centos|rocky|openeuler|kylin*)
      msg="在升级 GPU 驱动后，需要同步升级 Fabric Manager 并保持版本一致，否则可能导致：
  - 仅识别部分 GPU（nvidia-smi -L 只显示一张卡）
  - CUDA 初始化失败（cudaGetDeviceCount Error 802 等），大模型服务无法启动

请在当前机器上安装/升级匹配版本的 Fabric Manager rpm 包（包名和版本请与当前驱动文档对齐），示例：
  cd /data/download/nvidia
  sudo yum -y localinstall nvidia-fabric-manager-570.195.03-1.x86_64.rpm nvidia-fabric-manager-devel-570.195.03-1.x86_64.rpm  # 或 dnf localinstall
安装完成后执行：
  sudo systemctl enable nvidia-fabricmanager
  sudo systemctl restart nvidia-fabricmanager
并重新验证：
  nvidia-smi -L
  python -c 'import torch; print(torch.cuda.device_count())'"
      ;;
    *)
      msg="在升级 GPU 驱动后，需要同步升级 Fabric Manager 并保持版本一致，否则可能导致：
  - 仅识别部分 GPU（nvidia-smi -L 只显示一张卡）
  - CUDA 初始化失败（cudaGetDeviceCount Error 802 等），大模型服务无法启动

请根据当前发行版的官方文档安装/升级 NVIDIA Fabric Manager，并确保：
  - nvidia-fabricmanager.service 处于 active
  - 版本与当前驱动匹配
并重新验证：
  nvidia-smi -L
  python -c 'import torch; print(torch.cuda.device_count())'"
      ;;
  esac

  print_solution "${msg}"
}

find_node_name() {
  # 优先使用 K8S_NODE_NAME；其次使用 hostname；最后退化为 nodes 列表第一个
  local hn
  if [ -n "${K8S_NODE_NAME:-}" ]; then
    printf '%s\n' "${K8S_NODE_NAME}"
    return 0
  fi
  hn="$(hostname | tr 'A-Z' 'a-z')"
  if kubectl get node "${hn}" >/dev/null 2>&1; then
    printf '%s\n' "${hn}"
    return 0
  fi
  kubectl get nodes 2>/dev/null | awk 'NR==2{print $1}'
}

# print_solution
# 统一输出解决方案建议的格式
print_solution() {
  local msg="$1"
  log_info ""
  log_info "  [解决方案]"
  echo "$msg" | sed 's/^/  /' | while IFS= read -r line; do
    log_info "  ${line}"
  done
  log_info ""
}

# check_1_toolkit_packages
# 检查 NVIDIA toolkit 相关包与 nvidia-ctk 是否存在
check_1_toolkit_packages() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 1/6：NVIDIA container toolkit 相关包是否已安装"

  local pkgs=(
    "nvidia-container-toolkit"
    "nvidia-container-toolkit-base"
    "libnvidia-container1"
    "libnvidia-container-tools"
  )
  local missing_pkgs=0
  for p in "${pkgs[@]}"; do
    if check_pkg_installed "$p"; then
      log_info "  ✓ 已安装: ${p}"
    else
      log_error "  ✗ 未安装: ${p}"
      missing_pkgs=$((missing_pkgs+1))
    fi
  done
  if ! have_cmd nvidia-ctk; then
    log_error "  ✗ 未找到: nvidia-ctk（通常来自 nvidia-container-toolkit）"
    missing_pkgs=$((missing_pkgs+1))
  else
    log_info "  ✓ nvidia-ctk 已存在"
  fi
  if [ "$missing_pkgs" -ne 0 ]; then
    print_solution "离线场景：请补齐并安装 k8s-deploy 清单里的 NVIDIA 离线包（支持 deb/rpm，需与当前 OS 匹配）
执行安装脚本：sudo bash ${K8S_DEPLOY_ROOT}/Script/23-Deploy-nvidia.sh"
  else
    log_info "  ✓ 所有必需包已安装"
  fi
}

# check_2_containerd_config
# 检查 containerd 配置文件是否存在
check_2_containerd_config() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 2/6：containerd 配置文件是否存在"
  if [ ! -f "${CFG_CONTAINERD}" ]; then
    log_error "  ✗ 未找到 containerd 配置文件: ${CFG_CONTAINERD}"
    print_solution "先执行：sudo bash ${K8S_DEPLOY_ROOT}/Script/11-Install-containerd.sh"
    exit 1
  fi
  log_info "  ✓ 配置文件存在: ${CFG_CONTAINERD}"
}

# check_3_runtime_type
# 检查 runc runtime_type 是否为 io.containerd.runc.v2（cgroup v2 建议搭配 runc.v2）
check_3_runtime_type() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 3/6：runtime_type 是否为 ${EXPECTED_RUNTIME_TYPE}"
  local runtime_type
  runtime_type="$(toml_get_value_in_block "${CFG_CONTAINERD}" '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]' 'runtime_type' || true)"
  if [ -z "$runtime_type" ]; then
    log_error "  ✗ 未读取到 runc runtime_type（配置块缺失或格式不匹配）"
    print_solution "确保 containerd config 中存在块：
  [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc]
  runtime_type = \"io.containerd.runc.v2\"
修复后重启：sudo systemctl restart containerd
重启 device-plugin: kubectl delete pod -l name=nvidia-device-plugin -n kube-system"
  elif [ "$runtime_type" = "${EXPECTED_RUNTIME_TYPE}" ]; then
    log_info "  ✓ runtime_type=${runtime_type}"
  else
    log_warn "  ✗ runtime_type=${runtime_type}（期望 ${EXPECTED_RUNTIME_TYPE}）"
    print_solution "修改 /etc/containerd/config.toml：
  将 runc runtime_type 改为：runtime_type = \"${EXPECTED_RUNTIME_TYPE}\"
然后重启：sudo systemctl restart containerd
重启 device-plugin: kubectl delete pod -l name=nvidia-device-plugin -n kube-system"
  fi
}

# check_4_default_runtime_name
# 检查 default_runtime_name 是否为 nvidia（GPU 节点默认 runtime= nvidia）
check_4_default_runtime_name() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 4/6：default_runtime_name 是否为 ${EXPECTED_DEFAULT_RUNTIME_NAME}"
  local def_rt
  def_rt="$(toml_get_value_in_block "${CFG_CONTAINERD}" '[plugins."io.containerd.grpc.v1.cri".containerd]' 'default_runtime_name' || true)"
  if [ -z "$def_rt" ]; then
    log_warn "  ✗ 未设置 default_runtime_name（期望 ${EXPECTED_DEFAULT_RUNTIME_NAME}）"
    print_solution "修改 /etc/containerd/config.toml：
  [plugins.\"io.containerd.grpc.v1.cri\".containerd]
  default_runtime_name = \"nvidia\"
确保存在 nvidia runtime 块（nvidia-ctk 通常会写入）：
  [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia]
  runtime_type = \"io.containerd.runc.v2\"
然后重启：sudo systemctl restart containerd
重启 device-plugin: kubectl delete pod -l name=nvidia-device-plugin -n kube-system"
  elif [ "$def_rt" = "${EXPECTED_DEFAULT_RUNTIME_NAME}" ]; then
    log_info "  ✓ default_runtime_name=${def_rt}"
  else
    log_warn "  ✗ default_runtime_name=${def_rt}（期望 ${EXPECTED_DEFAULT_RUNTIME_NAME}）"
    print_solution "修改 /etc/containerd/config.toml：
  将 default_runtime_name 改为 \"${EXPECTED_DEFAULT_RUNTIME_NAME}\"
然后重启：sudo systemctl restart containerd
重启 device-plugin: kubectl delete pod -l name=nvidia-device-plugin -n kube-system"
  fi
}

# check_5_k8s_gpu_resource
# 检查 K8s Node 上是否出现 nvidia.com/gpu，并按你要求输出 Allocated resources
check_5_k8s_gpu_resource() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 5/6：Kubernetes 层面（nvidia.com/gpu 是否出现在 Node 上）"

  if ! kubectl_ok; then
    log_warn "  ⚠ kubectl 不可用或集群不可达，跳过本段自动检查"
    return 0
  fi

  local node_name gpu_cap gpu_all
  node_name="$(find_node_name || true)"
  if [ -z "${node_name}" ] || ! kubectl get node "${node_name}" >/dev/null 2>&1; then
    log_warn "  ⚠ 无法自动定位/访问 Node（可能未配置 KUBECONFIG 或 nodeName 不匹配）"
    return 0
  fi

  log_info "  检查节点: ${node_name}"
  gpu_cap="$(kubectl get node "${node_name}" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || true)"
  gpu_all="$(kubectl get node "${node_name}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
  
  if [ -n "${gpu_cap}${gpu_all}" ]; then
    log_info "  ✓ nvidia.com/gpu capacity=${gpu_cap:-?} allocatable=${gpu_all:-?}"
    log_info ""
    log_info "  [Node Allocated Resources]"
    kubectl describe node "${node_name}" 2>/dev/null | grep -A10 "Allocated resources" | sed 's/^/  /' || true
    log_info ""
    log_info "  [NVIDIA Device Plugin Pods]"
    kubectl get pods -A 2>/dev/null | grep -i nvidia | sed 's/^/  /' || log_info "  （未发现 nvidia 相关 Pod）"
  else
    log_warn "  ✗ Node ${node_name} 未发现 nvidia.com/gpu（device-plugin 可能未生效/驱动未就绪/需重启 kubelet）"
    print_solution "确认已执行：sudo bash ${K8S_DEPLOY_ROOT}/Script/23-Deploy-nvidia.sh
确认 device-plugin Pod 处于 Running
如已安装驱动/模块但资源仍不出现，可尝试重启 kubelet：
  sudo systemctl restart kubelet
手动检查命令：
  kubectl describe node ${node_name} | grep -A10 \"Allocated resources\"
  kubectl get node ${node_name} -o jsonpath='{.status.capacity.nvidia\\.com/gpu}{\" \"}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}'
  kubectl get pods -A | grep -i nvidia"
  fi
}

# check_6_device_plugin_ds_constraints
# 检查 device-plugin DS 的 nodeSelector/desiredNumberScheduled（是否因为缺 label 导致 desired=0）
check_6_device_plugin_ds_constraints() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 6/6：device-plugin DaemonSet 调度约束（nodeSelector/desiredNumberScheduled）"
  kubectl_ok || { log_warn "  ⚠ kubectl 不可用或集群不可达，跳过本段自动检查"; return 0; }

  if ! kubectl -n "${DS_NAMESPACE}" get ds "${DS_NAME}" >/dev/null 2>&1; then
    log_warn "  ⚠ 未找到 DaemonSet: ${DS_NAMESPACE}/${DS_NAME}（可能尚未部署 device-plugin）"
    return 0
  fi

  local node_name ds_desired sel has_label
  node_name="$(find_node_name || true)"
  ds_desired="$(kubectl -n "${DS_NAMESPACE}" get ds "${DS_NAME}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
  sel="$(kubectl -n "${DS_NAMESPACE}" get ds "${DS_NAME}" -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || true)"
  log_info "  DaemonSet 状态: desiredNumberScheduled=${ds_desired:-?} nodeSelector=${sel:-{}}"

  if [ "${ds_desired:-}" = "0" ] && [ -n "${node_name}" ] && kubectl get node "${node_name}" >/dev/null 2>&1; then
    has_label="$(kubectl get node "${node_name}" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.present}' 2>/dev/null || true)"
    if [ "${has_label}" != "true" ]; then
      log_warn "  ✗ device-plugin 未创建 Pod：节点缺少 label nvidia.com/gpu.present=true（DS nodeSelector 要求）"
      print_solution "给 GPU 节点打标签（示例）：
  kubectl label node ${node_name:-<nodeName>} nvidia.com/gpu.present=true --overwrite
然后再观察：
  kubectl -n ${DS_NAMESPACE} get ds ${DS_NAME}
  kubectl -n ${DS_NAMESPACE} get pods -l name=nvidia-device-plugin -o wide"
    else
      log_info "  ✓ 节点已打标签: nvidia.com/gpu.present=true"
    fi
  elif [ -n "${ds_desired}" ] && [ "${ds_desired}" != "0" ]; then
    log_info "  ✓ DaemonSet 期望调度数量: ${ds_desired}"
  fi
}

main() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "GPU 节点 containerd/NVIDIA 运行时配置检查"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}"

  if ! is_gpu_node; then
    log_warn "未检测到 NVIDIA GPU 节点（nvidia-smi/设备文件/lspci/驱动信息均未命中），跳过 GPU containerd 检查"
    exit 0
  fi

  log_info "检测到 GPU 节点，开始检查..."
  log_info ""

  check_fabric_manager
  check_1_toolkit_packages
  check_2_containerd_config
  check_3_runtime_type
  check_4_default_runtime_name
  check_5_k8s_gpu_resource
  check_6_device_plugin_ds_constraints

  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查完成"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"


