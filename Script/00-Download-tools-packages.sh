#!/usr/bin/env bash
set -euo pipefail

# 在**当前宿主机**上下载常用工具离线包（deb/rpm），不依赖 Docker；仅下载保存，不安装工具到系统。
# 用法：
#   bash 00-Download-tools-packages.sh [ubuntu|debian|centos|rocky|openeuler|kylin] [输出目录]
#
# 示例：
#   bash 00-Download-tools-packages.sh ubuntu /data/download/packages/ubuntu/tools
#   bash 00-Download-tools-packages.sh rocky /data/download/packages/rocky/tools
#
# 说明：需在**与目标离线环境相同或兼容的发行版**上执行（以便 yum/dnf/apt 解析依赖）。
#       可能为解析依赖而安装本机上的少量组件（如 epel-release、yum-utils），与 00-Download-tools-packages-docker.sh 在容器内的行为类似。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/framework.sh"

detect_os

OS_TYPE="${1:-${OS_ID}}"
OS_TYPE_LC="$(echo "${OS_TYPE}" | tr '[:upper:]' '[:lower:]')"
OUTPUT_DIR="${2:-}"

if [ -z "${OUTPUT_DIR}" ]; then
  case "${OS_TYPE_LC}" in
    ubuntu|debian)
      OUTPUT_DIR="/data/download/packages/ubuntu/tools"
      ;;
    centos)
      OUTPUT_DIR="/data/download/packages/centos/tools"
      ;;
    rocky)
      OUTPUT_DIR="/data/download/packages/rocky/tools"
      ;;
    openeuler)
      OUTPUT_DIR="/data/download/packages/openeuler/tools"
      ;;
    *)
      if [[ "${OS_TYPE_LC}" == *kylin* ]]; then
        OUTPUT_DIR="/data/download/packages/kylin/tools"
      else
        die "不支持的 OS 类型: ${OS_TYPE}（无法推断默认输出目录）。请显式传入输出目录，或使用 ubuntu|debian|centos|rocky|openeuler|kylin"
      fi
      ;;
  esac
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  die "请用 root 执行本脚本（例如: sudo bash 00-Download-tools-packages.sh ...），以便 apt/yum 使用软件源与缓存。"
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "下载常用工具离线安装包（本机 yum/dnf/apt，无 Docker）"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "OS 类型: ${OS_TYPE}（匹配用: ${OS_TYPE_LC}）"
log_info "输出目录: ${OUTPUT_DIR}"
log_info ""

mkdir -p "${OUTPUT_DIR}"
# 历史版本曾生成 baseos，本脚本已不再使用；清理残留以免误导
rm -rf "${OUTPUT_DIR}/baseos" 2>/dev/null || true

# 与 00-Download-tools-packages-docker.sh 中 PRIMARY_TOOLS 一致
PRIMARY_TOOLS="vim git tmux net-tools curl wget iputils-ping dnsutils telnet lsof unzip rsync chrony sysstat netcat-openbsd strace tcpdump psmisc less file zip openssh-client screen mlocate iproute2 ethtool numactl bash-completion ca-certificates jq tree htop silversearcher-ag nfs-kernel-server coreutils util-linux procps kmod gawk grep sed rsyslog rsyslog-gnutls logrotate openssl"

