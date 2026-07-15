#!/usr/bin/env bash
################################################################################
## Filename:    00-Download-tools-packages-docker.sh
## Description: 使用 Docker/Podman 容器下载常用工具离线安装包
## Usage:
##   bash 00-Download-tools-packages-docker.sh <os_id> <os_version> [输出目录]
## Examples:
##   bash 00-Download-tools-packages-docker.sh ubuntu 22.04 /data/download/packages/ubuntu/22.04/tools
##   bash 00-Download-tools-packages-docker.sh rocky 9.3 /data/download/packages/rocky/9.3/tools
##   bash 00-Download-tools-packages-docker.sh openeuler 24.03-lts-sp4 /data/download/packages/openeuler/24.03-lts-sp4/tools
##   bash 00-Download-tools-packages-docker.sh kylin v10-sp3 /data/download/packages/kylin/v10-sp3/tools
## Notes:
##   - 适用于没有对应 OS 环境的下载场景
################################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

OS_TYPE="${1:?请指定 os_id}"
OS_VERSION="${2:?请指定 os_version}"
platform_is_supported "${OS_TYPE}" "${OS_VERSION}" || die "不支持的平台: ${OS_TYPE}-${OS_VERSION}"
DOWNLOAD_OS_TYPE="${OS_TYPE}"
OUTPUT_DIR="${3:-$(artifact_get_os_tools_dir "${OS_TYPE}" "${OS_VERSION}")}"

DOCKER_IMAGE="$(platform_get_download_image "${OS_TYPE}" "${OS_VERSION}")"
REPO_CONFIG_DIR="${K8S_DEPLOY_ROOT}/config/package-repos"
[ -f "${REPO_CONFIG_DIR}/apply.sh" ] || die "未找到软件源配置应用脚本: ${REPO_CONFIG_DIR}/apply.sh"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "使用 Docker 容器下载常用工具离线安装包"
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

TMP_SCRIPT="/tmp/tools-download-$$.sh"
cat > "${TMP_SCRIPT}" <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

OS_TYPE="${1}"
OS_VERSION="${2}"
OUTPUT_DIR="/output"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

mkdir -p "${OUTPUT_DIR}"
source /repo-config/apply.sh
apply_package_repos "${OS_TYPE}" "${OS_VERSION}"

################################################################################
# Ubuntu/Debian：apt 下载 .deb
################################################################################
if [ "${OS_TYPE}" = "ubuntu" ]; then
  log "检测到 Ubuntu，使用 apt 下载 .deb 包..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true

  # 按工具「一个一个下载」：每个工具单独 apt-get install -d，只得到该工具及其真实依赖，再清缓存，避免依赖解析错乱
  # rsyslog / rsyslog-gnutls / logrotate / openssl：30-Deploy-rsyslog.sh
  # coreutils util-linux procps kmod gawk grep sed：04-Check-required-commands.sh 中部分 check_required 在极简/裁剪镜像上可能缺（iptables/ip6tables 随发行版基础环境提供，不单列）
  PRIMARY_TOOLS="vim git tmux net-tools curl wget iputils-ping dnsutils telnet lsof unzip rsync chrony sysstat netcat-openbsd strace tcpdump psmisc less file zip openssh-client screen mlocate iproute2 ethtool numactl bash-completion ca-certificates jq tree htop silversearcher-ag nfs-kernel-server coreutils util-linux procps kmod gawk grep sed rsyslog rsyslog-gnutls logrotate openssl"
  total_debs=0
  mkdir -p "${OUTPUT_DIR}/baseos"
  for tool in ${PRIMARY_TOOLS}; do
    log "下载工具: ${tool}（仅下载不安装）..."
    apt-get install -d -y "${tool}" 2>&1 || true
    mkdir -p "${OUTPUT_DIR}/${tool}"
    # 所有新下载的包统一汇总到 baseos，同时按工具分目录；baseos 目录可用于“先装基础依赖，再按需装工具”，方便完全离线环境
    cp -n /var/cache/apt/archives/*.deb "${OUTPUT_DIR}/baseos/" 2>/dev/null || true
    cp -n /var/cache/apt/archives/*.deb "${OUTPUT_DIR}/${tool}/" 2>/dev/null || true
    n=$(find "${OUTPUT_DIR}/${tool}" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
    if [ "${n}" -gt 0 ]; then
      echo "安装: sudo dpkg -i ${tool}/*.deb" > "${OUTPUT_DIR}/${tool}/README.txt"
      total_debs=$((total_debs + n))
      log "  ${tool}: ${n} 个包"
    else
      rmdir "${OUTPUT_DIR}/${tool}" 2>/dev/null || true
    fi
    rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true
  done
  if [ "${total_debs}" -eq 0 ]; then
    log "错误: 未下载到任何 .deb 包"
    exit 1
  fi
  log "下载完成！各工具子目录共 ${total_debs} 个 .deb（按工具分别存放）"
  cat > "${OUTPUT_DIR}/README.txt" <<'BYTOOL_EOF'
按工具分子目录，只装一个工具时进入对应目录执行即可。
例如只装 vim:   sudo dpkg -i vim/*.deb
例如只装 git:   sudo dpkg -i git/*.deb

如果是几乎“裸机”的离线环境，建议先安装 baseos 目录中的基础依赖：
  sudo dpkg -i baseos/*.deb || true
然后再按需进入各工具子目录补充安装。
BYTOOL_EOF
  log "子目录: $(ls -d ${OUTPUT_DIR}/*/ 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
  exit 0
