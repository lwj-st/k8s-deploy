#!/usr/bin/env bash
################################################################################
## Filename:    framework.sh
## Description: k8s-deploy 脚本公共函数库
## Usage:
##   source Script/framework.sh
## Notes:
##   - 由其他脚本 source，不直接执行
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 状态/备份记录（用于 cleanup）
STATE_DIR="/var/lib/k8s-deploy"
BACKUPS_FILE="${STATE_DIR}/backups.tsv"
STATE_FILE="${STATE_DIR}/state.env"

mkdir -p "${STATE_DIR}" >/dev/null 2>&1 || true

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/log.sh"

ts() { date '+%Y%m%d_%H%M%S'; }

get_cur_path() {
  cd "$(dirname "${BASH_SOURCE-$0}")"
  # shellcheck disable=SC2034
  g_curPath="${PWD}"
  # 取“真正执行的脚本名”，而不是 framework.sh 本身
  # 调用栈通常为：<your-script>.sh -> init_framework -> get_cur_path
  local caller="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"
  g_scriptName="$(basename "${caller}" .sh)"
  g_logPath="${K8S_DEPLOY_ROOT}/logs"
  g_logFile="${g_scriptName}.log"
  mkdir -p "${g_logPath}"
  cd - >/dev/null
}

init_logging() {
  # 将本脚本的 stdout/stderr 重定向到日志文件（同时在终端显示）
  # 支持彩色日志：终端保留颜色，写入文件时剥离 ANSI 颜色码
  local log_file="${g_logPath}/${g_logFile}"
  local color_mode="${LOG_COLOR:-auto}"
  local color_enabled="0"
  if [ "${color_mode}" = "always" ]; then
    color_enabled="1"
  elif [ "${color_mode}" = "never" ]; then
    color_enabled="0"
  else
    # auto：仅在当前 stdout 是 tty 时启用
    if [ -t 1 ]; then
      color_enabled="1"
    fi
  fi
  export LOG_COLOR_ENABLED="${color_enabled}"

  # stdout: 原样输出到终端；file: 去掉 ANSI 转义序列，避免污染日志文件
  # 说明：这里用 bash 的 $'..' 生成真实 ESC 字符，确保 sed 能正确匹配并剥离颜色码
  exec > >(tee >(sed -E $'s/\x1b\\[[0-9;]*[mK]//g' >> "${log_file}")) 2>&1
  # tee 下游 sed 或日志文件异常时，下一次写 stdout 可能 SIGPIPE；默认会终止脚本且易表现为「打几行日志后无声退出」
  trap '' PIPE
  log_info "-------------------脚本开始执行----------------------"
}

die() { log_error "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "请用 root 执行（sudo bash ${g_scriptName}.sh）"
  fi
}

is_tar_readable() {
  local file="$1"
  tar -tf "${file}" >/dev/null 2>&1
}

import_image_tar() {
  local name="$1" file="$2"
  [ -f "${file}" ] || die "缺少镜像 tar: name=${name} path=${file}"
  have tar || die "缺少 tar，无法校验镜像包"
  is_tar_readable "${file}" || die "镜像 tar 不可读/疑似损坏: name=${name} path=${file}"
  have ctr || die "缺少 ctr（containerd 未安装？请先执行 11-Install-containerd.sh）"
  log_command "ctr -n k8s.io images import \"${file}\""
}

import_image_artifact() {
  local name="$1"
  local file
  file="$(artifact_get_path_by_name "${name}")"
  import_image_tar "${name}" "${file}"
}

import_image_artifacts() {
  local name
  for name in "$@"; do
    import_image_artifact "${name}"
  done
}

log_command() {
  local cmd="$1"
  log_info "执行命令: $cmd"
  eval "$cmd"
  local status=$?
  if [ $status -eq 0 ]; then
    log_info "命令执行成功"
  else
    log_error "命令执行失败，退出码: $status"
    exit 1
  fi
}

backup_if_exists() {
  local p="$1"
  if [ -e "$p" ]; then
    local ts_stamp
    ts_stamp=$(ts)
    local b
    b="${p}.k8s-deploy.${ts_stamp}"
    log_warn "备份已存在路径: $p -> $b"
    mv -f "$p" "$b"
    printf '%s\t%s\n' "$p" "$b" >> "${BACKUPS_FILE}"
  fi
}

