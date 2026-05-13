#!/usr/bin/env bash
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
    local b="${p}.k8s-deploy.$(ts)"
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
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION_ID="unknown"
  fi
  export OS_ID OS_VERSION_ID
}

cleanup_kube_iptables() {
  # 默认只清 KUBE-/CALI- 链与引用规则（不 flush 全表）
  local ipt="$1" table
  have "$ipt" || return 0
  for table in filter nat mangle raw; do
    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      local del="${rule/-A /-D }"
      $ipt -t "$table" $del 2>/dev/null || true
    done < <($ipt -t "$table" -S 2>/dev/null | grep -E '^-A .* -j (KUBE|CALI)-' || true)

    while IFS= read -r chain; do
      [ -n "$chain" ] || continue
      $ipt -t "$table" -F "$chain" 2>/dev/null || true
      $ipt -t "$table" -X "$chain" 2>/dev/null || true
    done < <($ipt -t "$table" -S 2>/dev/null | awk '/^:(KUBE|CALI)-/ {sub(/^:/,"",$1); print $1}' || true)
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
  while IFS=$'\x1f' read -r m t n p url md5 d oid; do
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
  while IFS=$'\x1f' read -r m t p url md5 d os_id; do
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
# Description: 清单中一条 module=os,name=os.dir.kubernetes,type=dir 声明基目录；
#              返回 ${基目录}/${os_id}/kubernetes，path 中 /data/download 前缀替换为 DOWNLOAD_DIR
# Parameter:
#   $1 os_id  - ubuntu/centos/rocky/kylin/openeuler...
################################################################################
artifact_get_os_kubernetes_dir() {
  local os_id="$1"
  [ -n "${os_id}" ] || die "artifact_get_os_kubernetes_dir: os_id 不能为空"
  local manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  [ -f "${manifest}" ] || die "未找到制品清单: ${manifest}"
  if [ -z "${DOWNLOAD_DIR:-}" ]; then
    die "environment.sh 未设置 DOWNLOAD_DIR，无法解析 kubernetes 离线包目录"
  fi

  local cnt=0
  local base_from_yaml=""
  while IFS=$'\x1f' read -r m t n artifact_path url md5 d oid; do
    [ "${m}" = "os" ] || continue
    [ "${t}" = "dir" ] || continue
    [ "${n}" = "os.dir.kubernetes" ] || continue
    cnt=$((cnt + 1))
    base_from_yaml="${artifact_path}"
  done < <(parse_artifacts_yaml "${manifest}")

  if [ "${cnt}" -ne 1 ]; then
    die "制品清单应恰好 1 条 name=os.dir.kubernetes（module=os type=dir），当前匹配数=${cnt}"
  fi
  [ -n "${base_from_yaml}" ] || die "制品清单 os.dir.kubernetes 的 path 为空"

  local base="${base_from_yaml}"
  if [[ "${base}" == /data/download/* ]]; then
    base="${DOWNLOAD_DIR}${base#/data/download}"
  fi
  printf '%s\n' "${base}/${os_id}/kubernetes"
}

################################################################################
# Function: artifact_get_nvidia_toolkit_base_dir
# Description: 从清单读取 nvidia toolkit 离线包基目录（恰好 1 条 module=nvidia,type=dir）；
#              path 以 /data/download 开头时替换为 ${DOWNLOAD_DIR}；不含 OS 子目录，由调用方拼接 /<os>
################################################################################
artifact_get_nvidia_toolkit_base_dir() {
  local manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  [ -f "${manifest}" ] || die "未找到制品清单: ${manifest}"
  if [ -z "${DOWNLOAD_DIR:-}" ]; then
    die "environment.sh 未设置 DOWNLOAD_DIR，无法解析 nvidia toolkit 基目录"
  fi

  local cnt=0
  local base_from_yaml=""
  while IFS=$'\x1f' read -r m t n artifact_path url md5 d oid; do
    [ "${m}" = "nvidia" ] || continue
    [ "${t}" = "dir" ] || continue
    cnt=$((cnt + 1))
    base_from_yaml="${artifact_path}"
  done < <(parse_artifacts_yaml "${manifest}")

  if [ "${cnt}" -ne 1 ]; then
    die "制品清单应恰好 1 条 module=nvidia type=dir（toolkit 基目录），当前匹配数=${cnt}"
  fi
  [ -n "${base_from_yaml}" ] || die "制品清单 nvidia dir 的 path 为空"

  local base="${base_from_yaml}"
  if [[ "${base}" == /data/download/* ]]; then
    base="${DOWNLOAD_DIR}${base#/data/download}"
  fi
  printf '%s\n' "${base}"
}

init_framework() {
  get_cur_path
  init_logging
  if [ ! -f "${SCRIPT_DIR}/environment.sh" ]; then
    die "未找到 ${SCRIPT_DIR}/environment.sh（请先执行 01-Cluster-host.sh 生成配置）"
  fi
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/environment.sh"

  # 强约束：必须显式配置 DOWNLOAD_DIR（不在脚本里自作主张创建软链/改目录）
  if [ -z "${DOWNLOAD_DIR:-}" ]; then
    die "environment.sh 未设置 DOWNLOAD_DIR"
  fi

  detect_os
  log_info "OS: ${OS_ID} ${OS_VERSION_ID}"
}


