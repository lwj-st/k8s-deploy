#!/usr/bin/env bash
set -euo pipefail

################################################################################
## 08-install-nfs.sh：按 environment.sh 中 NFS 配置，在本机安装 NFS 服务端（若未安装）
## - 18-Deploy-nfs-provisioner.sh 脚本前置条件
## - 若 NFS_SERVER 为空则跳过（未配置 NFS）
## - 若已安装 NFS 服务端包则跳过
## - 否则从 DOWNLOAD_DIR/packages/tools/<os>/ 下对应子目录离线安装
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root

# 未配置 NFS 则跳过
if [ -z "${NFS_SERVER:-}" ] || [ -z "${NFS_PATH:-}" ]; then
  log_info "未配置 NFS（NFS_SERVER/NFS_PATH 为空），跳过安装 NFS 服务端"
  exit 0
fi

# 判断当前是否已安装 NFS 服务端（dpkg -l 未安装时也返回 0 且列出 un 状态，须看 Status）
nfs_installed=0
case "${OS_ID}" in
  ubuntu|debian)
    if dpkg-query -W -f='${Status}' nfs-kernel-server 2>/dev/null | grep -q 'install ok installed'; then
      nfs_installed=1
    fi
    nfs_pkg_name="nfs-kernel-server"
    tools_subdir="nfs-kernel-server"
    ;;
  rhel|almalinux)
    die "OS_ID=${OS_ID} 已剔除：不再提供离线 NFS 安装包"
    ;;
  centos|rocky|openeuler|kylin*)
    if rpm -q nfs-utils &>/dev/null; then
      nfs_installed=1
    fi
    nfs_pkg_name="nfs-utils"
    tools_subdir="nfs-utils"
    ;;
  *)
    log_warn "未识别的 OS_ID=${OS_ID}，跳过 NFS 安装"
    exit 0
    ;;
esac

if [ "$nfs_installed" -eq 1 ]; then
  log_info "NFS 服务端（${nfs_pkg_name}）已安装，跳过安装步骤"
else
  # 确定离线包目录：DOWNLOAD_DIR/packages/tools/<os_id>
  case "${OS_ID}" in
    ubuntu|debian)
      tools_base="${DOWNLOAD_DIR}/packages/tools/ubuntu"
      ;;
    centos)
      tools_base="${DOWNLOAD_DIR}/packages/tools/centos"
      ;;
    rocky)
      tools_base="${DOWNLOAD_DIR}/packages/tools/rocky"
      ;;
    openeuler)
      tools_base="${DOWNLOAD_DIR}/packages/tools/openeuler"
      ;;
    kylin*)
      tools_base="${DOWNLOAD_DIR}/packages/tools/kylin"
      ;;
    *)
      die "未识别的 OS_ID=${OS_ID}：请补齐 /packages/tools/<os_id> 离线工具目录"
      ;;
  esac

  nfs_dir="${tools_base}/${tools_subdir}"
  if [ ! -d "${nfs_dir}" ]; then
    die "未找到 NFS 离线包目录: ${nfs_dir}（请先执行 00-Download-tools-packages-docker.sh 下载对应 OS 工具包）"
  fi

  case "${OS_ID}" in
    ubuntu|debian)
      shopt -s nullglob
      debs=("${nfs_dir}"/*.deb)
      shopt -u nullglob
      [ ${#debs[@]} -gt 0 ] || die "目录为空: ${nfs_dir}"
      log_command "dpkg -i ${nfs_dir}/*.deb"
      ;;
    *)
      shopt -s nullglob
      rpms=("${nfs_dir}"/*.rpm)
      shopt -u nullglob
      [ ${#rpms[@]} -gt 0 ] || die "目录为空: ${nfs_dir}"
      if have dnf; then
        log_command "dnf -y install ${nfs_dir}/*.rpm"
      else
        log_command "yum -y localinstall ${nfs_dir}/*.rpm"
      fi
      ;;
  esac
fi

# 启用并启动 NFS 服务（服务名：Ubuntu nfs-kernel-server，RHEL 系 nfs-server）
if have systemctl; then
  for svc in nfs-server nfs-kernel-server; do
    if systemctl list-unit-files --type=service | grep -q "^${svc}.service"; then
      log_command "systemctl enable ${svc}"
      log_command "systemctl start ${svc} || true"
      break
    fi
  done
fi

# 配置 export：创建目录、写入 /etc/exports、执行 exportfs
log_info "配置 NFS export: ${NFS_PATH}"
mkdir -p "${NFS_PATH}"
chmod 755 "${NFS_PATH}"

exports_file="/etc/exports"
export_line="${NFS_PATH} *(rw,sync,no_subtree_check,no_root_squash)"
if [ -f "${exports_file}" ]; then
  if grep -qE "^[[:space:]]*${NFS_PATH}[[:space:]]+" "${exports_file}" 2>/dev/null; then
    log_info "已在 ${exports_file} 中存在 ${NFS_PATH} 的 export，跳过写入"
  else
    echo "${export_line}" >> "${exports_file}"
    log_info "已追加: ${export_line} -> ${exports_file}"
  fi
else
  echo "${export_line}" > "${exports_file}"
  log_info "已创建 ${exports_file} 并写入: ${export_line}"
fi

if command -v exportfs &>/dev/null; then
  log_command "exportfs -ra"
else
  log_command "systemctl restart nfs-server || systemctl restart nfs-kernel-server || true"
fi

log_info "NFS 服务端安装与 export 完成（后续可执行 18-Deploy-nfs-provisioner.sh）"