record_kv() {
  local k="$1" v="$2"
  if [ -f "${STATE_FILE}" ]; then
    grep -vE "^${k}=" "${STATE_FILE}" > "${STATE_FILE}.tmp" || true
    mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
  fi
  printf '%s=%q\n' "$k" "$v" >> "${STATE_FILE}"
}

load_state() {
  if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID_RAW="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_VERSION_NAME="${VERSION:-}"
  else
    OS_ID_RAW="unknown"
    OS_VERSION_ID="unknown"
    OS_VERSION_NAME=""
  fi

  OS_ID="$(printf '%s' "${OS_ID_RAW}" | tr '[:upper:]' '[:lower:]')"
  case "${OS_ID}" in
    kylin*) OS_ID="kylin" ;;
  esac
  OS_VERSION_DETECTED="$(normalize_os_version "${OS_ID}" "${OS_VERSION_ID}" "${OS_VERSION_NAME}")"
  export OS_ID OS_ID_RAW OS_VERSION_ID OS_VERSION_NAME OS_VERSION_DETECTED
}

# 将 /etc/os-release 中的版本统一为清单使用的平台版本标识。
normalize_os_version() {
  local os_id="$1" version_id="$2" version_name="$3"
  local normalized
  local version_name_lower
  normalized="$(printf '%s' "${version_id}" | tr '[:upper:]' '[:lower:]')"
  version_name_lower="$(printf '%s' "${version_name}" | tr '[:upper:]' '[:lower:]')"

  if [ "${os_id}" = "openeuler" ] && [[ "${version_name_lower}" =~ ([0-9]+\.[0-9]+).*lts[-[:space:]]*sp([0-9]+) ]]; then
    printf '%s-lts-sp%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  printf '%s\n' "${normalized}"
}

cleanup_kube_iptables() {
  # 默认只清 KUBE-/CALI- 链与引用规则（不 flush 全表）
  local ipt="$1" table
  have "$ipt" || return 0
  for table in filter nat mangle raw; do
    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      local del="${rule/-A /-D }"
      # shellcheck disable=SC2086 # $del 为 iptables 完整规则片段，须分词
      "$ipt" -t "$table" $del 2>/dev/null || true
    done < <("$ipt" -t "$table" -S 2>/dev/null | grep -E '^-A .* -j (KUBE|CALI)-' || true)

    while IFS= read -r chain; do
      [ -n "$chain" ] || continue
      "$ipt" -t "$table" -F "$chain" 2>/dev/null || true
      "$ipt" -t "$table" -X "$chain" 2>/dev/null || true
    done < <("$ipt" -t "$table" -S 2>/dev/null | awk '/^:(KUBE|CALI)-/ {sub(/^:/,"",$1); print $1}' || true)
  done
}

md5_check_file() {
  local file="$1" expected="$2"
  have md5sum || die "缺少 md5sum"
  local got
  got="$(md5sum "$file" | awk '{print $1}')"
  [ "$got" = "$expected" ]
}

download_file() {
  local url="$1" out="$2"
  if ! have curl && ! have wget; then
    die "缺少下载工具 curl 或 wget"
  fi
  mkdir -p "$(dirname "$out")"
  if have curl; then
    log_command "curl -fL --retry 3 --connect-timeout 10 -o \"$out\" \"$url\""
  else
    log_command "wget -O \"$out\" \"$url\""
  fi
}

