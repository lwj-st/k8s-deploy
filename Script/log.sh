#!/usr/bin/env bash

# 统一日志（参考 k8s-data-amd64/Script/log.sh 的风格，但改为 stdout 打印 + 由框架统一重定向到文件）

log_message() {
  local level="$1"
  local message="$2"
  local funcName="${FUNCNAME[2]:-main}"
  local lineNO="${BASH_LINENO[1]:-0}"
  local logTime
  logTime="$(date +'%Y-%m-%d %H:%M:%S')"

  # 仅给终端上色；写入文件时由 framework.sh 剥离 ANSI 码
  local c_reset="" c_level=""
  if [ "${LOG_COLOR_ENABLED:-0}" = "1" ]; then
    c_reset=$'\033[0m'
    case "$level" in
      ERROR) c_level=$'\033[31m' ;; # red
      WARN)  c_level=$'\033[33m' ;; # yellow
      INFO)  c_level=$'\033[32m' ;; # green
      *)     c_level=$'\033[36m' ;; # cyan
    esac
  fi

  # 不因 tee/sed 管道破裂、磁盘满或终端提前关闭导致 printf 非零而触发 set -e 退出（否则后续 die/排查信息可能打不出来）
  printf "[%s] [%s%s%s] [%s(%s):%s]\t%s\n" "$logTime" "${c_level}" "$level" "${c_reset}" "${g_scriptName:-script}" "$funcName" "$lineNO" "$message" || true
}

log_error() { log_message "ERROR" "$1"; }
log_warn()  { log_message "WARN"  "$1"; }
log_info()  { log_message "INFO"  "$1"; }


