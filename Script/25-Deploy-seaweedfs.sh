#!/usr/bin/env bash
################################################################################
## Filename:    25-Deploy-seaweedfs.sh
## Description: 使用离线 Helm Chart 部署/升级/卸载 SeaweedFS
## Usage:
##   bash 25-Deploy-seaweedfs.sh install   # 默认
##   bash 25-Deploy-seaweedfs.sh upgrade
##   bash 25-Deploy-seaweedfs.sh uninstall
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

NS="seaweedfs"
RELEASE="seaweedfs"
CSI_NS="seaweedfs-csi-driver"
CSI_RELEASE="seaweedfs-csi-driver"
CSI_PROVISIONER="${CSI_RELEASE}"
ACTION="${1:-install}"
CHART=""
VALUES=""
CSI_CHART=""
SEAWEEDFS_IMAGE_TAR=""
SEAWEEDFS_FILER="seaweedfs-filer.seaweedfs.svc.cluster.local:8888"
VALUES_SRC=""
SC_NAME="${SEAWEEDFS_STORAGE_CLASS_NAME:-seaweedfs-storage}"
SC_RECLAIM_POLICY="${SEAWEEDFS_STORAGE_RECLAIM_POLICY:-Retain}"
SC_VOLUME_BINDING_MODE="${SEAWEEDFS_STORAGE_BINDING_MODE:-Immediate}"
SC_REPLICATION="${SEAWEEDFS_STORAGE_REPLICATION:-001}"

init_env() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  have helm || die "缺少 helm（请先执行 09-Install-tools.sh）"
  have kubectl || die "缺少 kubectl"
  have base64 || die "缺少 base64"
  have tar || die "缺少 tar"
  if ! have ctr && ! have nerdctl && ! have docker; then
    die "缺少镜像导入工具（ctr/nerdctl/docker 至少需要一个）"
  fi

  CHART="$(artifact_get_path_by_name "seaweedfs.chart.seaweedfs.v4.20.0")"
  CSI_CHART="$(artifact_get_path_by_name "seaweedfs-csi.chart.driver.v0.2.14")"
  SEAWEEDFS_IMAGE_TAR="$(artifact_get_path_by_name "seaweedfs.image.seaweedfs.v4.20.0")"
  VALUES_SRC="${K8S_DEPLOY_ROOT}/config/seaweedfs-values.yaml"
  VALUES="${DOWNLOAD_DIR}/seaweedfs/seaweedfs-values.yaml"

  [ -f "${CHART}" ] || die "缺少制品: ${CHART}"
  [ -f "${CSI_CHART}" ] || die "缺少制品: ${CSI_CHART}"
  [ -f "${SEAWEEDFS_IMAGE_TAR}" ] || die "缺少制品: ${SEAWEEDFS_IMAGE_TAR}"
  [ -f "${VALUES_SRC}" ] || die "缺少配置文件: ${VALUES_SRC}"
  mkdir -p "$(dirname "${VALUES}")"
  log_info "覆盖拷贝 seaweedfs-values.yaml 到 ${VALUES}"
  log_command "cp -f \"${VALUES_SRC}\" \"${VALUES}\""
  [ -f "${VALUES}" ] || die "缺少 values 文件: ${VALUES}"
}

import_image_tar() {
  local image_tar="$1"
  tar -tf "${image_tar}" >/dev/null 2>&1 || die "镜像 tar 不可读/疑似损坏: ${image_tar}"

  if have ctr; then
    log_command "ctr -n k8s.io images import \"${image_tar}\""
    return 0
  fi
  if have nerdctl; then
    log_command "nerdctl -n k8s.io load -i \"${image_tar}\""
    return 0
  fi
  if have docker; then
    log_command "docker load -i \"${image_tar}\""
    return 0
  fi
  die "未找到可用镜像导入工具（ctr/nerdctl/docker）"
}

import_required_images() {
  local names=(
    seaweedfs.image.seaweedfs.v4.20.0
    seaweedfs-csi.image.driver.v1.4.8
    seaweedfs-csi.image.mount.v1.4.8
    seaweedfs-csi.image.csi-attacher.v4.3.0
    seaweedfs-csi.image.csi-node-driver-registrar.v2.8.0
    seaweedfs-csi.image.csi-provisioner.v3.5.0
    seaweedfs-csi.image.csi-resizer.v1.8.0
    seaweedfs-csi.image.livenessprobe.v2.10.0
  )
  local n f

  log_info "导入 SeaweedFS + CSI 组件所需镜像..."
  for n in "${names[@]}"; do
    f="$(artifact_get_path_by_name "${n}")"
    [ -f "${f}" ] || die "缺少制品: ${f} (name=${n})"
    log_info "导入镜像 tar: ${n}"
    import_image_tar "${f}"
  done
}

