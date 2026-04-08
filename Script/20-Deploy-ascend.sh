#!/usr/bin/env bash
################################################################################
## Filename:    20-Deploy-ascend.sh
## Description: 离线部署 Ascend（昇腾）NPU 相关组件 x86
## Notes:
##   - 仅做“装包 +（可选）配置 containerd runtime + 部署 device plugin”
##   - 不负责安装驱动/固件本身（npu-smi / 驱动需提前就绪）
##   - 默认通过环境变量指定离线目录与 device-plugin 清单路径
##   - ASCEND_DEVICE_PLUGIN_YAML https://gitcode.com/Ascend/mind-cluster/blob/master/component/ascend-device-plugin/build/ascendplugin-910.yaml
##                               https://raw.gitcode.com/Ascend/mind-cluster/blobs/c4639eea69b2d4d01771716114204143b5d49320/ascendplugin-910.yaml
##   - docker tag swr.cn-south-1.myhuaweicloud.com/ascendhub/ascend-k8sdeviceplugin:v3.0.0 ascend-k8sdeviceplugin:v3.0.0
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

################################################################################
# Function: collect_ascend_pkgs
# Description: 收集 Ascend 离线包（必填 ASCEND_TOOLKIT_DIR）
################################################################################
collect_ascend_pkgs() {
  ascend_pkgs=()

  local ascend_pkg_dir="${ASCEND_TOOLKIT_DIR:-}"
  local suffix=""

  [ -n "${ascend_pkg_dir}" ] || die "请设置 ASCEND_TOOLKIT_DIR（Ascend 离线包目录）"
  [ -d "${ascend_pkg_dir}" ] || die "缺少 Ascend 离线包目录: ${ascend_pkg_dir}"

  case "${OS_ID}" in
    ubuntu|debian) suffix=".deb" ;;
    centos|rocky|openeuler|kylin*) suffix=".rpm" ;;
    *) die "不支持的 OS_ID=${OS_ID}（请扩展 collect_ascend_pkgs 的 OS 映射）" ;;
  esac

  log_info "Ascend 离线包目录: ${ascend_pkg_dir}"

  shopt -s nullglob
  local pat="${ascend_pkg_dir}/*${suffix}"
  local files=(${pat})
  shopt -u nullglob

  [ "${#files[@]}" -gt 0 ] || die "目录为空，未找到 *${suffix}: ${ascend_pkg_dir}"

  ascend_pkgs=("${files[@]}")

  local f
  for f in "${ascend_pkgs[@]}"; do
    [ -f "${f}" ] || die "缺少制品: ${f}"
  done
}

################################################################################
# Function: install_ascend_toolkit_deb
# Description: 离线安装 Ascend 相关 deb
################################################################################
install_ascend_toolkit_deb() {
  have dpkg || die "当前系统不支持 dpkg，请确认系统为 Debian/Ubuntu 或改用 rpm 流程"

  log_info "安装 Ascend 组件（离线 deb）..."
  log_command "dpkg -i ${ascend_pkgs[*]}"
}

################################################################################
# Function: install_ascend_toolkit_rpm
# Description: 离线安装 Ascend 相关 rpm
################################################################################
install_ascend_toolkit_rpm() {
  have rpm || die "当前系统未找到 rpm，无法安装 Ascend rpm 包"

  local installer=""
  if have dnf; then
    installer="dnf"
  elif have yum; then
    installer="yum"
  fi

  log_info "安装 Ascend 组件（离线 rpm）..."

  if [ -n "${installer}" ]; then
    log_command "${installer} -y localinstall ${ascend_pkgs[*]}"
  else
    log_warn "未检测到 dnf/yum，改用 rpm -ivh 安装，可能需要你手动解决依赖"
    log_command "rpm -ivh ${ascend_pkgs[*]}"
  fi
}

################################################################################
# Function: install_ascend_toolkit
# Description: 根据 OS_ID 自动选择 deb/rpm 安装流程
################################################################################
install_ascend_toolkit() {
  case "${OS_ID}" in
    ubuntu|debian)
      install_ascend_toolkit_deb
      ;;
    centos|rocky|openeuler|kylin*)
      install_ascend_toolkit_rpm
      ;;
    *)
      die "不支持的 OS_ID=${OS_ID}，请在 install_ascend_toolkit 中增加对应分支"
      ;;
  esac
}