ubuntu_copy_archives_to() {
  local dest="$1"
  mkdir -p "${dest}"
  local deb
  shopt -s nullglob
  for deb in /var/cache/apt/archives/*.deb; do
    cp -n "${deb}" "${dest}/" 2>/dev/null || cp "${deb}" "${dest}/" 2>/dev/null || true
  done
  shopt -u nullglob
}

ubuntu_clear_archives() {
  rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true
}

download_ubuntu_tools() {
  log_info "使用 apt 下载 .deb（仅下载，不安装到系统；按工具分子目录，无 baseos）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true

  local total_debs=0
  local tool n
  local -a failed_tools=()

  for tool in ${PRIMARY_TOOLS}; do
    log_info "下载工具: ${tool}..."
    mkdir -p "${OUTPUT_DIR}/${tool}"
    ubuntu_clear_archives

    apt-get install -d -y "${tool}" 2>&1 || true
    ubuntu_copy_archives_to "${OUTPUT_DIR}/${tool}"
    ubuntu_clear_archives

    n=$(find "${OUTPUT_DIR}/${tool}" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
    if [ "${n}" -eq 0 ]; then
      log_info "  ${tool}: 首次无缓存，尝试 --reinstall -d（已安装包也会拉取 .deb）..."
      apt-get install -d -y --reinstall "${tool}" 2>&1 || true
      ubuntu_copy_archives_to "${OUTPUT_DIR}/${tool}"
      ubuntu_clear_archives
      n=$(find "${OUTPUT_DIR}/${tool}" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
    fi
    if [ "${n}" -eq 0 ]; then
      log_info "  ${tool}: 尝试 apt-get download（主包，依赖可能不全）..."
      (cd "${OUTPUT_DIR}/${tool}" && apt-get download "${tool}" 2>&1) || true
      n=$(find "${OUTPUT_DIR}/${tool}" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
    fi

    if [ "${n}" -gt 0 ]; then
      echo "安装: sudo dpkg -i ${tool}/*.deb" > "${OUTPUT_DIR}/${tool}/README.txt"
      total_debs=$((total_debs + n))
      log_info "  ${tool}: ${n} 个包"
    else
      failed_tools+=("${tool}")
      log_warn "  ${tool}: 未下载到任何 .deb"
      rmdir "${OUTPUT_DIR}/${tool}" 2>/dev/null || true
    fi
  done

  if [ "${total_debs}" -eq 0 ]; then
    die "未下载到任何 .deb 包"
  fi
  if [ "${#failed_tools[@]}" -gt 0 ]; then
    log_warn "以下工具未成功落盘（请检查网络与软件源）: ${failed_tools[*]}"
  fi

  cat > "${OUTPUT_DIR}/README.txt" <<'BYTOOL_EOF'
每个子目录对应一类工具及其依赖 .deb，按需进入目录安装即可。
例如只装 vim:   sudo dpkg -i vim/*.deb
例如只装 git:   sudo dpkg -i git/*.deb

若 dpkg 报依赖缺失，先安装该工具目录内全部 .deb；仍缺则再装相关工具目录中的包。
BYTOOL_EOF
  log_info "✓ Ubuntu/Debian 包下载完成: ${OUTPUT_DIR}"
}

# 与 00-Download-tools-packages-docker.sh 中 TOOLS_BASE 一致
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

download_pkgs_rpm() {
  local pkgs="$1"
  local destdir="$2"
  if [ -z "${pkgs}" ]; then return 0; fi
  mkdir -p "${destdir}"
  if command -v yumdownloader &>/dev/null; then
    # shellcheck disable=SC2086 # 故意对 ${pkgs} 分词，以支持多个包名参数
    yumdownloader --resolve --destdir="${destdir}" ${pkgs} 2>&1 || true
  else
    # shellcheck disable=SC2086
    dnf download --resolve --alldeps --arch=x86_64 --destdir="${destdir}" ${pkgs} 2>&1 || true
  fi
}

download_rpm_tools() {
  local PKG_MGR PKG_MGR_FLAGS tool PKG_COUNT

  log_info "使用 yum/dnf 下载 .rpm（含依赖，仅保存到输出目录）..."

  if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    PKG_MGR_FLAGS="-y"
  elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
    PKG_MGR_FLAGS="-y"
  else
    die "未找到 dnf 或 yum"
  fi

  if [ -f /etc/centos-release ]; then
    local CENTOS_VERSION
    CENTOS_VERSION=$(rpm -q --qf "%{VERSION}" "$(rpm -q --whatprovides /etc/redhat-release 2>/dev/null)" 2>/dev/null || echo "7")
    if [ "${CENTOS_VERSION}" = "7" ]; then
      log_info "检测到 CentOS 7，配置 vault 与 EPEL（仅用于本次下载）..."
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
      if ! rpm -q epel-release &>/dev/null; then
        log_info "安装 EPEL 源（本机）..."
        if command -v curl &>/dev/null; then
          curl -sL -o /tmp/epel-release.rpm \
            https://mirrors.aliyun.com/epel/epel-release-latest-7.noarch.rpm || \
            curl -sL -o /tmp/epel-release.rpm \
              https://download.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
        elif command -v wget &>/dev/null; then
          wget -q -O /tmp/epel-release.rpm \
            https://mirrors.aliyun.com/epel/epel-release-latest-7.noarch.rpm || true
        fi
        if [ -f /tmp/epel-release.rpm ]; then
          rpm -ivh /tmp/epel-release.rpm || true
          sed -i 's|^#*baseurl=.*epel|baseurl=https://mirrors.aliyun.com/epel|' /etc/yum.repos.d/epel*.repo 2>/dev/null || true
          sed -i 's|^mirrorlist=|#mirrorlist=|' /etc/yum.repos.d/epel*.repo 2>/dev/null || true
        fi
      fi
    fi
  fi

  if [ "${OS_TYPE_LC}" = "rocky" ]; then
    log_info "Rocky: 尝试安装 libcurl/findutils/epel-release（本机，便于依赖解析）..."
    ${PKG_MGR} ${PKG_MGR_FLAGS} install libcurl --allowerasing 2>/dev/null || true
    ${PKG_MGR} ${PKG_MGR_FLAGS} install findutils --allowerasing 2>/dev/null || true
    ${PKG_MGR} ${PKG_MGR_FLAGS} install epel-release 2>/dev/null || true
  fi
  if [ "${OS_TYPE_LC}" = "openeuler" ]; then
    ${PKG_MGR} ${PKG_MGR_FLAGS} install findutils --allowerasing 2>/dev/null || true
  fi
  if [ "${OS_TYPE_LC}" = "centos" ]; then
    ${PKG_MGR} ${PKG_MGR_FLAGS} install epel-release 2>/dev/null || true
  fi

  log_info "安装 yum-utils / dnf-plugins-core（本机，若尚未安装）..."
  ${PKG_MGR} ${PKG_MGR_FLAGS} install yum-utils 2>/dev/null || \
    ${PKG_MGR} ${PKG_MGR_FLAGS} install dnf-plugins-core 2>/dev/null || true

  ${PKG_MGR} makecache 2>/dev/null || true

  log_info "逐个下载基础工具包..."
  for tool in ${TOOLS_BASE}; do
    log_info "下载工具: ${tool}..."
    download_pkgs_rpm "${tool}" "${OUTPUT_DIR}/${tool}"
  done

  PKG_COUNT=$(find "${OUTPUT_DIR}" -maxdepth 2 -name "*.rpm" 2>/dev/null | wc -l)
  if [ "${PKG_COUNT}" -eq 0 ]; then
    log_warn "未下载到任何 RPM 包（请检查网络与仓库配置）"
  else
    log_info "共 ${PKG_COUNT} 个 RPM 包（按工具目录存放，无 baseos）"
  fi

  cat > "${OUTPUT_DIR}/README.txt" <<'RPMTOOL_EOF'
每个子目录对应一类工具及其依赖 .rpm，按需进入目录安装即可。
例如只装 vim: sudo rpm -ivh vim-enhanced/*.rpm 或 sudo yum localinstall vim-enhanced/*.rpm
例如只装 git: sudo rpm -ivh git/*.rpm

若 rpm 报依赖缺失，在同一工具目录内应已包含解析时拉取的依赖；仍缺时再装相关工具子目录中的包。
RPMTOOL_EOF
  log_info "✓ RPM 包下载完成: ${OUTPUT_DIR}"
}

case "${OS_TYPE_LC}" in
  ubuntu|debian)
    download_ubuntu_tools
    ;;
  centos|rocky|openeuler)
    download_rpm_tools
    ;;
  *)
    if [[ "${OS_TYPE_LC}" == *kylin* ]]; then
      download_rpm_tools
    else
      die "不支持的 OS 类型: ${OS_TYPE}。支持: ubuntu|debian|centos|rocky|openeuler|kylin（及 ID 含 kylin 的系统）"
    fi
    ;;
esac

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "下载完成！"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "输出目录: ${OUTPUT_DIR}"
if [ "${OS_TYPE_LC}" = "ubuntu" ] || [ "${OS_TYPE_LC}" = "debian" ]; then
  log_info "包数量（约）: $(find "${OUTPUT_DIR}" -maxdepth 2 -name '*.deb' 2>/dev/null | wc -l) .deb"
else
  log_info "包数量（约）: $(find "${OUTPUT_DIR}" -maxdepth 2 -name '*.rpm' 2>/dev/null | wc -l) .rpm"
fi
log_info "总大小: $(du -sh "${OUTPUT_DIR}" 2>/dev/null | awk '{print $1}' || echo 未知)"
log_info ""
log_info "下一步：将 ${OUTPUT_DIR} 复制到离线环境后，按目录内 README.txt 安装。"
