#!/usr/bin/env bash
################################################################################
## Filename:    13-Install-k8s-packages.sh
## Description: 按当前 OS 安装 Kubernetes 离线 deb/rpm 包
## Usage:
##   bash 13-Install-k8s-packages.sh
## Artifacts:
##   - os.dir.kubernetes.<os_id>.<os_version>
## Env:
##   - ALLOW_ONLINE: yes 时允许部分在线兜底
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

install_offline_debs() {
  local dir="$1"
  [ -d "$dir" ] || die "离线 deb 目录不存在: $dir"
  have dpkg-deb || die "当前系统未找到 dpkg-deb，无法读取离线 DEB"
  have dpkg-query || die "当前系统未找到 dpkg-query，无法检查已安装包"
  have apt-get || die "当前系统未找到 apt-get，无法安全解析 DEB 依赖"

  shopt -s nullglob
  local pkgs=("$dir"/*.deb)
  shopt -u nullglob
  [ ${#pkgs[@]} -gt 0 ] || die "离线 deb 目录为空: $dir"
  [ -f "${dir}/Packages" ] || [ -f "${dir}/Packages.gz" ] || \
    die "离线 DEB 目录缺少 Packages/Packages.gz，请重新执行下载脚本生成本地 APT 仓库元数据: ${dir}"

  local system_arch
  system_arch="$(dpkg --print-architecture)"
  local -a root_specs=()
  local pkg name version arch
  local has_kubelet=0 has_kubeadm=0 has_kubectl=0
  declare -A seen_names=()

  for pkg in "${pkgs[@]}"; do
    name="$(dpkg-deb -f "${pkg}" Package 2>/dev/null || true)"
    version="$(dpkg-deb -f "${pkg}" Version 2>/dev/null || true)"
    arch="$(dpkg-deb -f "${pkg}" Architecture 2>/dev/null || true)"
    if [ -z "${name}" ] || [ -z "${version}" ] || [ -z "${arch}" ]; then
      die "无法读取 DEB 元数据，文件可能损坏: ${pkg}"
    fi
    if [ "${arch}" != "all" ] && [ "${arch}" != "${system_arch}" ]; then
      die "DEB 架构不匹配: $(basename "${pkg}")（包架构=${arch}，系统架构=${system_arch}）"
    fi
    if [ -n "${seen_names[${name}]:-}" ]; then
      die "离线目录存在同名 DEB，请清理旧版本后重试: ${name}（${seen_names[${name}]}、$(basename "${pkg}")）"
    fi
    seen_names["${name}"]="$(basename "${pkg}")"

    case "${name}" in
      kubelet)
        has_kubelet=1
        root_specs+=("${name}=${version}")
        ;;
      kubeadm)
        has_kubeadm=1
        root_specs+=("${name}=${version}")
        ;;
      kubectl)
        has_kubectl=1
        root_specs+=("${name}=${version}")
        ;;
    esac
  done

  [ "${has_kubelet}" -eq 1 ] || die "离线目录缺少 kubelet DEB: ${dir}"
  [ "${has_kubeadm}" -eq 1 ] || die "离线目录缺少 kubeadm DEB: ${dir}"
  [ "${has_kubectl}" -eq 1 ] || die "离线目录缺少 kubectl DEB: ${dir}"

  local apt_tmp
  apt_tmp="$(mktemp -d /tmp/k8s-deploy-k8s-apt.XXXXXX)"
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

  log_info "本地 APT 仓库已就绪：目录共 ${#pkgs[@]} 个 DEB，仅请求 ${#root_specs[@]} 个 Kubernetes 主包"
  if run_command_argv apt-get "${apt_opts[@]}" update && \
    run_command_argv apt-get "${apt_opts[@]}" install -y --no-remove \
      --no-install-recommends --allow-change-held-packages "${root_specs[@]}"; then
    install_ok=1
  fi
  rm -rf "${apt_tmp}"

  if [ "${install_ok}" -eq 1 ]; then
    return 0
  fi
  if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
    log_warn "本地 APT 仓库依赖不足，ALLOW_ONLINE=yes，回退到系统软件源"
    run_command_argv apt-get update
    run_command_argv apt-get install -y --no-remove --no-install-recommends \
      --allow-change-held-packages "${root_specs[@]}"
    return 0
  fi
  die "严格离线安装 Kubernetes DEB 失败，请重新下载完整依赖"
}

install_offline_rpms() {
  local dir="$1"
  [ -d "$dir" ] || die "离线 rpm 目录不存在: $dir"
  have rpm || die "当前系统未找到 rpm，无法读取或安装离线 RPM"
  if ! have dnf && ! have yum; then
    die "当前系统未找到 dnf 或 yum，无法安全解析 RPM 依赖"
  fi
  shopt -s nullglob
  local pkgs=("$dir"/*.rpm)
  shopt -u nullglob
  [ ${#pkgs[@]} -gt 0 ] || die "离线 rpm 目录为空: $dir"

  # 下载目录由 dnf download --resolve --alldeps 生成，除了 Kubernetes 主包，
  # 还包含完整的候选依赖集合。不能把“所有未安装 RPM”都显式提交给 dnf：
  # 其中可能有并未被 Kubernetes 使用的包，或者与宿主机版本不匹配的包。
  # 正确做法是把整个目录作为只读本地仓库，只请求 Kubernetes 主包，
  # 让 dnf/yum 根据宿主机现状从仓库中选择真正需要的依赖。
  [ -f "${dir}/repodata/repomd.xml" ] || \
    die "离线 RPM 目录缺少 repodata/repomd.xml，请重新执行下载脚本生成本地仓库元数据后再安装: ${dir}"

  local system_arch
  system_arch="$(rpm --eval '%{_arch}')"
  local -a root_specs=()
  local pkg name arch nevra
  local has_kubelet=0 has_kubeadm=0 has_kubectl=0
  declare -A seen_names=()

  for pkg in "${pkgs[@]}"; do
    name="$(rpm -qp --qf '%{NAME}' "${pkg}" 2>/dev/null || true)"
    arch="$(rpm -qp --qf '%{ARCH}' "${pkg}" 2>/dev/null || true)"
    if [ -z "${name}" ] || [ -z "${arch}" ]; then
      die "无法读取 RPM 元数据，文件可能损坏: ${pkg}"
    fi

    if [ "${arch}" != "noarch" ] && [ "${arch}" != "${system_arch}" ]; then
      die "RPM 架构不匹配: $(basename "${pkg}")（包架构=${arch}，系统架构=${system_arch}）"
    fi
    if [ -n "${seen_names[${name}]:-}" ]; then
      die "离线目录存在同名 RPM，请清理旧版本后重试: ${name}（${seen_names[${name}]}、$(basename "${pkg}")）"
    fi
    seen_names["${name}"]="$(basename "${pkg}")"

    case "${name}" in
      kubelet|kubeadm|kubectl|cri-tools|kubernetes-cni)
        nevra="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "${pkg}")"
        root_specs+=("${nevra}")
        case "${name}" in
          kubelet) has_kubelet=1 ;;
          kubeadm) has_kubeadm=1 ;;
          kubectl) has_kubectl=1 ;;
        esac
        ;;
    esac
  done

  [ "${has_kubelet}" -eq 1 ] || die "离线目录缺少 kubelet RPM: ${dir}"
  [ "${has_kubeadm}" -eq 1 ] || die "离线目录缺少 kubeadm RPM: ${dir}"
  [ "${has_kubectl}" -eq 1 ] || die "离线目录缺少 kubectl RPM: ${dir}"

  local repo_id="k8s-deploy-offline"
  local repo_url="file://${dir}"
  log_info "离线仓库已就绪：目录共 ${#pkgs[@]} 个 RPM，仅请求 ${#root_specs[@]} 个 Kubernetes 主包"
  if have dnf; then
    if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      run_command_argv dnf -y \
        --repofrompath="${repo_id},${repo_url}" \
        --setopt="${repo_id}.gpgcheck=0" \
        --setopt="${repo_id}.repo_gpgcheck=0" \
        install "${root_specs[@]}" || \
        die "dnf 安装失败；为保护系统，脚本不会使用 --allowerasing 删除已有软件包"
    else
      run_command_argv dnf -y \
        --disablerepo='*' \
        --repofrompath="${repo_id},${repo_url}" \
        --enablerepo="${repo_id}" \
        --setopt="${repo_id}.gpgcheck=0" \
        --setopt="${repo_id}.repo_gpgcheck=0" \
        --setopt=install_weak_deps=False \
        install "${root_specs[@]}" || \
        die "严格离线 dnf 安装失败；请检查离线依赖是否齐全或是否与目标机系统版本冲突"
    fi
  else
    if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      run_command_argv yum -y \
        --repofrompath="${repo_id},${repo_url}" \
        --setopt="${repo_id}.gpgcheck=0" \
        install "${root_specs[@]}" || die "yum 安装失败"
    else
      run_command_argv yum -y \
        --disablerepo='*' \
        --repofrompath="${repo_id},${repo_url}" \
        --enablerepo="${repo_id}" \
        --setopt="${repo_id}.gpgcheck=0" \
        install "${root_specs[@]}" || \
        die "严格离线 yum 安装失败；请检查离线依赖是否齐全或是否与目标机系统版本冲突"
    fi
  fi
}

if [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
  log_warn "ALLOW_ONLINE=yes：允许在线安装（若你希望严格离线，请把 ALLOW_ONLINE 设为 no）"
fi

case "${OS_ID}" in
  ubuntu)
    deb_dir="$(artifact_get_os_kubernetes_dir "${OS_ID}" "${TARGET_OS_VERSION}")"
    if [ -d "${deb_dir}" ]; then
      install_offline_debs "${deb_dir}"
    elif [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      log_command "apt-get update"
      # 兼容已被 hold 的包（重复执行/系统预装场景）
      log_command "apt-get install -y --allow-change-held-packages kubelet kubeadm kubectl"
      log_command "apt-mark hold kubelet kubeadm kubectl || true"
    else
      die "缺少离线包目录：${deb_dir}（并且 ALLOW_ONLINE=no）"
    fi
    ;;
  centos|rocky|openeuler|kylin)
    rpm_dir="$(artifact_get_os_kubernetes_dir "${OS_ID}" "${TARGET_OS_VERSION}")"

    if [ -d "${rpm_dir}" ]; then
      install_offline_rpms "${rpm_dir}"
    elif [ "${ALLOW_ONLINE:-no}" = "yes" ]; then
      # 在线安装包名可能因发行版差异而不同，这里只给出兜底提示
      die "在线安装 rpm 系发行版尚未内置（请先准备离线 rpm：${rpm_dir}）"
    else
      die "缺少离线包目录：${rpm_dir}（并且 ALLOW_ONLINE=no）"
    fi
    ;;
  *)
    die "不支持的 OS_ID=${OS_ID}，请补充 manifests/artifacts.yaml 中的 OS 离线包目录并扩展脚本"
    ;;
esac

for required_command in kubelet kubeadm kubectl; do
  have "${required_command}" || die "Kubernetes 包安装后仍未找到命令: ${required_command}"
done

if have systemctl; then
  log_command "systemctl enable kubelet"
  log_command "systemctl restart kubelet || true"
fi

log_info "k8s 包安装完成"
