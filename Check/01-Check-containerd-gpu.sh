#!/usr/bin/env bash
set -euo pipefail

# 校验顺序（GPU 节点才执行）
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
# 返回 0 表示已安装；返回 1 表示未安装；返回 2 表示无法检查（无 dpkg-query）
check_dpkg_installed() {
  local pkg="$1"
  if ! have_cmd dpkg-query; then
    log_warn "未找到 dpkg-query，跳过 deb 包安装检查（OS=${OS_ID}）"
    return 2
  fi
  dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q "install ok installed"
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

# check_1_toolkit_packages
# 检查 NVIDIA toolkit 相关包与 nvidia-ctk 是否存在
check_1_toolkit_packages() {
  log_info "检查 1/6：NVIDIA container toolkit 相关包是否已安装"

  local pkgs=(
    "nvidia-container-toolkit"
    "nvidia-container-toolkit-base"
    "libnvidia-container1"
    "libnvidia-container-tools"
  )
  local missing_pkgs=0
  for p in "${pkgs[@]}"; do
    if check_dpkg_installed "$p"; then
      log_info "OK: 已安装 ${p}"
    else
      log_error "MISSING: 未安装 ${p}"
      missing_pkgs=$((missing_pkgs+1))
    fi
  done
  if ! have_cmd nvidia-ctk; then
    log_error "MISSING: 未找到 nvidia-ctk（通常来自 nvidia-container-toolkit）"
    missing_pkgs=$((missing_pkgs+1))
  else
    log_info "OK: nvidia-ctk 已存在"
  fi
  if [ "$missing_pkgs" -ne 0 ]; then
    cat <<EOF
解决方案建议：
- 离线场景：请补齐并安装 k8s-deploy 清单里的 NVIDIA deb（或自行准备 rpm 并扩展脚本）
- 执行安装脚本：sudo bash ${K8S_DEPLOY_ROOT}/Script/20-Deploy-nvidia.sh
EOF
  fi
}

# check_2_containerd_config
# 检查 containerd 配置文件是否存在
check_2_containerd_config() {
  log_info "检查 2/6：containerd 配置文件是否存在"
  if [ ! -f "${CFG_CONTAINERD}" ]; then
    log_error "未找到 containerd 配置文件: ${CFG_CONTAINERD}"
    cat <<EOF
解决方案建议：
- 先执行：sudo bash ${K8S_DEPLOY_ROOT}/Script/11-Install-containerd.sh
EOF
    exit 1
  fi
  log_info "OK: ${CFG_CONTAINERD}"
}

# check_3_runtime_type
# 检查 runc runtime_type 是否为 io.containerd.runc.v2（cgroup v2 建议搭配 runc.v2）
check_3_runtime_type() {
  log_info "检查 3/6：runtime_type 是否为 ${EXPECTED_RUNTIME_TYPE}"
  local runtime_type
  runtime_type="$(toml_get_value_in_block "${CFG_CONTAINERD}" '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]' 'runtime_type' || true)"
  if [ -z "$runtime_type" ]; then
    log_error "未读取到 runc runtime_type（配置块缺失或格式不匹配）"
    cat <<'EOF'
解决方案建议：
- 确保 containerd config 中存在块：
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
- 修复后重启：sudo systemctl restart containerd
- 重启device-plugin: kubectl delete pod -l name=nvidia-device-plugin -n kube-system
EOF
  elif [ "$runtime_type" = "${EXPECTED_RUNTIME_TYPE}" ]; then
    log_info "OK: runtime_type=${runtime_type}"
  else
    log_warn "NOT-OK: runtime_type=${runtime_type}（期望 ${EXPECTED_RUNTIME_TYPE}）"
    cat <<EOF
解决方案建议：
- 修改 /etc/containerd/config.toml：
  将 runc runtime_type 改为：runtime_type = "${EXPECTED_RUNTIME_TYPE}"
- 然后重启：sudo systemctl restart containerd
- 重启device-plugin: kubectl delete pod -l name=nvidia-device-plugin -n kube-system
EOF
  fi
}

# check_4_default_runtime_name
# 检查 default_runtime_name 是否为 nvidia（GPU 节点默认 runtime= nvidia）
check_4_default_runtime_name() {
  log_info "检查 4/6：default_runtime_name 是否为 ${EXPECTED_DEFAULT_RUNTIME_NAME}"
  local def_rt
  def_rt="$(toml_get_value_in_block "${CFG_CONTAINERD}" '[plugins."io.containerd.grpc.v1.cri".containerd]' 'default_runtime_name' || true)"
  if [ -z "$def_rt" ]; then
    log_warn "NOT-OK: 未设置 default_runtime_name（期望 ${EXPECTED_DEFAULT_RUNTIME_NAME}）"
    cat <<'EOF'
解决方案建议（按你的策略：GPU 节点默认 runtime = nvidia）：
- 修改 /etc/containerd/config.toml：
  [plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "nvidia"
- 确保存在 nvidia runtime 块（nvidia-ctk 通常会写入）：
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
- 然后重启：sudo systemctl restart containerd
- 重启device-plugin: kubectl delete pod -l name=nvidia-device-plugin -n kube-system
EOF
  elif [ "$def_rt" = "${EXPECTED_DEFAULT_RUNTIME_NAME}" ]; then
    log_info "OK: default_runtime_name=${def_rt}"
  else
    log_warn "NOT-OK: default_runtime_name=${def_rt}（期望 ${EXPECTED_DEFAULT_RUNTIME_NAME}）"
    cat <<EOF
解决方案建议（按你的策略：GPU 节点默认 runtime = nvidia）：
- 修改 /etc/containerd/config.toml：
  将 default_runtime_name 改为 "${EXPECTED_DEFAULT_RUNTIME_NAME}"
- 然后重启：sudo systemctl restart containerd
- 重启device-plugin: kubectl delete pod -l name=nvidia-device-plugin -n kube-system
EOF
  fi
}

# check_5_k8s_gpu_resource
# 检查 K8s Node 上是否出现 nvidia.com/gpu，并按你要求输出 Allocated resources
check_5_k8s_gpu_resource() {
  log_info "检查 5/6：Kubernetes 层面（nvidia.com/gpu 是否出现在 Node 上）"

  cat <<'EOF'
你可以手动执行（示例）：
  kubectl describe node <nodeName> | grep -A10 "Allocated resources"
  kubectl get node <nodeName> -o jsonpath='{.status.capacity.nvidia\.com/gpu}{" "}{.status.allocatable.nvidia\.com/gpu}{"\n"}'
  kubectl get pods -A | grep -i nvidia
EOF

  if ! kubectl_ok; then
    log_warn "kubectl 不可用或集群不可达，跳过本段自动检查"
    return 0
  fi

  local node_name gpu_cap gpu_all
  node_name="$(find_node_name || true)"
  if [ -z "${node_name}" ] || ! kubectl get node "${node_name}" >/dev/null 2>&1; then
    log_warn "无法自动定位/访问 Node（可能未配置 KUBECONFIG 或 nodeName 不匹配）"
    return 0
  fi

  gpu_cap="$(kubectl get node "${node_name}" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || true)"
  gpu_all="$(kubectl get node "${node_name}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
  if [ -n "${gpu_cap}${gpu_all}" ]; then
    log_info "Node ${node_name} nvidia.com/gpu capacity=${gpu_cap:-?} allocatable=${gpu_all:-?}"
  else
    log_warn "Node ${node_name} 未发现 nvidia.com/gpu（device-plugin 可能未生效/驱动未就绪/需重启 kubelet）"
    cat <<EOF
解决方案建议：
- 确认已执行：sudo bash ${K8S_DEPLOY_ROOT}/Script/20-Deploy-nvidia.sh
- 确认 device-plugin Pod 处于 Running
- 如已安装驱动/模块但资源仍不出现，可尝试重启 kubelet：
  sudo systemctl restart kubelet
EOF
  fi

  # 输出 Allocated resources（按你要求的 grep 方式）
  kubectl describe node "${node_name}" 2>/dev/null | grep -A10 "Allocated resources" || true

  # device-plugin 运行态（尽量宽松匹配）
  kubectl get pods -A 2>/dev/null | grep -i nvidia || true
}

# check_6_device_plugin_ds_constraints
# 检查 device-plugin DS 的 nodeSelector/desiredNumberScheduled（是否因为缺 label 导致 desired=0）
check_6_device_plugin_ds_constraints() {
  log_info "检查 6/6：device-plugin DaemonSet 调度约束（nodeSelector/desiredNumberScheduled）"
  kubectl_ok || { log_warn "kubectl 不可用或集群不可达，跳过本段自动检查"; return 0; }

  if ! kubectl -n "${DS_NAMESPACE}" get ds "${DS_NAME}" >/dev/null 2>&1; then
    log_warn "未找到 DaemonSet: ${DS_NAMESPACE}/${DS_NAME}（可能尚未部署 device-plugin）"
    return 0
  fi

  local node_name ds_desired sel has_label
  node_name="$(find_node_name || true)"
  ds_desired="$(kubectl -n "${DS_NAMESPACE}" get ds "${DS_NAME}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
  sel="$(kubectl -n "${DS_NAMESPACE}" get ds "${DS_NAME}" -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || true)"
  log_info "device-plugin DS: desiredNumberScheduled=${ds_desired:-?} nodeSelector=${sel:-{}}"

  if [ "${ds_desired:-}" = "0" ] && [ -n "${node_name}" ] && kubectl get node "${node_name}" >/dev/null 2>&1; then
    has_label="$(kubectl get node "${node_name}" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.present}' 2>/dev/null || true)"
    if [ "${has_label}" != "true" ]; then
      log_warn "device-plugin 未创建 Pod：节点缺少 label nvidia.com/gpu.present=true（DS nodeSelector 要求）"
      cat <<EOF
解决方案建议：
- 给 GPU 节点打标签（示例）：
  kubectl label node ${node_name:-<nodeName>} nvidia.com/gpu.present=true --overwrite
- 然后再观察：
  kubectl -n ${DS_NAMESPACE} get ds ${DS_NAME}
  kubectl -n ${DS_NAMESPACE} get pods -l name=nvidia-device-plugin -o wide
EOF
    fi
  fi
}

main() {
  log_info "OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}"

  if ! is_gpu_node; then
    log_warn "未检测到 NVIDIA GPU 节点（nvidia-smi/设备文件/lspci/驱动信息均未命中），跳过 GPU containerd 检查"
    exit 0
  fi

  log_info "检测到 GPU 节点，开始检查 containerd/NVIDIA 运行时配置"

  check_1_toolkit_packages
  check_2_containerd_config
  check_3_runtime_type
  check_4_default_runtime_name
  check_5_k8s_gpu_resource
  check_6_device_plugin_ds_constraints

  log_info "检查完成"
}

main "$@"