ensure_namespace() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace "${CSI_NS}" --dry-run=client -o yaml | kubectl apply -f -
}

deploy_or_upgrade() {
  if [ "${ACTION}" = "install" ]; then
    if helm -n "${NS}" status "${RELEASE}" >/dev/null 2>&1; then
      log_warn "检测到 ${RELEASE} 已存在，install 将转为 upgrade"
    fi
  fi

  log_info "执行 Helm 部署（install/upgrade 幂等）..."
  log_command "helm -n \"${NS}\" upgrade --install \"${RELEASE}\" \"${CHART}\" --create-namespace -f \"${VALUES}\""

  log_info "执行 SeaweedFS CSI Driver 部署（install/upgrade 幂等）..."
  log_command "helm -n \"${CSI_NS}\" upgrade --install \"${CSI_RELEASE}\" \"${CSI_CHART}\" --create-namespace --set seaweedfsFiler=\"${SEAWEEDFS_FILER}\""

  apply_storage_class
}

apply_storage_class() {
  local tmp_sc
  tmp_sc="$(mktemp -t seaweedfs-sc.XXXXXX.yaml)"
  # shellcheck disable=SC2064
  trap 'rm -f "${tmp_sc}"' EXIT

  cat > "${tmp_sc}" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_NAME}
provisioner: ${CSI_PROVISIONER}
reclaimPolicy: ${SC_RECLAIM_POLICY}
volumeBindingMode: ${SC_VOLUME_BINDING_MODE}
parameters:
  replication: "${SC_REPLICATION}"
EOF

  # StorageClass 的 parameters/reclaimPolicy/volumeBindingMode 为不可变字段；
  # 若现有对象与目标配置不一致，需先删除再重建。
  if kubectl get storageclass "${SC_NAME}" >/dev/null 2>&1; then
    local cur_provisioner cur_reclaim cur_binding cur_replication
    cur_provisioner="$(kubectl get storageclass "${SC_NAME}" -o jsonpath='{.provisioner}' 2>/dev/null || true)"
    cur_reclaim="$(kubectl get storageclass "${SC_NAME}" -o jsonpath='{.reclaimPolicy}' 2>/dev/null || true)"
    cur_binding="$(kubectl get storageclass "${SC_NAME}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || true)"
    cur_replication="$(kubectl get storageclass "${SC_NAME}" -o jsonpath='{.parameters.replication}' 2>/dev/null || true)"

    if [ "${cur_provisioner}" != "${CSI_PROVISIONER}" ] \
      || [ "${cur_reclaim}" != "${SC_RECLAIM_POLICY}" ] \
      || [ "${cur_binding}" != "${SC_VOLUME_BINDING_MODE}" ] \
      || [ "${cur_replication}" != "${SC_REPLICATION}" ]; then
      log_warn "StorageClass ${SC_NAME} 存在不可变字段差异，将删除后重建"
      log_command "kubectl delete storageclass \"${SC_NAME}\""
    fi
  fi

  log_info "应用 SeaweedFS StorageClass（name=${SC_NAME}, replication=${SC_REPLICATION}）..."
  log_command "kubectl create -f \"${tmp_sc}\" || kubectl apply -f \"${tmp_sc}\""

  trap - EXIT
  rm -f "${tmp_sc}"
}

uninstall_release() {
  if helm -n "${NS}" status "${RELEASE}" >/dev/null 2>&1; then
    log_info "卸载 ${RELEASE}..."
    log_command "helm -n \"${NS}\" uninstall \"${RELEASE}\""
  else
    log_warn "release ${RELEASE} 不存在，跳过卸载"
  fi

  if helm -n "${CSI_NS}" status "${CSI_RELEASE}" >/dev/null 2>&1; then
    log_info "卸载 ${CSI_RELEASE}..."
    log_command "helm -n \"${CSI_NS}\" uninstall \"${CSI_RELEASE}\""
  else
    log_warn "release ${CSI_RELEASE} 不存在，跳过卸载"
  fi
}

print_s3_credentials_hint() {
  log_info "SeaweedFS 部署完成。可用以下命令获取 S3 AK/SK："
  echo "kubectl -n ${NS} get secret ${RELEASE}-s3-secret -o jsonpath=\"{.data.admin_access_key_id}\" | base64 --decode; echo"
  echo "kubectl -n ${NS} get secret ${RELEASE}-s3-secret -o jsonpath=\"{.data.admin_secret_access_key}\" | base64 --decode; echo"
}

main() {
  init_env

  case "${ACTION}" in
    install|upgrade)
      import_required_images
      ensure_namespace
      deploy_or_upgrade
      print_s3_credentials_hint
      ;;
    uninstall)
      uninstall_release
      ;;
    *)
      die "不支持的动作: ${ACTION}（可选: install | upgrade | uninstall）"
      ;;
  esac
}

main "$@"

