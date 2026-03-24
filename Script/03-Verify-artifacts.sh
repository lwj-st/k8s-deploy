#!/usr/bin/env bash
################################################################################
## Filename:    02-Verify-artifacts.sh
## Description: 校验所有制品是否存在以及（可选）md5 是否正确
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

  while IFS=$'\x1f' read -r module type name path url md5 desc os_id; do
    [ -n "${module}" ] || continue

    # os 模块：只校验当前 OS 的目录
    if [ "${module}" = "os" ]; then
      # 如果允许在线安装，则不要求离线 OS 包目录存在
      if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
        continue
      fi
      [ -n "${os_id}" ] || continue
      if [ "${OS_ID}" != "${os_id}" ]; then
        # kylin 可能是 kylin*，允许前缀匹配
        case "${OS_ID}" in
          kylin*) [ "${os_id}" = "kylin" ] || continue ;;
          *) continue ;;
        esac
      fi
    fi

    # nvidia toolkit：清单为基目录，校验当前 OS 对应 <基目录>/<os>/
    if [ "${module}" = "nvidia" ] && [ "${type}" = "dir" ]; then
      local sub=""
      case "${OS_ID}" in
        ubuntu|debian) sub="ubuntu" ;;
        centos) sub="centos" ;;
        rocky) sub="rocky" ;;
        openeuler) sub="openeuler" ;;
        kylin*) sub="kylin" ;;
        *) continue ;;
      esac
      local nb="${path}"
      if [[ "${nb}" == /data/download/* ]]; then
        nb="${DOWNLOAD_DIR}${nb#/data/download}"
      fi
      local nd="${nb}/${sub}"
      if [ ! -d "${nd}" ]; then
        log_error "[MISSING] nvidia toolkit dir: ${nd}\tname=${name}\t${desc}"
        missing=$((missing + 1))
      fi
      continue
    fi

    if [ "${type}" = "dir" ]; then
      if [ ! -d "${path}" ]; then
        log_error "[MISSING] ${module} dir: ${path}\tname=${name}\t${desc}"
        missing=$((missing+1))
      fi
      continue
    fi

    if [ ! -f "${path}" ]; then
      log_error "[MISSING] ${module} file: ${path}\tname=${name}\t${desc}"
      missing=$((missing+1))
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

  log_info "DOWNLOAD_DIR: ${DOWNLOAD_DIR:-/data/download}"
  log_info "MAAS_MD5_CHECK: ${MAAS_MD5_CHECK:-0}"

  verify_manifest "${manifest}"
  log_info "制品检查通过"
}

main "$@"

