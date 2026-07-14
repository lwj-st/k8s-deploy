#!/usr/bin/env bash
################################################################################
## Filename:    03-Verify-artifacts.sh
## Description: 校验所有制品是否存在以及（可选）md5 是否正确
## Usage:
##   bash 03-Verify-artifacts.sh
## Notes:
##   - 只检查，不做下载/修复
##   - 支持按 OS 过滤 os 模块的目录条目
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

################################################################################
# Function: verify_manifest
# Description: 遍历 artifacts.yaml，做存在性与 md5 校验
################################################################################
verify_manifest() {
  local manifest="$1"
  local missing=0
  while IFS=$'\x1f' read -r module type name path _url md5 desc os_id; do
    [ -n "${module}" ] || continue

    if [ "${module}" = "os" ] && [ "${type}" = "dir" ] && [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      continue
    fi

    # 带 os_id 的目录仅校验当前 OS 和目标版本对应的条目。
    if [ "${type}" = "dir" ] && [ -n "${os_id}" ]; then
      [ "${OS_ID}" = "${os_id}" ] || continue
      case "${name}" in
        *."${TARGET_OS_VERSION}") ;;
        *) continue ;;
      esac
    fi

    if [ "${type}" = "dir" ]; then
      if [ ! -d "${path}" ]; then
        log_error "[MISSING] ${module} 目录不存在: ${path} (清单项: ${name}; ${desc})"
        missing=$((missing+1))
      fi
      continue
    fi

    if [ ! -f "${path}" ]; then
      log_error "[MISSING] ${module} 文件不存在: ${path} (清单项: ${name}; ${desc})"
      missing=$((missing+1))
      continue
    fi

    if [ "${md5}" = "__LOCAL_ONLY__" ]; then
      log_warn "[NO-MD5] 本地预置制品未配置 md5: ${path}"
      continue
    fi

    # md5 字段必须存在；开关打开才校验
    if [ -z "${md5}" ]; then
      log_error "[BAD-MANIFEST] md5 为空: ${path}"
      missing=$((missing+1))
      continue
    fi
    if [ "${MAAS_MD5_CHECK:-0}" = "1" ]; then
      if [ "${md5}" = "__FILL_ME__" ]; then
        log_error "[BAD-MD5] MAAS_MD5_CHECK=1 但 md5 未补齐: ${path}"
        missing=$((missing+1))
        continue
      fi
      if ! md5_check_file "${path}" "${md5}"; then
        log_error "[BAD-MD5] ${path} expected=${md5}"
        missing=$((missing+1))
      fi
    fi
  done < <(parse_artifacts_yaml "${manifest}")

  if [ "${missing}" -ne 0 ]; then
    die "制品检查失败：缺失/校验失败项数量 = ${missing}"
  fi
}

################################################################################
# Function: main
# Description: 主流程
################################################################################
main() {
  init_framework

  local manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  [ -f "${manifest}" ] || die "未找到制品清单: ${manifest}"

  log_info "MAAS_MD5_CHECK: ${MAAS_MD5_CHECK:-0}"

  verify_manifest "${manifest}"
  log_info "制品检查通过"
}

main "$@"
