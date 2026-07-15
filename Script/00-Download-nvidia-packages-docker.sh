#!/usr/bin/env bash
################################################################################
## Filename:    00-Download-nvidia-packages-docker.sh
## Description: 使用 Docker/Podman 容器下载 NVIDIA container toolkit 离线安装包
## Usage:
##   bash 00-Download-nvidia-packages-docker.sh <os_id> <os_version> [输出目录]
## Examples:
##   bash 00-Download-nvidia-packages-docker.sh ubuntu 22.04 /data/download/nvidia/ubuntu/22.04
##   bash 00-Download-nvidia-packages-docker.sh rocky 9.3 /data/download/nvidia/rocky/9.3
##   bash 00-Download-nvidia-packages-docker.sh openeuler 24.03-lts-sp4 /data/download/nvidia/openeuler/24.03-lts-sp4
##   bash 00-Download-nvidia-packages-docker.sh kylin v10-sp3 /data/download/nvidia/kylin/v10-sp3
## Notes:
##   - 适用于没有对应 OS 环境、但需要提前准备 deb/rpm 离线包的场景
##   - RPM 系（含 openeuler/kylin）使用 NVIDIA stable/rpm 通用仓库，版本固定 1.17.8-1
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

OS_TYPE="${1:?请指定 os_id}"
OS_VERSION="${2:?请指定 os_version}"
platform_is_supported "${OS_TYPE}" "${OS_VERSION}" || die "不支持的平台: ${OS_TYPE}-${OS_VERSION}"
OUTPUT_DIR="${3:-$(artifact_get_nvidia_toolkit_dir "${OS_TYPE}" "${OS_VERSION}")}"

DOCKER_IMAGE="$(platform_get_download_image "${OS_TYPE}" "${OS_VERSION}")"
REPO_CONFIG_DIR="${K8S_DEPLOY_ROOT}/config/package-repos"
[ -f "${REPO_CONFIG_DIR}/apply.sh" ] || die "未找到软件源配置应用脚本: ${REPO_CONFIG_DIR}/apply.sh"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "使用 Docker 容器下载 NVIDIA container toolkit 离线安装包"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "目标平台: ${OS_TYPE}-${OS_VERSION}"
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
OS_VERSION="${2}"
OUTPUT_DIR="/output"
source /repo-config/nvidia/stable/repositories.env

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

mkdir -p "${OUTPUT_DIR}"
source /repo-config/apply.sh
apply_package_repos "${OS_TYPE}" "${OS_VERSION}"

################################################################################
# Ubuntu：apt 下载 NVIDIA container toolkit 相关 deb
################################################################################
if [ "${OS_TYPE}" = "ubuntu" ]; then
  log "检测到 Ubuntu，使用 apt 下载 nvidia-container-toolkit 相关 deb..."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y curl ca-certificates gnupg lsb-release || true

  log "配置 NVIDIA libnvidia-container 通用 APT 源..."
  mkdir -p /usr/share/keyrings
  curl -fsSL "${NVIDIA_APT_KEY_URL}" | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL "${NVIDIA_APT_LIST_URL}" \
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

  ${PKG_MGR} ${PKG_MGR_FLAGS} install -y curl ca-certificates || true

  # 对于 RPM 系发行版，官方推荐使用通用 stable 仓库
  log "配置 NVIDIA libnvidia-container YUM/DNF 源 (stable/rpm)..."
  curl -fsSL "${NVIDIA_RPM_REPO_URL}" \
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

  # 下载固定版本的 toolkit 包及其全部 RPM 依赖，确保可严格离线安装。
  download_pkgs() {
    local pkgs="$1"
    if [ -z "${pkgs}" ]; then
      return 0
    fi
    if command -v yumdownloader &>/dev/null; then
      yumdownloader --resolve --archlist=x86_64,noarch --setopt=exactarch=1 --exclude='*.i?86' --destdir="${OUTPUT_DIR}" ${pkgs} 2>&1 || true
    else
      dnf download --resolve --alldeps --arch=x86_64,noarch --exclude='*.i?86' --destdir="${OUTPUT_DIR}" ${pkgs} 2>&1 || true
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
  ${DOCKER_CMD} run --rm --platform linux/amd64 \
    -v "${OUTPUT_DIR}:/output" \
    -v "${TMP_SCRIPT}:/download.sh:ro" \
    -v "${REPO_CONFIG_DIR}:/repo-config:ro" \
    "${DOCKER_IMAGE}" \
    /bin/bash /download.sh "${OS_TYPE}" "${OS_VERSION}" || {
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
    sudo ${DOCKER_CMD} run --rm --platform linux/amd64 \
      -v "${OUTPUT_DIR}:/output" \
      -v "${TMP_SCRIPT}:/download.sh:ro" \
      -v "${REPO_CONFIG_DIR}:/repo-config:ro" \
      "${DOCKER_IMAGE}" \
      /bin/bash /download.sh "${OS_TYPE}" "${OS_VERSION}" || {
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
if [ "${PKG_COUNT}" -gt 0 ]; then
  for pkg in "${HOST_PKG_FILES[@]}"; do
    size="$(du -h "${pkg}" | awk '{print $1}')"
    log_info "  ${pkg} (${size})"
  done
else
  log_info "  （无）"
fi
log_info ""
