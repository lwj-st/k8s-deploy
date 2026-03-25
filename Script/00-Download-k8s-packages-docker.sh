#!/usr/bin/env bash
set -euo pipefail

# 使用 Docker 容器下载 Kubernetes 离线安装包（适用于没有对应 OS 环境的情况） 可选
# 用法：
#   bash 00-Download-k8s-packages-docker.sh [centos|rocky|openeuler|kylin|ubuntu|debian] [输出目录] [K8S版本]
#
# 示例：
#   bash 00-Download-k8s-packages-docker.sh centos /data/download/packages/kubernetes/centos 1.31.11
#   bash 00-Download-k8s-packages-docker.sh ubuntu /data/download/packages/kubernetes/ubuntu 1.31.11

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

OS_TYPE="${1:-centos}"
K8S_OS_DIR="${OS_TYPE}"
if [ "${OS_TYPE}" = "debian" ]; then
  # debian 与 ubuntu 共享同一套 .deb
  K8S_OS_DIR="ubuntu"
fi
DOWNLOAD_OS_TYPE="${OS_TYPE}"
if [ "${OS_TYPE}" = "debian" ]; then
  # 让容器内下载逻辑走 ubuntu/apt 分支
  DOWNLOAD_OS_TYPE="ubuntu"
fi
OUTPUT_DIR="${2:-/data/download/packages/kubernetes/${K8S_OS_DIR}}"
K8S_VERSION="${3:-1.31.11}"
K8S_VERSION_SHORT="${K8S_VERSION%.*}"

# Docker 镜像映射

# declare -A DOCKER_IMAGES=(
#   ["centos"]="centos:7"
#   ["rocky"]="rockylinux:8"
#   ["openeuler"]="openeuler/openeuler:22.03"
#   ["kylin"]="macrosan/kylin:v10-sp3-2403"
#   ["ubuntu"]="ubuntu:22.04"
# )

