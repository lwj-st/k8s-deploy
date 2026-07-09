#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

rg -n '/data/download' "${ROOT_DIR}/Script" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE '/Script/00-[^:]+\.sh:' \
  | grep -vE '/Script/(environment|01-Cluster-host)\.sh:' \
  | grep -vE 'DOWNLOAD_DIR="\$\{DOWNLOAD_DIR:-/data/download\}"' \
  | grep -vE '/Script/(framework|03-Verify-artifacts)\.sh:.*(/data/download/\*|#/data/download|DOWNLOAD_DIR:-/data/download)' \
  > "${tmp_file}" || true

if [ -s "${tmp_file}" ]; then
  echo "Script 中存在未通过 DOWNLOAD_DIR 获取的 /data/download 引用:" >&2
  cat "${tmp_file}" >&2
  exit 1
fi