# YAML manifest 解析：只支持本仓库生成的简单结构（list-of-maps）
# 重要：分隔符使用 ASCII Unit Separator(\x1f)，避免 bash read 在 IFS 为“空白字符(tab/space)”时吞掉空字段（例如 url 为空）。
# 输出：module<US>type<US>name<US>path<US>url<US>md5<US>description<US>os_id
parse_artifacts_yaml() {
  local yaml_file="$1"
  [ -f "$yaml_file" ] || die "制品清单不存在: $yaml_file"

  awk '
  function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
  function stripq(s){ s=trim(s); gsub(/^["\047]|["\047]$/, "", s); return s }
  function emit(){
    if (in_item) {
      # use ASCII Unit Separator between fields
      printf "%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n", module, type, name, path, url, md5, desc, os_id
    }
  }
  BEGIN{in_item=0; module=type=name=path=url=md5=desc=os_id=""}
  /^[[:space:]]*-[[:space:]]+module:/{
    emit()
    in_item=1
    module=stripq($0); sub(/^[[:space:]]*-[[:space:]]+module:[[:space:]]*/, "", module)
    type=name=path=url=md5=desc=os_id=""
    next
  }
  in_item && /^[[:space:]]+type:/{
    type=$0; sub(/^[[:space:]]+type:[[:space:]]*/, "", type); type=stripq(type); next
  }
  in_item && /^[[:space:]]+name:/{
    name=$0; sub(/^[[:space:]]+name:[[:space:]]*/, "", name); name=stripq(name); next
  }
  in_item && /^[[:space:]]+path:/{
    path=$0; sub(/^[[:space:]]+path:[[:space:]]*/, "", path); path=stripq(path); next
  }
  in_item && /^[[:space:]]+url:/{
    url=$0; sub(/^[[:space:]]+url:[[:space:]]*/, "", url); url=stripq(url); next
  }
  in_item && /^[[:space:]]+md5:/{
    md5=$0; sub(/^[[:space:]]+md5:[[:space:]]*/, "", md5); md5=stripq(md5); next
  }
  in_item && /^[[:space:]]+description:/{
    desc=$0; sub(/^[[:space:]]+description:[[:space:]]*/, "", desc); desc=stripq(desc); next
  }
  in_item && /^[[:space:]]+os_id:/{
    os_id=$0; sub(/^[[:space:]]+os_id:[[:space:]]*/, "", os_id); os_id=stripq(os_id); next
  }
  END{ emit() }
  ' "$yaml_file"
}

################################################################################
# Function: artifact_get_path_by_name
# Description: 从 manifests/artifacts.yaml 中按（name）精确查找制品 path（name 全局唯一）
# Parameter:
#   input:
#     $1 name - 制品唯一名（推荐以 module. 前缀组织）
#   output:
#     stdout: path
# Return:
#   0 success; non-0 failure（找不到或重复时 die）
################################################################################
artifact_get_path_by_name() {
  local name="$1"
  local manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  [ -f "${manifest}" ] || die "未找到制品清单: ${manifest}"
  [ -n "${name}" ] || die "artifact_get_path_by_name: name 不能为空"

  local found=""
  local cnt=0
  while IFS=$'\x1f' read -r _m _t n p _url _md5 _d _oid; do
    [ "${n}" = "${name}" ] || continue
    found="${p}"
    cnt=$((cnt+1))
  done < <(parse_artifacts_yaml "${manifest}")

  if [ "${cnt}" -eq 0 ]; then
    die "制品清单未找到 name=${name}"
  fi
  if [ "${cnt}" -gt 1 ]; then
    die "制品清单存在重复 name=${name}（匹配数量=${cnt}）"
  fi
  printf '%s\n' "${found}"
}

# 输出清单中某个发行版可选的目标版本，每行一个。
platform_get_supported_versions() {
  local os_id="$1"
  local manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  [ -n "${os_id}" ] || die "platform_get_supported_versions: os_id 不能为空"

  awk -v wanted="${os_id}" '
    function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function stripq(s){ s=trim(s); gsub(/^["\047]|["\047]$/, "", s); return s }
    /^platforms:/ { in_platforms=1; next }
    /^artifacts:/ { in_platforms=0 }
    !in_platforms { next }
    /^[[:space:]]*-[[:space:]]+os_id:/ {
      id=$0; sub(/^[[:space:]]*-[[:space:]]+os_id:[[:space:]]*/, "", id); id=stripq(id); next
    }
    id == wanted && /^[[:space:]]+os_version:/ {
      version=$0; sub(/^[[:space:]]+os_version:[[:space:]]*/, "", version); print stripq(version)
    }
  ' "${manifest}"
}

platform_is_supported() {
  local os_id="$1" os_version="$2"
  platform_get_supported_versions "${os_id}" | grep -Fxq "${os_version}"
}

platform_get_download_image() {
  local os_id="$1" os_version="$2"
  local manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  local image=""

  image="$(awk -v wanted_id="${os_id}" -v wanted_version="${os_version}" '
    function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function stripq(s){ s=trim(s); gsub(/^["\047]|["\047]$/, "", s); return s }
    function emit(){ if (id == wanted_id && version == wanted_version) { print image; emitted=1 } }
    /^platforms:/ { in_platforms=1; next }
    /^artifacts:/ { if (in_platforms) emit(); exit }
    !in_platforms { next }
    /^[[:space:]]*-[[:space:]]+os_id:/ {
      emit(); id=$0; sub(/^[[:space:]]*-[[:space:]]+os_id:[[:space:]]*/, "", id); id=stripq(id); version=image=""; next
    }
    /^[[:space:]]+os_version:/ { version=$0; sub(/^[[:space:]]+os_version:[[:space:]]*/, "", version); version=stripq(version); next }
    /^[[:space:]]+download_image:/ { image=$0; sub(/^[[:space:]]+download_image:[[:space:]]*/, "", image); image=stripq(image); next }
    END { if (in_platforms && !emitted) emit() }
  ' "${manifest}")"
  [ -n "${image}" ] || die "不支持的平台: ${os_id}-${os_version}"
  printf '%s\n' "${image}"
}

