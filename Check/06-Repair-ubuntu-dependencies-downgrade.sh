#!/usr/bin/env bash
################################################################################
## Filename:    06-Repair-ubuntu-dependencies-downgrade.sh
## Description: 检测并修复 Ubuntu 离线环境中的精确版本依赖冲突
## Usage:
##   bash 06-Repair-ubuntu-dependencies-downgrade.sh detect /tmp/apt-repair-packages.txt
##   bash 06-Repair-ubuntu-dependencies-downgrade.sh download /tmp/apt-repair-packages.txt /tmp/apt-repair-debs
##   bash 06-Repair-ubuntu-dependencies-downgrade.sh install /tmp/apt-repair-debs
## Examples:
##   bash 06-Repair-ubuntu-dependencies-downgrade.sh detect /tmp/ubuntu-apt-repair.txt
##   bash 06-Repair-ubuntu-dependencies-downgrade.sh download /tmp/ubuntu-apt-repair.txt /tmp/ubuntu-apt-repair-debs
##   bash 06-Repair-ubuntu-dependencies-downgrade.sh install /tmp/ubuntu-apt-repair-debs
## Artifacts:
##   - 输入: apt-get -s --no-download -f install 输出中的精确依赖版本
##   - 输出: 包名=版本格式的离线修复清单和 .deb 文件
## Env:
##   - 无
## Notes:
##   - 仅支持 Ubuntu amd64；download 必须在可访问同版本软件源的 Ubuntu 机器执行
##   - 默认采用“将依赖降级到报错要求的精确版本”方案
##   - download 只下载，不安装到联网机器；install 使用严格离线模式
################################################################################
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<EOF
用法:
  ${SCRIPT_NAME} detect <清单路径>
  ${SCRIPT_NAME} download <清单路径> <下载目录>
  ${SCRIPT_NAME} install <下载目录>

流程:
  1. 在客户机执行 detect，生成需要的精确包版本清单。
  2. 将清单带到同版本、可联网的 Ubuntu 机器执行 download。
  3. 将下载目录复制回客户机执行 install。
EOF
  exit 2
}

require_ubuntu_amd64() {
  [ "$(dpkg --print-architecture)" = "amd64" ] || \
    die "仅支持 amd64，当前架构: $(dpkg --print-architecture)"
  # shellcheck disable=SC1091
  source /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "仅支持 Ubuntu，当前系统: ${ID:-unknown}"
}

detect_packages() {
  local manifest="$1"
  local report line package version
  local dependency_re='(PreDepends|Depends):[[:space:]]+([^[:space:]]+)[[:space:]]+\(=[[:space:]]*([^)]+)\)'
  declare -A packages=()

  mkdir -p "$(dirname "${manifest}")"
  report="$(mktemp)"
  log "检测 APT 精确版本依赖冲突..."
  set +e
  LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    apt-get -s --no-download -f install >"${report}" 2>&1
  set -e

  # 提取明确的“包 A 要求包 B=版本 R，但系统安装的是其他版本”关系。
  # 降级方案下载错误右侧明确要求的 B=R，不根据包名或 Ubuntu 点版本推断。
  while IFS= read -r line; do
    [[ "${line}" == *but* && "${line}" == *" is installed"* ]] || continue
    if [[ "${line}" =~ ${dependency_re} ]]; then
      package="${BASH_REMATCH[2]}"
      version="${BASH_REMATCH[3]}"
      if [ -z "${package}" ] || [ -z "${version}" ]; then
        continue
      fi
      packages["${package}=${version}"]=1
    fi
  done <"${report}"

  {
    echo "# Ubuntu APT offline repair package manifest"
    echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# OS: ${PRETTY_NAME:-unknown}"
    echo "# OS_VERSION=${VERSION_ID:-unknown}"
    echo "# Package versions come directly from exact versions required by apt-get errors."
    for package in "${!packages[@]}"; do
      printf '%s\n' "${package}"
    done | sort
  } >"${manifest}"

  if [ "${#packages[@]}" -eq 0 ]; then
    log "未检测到可直接提取的精确版本冲突。原始输出:"
    cat "${report}" >&2
    rm -f "${report}"
    rm -f "${manifest}"
    die "未生成修复包清单: ${manifest}"
  fi

  rm -f "${report}"
  log "已生成修复清单: ${manifest}"
  printf '%s\n' "${!packages[@]}" | sort
}

download_packages() {
  local manifest="$1"
  local output_dir="$2"
  local spec
  local failed=0
  local manifest_os_version current_os_version

  [ -f "${manifest}" ] || die "清单不存在: ${manifest}"
  mkdir -p "${output_dir}"
  require_ubuntu_amd64
  manifest_os_version="$(sed -n 's/^# OS_VERSION=//p' "${manifest}" | head -n 1)"
  current_os_version="${VERSION_ID:-}"
  if [ -z "${manifest_os_version}" ] || [ "${manifest_os_version}" != "${current_os_version}" ]; then
    die "清单系统版本 ${manifest_os_version:-unknown} 与当前下载机 ${current_os_version:-unknown} 不一致"
  fi

  log "更新 APT 包索引（不会安装包）..."
  apt-get update

  while IFS= read -r spec; do
    case "${spec}" in
      ''|'#'*) continue ;;
    esac
    log "下载精确版本: ${spec}"
    if ! (cd "${output_dir}" && apt-get download "${spec}"); then
      log "ERROR: 无法下载 ${spec}，请检查软件源是否保留该版本" >&2
      failed=$((failed + 1))
    fi
  done <"${manifest}"

  [ "${failed}" -eq 0 ] || die "有 ${failed} 个包下载失败"
  log "下载完成: ${output_dir}"
  dpkg-deb -W "${output_dir}"/*.deb
}

install_packages() {
  local package_dir="$1"
  local -a debs=()

  [ -d "${package_dir}" ] || die "下载目录不存在: ${package_dir}"
  require_ubuntu_amd64
  shopt -s nullglob
  debs=("${package_dir}"/*.deb)
  shopt -u nullglob
  [ "${#debs[@]}" -gt 0 ] || die "目录中没有 .deb: ${package_dir}"

  log "严格离线写入 ${#debs[@]} 个降级修复包..."
  # 当前 dpkg 状态已损坏时，apt-get 可能在解析阶段拒绝本地包。
  # 先统一解包，让新版本包进入 dpkg 数据库，再统一配置依赖关系。
  dpkg --unpack "${debs[@]}" || \
    log "部分包在解包后暂未配置，继续执行统一配置"
  dpkg --configure -a

  log "重新检查依赖..."
  if apt-get -s --no-download -f install; then
    log "依赖检查通过"
  else
    die "依赖仍未闭合，请重新执行 detect，处理新增的精确版本冲突"
  fi
}

[ "$#" -ge 2 ] || usage
mode="$1"
case "${mode}" in
  detect)
    [ "$#" -eq 2 ] || usage
    require_ubuntu_amd64
    detect_packages "$2"
    ;;
  download)
    [ "$#" -eq 3 ] || usage
    download_packages "$2" "$3"
    ;;
  install)
    [ "$#" -eq 2 ] || usage
    install_packages "$2"
    ;;
  *)
    usage
    ;;
esac
