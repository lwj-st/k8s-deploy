#!/usr/bin/env bash
################################################################################
## Filename:    01-Download.sh
## Description: 根据 artifacts.yaml 下载所有缺失制品（可选做 md5 校验）
## Notes:
##   - 只负责下载，不做镜像导入/包安装
##   - 已存在文件：根据 MAAS_MD5_CHECK 决定是否重下
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

################################################################################
# Function: download_from_manifest
# Description: 遍历 manifest，按规则下载缺失制品
################################################################################
download_from_manifest() {
  local manifest="$1"
  local downloaded=0
  local skipped=0
  local no_url=0

  while IFS=$'\x1f' read -r module type name path url md5 desc os_id; do
    [ -n "${module}" ] || continue

    # os 模块不下载（只做目录校验/占位）
    if [ "${module}" = "os" ]; then
      continue
    fi

    # 目录类型不下载
    if [ "${type}" = "dir" ]; then
      continue
    fi

    # 已存在：按开关决定跳过或校验
    if [ -f "${path}" ]; then
      if [ "${MAAS_MD5_CHECK:-0}" = "1" ]; then
        if [ -z "${md5}" ] || [ "${md5}" = "__FILL_ME__" ]; then
          die "MAAS_MD5_CHECK=1 但 manifest 的 md5 未补齐: ${path}"
        fi
        if md5_check_file "${path}" "${md5}"; then
          log_info "[SKIP] 已存在且 md5 正确: ${path}"
          skipped=$((skipped+1))
          continue
        fi
        bad="${path}.bad.$(ts)"
        log_warn "[BAD] md5 不正确，先移走: ${path} -> ${bad}"
        mv -f "${path}" "${bad}"
      else
        log_info "[SKIP] 已存在（未启用 md5）: ${path}"
        skipped=$((skipped+1))
        continue
      fi
    fi

    if [ -z "${url}" ]; then
      log_warn "[NO-URL] 无下载地址，跳过：${path} (name=${name} ${desc})"
      no_url=$((no_url+1))
      continue
    fi

    log_info "[GET] ${module}: name=${name} ${desc}"
    download_file "${url}" "${path}"
    downloaded=$((downloaded+1))

    if [ "${MAAS_MD5_CHECK:-0}" = "1" ]; then
      if [ -z "${md5}" ] || [ "${md5}" = "__FILL_ME__" ]; then
        die "MAAS_MD5_CHECK=1 但 manifest 的 md5 未补齐: ${path}"
      fi
      if ! md5_check_file "${path}" "${md5}"; then
        die "下载后 md5 仍不匹配：${path}"
      fi
    fi
  done < <(parse_artifacts_yaml "${manifest}")

  log_info "下载完成：downloaded=${downloaded}, skipped=${skipped}, no_url=${no_url}"
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
  download_from_manifest "${manifest}"
  log_info "建议下一步：bash 03-Verify-artifacts.sh"
}

main "$@"

