#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

grep -R -n --include='*.sh' 'DOWNLOAD_DIR' "${ROOT_DIR}/Script" \
  > "${tmp_file}" || true

if [ -s "${tmp_file}" ]; then
  echo "Script 中不应再使用 DOWNLOAD_DIR；制品路径必须从 manifests/artifacts.yaml 获取:" >&2
  cat "${tmp_file}" >&2
  exit 1
fi

grep -R -n --include='*.sh' '/data/download' "${ROOT_DIR}/Script" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  > "${tmp_file}" || true

if [ -s "${tmp_file}" ]; then
  echo "Script 中存在未通过 manifests/artifacts.yaml 获取的 /data/download 引用:" >&2
  cat "${tmp_file}" >&2
  exit 1
fi

assert_path() {
  local helper="$1" expected="$2"
  local got
  if ! got="$(bash -c "source '${ROOT_DIR}/Script/framework.sh'; ${helper}" 2>&1)"; then
    echo "制品路径 helper 执行失败: ${helper}" >&2
    printf '%s\n' "${got}" >&2
    exit 1
  fi
  if [ "${got}" != "${expected}" ]; then
    echo "制品路径 helper 返回错误: ${helper}; got=${got}; expected=${expected}" >&2
    exit 1
  fi
}

assert_path 'artifact_get_os_kubernetes_dir ubuntu 22.04' '/data/download/packages/ubuntu/22.04/kubernetes'
assert_path 'artifact_get_os_tools_dir rocky 9.3' '/data/download/packages/rocky/9.3/tools'
assert_path 'artifact_get_nvidia_toolkit_dir kylin v10-sp3' '/data/download/nvidia/kylin/v10-sp3'
assert_path 'platform_get_download_image openeuler 24.03-lts-sp4' 'swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/openeuler/openeuler:24.03-lts-sp4'

supported_versions="$(bash -c "source '${ROOT_DIR}/Script/framework.sh'; platform_get_supported_versions ubuntu")"
expected_versions=$'22.04\n24.04\n26.04'
if [ "${supported_versions}" != "${expected_versions}" ]; then
  echo "Ubuntu 支持版本列表错误: ${supported_versions}" >&2
  exit 1
fi

for os_id in ubuntu centos rocky openeuler kylin; do
  while IFS= read -r os_version; do
    [ -n "${os_version}" ] || continue
    assert_path "artifact_get_os_kubernetes_dir ${os_id} ${os_version}" \
      "/data/download/packages/${os_id}/${os_version}/kubernetes"
    assert_path "artifact_get_os_tools_dir ${os_id} ${os_version}" \
      "/data/download/packages/${os_id}/${os_version}/tools"
    assert_path "artifact_get_nvidia_toolkit_dir ${os_id} ${os_version}" \
      "/data/download/nvidia/${os_id}/${os_version}"
    image="$(bash -c "source '${ROOT_DIR}/Script/framework.sh'; platform_get_download_image '${os_id}' '${os_version}'")"
    case "${image}" in
      swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/*) ;;
      *)
        echo "平台下载镜像未使用 ddn-k8s 中转: ${os_id}-${os_version}: ${image}" >&2
        exit 1
        ;;
    esac
  done < <(bash -c "source '${ROOT_DIR}/Script/framework.sh'; platform_get_supported_versions '${os_id}'")
done