fi

################################################################################
# RPM 系：yum/dnf 下载 .rpm
################################################################################
# 常用工具包（RPM 名）；nfs-utils 为 NFS 服务端/客户端
# rsyslog / rsyslog-gnutls / logrotate：30-Deploy-rsyslog.sh
# coreutils util-linux procps-ng kmod gawk grep sed：04-Check 在极简镜像上可能缺；iptables/ip6tables 由系统基础提供，不单列
TOOLS_BASE="
  vim-enhanced tmux net-tools curl wget iputils bind-utils telnet lsof
  unzip tar rsync chrony git sysstat nmap-ncat strace tcpdump psmisc
  less file zip openssh-clients screen mlocate iproute ethtool numactl
  bash-completion ca-certificates libcurl openssl zlib lua ncurses
  jq tree htop the_silver_searcher
  nfs-utils
  coreutils util-linux procps-ng kmod gawk grep sed
  rsyslog rsyslog-gnutls logrotate
"

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

if [ "${OS_TYPE}" = "rocky" ]; then
    log "Rocky: 尝试安装 libcurl（--allowerasing）以解决 libcurl-minimal 冲突，仅影响临时容器..."
    ${PKG_MGR} ${PKG_MGR_FLAGS}  install libcurl --allowerasing || true
    ${PKG_MGR} ${PKG_MGR_FLAGS}  install findutils --allowerasing || true
    ${PKG_MGR} ${PKG_MGR_FLAGS}  install epel-release || true
fi
if [ "${OS_TYPE}" = "openeuler" ]; then
    ${PKG_MGR} ${PKG_MGR_FLAGS}  install findutils --allowerasing || true
fi
if [ "${OS_TYPE}" = "centos" ]; then
    ${PKG_MGR} ${PKG_MGR_FLAGS} install  epel-release || true
fi

log "安装 yum-utils / dnf-plugins-core..."
${PKG_MGR} ${PKG_MGR_FLAGS} install yum-utils 2>/dev/null || \
${PKG_MGR} ${PKG_MGR_FLAGS} install dnf-plugins-core 2>/dev/null || true

${PKG_MGR} makecache || true

mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

log "待下载工具包（基础 + 扩展）..."

download_pkgs() {
  local pkgs="$1"
  local destdir="$2"
  if [ -z "${pkgs}" ]; then return 0; fi
  mkdir -p "${destdir}"
  if command -v yumdownloader &>/dev/null; then
    yumdownloader --resolve --destdir="${destdir}" ${pkgs} 2>&1 || true
  else
    dnf download --resolve --alldeps --arch=x86_64 --destdir="${destdir}" ${pkgs} 2>&1 || true
  fi
}

# 逐个下载基础包
# 这样即便 Rocky 9 下某个工具/依赖解析失败，也不会影响其它工具的下载结果。
log "逐个下载基础工具包..."
for tool in ${TOOLS_BASE}; do
  log "下载工具: ${tool}（含依赖，解析后下载）..."
  download_pkgs "${tool}" "${OUTPUT_DIR}/${tool}"
done

# 统计下载结果（RPM 在各工具目录内，不再集中在 OUTPUT_DIR 根目录）
PKG_COUNT=$(find "${OUTPUT_DIR}" -maxdepth 2 -name "*.rpm" 2>/dev/null | wc -l)
if [ "${PKG_COUNT}" -eq 0 ]; then
  log "警告: 未下载到任何 RPM 包（可能镜像超时/网络问题）。继续执行以避免整体流程失败。"