declare -A DOCKER_IMAGES=(
  ["centos"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:centos-7"
  ["rocky"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:rockylinux-8"
  ["openeuler"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:openeuler-22.03"
  ["kylin"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:kylin-v10-sp3-2403"
  ["ubuntu"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:ubuntu-22.04"
  ["debian"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:ubuntu-22.04"
)

if [ -z "${DOCKER_IMAGES[${OS_TYPE}]:-}" ]; then
  die "不支持的 OS_TYPE: ${OS_TYPE}。支持: centos|rocky|openeuler|kylin|ubuntu|debian"
fi

DOCKER_IMAGE="${DOCKER_IMAGES[${OS_TYPE}]}"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "使用 Docker 容器下载 Kubernetes ${K8S_VERSION} 离线安装包"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "OS 类型: ${OS_TYPE}"
log_info "Docker 镜像: ${DOCKER_IMAGE}"
log_info "输出目录: ${OUTPUT_DIR}"
log_info "Kubernetes 版本: ${K8S_VERSION}"
log_info ""

# 检查 Docker 或 Podman
DOCKER_CMD=""
if command -v docker &>/dev/null; then
  DOCKER_CMD="docker"
elif command -v podman &>/dev/null; then
  DOCKER_CMD="podman"
  log_info "检测到 podman，将使用 podman 替代 docker"
else
  cat <<EOF
错误: 未找到 docker 或 podman 命令

请选择以下方式之一：

方式 1: 安装 Docker
  Ubuntu/Debian:
    sudo apt-get update
    sudo apt-get install -y docker.io
    sudo systemctl start docker
    sudo systemctl enable docker

  CentOS/Rocky:
    sudo yum install -y docker
    sudo systemctl start docker
    sudo systemctl enable docker

方式 2: 安装 Podman
  Ubuntu/Debian:
    sudo apt-get update
    sudo apt-get install -y podman

  CentOS/Rocky:
    sudo yum install -y podman

方式 3: 使用非 Docker 方式下载（需要对应 OS 环境）
  使用脚本: 00-Download-k8s-packages.sh
  该脚本需要在对应的 OS 环境中运行

EOF
  exit 1
fi

# 创建输出目录
mkdir -p "${OUTPUT_DIR}"

# 创建临时下载脚本
TMP_SCRIPT="/tmp/k8s-download-$$.sh"
cat > "${TMP_SCRIPT}" <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

OS_TYPE="${1}"
K8S_VERSION="${2}"
K8S_VERSION_SHORT="${3}"
OUTPUT_DIR="/output"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

mkdir -p "${OUTPUT_DIR}"

################################################################################
# Ubuntu/Debian：apt 下载 .deb
################################################################################
if [ "${OS_TYPE}" = "ubuntu" ] || [ "${OS_TYPE}" = "debian" ]; then
  log "检测到 Ubuntu/Debian，使用 apt 下载 Kubernetes .deb 包..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y -qq curl ca-certificates gpg 2>/dev/null || true

  # Kubernetes 官方 apt 源（URL 格式须为 core:/stable:/vX.XX，见 https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/）
  K8S_DEB_REPO="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_SHORT}/deb"
  log "配置 Kubernetes apt 源（v${K8S_VERSION_SHORT}）..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL "${K8S_DEB_REPO}/Release.key" -o /tmp/k8s-apt-key.asc 2>/dev/null && gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg < /tmp/k8s-apt-key.asc 2>/dev/null || true
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_DEB_REPO}/ /" > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq || true
  if ! apt-cache show kubelet &>/dev/null; then
    log "警告: pkgs.k8s.io 不可用（可能 403/网络限制），尝试 packages.kubernetes.io 备用..."
    K8S_DEB_REPO="https://packages.kubernetes.io/core:/stable:/v${K8S_VERSION_SHORT}/deb"
    curl -fsSL "${K8S_DEB_REPO}/Release.key" -o /tmp/k8s-apt-key.asc 2>/dev/null && gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg < /tmp/k8s-apt-key.asc 2>/dev/null || true
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_DEB_REPO}/ /" > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq || true
  fi

  log "下载 kubelet/kubeadm/kubectl 及其依赖（仅下载不安装）..."
  apt-get install -d -y kubelet="${K8S_VERSION}-*" kubeadm="${K8S_VERSION}-*" kubectl="${K8S_VERSION}-*" 2>&1 || true
  # 将缓存目录下所有相关 .deb 一并打包，方便在离线环境完整安装依赖
  cp -n /var/cache/apt/archives/*.deb "${OUTPUT_DIR}/" 2>/dev/null || true
  rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true

  shopt -s nullglob
  DEB_FILES=("${OUTPUT_DIR}"/*.deb)
  PKG_COUNT="${#DEB_FILES[@]}"
  shopt -u nullglob
  if [ "${PKG_COUNT}" -eq 0 ]; then
    log "错误: 未下载到任何 .deb 包，请检查网络或版本 ${K8S_VERSION} 是否存在"
    exit 1
  fi
  log "下载完成！共 ${PKG_COUNT} 个 .deb 包"
  ls -lh "${OUTPUT_DIR}"/*.deb 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || true
  exit 0
fi

################################################################################
# RPM 系：yum/dnf 下载 .rpm
################################################################################
has_dnf_download() {
  dnf download --help >/dev/null 2>&1
}

log "开始配置 Kubernetes 仓库..."

# 安装必要工具
if command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
  PKG_MGR_FLAGS="-y"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
  PKG_MGR_FLAGS="-y"
else
  log "错误: 未找到 dnf 或 yum"
  exit 1
fi

# 检测 CentOS 版本并配置镜像源（CentOS 7 已 EOL，需要使用 vault）
if [ -f /etc/centos-release ]; then
  CENTOS_VERSION=$(rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides /etc/redhat-release) 2>/dev/null || echo "7")
  if [ "${CENTOS_VERSION}" = "7" ]; then
    log "检测到 CentOS 7，配置镜像源（CentOS 7 已 EOL）..."
    # 备份原配置
    mkdir -p /etc/yum.repos.d/backup
    mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
    
    # 优先尝试阿里云镜像，失败则使用 vault
    log "尝试配置阿里云 CentOS 7 镜像源..."
    cat > /etc/yum.repos.d/CentOS-Base.repo <<'REPO_EOF'
[base]
name=CentOS-$releasever - Base
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/$basearch/
        http://vault.centos.org/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
failovermethod=priority

[updates]
name=CentOS-$releasever - Updates
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/$basearch/
        http://vault.centos.org/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
failovermethod=priority

[extras]
name=CentOS-$releasever - Extras
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/extras/$basearch/
        http://vault.centos.org/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
failovermethod=priority
REPO_EOF
    log "CentOS 7 镜像源配置完成（优先使用阿里云镜像）"
  fi
fi

# 安装必要工具（禁用其他 repo，只使用 base 和 kubernetes）
log "安装必要工具..."
if [ "${PKG_MGR}" = "dnf" ]; then
  ${PKG_MGR} ${PKG_MGR_FLAGS} --disablerepo="*" --enablerepo="base,updates,extras" install curl ca-certificates dnf-plugins-core yum-utils || {
    # 如果禁用 repo 失败，尝试正常安装
    log "警告: 使用默认 repo 配置安装工具..."
    ${PKG_MGR} ${PKG_MGR_FLAGS} install curl ca-certificates dnf-plugins-core yum-utils || true
  }
else
  ${PKG_MGR} ${PKG_MGR_FLAGS} --disablerepo="*" --enablerepo="base,updates,extras" install curl ca-certificates yum-utils || {
    # 如果禁用 repo 失败，尝试正常安装
    log "警告: 使用默认 repo 配置安装工具..."
    ${PKG_MGR} ${PKG_MGR_FLAGS} install curl ca-certificates yum-utils || true
  }
fi

# 创建 Kubernetes 仓库（阿里云）
log "配置 Kubernetes 仓库（阿里云镜像）..."
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_VERSION_SHORT}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_VERSION_SHORT}/rpm/repodata/repomd.xml.key
EOF

# 清理并更新缓存
log "更新仓库缓存..."
${PKG_MGR} clean all
${PKG_MGR} makecache --disablerepo="*" --enablerepo="base,updates,extras,kubernetes" || {
  log "警告: makecache 失败，尝试使用所有 repo..."
  ${PKG_MGR} makecache || {
    log "警告: makecache 完全失败，尝试继续..."
  }
}

# 确保下载命令可用（部分镜像默认不带 dnf download）
if [ "${PKG_MGR}" = "dnf" ]; then
  if ! has_dnf_download; then
    log "检测到 dnf download 不可用，尝试安装插件..."
    ${PKG_MGR} ${PKG_MGR_FLAGS} install dnf-plugins-core || true
    ${PKG_MGR} ${PKG_MGR_FLAGS} install 'dnf-command(download)' || true
  fi
fi

# 创建输出目录
mkdir -p "${OUTPUT_DIR}"

# 优先使用传入的版本；若仓库中不存在则再按仓库可用版本选择
log "检测 Kubernetes 仓库中可用的版本（期望大版本: ${K8S_VERSION_SHORT}）..."
K8S_YUM_VERSION="${K8S_VERSION}"

AVAILABLE_VERSIONS=$(${PKG_MGR} --enablerepo=kubernetes --showduplicates list kubelet 2>/dev/null \
  | awk '/kubelet/ {print $2}' | sed 's/-.*//' | grep "^${K8S_VERSION_SHORT}\." | sort -V || true)

if echo "${AVAILABLE_VERSIONS}" | grep -q "^${K8S_VERSION}$"; then
  K8S_YUM_VERSION="${K8S_VERSION}"
  log "使用指定版本: ${K8S_YUM_VERSION}"
elif [ -n "${AVAILABLE_VERSIONS}" ]; then
  K8S_YUM_VERSION=$(echo "${AVAILABLE_VERSIONS}" | tail -1)
  log "指定版本 ${K8S_VERSION} 不在仓库中，使用同系列可用版本: ${K8S_YUM_VERSION}"
else
  # 如果没有匹配到相同大版本，则尝试取仓库中最新版本
  K8S_YUM_VERSION=$(${PKG_MGR} --enablerepo=kubernetes --showduplicates list kubelet 2>/dev/null \
    | awk '/kubelet/ {print $2}' | sed 's/-.*//' | sort -V | tail -1 || echo "")
  if [ -n "${K8S_YUM_VERSION}" ]; then
    log "未找到 ${K8S_VERSION_SHORT}.* ，使用仓库中最新版本: ${K8S_YUM_VERSION}"
  else
    log "警告: 无法从仓库中解析 kubelet 版本，将直接使用传入版本: ${K8S_VERSION}"
    K8S_YUM_VERSION="${K8S_VERSION}"
  fi
fi

# 下载 RPM 包（指定版本，避免被解析为仓库最新）
log "开始下载 Kubernetes RPM 包（目标版本: ${K8S_YUM_VERSION}）..."
cd "${OUTPUT_DIR}"

PKG_NAMES="kubelet kubeadm kubectl"
PKG_NAMES_VERSIONED="kubelet-${K8S_YUM_VERSION}-* kubeadm-${K8S_YUM_VERSION}-* kubectl-${K8S_YUM_VERSION}-*"
log "下载包: ${PKG_NAMES}（版本 ${K8S_YUM_VERSION}）"

# 执行下载
if [ "${PKG_MGR}" = "dnf" ]; then
  if has_dnf_download; then
    log "使用 dnf download 下载..."
    dnf download --resolve --alldeps --arch=x86_64 --enablerepo=kubernetes --disablerepo="*" \
      ${PKG_NAMES_VERSIONED} 2>&1 || {
      log "警告: 使用所有 repo 重试..."
      dnf download --resolve --alldeps --arch=x86_64 ${PKG_NAMES_VERSIONED} 2>&1 || true
    }
  elif command -v yumdownloader &>/dev/null; then
    log "dnf download 不可用，回退使用 yumdownloader..."
    yumdownloader --resolve --destdir="${OUTPUT_DIR}" --enablerepo=kubernetes --disablerepo="*" \
      ${PKG_NAMES_VERSIONED} 2>&1 || {
      log "警告: 使用所有 repo 重试..."
      yumdownloader --resolve --destdir="${OUTPUT_DIR}" ${PKG_NAMES_VERSIONED} 2>&1 || true
    }
  else
    log "错误: dnf download 不可用且 yumdownloader 不存在"
    exit 1
  fi
else
  if command -v yumdownloader &>/dev/null; then
    log "使用 yumdownloader 下载..."
    yumdownloader --resolve --destdir="${OUTPUT_DIR}" --enablerepo=kubernetes --disablerepo="*" \
      ${PKG_NAMES_VERSIONED} 2>&1 || {
      log "警告: 使用所有 repo 重试..."
      yumdownloader --resolve --destdir="${OUTPUT_DIR}" ${PKG_NAMES_VERSIONED} 2>&1 || true
    }
  else
    log "错误: yumdownloader 不可用（应该在安装工具阶段已安装）"
    exit 1
  fi
fi

# 统计下载的包
shopt -s nullglob
RPM_FILES=(*.rpm)
PKG_COUNT="${#RPM_FILES[@]}"
shopt -u nullglob
log "下载完成！共下载 ${PKG_COUNT} 个 RPM 包"
if [ "${PKG_COUNT}" -eq 0 ]; then
  log "错误: 未下载到任何 RPM 包，请检查仓库和插件配置"
  exit 1
fi

# 列出下载的包
log "下载的包列表:"
ls -lh *.rpm 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || true
SCRIPT_EOF

chmod +x "${TMP_SCRIPT}"

log_info "拉取 Docker 镜像: ${DOCKER_IMAGE}"
${DOCKER_CMD} pull "${DOCKER_IMAGE}" || die "拉取镜像失败: ${DOCKER_IMAGE}"

log_info "启动容器并下载 Kubernetes 包..."
log_info "（这可能需要几分钟，请耐心等待...）"

# 运行容器
# 注意：podman 不需要 sudo，docker 可能需要（取决于配置）
if [ "${DOCKER_CMD}" = "podman" ]; then
  ${DOCKER_CMD} run --rm \
    -v "${OUTPUT_DIR}:/output" \
    -v "${TMP_SCRIPT}:/download.sh:ro" \
    "${DOCKER_IMAGE}" \
    /bin/bash /download.sh "${DOWNLOAD_OS_TYPE}" "${K8S_VERSION}" "${K8S_VERSION_SHORT}" || {
    rm -f "${TMP_SCRIPT}"
    die "容器执行失败"
  }
else
  # docker 可能需要 sudo，但先尝试不用 sudo
  if ${DOCKER_CMD} ps &>/dev/null; then
    ${DOCKER_CMD} run --rm \
      -v "${OUTPUT_DIR}:/output" \
      -v "${TMP_SCRIPT}:/download.sh:ro" \
      "${DOCKER_IMAGE}" \
      /bin/bash /download.sh "${DOWNLOAD_OS_TYPE}" "${K8S_VERSION}" "${K8S_VERSION_SHORT}" || {
      rm -f "${TMP_SCRIPT}"
      die "容器执行失败"
    }
  else
    log_warn "docker 命令需要 root 权限，尝试使用 sudo..."
    sudo ${DOCKER_CMD} run --rm \
      -v "${OUTPUT_DIR}:/output" \
      -v "${TMP_SCRIPT}:/download.sh:ro" \
      "${DOCKER_IMAGE}" \
      /bin/bash /download.sh "${DOWNLOAD_OS_TYPE}" "${K8S_VERSION}" "${K8S_VERSION_SHORT}" || {
      rm -f "${TMP_SCRIPT}"
      die "容器执行失败（可能需要将当前用户添加到 docker 组：sudo usermod -aG docker $USER）"
    }
  fi
fi

rm -f "${TMP_SCRIPT}"

# 统计结果（按 OS 区分 .rpm / .deb）
shopt -s nullglob
if [ "${OS_TYPE}" = "ubuntu" ] || [ "${OS_TYPE}" = "debian" ]; then
  HOST_PKG_FILES=("${OUTPUT_DIR}"/*.deb)
  PKG_EXT="deb"
else
  HOST_PKG_FILES=("${OUTPUT_DIR}"/*.rpm)
  PKG_EXT="rpm"
fi
PKG_COUNT="${#HOST_PKG_FILES[@]}"
shopt -u nullglob
TOTAL_SIZE=$(du -sh "${OUTPUT_DIR}" 2>/dev/null | awk '{print $1}' || echo "未知")

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "下载完成！"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "输出目录: ${OUTPUT_DIR}"
log_info "包数量: ${PKG_COUNT} (.${PKG_EXT})"
log_info "总大小: ${TOTAL_SIZE}"
log_info ""
log_info "下载的包列表:"
ls -lh "${OUTPUT_DIR}"/*.${PKG_EXT} 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || log_info "  （无）"
log_info ""
log_info "下一步："
log_info "1. 将 ${OUTPUT_DIR} 目录复制到离线环境"
log_info "2. 确保 artifacts.yaml 中的 path 指向正确路径"
if [ "${OS_TYPE}" = "ubuntu" ] || [ "${OS_TYPE}" = "debian" ]; then
  log_info "3. 离线安装: dpkg -i *.deb 或 apt install ./*.deb（需与 13-Install-k8s-packages 等脚本配合）"
else
  log_info "3. 执行 13-Install-k8s-packages.sh 进行离线安装"
fi

