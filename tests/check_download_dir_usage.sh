#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

rg -n 'DOWNLOAD_DIR' "${ROOT_DIR}/Script" \
  > "${tmp_file}" || true

if [ -s "${tmp_file}" ]; then
  echo "Script 中不应再使用 DOWNLOAD_DIR；制品路径必须从 manifests/artifacts.yaml 获取:" >&2
  cat "${tmp_file}" >&2
  exit 1
fi

rg -n '/data/download' "${ROOT_DIR}/Script" \
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
  got="$(bash -c "source '${ROOT_DIR}/Script/framework.sh'; ${helper}")"
  if [ "${got}" != "${expected}" ]; then
    echo "制品路径 helper 返回错误: ${helper}; got=${got}; expected=${expected}" >&2
    exit 1
  fi
}

assert_path 'artifact_get_os_kubernetes_dir ubuntu' '/data/download/packages/ubuntu/kubernetes'
assert_path 'artifact_get_os_tools_dir rocky' '/data/download/packages/rocky/tools'
assert_path 'artifact_get_nvidia_toolkit_dir kylin' '/data/download/nvidia/kylin'