else
  log "下载完成！共 ${PKG_COUNT} 个 RPM 包（已按工具目录存放）"
fi

# 提供 baseos（基础依赖全集），便于离线环境先批量安装
rm -rf "${OUTPUT_DIR}/baseos" 2>/dev/null || true
mkdir -p "${OUTPUT_DIR}/baseos"
for f in "${OUTPUT_DIR}"/*/*.rpm; do
  [ -f "$f" ] || continue
  cp -n "$f" "${OUTPUT_DIR}/baseos/" 2>/dev/null || true
done

cat > "${OUTPUT_DIR}/README.txt" <<'RPMTOOL_EOF'
按工具分好的子目录，只装一个工具时进入对应目录执行即可。
例如只装 vim: sudo rpm -ivh vim-enhanced/*.rpm 或 sudo yum localinstall vim-enhanced/*.rpm
例如只装 git: sudo rpm -ivh git/*.rpm

如果是几乎“裸机”的离线环境，建议：
  1. 先安装 baseos 目录中的基础依赖：
       sudo rpm -ivh baseos/*.rpm || sudo yum localinstall baseos/*.rpm
  2. 再按需进入各工具子目录补充安装对应工具：
       cd <工具名> && sudo rpm -ivh *.rpm
RPMTOOL_EOF
log "子目录: $(for d in "${OUTPUT_DIR}"/*/; do [ -d "$d" ] || continue; basename "$d"; done | tr '\n' ' ' || true)"
SCRIPT_EOF

chmod +x "${TMP_SCRIPT}"

log_info "拉取 Docker 镜像: ${DOCKER_IMAGE}"
${DOCKER_CMD} pull "${DOCKER_IMAGE}" || die "拉取镜像失败: ${DOCKER_IMAGE}"

log_info "启动容器并下载工具包..."
log_info "（这可能需要几分钟，请耐心等待...）"

run_container() {
  ${DOCKER_CMD} run --rm --platform linux/amd64 \
    -v "${OUTPUT_DIR}:/output" \
    -v "${TMP_SCRIPT}:/download.sh:ro" \
    -v "${REPO_CONFIG_DIR}:/repo-config:ro" \
    "${DOCKER_IMAGE}" \
    /bin/bash /download.sh "${DOWNLOAD_OS_TYPE}" "${OS_VERSION}" || {
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
      /bin/bash /download.sh "${DOWNLOAD_OS_TYPE}" "${OS_VERSION}" || {
      rm -f "${TMP_SCRIPT}"
      die "容器执行失败（可尝试: sudo usermod -aG docker $USER）"
    }
  fi
fi

rm -f "${TMP_SCRIPT}"

shopt -s nullglob
if [ "${OS_TYPE}" = "ubuntu" ]; then
  PKG_EXT="deb"
  PKG_COUNT=$(find "${OUTPUT_DIR}" -maxdepth 2 -name "*.deb" 2>/dev/null | wc -l)
else
  PKG_EXT="rpm"
  PKG_COUNT=$(find "${OUTPUT_DIR}" -maxdepth 2 -name "*.rpm" 2>/dev/null | wc -l)
fi
shopt -u nullglob
TOTAL_SIZE=$(du -sh "${OUTPUT_DIR}" 2>/dev/null | awk '{print $1}' || echo "未知")

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "下载完成！"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "输出目录: ${OUTPUT_DIR}"
log_info "包数量: ${PKG_COUNT} (.${PKG_EXT}，按工具分子目录存放)"
log_info "总大小: ${TOTAL_SIZE}"
log_info ""
log_info "子目录（每目录仅含该工具及其依赖）:"
for d in "${OUTPUT_DIR}"/*/; do
  [ -d "$d" ] || continue
  if [ "${OS_TYPE}" = "ubuntu" ]; then
    n=$(find "$d" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
    suffix=".deb"
  else
    n=$(find "$d" -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l)
    suffix=".rpm"
  fi
  log_info "  $(basename "$d")/: ${n} 个 ${suffix}"
done
log_info ""
if [ "${OS_TYPE}" = "ubuntu" ]; then
  log_info "下一步：cd ${OUTPUT_DIR} && sudo dpkg -i <工具名>/*.deb（如 vim/*.deb、nfs-kernel-server/*.deb）"
else
  log_info "下一步："
  log_info "  - 只装单个工具：cd ${OUTPUT_DIR} && sudo rpm -ivh vim-enhanced/*.rpm 或 git/*.rpm 等"
  log_info "  - 全装：根据需要依次进入各工具子目录，批量安装 *.rpm"
fi
