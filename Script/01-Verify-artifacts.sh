#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/framework.sh"

init_framework

MANIFEST="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
[ -f "${MANIFEST}" ] || die "未找到制品清单: ${MANIFEST}"

log_info "DOWNLOAD_DIR: ${DOWNLOAD_DIR:-/data/download}"
log_info "MAAS_MD5_CHECK: ${MAAS_MD5_CHECK:-0}"

missing=0

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
done < <(parse_artifacts_yaml "${MANIFEST}")

if [ "${missing}" -ne 0 ]; then
  die "制品检查失败：缺失/校验失败项数量 = ${missing}"
fi

log_info "制品检查通过"


