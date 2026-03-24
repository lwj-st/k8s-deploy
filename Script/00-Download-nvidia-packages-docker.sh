#!/usr/bin/env bash
set -euo pipefail

# 待验证
# 使用 Docker 容器下载 NVIDIA container toolkit 离线安装包
# 适用于没有对应 OS 环境、但需要提前准备 deb/rpm 离线包的场景
#
# 查看已安装版本
# dpkg -l | grep -E 'nvidia-container-toolkit|libnvidia-container'
# rpm -q nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1
#
# 用法：
#   bash 00-Download-nvidia-packages-docker.sh [centos|rocky|openeuler|kylin|ubuntu] [输出目录]
# 示例：
#   bash 00-Download-nvidia-packages-docker.sh ubuntu /data/download/nvidia/ubuntu
#   bash 00-Download-nvidia-packages-docker.sh centos /data/download/nvidia/centos
#   bash 00-Download-nvidia-packages-docker.sh openeuler /data/download/nvidia/openeuler
#
# 说明：
#   - RPM 系（含 openeuler/kylin）使用 NVIDIA stable/rpm 通用仓库，版本固定 1.17.8-1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

OS_TYPE="${1:-ubuntu}"
OUTPUT_DIR="${2:-/data/download/nvidia/${OS_TYPE}}"

