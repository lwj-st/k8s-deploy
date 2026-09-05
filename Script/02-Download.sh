#!/usr/bin/env bash
################################################################################
## Filename:    02-Download.sh
## Description: 下载当前 OS 离线包，并根据 artifacts.yaml 下载其他缺失制品
## Usage:
##   bash 02-Download.sh
## Artifacts:
##   - os.dir.kubernetes.<os_id>.<os_version>
##   - os.dir.tools.<os_id>.<os_version>
## Notes:
##   - 只负责下载，不做镜像导入/包安装
##   - Kubernetes 和工具离线包下载对应 .md5，校验通过后解压并保留两个文件
##   - 已存在文件：根据 MAAS_MD5_CHECK 决定是否重下
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

PACKAGE_OSS_BASE_URL="https://aoss.cn-sh-01b.sensecoreapi-oss.cn/devops/sensecorex/x86/download/packages"

################################################################################
# Function: validate_package_archive
# Description: 校验压缩包可读，且所有内容都在预期的顶层目录中
################################################################################
validate_package_archive() {
  local archive="$1"
  local expected_dir="$2"

  have tar || die "缺少 tar，无法解压离线包"
  if ! tar -tzf "$archive" | awk -v expected="$expected_dir" '
    BEGIN { found = 0 }
    {
      entry = $0
      sub(/^\.\//, "", entry)
      if (entry == "") next
      if (entry ~ /^\// || entry ~ /(^|\/)\.\.(\/|$)/) exit 2
      split(entry, parts, "/")
      if (parts[1] != expected) exit 3
      found = 1
    }
    END { if (!found) exit 4 }
  '; then
    die "压缩包内容不正确，必须只包含 ${expected_dir}/ 顶层目录: ${archive}"
  fi
}

################################################################################
# Function: download_and_extract_package_archive
# Description: 下载并解压单个 OS 离线包；已有 tar.gz 会保留并复用
################################################################################
download_and_extract_package_archive() {
  local package_type="$1"
  local expected_dir="$2"
  local target_dir="$3"
  local archive_name="${OS_ID}-${TARGET_OS_VERSION}-${package_type}-x86.tar.gz"
  local archive_path="${target_dir}/${archive_name}"
  local archive_url="${PACKAGE_OSS_BASE_URL}/${OS_ID}/${TARGET_OS_VERSION}/${archive_name}"
  local partial_path="${archive_path}.part.$$"
  local md5_name="${archive_name}.md5"
  local md5_path="${target_dir}/${md5_name}"
  local md5_url="${PACKAGE_OSS_BASE_URL}/${OS_ID}/${TARGET_OS_VERSION}/${md5_name}"
  local md5_partial_path="${md5_path}.part.$$"
  local expected_md5=""
  local expected_filename=""
  local extra_field=""
  local actual_md5=""

  have md5sum || die "缺少 md5sum，无法校验离线包"

  if [ -f "$archive_path" ]; then
    log_info "[SKIP] 离线包已存在，将复用并校验: ${archive_path}"
  else
    log_info "[GET] ${package_type}: ${archive_name}"
    if ! download_file "$archive_url" "$partial_path"; then
      rm -f "$partial_path"
      die "离线包下载失败: ${archive_url}"
    fi
    mv -f "$partial_path" "$archive_path"
  fi

  log_info "[GET] MD5: ${md5_name}"
  if ! download_file "$md5_url" "$md5_partial_path"; then
    rm -f "$md5_partial_path"
    die "MD5 文件下载失败: ${md5_url}"
  fi
  mv -f "$md5_partial_path" "$md5_path"

  read -r expected_md5 expected_filename extra_field < "$md5_path" || true
  expected_filename="${expected_filename#\*}"
  if [[ ! "$expected_md5" =~ ^[[:xdigit:]]{32}$ ]] || \
    [ "$expected_filename" != "$archive_name" ] || [ -n "$extra_field" ]; then
    die "MD5 文件格式或文件名不正确: ${md5_path}"
  fi
  expected_md5=$(printf '%s' "$expected_md5" | tr '[:upper:]' '[:lower:]')
  actual_md5=$(md5sum "$archive_path" | awk '{print $1}')
  if [ "$actual_md5" != "$expected_md5" ]; then
    die "离线包 MD5 校验失败: ${archive_path}（期望 ${expected_md5}，实际 ${actual_md5}）"
  fi
  log_info "[OK] MD5 校验通过: ${actual_md5}  ${archive_name}"

  validate_package_archive "$archive_path" "$expected_dir"
  log_info "[EXTRACT] ${archive_name} -> ${target_dir}/${expected_dir}/"
  tar -xzf "$archive_path" -C "$target_dir"
  [ -d "${target_dir}/${expected_dir}" ] || die "离线包解压后缺少目录: ${target_dir}/${expected_dir}"
}

################################################################################
# Function: download_os_package_archives
# Description: 按当前 OS 和目标版本下载 Kubernetes、tools 离线包
################################################################################
download_os_package_archives() {
  local kubernetes_dir=""
  local tools_dir=""
  local target_dir=""
  local packages_root=""

  kubernetes_dir="$(artifact_get_os_kubernetes_dir "$OS_ID" "$TARGET_OS_VERSION")"
  tools_dir="$(artifact_get_os_tools_dir "$OS_ID" "$TARGET_OS_VERSION")"
  target_dir="$(dirname "$kubernetes_dir")"
  [ "$(dirname "$tools_dir")" = "$target_dir" ] || die "Kubernetes 与 tools 离线包目录不在同一版本目录"

  packages_root="$(dirname "$(dirname "$(dirname "$kubernetes_dir")")")"
  [ -d "$packages_root" ] || die "离线包根目录不存在，请先创建: ${packages_root}"
  mkdir -p "$target_dir"

  log_info "OS 离线包目录: ${target_dir}"
  download_and_extract_package_archive "k8s-packages" "kubernetes" "$target_dir"
  download_and_extract_package_archive "tools-packages" "tools" "$target_dir"
}

################################################################################
# Function: download_from_manifest
# Description: 遍历 manifest，按规则下载缺失制品
################################################################################
download_from_manifest() {
  local manifest="$1"
  local downloaded=0
  local skipped=0
  local no_url=0

  while IFS=$'\x1f' read -r module type name path url md5 desc _os_id; do
    [ -n "${module}" ] || continue

    # os 模块不下载（只做目录校验/占位）
    if [ "${module}" = "os" ]; then
      continue
    fi

    # 目录类型不下载
    if [ "${type}" = "dir" ]; then
      continue
    fi

    # 无校验值的本地预置制品不下载，也不能用 md5 判定是否需要重下。
    if [ "${md5}" = "__LOCAL_ONLY__" ]; then
      if [ -f "${path}" ]; then
        log_info "[SKIP] 本地预置制品（无 md5）: ${path}"
        skipped=$((skipped+1))
      else
        log_warn "[LOCAL-ONLY] 缺少本地预置制品，无法自动下载: ${path} (name=${name})"
        no_url=$((no_url+1))
      fi
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
  log_info "Kubernetes 与 tools 离线包使用随包发布的 .md5 文件校验"
  download_os_package_archives
  download_from_manifest "${manifest}"
  log_info "建议下一步：bash 03-Verify-artifacts.sh"
}

main "$@"