require_target_platform() {
  [ -n "${TARGET_OS_VERSION:-}" ] || die "未配置 TARGET_OS_VERSION，请先执行 01-Cluster-host.sh"
  platform_is_supported "${OS_ID}" "${TARGET_OS_VERSION}" || die "不支持的平台: ${OS_ID}-${TARGET_OS_VERSION}；支持版本: $(platform_get_supported_versions "${OS_ID}" | paste -sd ',')"
}

################################################################################
# Function: artifact_get_path
# Description: 从 manifests/artifacts.yaml 中按（module/type/description）精确查找制品 path
# Parameter:
#   input:
#     $1 module        - 模块名（如 base/containerd/k8s/...）
#     $2 type          - 类型（file/tar/dir）
#     $3 description   - description 精确匹配（建议作为稳定标识，不随文件名变化）
#   output:
#     stdout: path
# Return:
#   0 success; non-0 failure（找不到或重复时 die）
################################################################################
artifact_get_path() {
  local module="$1" type="$2" desc="$3"
  local manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  [ -f "${manifest}" ] || die "未找到制品清单: ${manifest}"

  local found=""
  local cnt=0
  while IFS=$'\x1f' read -r m t _n p _url _md5 d _os_id; do
    [ "${m}" = "${module}" ] || continue
    [ "${t}" = "${type}" ] || continue
    [ "${d}" = "${desc}" ] || continue
    found="${p}"
    cnt=$((cnt+1))
  done < <(parse_artifacts_yaml "${manifest}")

  if [ "${cnt}" -eq 0 ]; then
    die "制品清单未找到条目：module=${module} type=${type} description=${desc}"
  fi
  if [ "${cnt}" -gt 1 ]; then
    die "制品清单存在重复条目：module=${module} type=${type} description=${desc}（匹配数量=${cnt}）"
  fi
  printf '%s\n' "${found}"
}

################################################################################
# Function: artifact_get_os_kubernetes_dir
# Description: 从清单读取当前 OS 的 Kubernetes 离线包目录
# Parameter:
#   $1 os_id  - ubuntu/centos/rocky/kylin/openeuler...
################################################################################
artifact_get_os_kubernetes_dir() {
  local os_id="$1" os_version="$2"
  [ -n "${os_id}" ] && [ -n "${os_version}" ] || die "artifact_get_os_kubernetes_dir: os_id/os_version 不能为空"
  artifact_get_path_by_name "os.dir.kubernetes.${os_id}.${os_version}"
}

################################################################################
# Function: artifact_get_os_tools_dir
# Description: 从清单读取当前 OS 的常用工具离线包目录
################################################################################
artifact_get_os_tools_dir() {
  local os_id="$1" os_version="$2"
  [ -n "${os_id}" ] && [ -n "${os_version}" ] || die "artifact_get_os_tools_dir: os_id/os_version 不能为空"
  artifact_get_path_by_name "os.dir.tools.${os_id}.${os_version}"
}

################################################################################
# Function: artifact_get_nvidia_toolkit_dir
# Description: 从清单读取当前 OS 的 NVIDIA Container Toolkit 离线包目录
################################################################################
artifact_get_nvidia_toolkit_dir() {
  local os_id="$1" os_version="$2"
  [ -n "${os_id}" ] && [ -n "${os_version}" ] || die "artifact_get_nvidia_toolkit_dir: os_id/os_version 不能为空"
  artifact_get_path_by_name "nvidia.dir.toolkit.${os_id}.${os_version}"
}

init_framework() {
  get_cur_path
  init_logging
  if [ ! -f "${SCRIPT_DIR}/environment.sh" ]; then
    die "未找到 ${SCRIPT_DIR}/environment.sh（请先执行 01-Cluster-host.sh 生成配置）"
  fi
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/environment.sh"

  detect_os
  require_target_platform
  log_info "OS: ${OS_ID} ${OS_VERSION_DETECTED}（目标离线包版本: ${TARGET_OS_VERSION}）"
}
