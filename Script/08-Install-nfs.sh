#!/usr/bin/env bash
################################################################################
## Filename:    08-Install-nfs.sh
## Description: 按 environment.sh 中 NFS 配置安装本机 NFS 服务端
## Usage:
##   bash 08-Install-nfs.sh
## Artifacts:
##   - os.dir.tools.<os_id>.<os_version>
## Env:
##   - NFS_SERVER/NFS_PATH: 为空时跳过
##   - ALLOW_ONLINE: yes 时允许使用系统源补齐依赖，默认 no
## Notes:
##   - 21-Deploy-nfs-provisioner.sh 的前置条件
##   - 已安装 NFS 服务端包时跳过
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root

run_command_argv() {
  local rendered=""
  printf -v rendered ' %q' "$@"
  log_info "执行命令:${rendered}"
  "$@"
}

install_ubuntu_nfs_from_repo() {
  local dir="$1"
  [ -f "${dir}/Packages" ] || [ -f "${dir}/Packages.gz" ] || \
    die "NFS 离线 DEB 目录缺少 Packages/Packages.gz，请重新执行工具包下载脚本: ${dir}"

  local apt_tmp
  apt_tmp="$(mktemp -d /tmp/k8s-deploy-nfs-apt.XXXXXX)"
  mkdir -p "${apt_tmp}/lists/partial"
  chmod 755 "${apt_tmp}" "${apt_tmp}/lists"
  printf 'deb [trusted=yes] file:%s ./\n' "${dir}" > "${apt_tmp}/sources.list"

  local -a apt_opts=(
    -o "Dir::Etc::sourcelist=${apt_tmp}/sources.list"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State::lists=${apt_tmp}/lists"
    -o "APT::Get::List-Cleanup=0"
  )
  local install_ok=0

  if run_command_argv apt-get "${apt_opts[@]}" update && \
    run_command_argv apt-get "${apt_opts[@]}" install -y --no-download --no-remove --no-install-recommends nfs-kernel-server; then
    install_ok=1
  fi
  rm -rf "${apt_tmp}"

  if [ "${install_ok}" -eq 1 ]; then
    return 0
  fi
  if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
    log_warn "本地 APT 仓库依赖不足，ALLOW_ONLINE=yes，回退到系统软件源"
    run_command_argv apt-get update
    run_command_argv apt-get install -y --no-remove --no-install-recommends nfs-kernel-server
    return 0
  fi
  die "严格离线安装 nfs-kernel-server 失败，请重新下载完整依赖"
}

install_rpm_nfs_from_repo() {
  local dir="$1"
  [ -f "${dir}/repodata/repomd.xml" ] || \
    die "NFS 离线 RPM 目录缺少 repodata/repomd.xml，请重新执行工具包下载脚本: ${dir}"

  local repo_id="k8s-deploy-nfs-offline"
  local repo_url="file://${dir}"
  if have dnf; then
    if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      run_command_argv dnf -y \
        --repofrompath="${repo_id},${repo_url}" \
        --setopt="${repo_id}.gpgcheck=0" \
        --setopt="${repo_id}.repo_gpgcheck=0" \
        install nfs-utils || die "dnf 安装 nfs-utils 失败"
    else
      run_command_argv dnf -y \
        --disablerepo='*' \
        --repofrompath="${repo_id},${repo_url}" \
        --enablerepo="${repo_id}" \
        --setopt="${repo_id}.gpgcheck=0" \
        --setopt="${repo_id}.repo_gpgcheck=0" \
        --setopt=install_weak_deps=False \
        install nfs-utils || die "严格离线安装 nfs-utils 失败，请重新下载完整依赖"
    fi
  elif have yum; then
    if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      run_command_argv yum -y \
        --repofrompath="${repo_id},${repo_url}" \
        --setopt="${repo_id}.gpgcheck=0" \
        install nfs-utils || die "yum 安装 nfs-utils 失败"
    else
      run_command_argv yum -y \
        --disablerepo='*' \
        --repofrompath="${repo_id},${repo_url}" \
        --enablerepo="${repo_id}" \
        --setopt="${repo_id}.gpgcheck=0" \
        install nfs-utils || die "严格离线安装 nfs-utils 失败，请重新下载完整依赖"
    fi
  else
    die "未找到 dnf 或 yum，无法安全解析 NFS RPM 依赖"
  fi
}

# 未配置 NFS 则跳过
if [ -z "${NFS_SERVER:-}" ] || [ -z "${NFS_PATH:-}" ]; then
  log_info "未配置 NFS（NFS_SERVER/NFS_PATH 为空），跳过安装 NFS 服务端"
  exit 0
fi

# 判断当前是否已安装 NFS 服务端（dpkg -l 未安装时也返回 0 且列出 un 状态，须看 Status）
nfs_installed=0
case "${OS_ID}" in
  ubuntu)
    if dpkg-query -W -f='${Status}' nfs-kernel-server 2>/dev/null | grep -q 'install ok installed'; then
      nfs_installed=1
    fi
    nfs_pkg_name="nfs-kernel-server"
    tools_subdir="nfs-kernel-server"
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
  tools_base="$(artifact_get_os_tools_dir "${OS_ID}" "${TARGET_OS_VERSION}")"

  nfs_dir="${tools_base}/${tools_subdir}"
  if [ ! -d "${nfs_dir}" ]; then
    die "未找到 NFS 离线包目录: ${nfs_dir}（请先执行 00-Download-tools-packages-docker.sh 下载对应 OS 工具包）"
  fi

  case "${OS_ID}" in
    ubuntu)
      install_ubuntu_nfs_from_repo "${nfs_dir}"
      ;;
    *)
      install_rpm_nfs_from_repo "${nfs_dir}"
      ;;
  esac
fi

case "${OS_ID}" in
  ubuntu)
    dpkg-query -W -f='${Status}' nfs-kernel-server 2>/dev/null | grep -q 'install ok installed' || \
      die "NFS 安装完成后仍未检测到 nfs-kernel-server"
    ;;
  *)
    rpm -q nfs-utils >/dev/null 2>&1 || die "NFS 安装完成后仍未检测到 nfs-utils"
    ;;
esac

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

log_info "NFS 服务端安装与 export 完成（后续可执行 21-Deploy-nfs-provisioner.sh）"
