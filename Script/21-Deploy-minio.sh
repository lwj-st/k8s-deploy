#!/usr/bin/env bash
################################################################################
## Filename:    21-Deploy-minio.sh
## Description: 离线导入 MinIO 镜像并 apply 清单（与 install.md 步骤一致）
## Notes:
##   - minio-deploy.yaml 按文档删除第 91–92 行后 apply（每次从制品原文件拷贝到临时文件处理，可重复执行）
##   - 制品路径来自 manifests/artifacts.yaml，下载走 02-Download.sh
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

NS="minio"
MINIO_TAR=""
F_SECRET=""
F_SA=""
F_PVC=""
F_SVC=""
F_DEPLOY=""

################################################################################
# Function: init_env
################################################################################
init_env() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  have kubectl || die "缺少 kubectl"
  have ctr || die "缺少 ctr（请先安装 containerd）"

  MINIO_TAR="$(artifact_get_path_by_name "minio.image.amd64.20250524")"
  F_SECRET="$(artifact_get_path_by_name "minio.manifest.secret")"
  F_SA="$(artifact_get_path_by_name "minio.manifest.service-account")"
  F_PVC="$(artifact_get_path_by_name "minio.manifest.pvc")"
  F_SVC="$(artifact_get_path_by_name "minio.manifest.svc")"
  F_DEPLOY="$(artifact_get_path_by_name "minio.manifest.deploy")"

  [ -f "${MINIO_TAR}" ] || die "缺少制品: ${MINIO_TAR}"
  [ -f "${F_SECRET}" ] || die "缺少制品: ${F_SECRET}"
  [ -f "${F_SA}" ] || die "缺少制品: ${F_SA}"
  [ -f "${F_PVC}" ] || die "缺少制品: ${F_PVC}"
  [ -f "${F_SVC}" ] || die "缺少制品: ${F_SVC}"
  [ -f "${F_DEPLOY}" ] || die "缺少制品: ${F_DEPLOY}"
}

################################################################################
# Function: import_minio_image
################################################################################
import_minio_image() {
  log_info "导入 MinIO 镜像 tar..."
  log_command "ctr -n k8s.io images import \"${MINIO_TAR}\""
}

################################################################################
# Function: ensure_namespace
################################################################################
ensure_namespace() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
}

################################################################################
# Function: apply_minio_manifests
# 顺序与 install.md 一致：secret -> sa -> pvc -> svc -> deploy（deploy 需 sed 删 91–92 行）
################################################################################
apply_minio_manifests() {
  log_info "应用 MinIO 清单..."
  log_command "kubectl apply -f \"${F_SECRET}\""
  log_command "kubectl apply -f \"${F_SA}\""
  log_command "kubectl apply -f \"${F_PVC}\""
  log_command "kubectl apply -f \"${F_SVC}\""

  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap 'rm -f "${tmp}"' EXIT
  cp -f "${F_DEPLOY}" "${tmp}"
  sed -i '91,92d' "${tmp}"
  log_command "kubectl apply -f \"${tmp}\""
  trap - EXIT
  rm -f "${tmp}"
}

################################################################################
# Function: main
################################################################################
main() {
  init_env
  import_minio_image
  ensure_namespace
  apply_minio_manifests
  log_info "MinIO 部署步骤已完成（命名空间 ${NS}）"
}

main "$@"
