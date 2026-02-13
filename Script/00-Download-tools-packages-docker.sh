#!/usr/bin/env bash
set -euo pipefail

# 使用 Docker 容器下载常用工具离线安装包（适用于没有对应 OS 环境的情况） 可选
# 用法：
#   bash 00-Download-tools-packages-docker.sh [centos|rocky|almalinux|rhel|openeuler|kylin|ubuntu] [输出目录]
#
# 示例：
#   bash 00-Download-tools-packages-docker.sh centos /data/download/packages/centos/tools
#   bash 00-Download-tools-packages-docker.sh ubuntu /data/download/packages/ubuntu/tools

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

OS_TYPE="${1:-centos}"
OUTPUT_DIR="${2:-/data/download/packages/${OS_TYPE}/tools}"

# Docker 镜像映射（RPM 系与 00-Download-k8s-packages-docker.sh 一致；ubuntu 为官方镜像）
declare -A DOCKER_IMAGES=(
  ["centos"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:centos-7"
  ["rocky"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:rockylinux-8"
  ["almalinux"]="almalinux:8"
  ["rhel"]="redhat/ubi8:latest"
  ["openeuler"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:openeuler-22.03"
  ["kylin"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:kylin-v10-sp3-2403"
  ["ubuntu"]="registry.cn-hangzhou.aliyuncs.com/liwenjian123/test:ubuntu-22.04"
)

if [ -z "${DOCKER_IMAGES[${OS_TYPE}]:-}" ]; then
  die "不支持的 OS_TYPE: ${OS_TYPE}。支持: centos|rocky|almalinux|rhel|openeuler|kylin|ubuntu"
fi

DOCKER_IMAGE="${DOCKER_IMAGES[${OS_TYPE}]}"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "使用 Docker 容器下载常用工具离线安装包"
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

TMP_SCRIPT="/tmp/tools-download-$$.sh"
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
# Ubuntu/Debian：apt 下载 .deb
################################################################################
if [ "${OS_TYPE}" = "ubuntu" ]; then
  log "检测到 Ubuntu，使用 apt 下载 .deb 包..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true

  # Ubuntu/Debian 包名（与 RPM 系对应）
  TOOLS_APT="
    vim tmux net-tools curl wget iputils-ping dnsutils telnet lsof
    unzip tar rsync chrony git sysstat netcat-openbsd strace tcpdump psmisc
    less file zip openssh-client screen mlocate iproute2 ethtool numactl
    bash-completion ca-certificates jq tree htop silversearcher-ag
  "
  log "下载工具包（仅下载不安装）..."
  apt-get install -d -y ${TOOLS_APT} 2>&1 || true
  cp -n /var/cache/apt/archives/*.deb "${OUTPUT_DIR}/" 2>/dev/null || true
  rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true

  shopt -s nullglob
  DEB_FILES=("${OUTPUT_DIR}"/*.deb)
  PKG_COUNT="${#DEB_FILES[@]}"
  shopt -u nullglob
  if [ "${PKG_COUNT}" -eq 0 ]; then
    log "错误: 未下载到任何 .deb 包"
    exit 1
  fi
  log "下载完成！共 ${PKG_COUNT} 个 .deb 包"

  # 按“单个工具”分子目录，便于只装 vim 或只装 git 等（直接放在输出目录下 vim/ git/ ...）
  PRIMARY_TOOLS="vim git tmux net-tools curl wget iputils-ping dnsutils telnet lsof unzip rsync chrony sysstat netcat-openbsd strace tcpdump psmisc less file zip openssh-client screen mlocate iproute2 ethtool numactl bash-completion ca-certificates jq tree htop silversearcher-ag"
  log "按工具分子目录（vim/ git/ ...）..."
  for f in "${OUTPUT_DIR}"/*.deb; do
    [ -f "$f" ] || continue
    pkg=$(dpkg-deb -f "$f" Package 2>/dev/null) || continue
    echo "$f" >> "${OUTPUT_DIR}/.pkg-to-file.${pkg}"
  done
  for tool in ${PRIMARY_TOOLS}; do
    [ -d "${OUTPUT_DIR}/${tool}" ] && rm -rf "${OUTPUT_DIR}/${tool}"
    mkdir -p "${OUTPUT_DIR}/${tool}"
    deps=$(apt-cache depends --recurse --no-recommends --no-suggests "$tool" 2>/dev/null | awk '/^[a-zA-Z0-9]/ {print $1}' | sort -u) || true
    copied=0
    for dep in $deps; do
      list="${OUTPUT_DIR}/.pkg-to-file.${dep}"
      if [ -f "$list" ]; then
        while IFS= read -r path; do
          [ -f "$path" ] && cp -n "$path" "${OUTPUT_DIR}/${tool}/" 2>/dev/null && copied=$((copied+1))
        done < "$list"
      fi
    done
    if [ "$copied" -gt 0 ]; then
      echo "安装: sudo dpkg -i ${tool}/*.deb" > "${OUTPUT_DIR}/${tool}/README.txt"
      log "  ${tool}: ${copied} 个包"
    else
      rmdir "${OUTPUT_DIR}/${tool}" 2>/dev/null || true
    fi
  done
  rm -f "${OUTPUT_DIR}"/.pkg-to-file.* 2>/dev/null || true
  cat > "${OUTPUT_DIR}/README.txt" <<'BYTOOL_EOF'
按工具分好的子目录，只装一个工具时进入对应目录执行即可。
例如只装 vim:   sudo dpkg -i vim/*.deb
例如只装 git:  sudo dpkg -i git/*.deb
BYTOOL_EOF
  log "子目录: $(ls -d ${OUTPUT_DIR}/*/ 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
  exit 0
fi

################################################################################
# RPM 系：yum/dnf 下载 .rpm
################################################################################
# 常用工具包（RPM 名）
TOOLS_BASE="
  vim-enhanced tmux net-tools curl wget iputils bind-utils telnet lsof
  unzip tar rsync chrony git sysstat nmap-ncat strace tcpdump psmisc
  less file zip openssh-clients screen mlocate iproute ethtool numactl
  bash-completion ca-certificates libcurl openssl zlib lua ncurses
"

TOOLS_EXTRA="
  jq tree htop the_silver_searcher
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

# CentOS 7 已 EOL，配置 vault 与 EPEL
if [ -f /etc/centos-release ]; then
  CENTOS_VERSION=$(rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides /etc/redhat-release) 2>/dev/null || echo "7")
  if [ "${CENTOS_VERSION}" = "7" ]; then
    log "检测到 CentOS 7，配置镜像源与 EPEL..."
    mkdir -p /etc/yum.repos.d/backup
    mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
    cat > /etc/yum.repos.d/CentOS-Base.repo <<'REPO_EOF'
[base]
name=CentOS-$releasever - Base
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-$releasever - Updates
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-$releasever - Extras
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
REPO_EOF
    # EPEL for CentOS 7 (jq, tree, htop)
    if ! rpm -q epel-release &>/dev/null; then
      log "安装 EPEL 源..."
      curl -sL -o /tmp/epel-release.rpm \
        https://mirrors.aliyun.com/epel/epel-release-latest-7.noarch.rpm || \
        curl -sL -o /tmp/epel-release.rpm \
        https://download.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
      rpm -ivh /tmp/epel-release.rpm || true
      sed -i 's|^#*baseurl=.*epel|baseurl=https://mirrors.aliyun.com/epel|' /etc/yum.repos.d/epel*.repo 2>/dev/null || true
      sed -i 's|^mirrorlist=|#mirrorlist=|' /etc/yum.repos.d/epel*.repo 2>/dev/null || true
    fi
    log "CentOS 7 镜像源与 EPEL 配置完成"
  fi
fi

# Rocky/AlmaLinux/RHEL 8：确保 EPEL 可用（可选，用于 jq/tree/htop）
if command -v dnf &>/dev/null; then
  case "${OS_TYPE}" in
    rocky|almalinux|rhel|centos)
      if ! rpm -q epel-release &>/dev/null; then
        log "尝试启用 EPEL..."
        dnf install -y epel-release || true
      fi
      ;;
  esac
fi

log "安装 yum-utils / dnf-plugins-core..."
${PKG_MGR} ${PKG_MGR_FLAGS} install -y yum-utils 2>/dev/null || \
  ${PKG_MGR} ${PKG_MGR_FLAGS} install -y dnf-plugins-core 2>/dev/null || true

${PKG_MGR} makecache || true

mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

log "待下载工具包（基础 + 扩展）..."

download_pkgs() {
  local pkgs="$1"
  if [ -z "${pkgs}" ]; then return 0; fi
  if command -v yumdownloader &>/dev/null; then
    yumdownloader --resolve --destdir="${OUTPUT_DIR}" ${pkgs} 2>&1 || true
  else
    dnf download --resolve --alldeps --arch=x86_64 --destdir="${OUTPUT_DIR}" ${pkgs} 2>&1 || true
  fi
}

# 先下载基础包
log "下载基础工具包..."
download_pkgs "${TOOLS_BASE}"

# 再下载扩展包（可能部分不存在，忽略失败）
log "下载扩展包（jq/tree/htop 等）..."
download_pkgs "${TOOLS_EXTRA}"

shopt -s nullglob
RPM_FILES=(*.rpm)
PKG_COUNT="${#RPM_FILES[@]}"
shopt -u nullglob

if [ "${PKG_COUNT}" -eq 0 ]; then
  log "错误: 未下载到任何 RPM 包，请检查仓库与网络"
  exit 1
fi

log "下载完成！共 ${PKG_COUNT} 个 RPM 包"

# 按“单个工具”分子目录（vim-enhanced/ git/ ...），与 Ubuntu 一致
PRIMARY_TOOLS_RPM="vim-enhanced tmux net-tools curl wget iputils bind-utils telnet lsof unzip rsync chrony git sysstat nmap-ncat strace tcpdump psmisc less file zip openssh-clients screen mlocate iproute ethtool numactl bash-completion ca-certificates jq tree htop the_silver_searcher"
log "按工具分子目录（vim-enhanced/ git/ ...）..."
for f in "${OUTPUT_DIR}"/*.rpm; do
  [ -f "$f" ] || continue
  pkg=$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null) || continue
  echo "$f" >> "${OUTPUT_DIR}/.pkg-to-file.${pkg}"
done
for tool in ${PRIMARY_TOOLS_RPM}; do
  [ -d "${OUTPUT_DIR}/${tool}" ] && rm -rf "${OUTPUT_DIR}/${tool}"
  mkdir -p "${OUTPUT_DIR}/${tool}"
  if command -v dnf &>/dev/null; then
    deps=$(dnf repoquery -q --resolve --recursive --requires "$tool" 2>/dev/null | sort -u) || true
  else
    deps=$(repoquery -q -R --recursive "$tool" 2>/dev/null | sort -u || repoquery -q -R "$tool" 2>/dev/null | sort -u) || true
  fi
  deps="$tool $deps"
  copied=0
  for dep in $deps; do
    list="${OUTPUT_DIR}/.pkg-to-file.${dep}"
    if [ -f "$list" ]; then
      while IFS= read -r path; do
        [ -f "$path" ] && cp -n "$path" "${OUTPUT_DIR}/${tool}/" 2>/dev/null && copied=$((copied+1))
      done < "$list"
    fi
  done
  if [ "$copied" -gt 0 ]; then
    echo "安装: sudo rpm -ivh ${tool}/*.rpm 或 sudo yum localinstall ${tool}/*.rpm" > "${OUTPUT_DIR}/${tool}/README.txt"
    log "  ${tool}: ${copied} 个包"
  else
    rmdir "${OUTPUT_DIR}/${tool}" 2>/dev/null || true
  fi
done
rm -f "${OUTPUT_DIR}"/.pkg-to-file.* 2>/dev/null || true
cat > "${OUTPUT_DIR}/README.txt" <<'RPMTOOL_EOF'
按工具分好的子目录，只装一个工具时进入对应目录执行即可。
例如只装 vim: sudo rpm -ivh vim-enhanced/*.rpm 或 sudo yum localinstall vim-enhanced/*.rpm
例如只装 git: sudo rpm -ivh git/*.rpm
RPMTOOL_EOF
log "子目录: $(ls -d ${OUTPUT_DIR}/*/ 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"

ls -lh *.rpm 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || true
SCRIPT_EOF

chmod +x "${TMP_SCRIPT}"

log_info "拉取 Docker 镜像: ${DOCKER_IMAGE}"
${DOCKER_CMD} pull "${DOCKER_IMAGE}" || die "拉取镜像失败: ${DOCKER_IMAGE}"

log_info "启动容器并下载工具包..."
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
log_info "下载完成！"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "输出目录: ${OUTPUT_DIR}"
log_info "包数量: ${PKG_COUNT} (.${PKG_EXT})"
log_info "总大小: ${TOTAL_SIZE}"
log_info ""
log_info "下载的包列表:"
ls -lh "${OUTPUT_DIR}"/*.${PKG_EXT} 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || log_info "  （无）"
log_info ""
if [ "${OS_TYPE}" = "ubuntu" ]; then
  log_info "下一步："
  log_info "  - 只装单个工具：cd ${OUTPUT_DIR} && sudo dpkg -i vim/*.deb 或 git/*.deb 等"
  log_info "  - 全装：将 ${OUTPUT_DIR} 复制到离线环境后 sudo dpkg -i *.deb 或 apt install ./*.deb"
else
  log_info "下一步："
  log_info "  - 只装单个工具：cd ${OUTPUT_DIR} && sudo rpm -ivh vim-enhanced/*.rpm 或 git/*.rpm 等"
  log_info "  - 全装：将 ${OUTPUT_DIR} 复制到离线环境后 sudo yum/dnf localinstall *.rpm 或 rpm -ivh *.rpm"
fi
