#!/usr/bin/env bash
set -euo pipefail

# 下载 Kubernetes v1.31.11 离线安装包（deb/rpm） 可选
# 用法：
#   bash 00-Download-k8s-packages.sh [ubuntu|centos|rocky|openeuler|kylin] [输出目录]
#
# 示例：
#   bash 00-Download-k8s-packages.sh ubuntu /data/download/packages/ubuntu/kubernetes
#   bash 00-Download-k8s-packages.sh centos /data/download/packages/centos/kubernetes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

K8S_VERSION="${K8S_VERSION:-1.31.11}"
K8S_VERSION_SHORT="${K8S_VERSION%.*}"

# 检测 OS
detect_os

# 解析参数
OS_TYPE="${1:-${OS_ID}}"
OUTPUT_DIR="${2:-}"

if [ -z "${OUTPUT_DIR}" ]; then
  case "${OS_TYPE}" in
    ubuntu|debian)
      OUTPUT_DIR="/data/download/packages/ubuntu/kubernetes"
      ;;
    centos|rhel|rocky|almalinux)
      OUTPUT_DIR="/data/download/packages/centos/kubernetes"
      ;;
    openeuler)
      OUTPUT_DIR="/data/download/packages/openeuler/kubernetes"
      ;;
    kylin*)
      OUTPUT_DIR="/data/download/packages/kylin/kubernetes"
      ;;
    *)
      die "不支持的 OS 类型: ${OS_TYPE}"
      ;;
  esac
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "下载 Kubernetes ${K8S_VERSION} 离线安装包"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "OS 类型: ${OS_TYPE}"
log_info "输出目录: ${OUTPUT_DIR}"
log_info ""

mkdir -p "${OUTPUT_DIR}"

download_ubuntu_debs() {
  log_info "配置 Kubernetes APT 仓库..."
  
  # 安装必要的工具
  if ! command -v curl &>/dev/null; then
    apt-get update && apt-get install -y curl
  fi
  
  # 添加 Kubernetes GPG key
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  
  # 添加 Kubernetes 仓库
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
  
  log_info "更新 APT 仓库索引..."
  apt-get update
  
  log_info "下载 Kubernetes 包及其依赖..."
  cd "${OUTPUT_DIR}"
  
  # 方法1: 使用 apt-get download 下载主包
  log_info "  下载主包: kubelet kubeadm kubectl"
  apt-get download kubelet=${K8S_VERSION}-* kubeadm=${K8S_VERSION}-* kubectl=${K8S_VERSION}-* 2>/dev/null || {
    log_warn "  指定版本下载失败，尝试下载最新版本..."
    apt-get download kubelet kubeadm kubectl 2>/dev/null || true
  }
  
  # 方法2: 使用 apt-cache depends 获取依赖并下载
  log_info "  解析并下载依赖包..."
  local deps_file="/tmp/k8s-deps-$$.txt"
  apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances \
    kubelet=${K8S_VERSION}-* kubeadm=${K8S_VERSION}-* kubectl=${K8S_VERSION}-* 2>/dev/null | \
    grep "^\w" | sort -u > "${deps_file}" || true
  
  if [ -s "${deps_file}" ]; then
    while IFS= read -r dep; do
      [ -z "${dep}" ] && continue
      # 检查是否已下载
      if ! ls "${OUTPUT_DIR}/${dep}"*.deb 1>/dev/null 2>&1; then
        apt-get download "${dep}" 2>/dev/null || true
      fi
    done < "${deps_file}"
    rm -f "${deps_file}"
  fi
  
  log_info "✓ Ubuntu/Debian 包下载完成: ${OUTPUT_DIR}"
  log_info "  包数量: $(ls -1 *.deb 2>/dev/null | wc -l)"
}

download_centos_rpms() {
  log_info "配置 Kubernetes YUM/DNF 仓库..."
  
  # 创建仓库配置
  cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
  
  # 清理并更新缓存
  if command -v dnf &>/dev/null; then
    dnf clean all
    dnf makecache
    log_info "下载 Kubernetes RPM 包及其依赖..."
    cd "${OUTPUT_DIR}"
    dnf download --resolve --alldeps kubelet-${K8S_VERSION}-* kubeadm-${K8S_VERSION}-* kubectl-${K8S_VERSION}-* || {
      log_warn "依赖解析失败，使用简单下载方式..."
      dnf download kubelet-${K8S_VERSION}-* kubeadm-${K8S_VERSION}-* kubectl-${K8S_VERSION}-* || true
    }
  else
    yum clean all
    yum makecache
    log_info "下载 Kubernetes RPM 包及其依赖..."
    cd "${OUTPUT_DIR}"
    # yum 需要安装 yum-plugin-downloadonly（如果可用）
    if yum install -y yum-plugin-downloadonly 2>/dev/null; then
      yumdownloader --resolve --destdir="${OUTPUT_DIR}" kubelet-${K8S_VERSION}-* kubeadm-${K8S_VERSION}-* kubectl-${K8S_VERSION}-* || {
        log_warn "依赖解析失败，使用简单下载方式..."
        yumdownloader --destdir="${OUTPUT_DIR}" kubelet-${K8S_VERSION}-* kubeadm-${K8S_VERSION}-* kubectl-${K8S_VERSION}-* || true
      }
    else
      # 如果没有 downloadonly 插件，尝试直接下载
      log_warn "yum-plugin-downloadonly 不可用，尝试其他方法..."
      # 使用 repotrack（如果可用）
      if command -v repotrack &>/dev/null; then
        repotrack -a x86_64 -p "${OUTPUT_DIR}" kubelet-${K8S_VERSION} kubeadm-${K8S_VERSION} kubectl-${K8S_VERSION} || true
      else
        log_error "无法下载 RPM 包，请手动安装 yum-plugin-downloadonly 或 repotrack"
        return 1
      fi
    fi
  fi
  
  log_info "✓ CentOS/RHEL/Rocky RPM 包下载完成: ${OUTPUT_DIR}"
  log_info "  包数量: $(ls -1 *.rpm 2>/dev/null | wc -l)"
}

download_openeuler_rpms() {
  # OpenEuler 通常使用与 CentOS 相同的仓库
  download_centos_rpms
  log_info "✓ OpenEuler RPM 包下载完成: ${OUTPUT_DIR}"
}

download_kylin_rpms() {
  # 麒麟系统通常使用与 CentOS 相同的仓库
  download_centos_rpms
  log_info "✓ Kylin RPM 包下载完成: ${OUTPUT_DIR}"
}

case "${OS_TYPE}" in
  ubuntu|debian)
    download_ubuntu_debs
    ;;
  centos|rhel|rocky|almalinux)
    download_centos_rpms
    ;;
  openeuler)
    download_openeuler_rpms
    ;;
  kylin*)
    download_kylin_rpms
    ;;
  *)
    die "不支持的 OS 类型: ${OS_TYPE}"
    ;;
esac

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "下载完成！"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "下一步："
log_info "1. 将 ${OUTPUT_DIR} 目录复制到离线环境"
log_info "2. 在 artifacts.yaml 中取消注释对应的 os.dir.kubernetes.* 条目"
log_info "3. 更新 path 为实际路径"
log_info "4. 执行 13-Install-k8s-packages.sh 进行离线安装"