declare -A DOCKER_IMAGES=(
  ["centos"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:centos-7"
  ["rocky"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:rockylinux-8"
  ["openeuler"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:openeuler-22.03"
  ["kylin"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:kylin-v10-sp3-2403"
  ["ubuntu"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:ubuntu-22.04"
)

if [ -z "${DOCKER_IMAGES[${OS_TYPE}]:-}" ]; then
  die "不支持的 OS_TYPE: ${OS_TYPE}。支持: centos|rocky|openeuler|kylin|ubuntu"
fi

DOCKER_IMAGE="${DOCKER_IMAGES[${OS_TYPE}]}"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "使用 Docker 容器下载 NVIDIA container toolkit 离线安装包"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "OS 类型: ${OS_TYPE}"
log_info "Docker 镜像: ${DOCKER_IMAGE}"
log_info "输出目录: ${OUTPUT_DIR}"
log_info ""

# 检查 Docker 或 Podman
DOCKER_CMD=""
if command -v docker &>/dev/null; then
  DOCKER_CMD="docker"
elif command -v podman &>/dev/null; then
  DOCKER_CMD="podman"
  log_info "检测到 podman，将使用 podman 替代 docker"
else
  die "未找到 docker 或 podman 命令，请先安装其一"
fi

mkdir -p "${OUTPUT_DIR}"

TMP_SCRIPT="/tmp/nvidia-download-$$.sh"
cat > "${TMP_SCRIPT}" <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

OS_TYPE="${1}"
OUTPUT_DIR="/output"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

mkdir -p "${OUTPUT_DIR}"

################################################################################
# Ubuntu：apt 下载 NVIDIA container toolkit 相关 deb
################################################################################
if [ "${OS_TYPE}" = "ubuntu" ]; then
  log "检测到 Ubuntu，使用 apt 下载 nvidia-container-toolkit 相关 deb..."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y curl ca-certificates gnupg lsb-release || true

  distribution=$(. /etc/os-release; echo "${ID}${VERSION_ID}")

  log "配置 NVIDIA libnvidia-container APT 源 (distribution=${distribution})..."
  mkdir -p /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt-get update -qq

  # 与 artifacts.yaml 中 deb 相同的一组包
  NVIDIA_PKGS="
    nvidia-container-toolkit=1.17.8-1
    nvidia-container-toolkit-base=1.17.8-1
    libnvidia-container-tools=1.17.8-1
    libnvidia-container1=1.17.8-1
  "

  log "仅下载（不安装）NVIDIA 相关 deb..."
  apt-get install -d -y ${NVIDIA_PKGS} 2>&1 || true
  cp -n /var/cache/apt/archives/*.deb "${OUTPUT_DIR}/" 2>/dev/null || true
  rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true

  shopt -s nullglob
  DEB_FILES=("${OUTPUT_DIR}"/*.deb)
  PKG_COUNT="${#DEB_FILES[@]}"
  shopt -u nullglob

  if [ "${PKG_COUNT}" -eq 0 ]; then
    log "错误: 未下载到任何 NVIDIA 相关 deb 包，请检查仓库与网络"
    exit 1
  fi

  log "下载完成！共 ${PKG_COUNT} 个 deb 包"
  cat > "${OUTPUT_DIR}/README.txt" <<'UBUNTU_EOF'
本目录为通过 APT 源离线下载的 NVIDIA container toolkit 相关 deb 包。

在离线 Ubuntu 节点上使用示例：
  sudo dpkg -i ./*.deb
或：
  sudo apt install ./nvidia-container-toolkit_*.deb ./nvidia-container-toolkit-base_*.deb ./libnvidia-container-tools_*.deb ./libnvidia-container1_*.deb
UBUNTU_EOF

  exit 0
fi

################################################################################
# RPM 系：dnf/yum 下载 NVIDIA container toolkit 相关 rpm
################################################################################
if [ "${OS_TYPE}" = "centos" ] || [ "${OS_TYPE}" = "rocky" ] || [ "${OS_TYPE}" = "openeuler" ] || [ "${OS_TYPE}" = "kylin" ]; then
  log "检测到 RPM 系 (${OS_TYPE})，使用 dnf/yum 下载 nvidia-container-toolkit 相关 rpm..."

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

  ##############################################################################
  # CentOS 7: 配置 vault 源，避免访问 mirrorlist.centos.org 失败
  ##############################################################################
  if [ -f /etc/centos-release ]; then
    CENTOS_VERSION=$(rpm -q --qf "%{VERSION}" "$(rpm -q --whatprovides /etc/redhat-release)" 2>/dev/null || echo "7")
    if [ "${CENTOS_VERSION}" = "7" ]; then
      log "检测到 CentOS 7，配置 vault 镜像源..."
      mkdir -p /etc/yum.repos.d/backup
      mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
      cat > /etc/yum.repos.d/CentOS-Base.repo <<'REPO_EOF'
[base]
name=CentOS-$releasever - Base
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/$basearch/
gpgcheck=0
enabled=1

[updates]
name=CentOS-$releasever - Updates
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/$basearch/
gpgcheck=0
enabled=1

[extras]
name=CentOS-$releasever - Extras
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/extras/$basearch/
gpgcheck=0
enabled=1
REPO_EOF
      log "CentOS 7 vault 镜像源配置完成"
    fi
  fi

  ${PKG_MGR} ${PKG_MGR_FLAGS} install -y curl ca-certificates || true

  # 对于 RPM 系发行版，官方推荐使用通用 stable 仓库
  # https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
  log "配置 NVIDIA libnvidia-container YUM/DNF 源 (stable/rpm)..."
  curl -fsSL "https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo" \
    -o /etc/yum.repos.d/nvidia-container-toolkit.repo

  ${PKG_MGR} makecache || true

  NVIDIA_PKGS="
    nvidia-container-toolkit-1.17.8-1
    nvidia-container-toolkit-base-1.17.8-1
    libnvidia-container-tools-1.17.8-1
    libnvidia-container1-1.17.8-1
  "

  log "安装 yum-utils / dnf-plugins-core（用于 yumdownloader/dnf download）..."
  ${PKG_MGR} ${PKG_MGR_FLAGS} install -y yum-utils 2>/dev/null || \
    ${PKG_MGR} ${PKG_MGR_FLAGS} install -y dnf-plugins-core 2>/dev/null || true

  cd "${OUTPUT_DIR}"

  # 已指定精确版本，不加 --resolve 避免 dnf 把依赖解析成仓库里更新的 1.18.x
  download_pkgs() {
    local pkgs="$1"
    if [ -z "${pkgs}" ]; then
      return 0
    fi
    if command -v yumdownloader &>/dev/null; then
      yumdownloader --destdir="${OUTPUT_DIR}" ${pkgs} 2>&1 || true
    else
      dnf download --destdir="${OUTPUT_DIR}" ${pkgs} 2>&1 || true
    fi
  }

  log "下载 NVIDIA container toolkit 相关 rpm..."
  download_pkgs "${NVIDIA_PKGS}"

  shopt -s nullglob
  RPM_FILES=("${OUTPUT_DIR}"/*.rpm)
  PKG_COUNT="${#RPM_FILES[@]}"
  shopt -u nullglob

  if [ "${PKG_COUNT}" -eq 0 ]; then
    log "错误: 未下载到任何 NVIDIA 相关 RPM 包，请检查仓库与网络"
    exit 1
  fi

  log "下载完成！共 ${PKG_COUNT} 个 RPM 包"
  cat > "${OUTPUT_DIR}/README.txt" <<'RPM_EOF'
本目录为通过 YUM/DNF 源离线下载的 NVIDIA container toolkit 相关 rpm 包。

在离线 RPM 系节点（CentOS/Rocky）上使用示例：
  sudo yum localinstall -y ./*.rpm
或：
  sudo dnf install -y ./*.rpm
RPM_EOF

  exit 0
fi

log "错误: OS_TYPE=${OS_TYPE} 未在脚本内部支持（仅支持 ubuntu|centos|rocky|openeuler|kylin）"
exit 1
SCRIPT_EOF

chmod +x "${TMP_SCRIPT}"

log_info "拉取 Docker 镜像: ${DOCKER_IMAGE}"
${DOCKER_CMD} pull "${DOCKER_IMAGE}" || die "拉取镜像失败: ${DOCKER_IMAGE}"

log_info "启动容器并下载 NVIDIA container toolkit 包..."
log_info "（这可能需要几分钟，请耐心等待...）"

run_container() {
  ${DOCKER_CMD} run --rm \
    -v "${OUTPUT_DIR}:/output" \
    -v "${TMP_SCRIPT}:/download.sh:ro" \
    "${DOCKER_IMAGE}" \
    /bin/bash /download.sh "${OS_TYPE}" || {
    rm -f "${TMP_SCRIPT}"
    die "容器执行失败"
  }
}

if [ "${DOCKER_CMD}" = "podman" ]; then
  run_container
else
  if ${DOCKER_CMD} ps &>/dev/null; then
    run_container
  else
    log_warn "docker 可能需要 root，尝试 sudo..."
    sudo ${DOCKER_CMD} run --rm \
      -v "${OUTPUT_DIR}:/output" \
      -v "${TMP_SCRIPT}:/download.sh:ro" \
      "${DOCKER_IMAGE}" \
      /bin/bash /download.sh "${OS_TYPE}" || {
      rm -f "${TMP_SCRIPT}"
      die "容器执行失败（可尝试: sudo usermod -aG docker $USER）"
    }
  fi
fi

rm -f "${TMP_SCRIPT}"

shopt -s nullglob
if [ "${OS_TYPE}" = "ubuntu" ]; then
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
log_info "NVIDIA container toolkit 离线包下载完成"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "输出目录: ${OUTPUT_DIR}"
log_info "包数量: ${PKG_COUNT} (.${PKG_EXT})"
log_info "总大小: ${TOTAL_SIZE}"
log_info ""
log_info "下载的包列表:"
ls -lh "${OUTPUT_DIR}"/*.${PKG_EXT} 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || log_info "  （无）"
log_info ""