################################################################################
# Function: configure_containerd_runtime_for_ascend
# Description: 配置 Ascend runtime（优先 ASCEND_RUNTIME_CONFIG_CMD）
################################################################################
configure_containerd_runtime_for_ascend() {
  # 可选：ASCEND_SKIP_RUNTIME_CONFIG=true 时跳过
  if [ "${ASCEND_SKIP_RUNTIME_CONFIG:-false}" = "true" ]; then
    log_warn "已设置 ASCEND_SKIP_RUNTIME_CONFIG=true，跳过 containerd runtime 配置"
    return 0
  fi

  log_info "配置 Ascend runtime for containerd..."

  if [ -n "${ASCEND_RUNTIME_CONFIG_CMD:-}" ]; then
    log_command "${ASCEND_RUNTIME_CONFIG_CMD}"
    log_command "systemctl restart containerd"
    return 0
  fi

  # 常见安装路径下的工具脚本（不同版本可能不同）
  if [ -x /usr/local/Ascend/driver/tools/containerd_install.sh ]; then
    log_command "bash /usr/local/Ascend/driver/tools/containerd_install.sh"
    log_command "systemctl restart containerd"
    return 0
  fi
  if [ -x /usr/local/Ascend/driver/tools/containerd_config.sh ]; then
    log_command "bash /usr/local/Ascend/driver/tools/containerd_config.sh"
    log_command "systemctl restart containerd"
    return 0
  fi

  log_warn "未检测到 Ascend containerd 配置脚本，且未设置 ASCEND_RUNTIME_CONFIG_CMD"
  log_warn "请按驱动版本文档手动配置 containerd runtime；可通过 ASCEND_RUNTIME_CONFIG_CMD 注入命令"
}

################################################################################
# Function: deploy_ascend_device_plugin
# Description: 按清单路径部署 Ascend device plugin
################################################################################
deploy_ascend_device_plugin() {
  local yaml="${ASCEND_DEVICE_PLUGIN_YAML:-}"
  [ -n "${yaml}" ] || die "请设置 ASCEND_DEVICE_PLUGIN_YAML（Ascend device-plugin YAML 路径）"
  [ -f "${yaml}" ] || die "缺少制品: ${yaml}"

  # device-plugin YAML 通常带 nodeSelector: { accelerator: huawei-AscendXXXX }
  # 若节点缺少该 label，则 DaemonSet 会 Desired=0 / 不创建 Pod。
  # 这里自动给当前节点打上 label，避免用户手动 kubectl label。
  ensure_node_label_for_device_plugin "${yaml}"

  # 默认官方建议装在 kube-system；但也允许用户通过环境变量覆盖命名空间。
  # 由于 YAML 里 ServiceAccount/DaemonSet/Subject 都写死了 namespace，我们在 apply 前做临时重写。
  local target_ns="${ASCEND_DEVICE_PLUGIN_NAMESPACE:-kube-system}"
  [ -n "${target_ns}" ] || die "ASCEND_DEVICE_PLUGIN_NAMESPACE 不能为空"

  log_info "部署 Ascend device plugin..."

  if [ "${target_ns}" = "kube-system" ]; then
    log_command "kubectl apply -f \"${yaml}\""
  else
    local tmp
    tmp="$(mktemp -t ascend-device-plugin.XXXXXX.yaml)"
    # 这里简单替换 YAML 内所有 kube-system namespace 字段，覆盖 SA/DaemonSet/ClusterRoleBinding.subject。
    sed "s/namespace:[[:space:]]*kube-system/namespace: ${target_ns}/g" "${yaml}" > "${tmp}"
    trap 'rm -f "${tmp}"' EXIT
    # 如果目标命名空间不存在，则先建好（幂等）
    kubectl create namespace "${target_ns}" --dry-run=client -o yaml | kubectl apply -f -
    log_command "kubectl apply -f \"${tmp}\""
    trap - EXIT
    rm -f "${tmp}"
  fi
}

################################################################################
# Function: ensure_node_label_for_device_plugin
# Description: 根据 device-plugin YAML 自动给当前节点打 required label
################################################################################
ensure_node_label_for_device_plugin() {
  local yaml="$1"

  # 获取 nodeSelector 下 accelerator 的 value，例如 huawei-Ascend910
  local accel_value=""
  accel_value="$(
    awk '
      BEGIN{in_ns=0}
      /^[[:space:]]*nodeSelector:[[:space:]]*$/ {in_ns=1; next}
      in_ns && /^[[:space:]]*accelerator:[[:space:]]*/ {
        line=$0
        sub(/^[[:space:]]*accelerator:[[:space:]]*/, "", line)
        gsub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
      in_ns && /^[^[:space:]]/ {in_ns=0}
    ' "${yaml}" 2>/dev/null || true
  )"

  [ -n "${accel_value}" ] || return 0

  # 推断当前节点名：node 名一般等于 hostname（或 hostname 去掉域名部分）
  local local_node
  local_node="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  local_node="${local_node%%.*}"

  kubectl get node "${local_node}" >/dev/null 2>&1 || die "无法找到当前节点对象：node=${local_node}（请确认 kube-apiserver 可访问且节点名与 hostname 一致）"

  log_info "为当前节点自动打 label：node=${local_node} accelerator=${accel_value}"
  kubectl label node "${local_node}" "accelerator=${accel_value}" --overwrite
}

################################################################################
# Function: main
# Description: 主流程
################################################################################
main() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  # collect_ascend_pkgs #TUDO 后续补充
  # install_ascend_toolkit #TUDO 后续补充
  configure_containerd_runtime_for_ascend
  deploy_ascend_device_plugin

  log_info "ascend 部署完成"
}

main "$@"

