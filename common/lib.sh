#!/usr/bin/env bash
set -euo pipefail

K8S_DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DEPLOY_STATE_DIR="/var/lib/k8s-deploy"
K8S_DEPLOY_BACKUPS_FILE="${K8S_DEPLOY_STATE_DIR}/backups.tsv"
K8S_DEPLOY_STATE_FILE="${K8S_DEPLOY_STATE_DIR}/state.env"

mkdir -p "${K8S_DEPLOY_STATE_DIR}" >/dev/null 2>&1 || true

ts() { date '+%Y%m%d_%H%M%S'; }

log_info() { printf '[%s] [INFO] %s\n' "$(date '+%F %T')" "$*" >&2; }
log_warn() { printf '[%s] [WARN] %s\n' "$(date '+%F %T')" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log_error "$*"; exit 1; }

run() {
  log_info "RUN: $*"
  # shellcheck disable=SC2086
  eval "$@"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "请用 root 执行（sudo bash $0）"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

record_kv() {
  local k="$1" v="$2"
  mkdir -p "${K8S_DEPLOY_STATE_DIR}" >/dev/null 2>&1 || true
  # 删除旧值再写入（幂等）
  if [ -f "${K8S_DEPLOY_STATE_FILE}" ]; then
    grep -vE "^${k}=" "${K8S_DEPLOY_STATE_FILE}" > "${K8S_DEPLOY_STATE_FILE}.tmp" || true
    mv -f "${K8S_DEPLOY_STATE_FILE}.tmp" "${K8S_DEPLOY_STATE_FILE}"
  fi
  printf '%s=%q\n' "$k" "$v" >> "${K8S_DEPLOY_STATE_FILE}"
}

load_state() {
  if [ -f "${K8S_DEPLOY_STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${K8S_DEPLOY_STATE_FILE}"
  fi
}

backup_if_exists() {
  local p="$1"
  if [ -e "$p" ]; then
    local b="${p}.k8s-deploy.$(ts)"
    log_warn "备份已存在路径: $p -> $b"
    mv -f "$p" "$b"
    mkdir -p "${K8S_DEPLOY_STATE_DIR}" >/dev/null 2>&1 || true
    printf '%s\t%s\n' "$p" "$b" >> "${K8S_DEPLOY_BACKUPS_FILE}"
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

md5_check_file() {
  local file="$1" expected="$2"
  [ -n "$expected" ] || return 0
  have md5sum || die "缺少 md5sum"
  local got
  got="$(md5sum "$file" | awk '{print $1}')"
  if [ "$got" != "$expected" ]; then
    return 1
  fi
  return 0
}

download_file() {
  local url="$1" out="$2"
  if ! have curl && ! have wget; then
    die "缺少下载工具 curl 或 wget"
  fi
  mkdir -p "$(dirname "$out")"
  if have curl; then
    run "curl -fL --retry 3 --connect-timeout 10 -o \"$out\" \"$url\""
  else
    run "wget -O \"$out\" \"$url\""
  fi
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



