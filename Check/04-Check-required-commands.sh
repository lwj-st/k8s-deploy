#!/usr/bin/env bash
set -euo pipefail

CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DEPLOY_ROOT="$(cd "${CHECK_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${K8S_DEPLOY_ROOT}/Script/framework.sh"

get_cur_path
init_logging
detect_os

have_cmd() { command -v "$1" >/dev/null 2>&1; }

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FAIL_ITEMS=()
WARN_ITEMS=()

check_required() {
  local cmd="$1"
  if have_cmd "${cmd}"; then
    log_info "  ✓ ${cmd}"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    log_error "  ✗ ${cmd}（必需）"
    FAIL_COUNT=$((FAIL_COUNT+1))
    FAIL_ITEMS+=("${cmd}")
  fi
}

check_recommended() {
  local cmd="$1"
  if have_cmd "${cmd}"; then
    log_info "  ✓ ${cmd}"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    log_warn "  ⚠ ${cmd}（推荐/条件命令）"
    WARN_COUNT=$((WARN_COUNT+1))
    WARN_ITEMS+=("${cmd}")
  fi
}

print_section() {
  local title="$1"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "${title}"
}

check_basic_required() {
  print_section "检查 1/8：基础必需命令"
  local cmds=(
    chmod chown cp date dirname basename id ls mkdir mktemp mv printf pwd rm rmdir tac tr tar xargs
  )
  local c
  for c in "${cmds[@]}"; do
    check_required "${c}"
  done
}

check_text_required() {
  print_section "检查 2/8：文本处理必需命令"
  local cmds=(awk cut sed sort tee uniq)
  local c
  for c in "${cmds[@]}"; do
    check_required "${c}"
  done
  # 文档中写的是 grep；仓库脚本核心依赖 grep，因此仍按必需检查。
  check_required "grep"
}

check_system_required() {
  print_section "检查 3/8：系统管理必需命令"
  local cmds=(getent hostname modprobe swapoff sysctl systemctl)
  local c
  for c in "${cmds[@]}"; do
    check_required "${c}"
  done
  # SELinux 相关：无 SELinux 的系统可不装，按推荐项处理。
  check_recommended "getenforce"
  check_recommended "setenforce"
}

check_network_required() {
  print_section "检查 4/8：网络与下载命令"
  local cmds=(curl ip iptables ip6tables ss wget)
  local c
  for c in "${cmds[@]}"; do
    check_required "${c}"
  done
  check_recommended "exportfs"
  check_recommended "ipvsadm"
}

check_pkg_tooling() {
  print_section "检查 5/8：包管理与校验命令"
  check_required "md5sum"
  check_recommended "gpg"

  case "${OS_ID}" in
    ubuntu|debian)
      check_required "apt-cache"
      check_required "apt-get"
      check_required "dpkg"
      check_required "dpkg-query"
      ;;
    centos|rocky|openeuler|kylin*)
      check_required "rpm"
      if have_cmd dnf || have_cmd yum; then
        if have_cmd dnf; then
          log_info "  ✓ dnf"
          PASS_COUNT=$((PASS_COUNT+1))
        fi
        if have_cmd yum; then
          log_info "  ✓ yum"
          PASS_COUNT=$((PASS_COUNT+1))
        fi
      else
        log_error "  ✗ dnf/yum（rpm 系至少需要一个）"
        FAIL_COUNT=$((FAIL_COUNT+1))
        FAIL_ITEMS+=("dnf_or_yum")
      fi
      check_recommended "yumdownloader"
      check_recommended "repotrack"
      ;;
    *)
      log_warn "  ⚠ 未识别发行版（OS_ID=${OS_ID}），跳过 apt/rpm 发行版专属检查"
      WARN_COUNT=$((WARN_COUNT+1))
      WARN_ITEMS+=("os_pkg_manager_unknown")
      ;;
  esac
}

# Script/30-Deploy-rsyslog.sh：与日志集中、外发、kube-apiserver audit 直接相关的可执行文件。
# 不含 apt-get/dnf/systemctl 等通用项（见上文各节）；rsyslogd 多由该脚本安装，未装时仅告警。
check_rsyslog_30_deploy_related() {
  print_section "检查 6/8：30-Deploy-rsyslog 日志外发脚本相关命令"
  log_info "  （rsyslogd 若缺失，脚本会尝试在线/离线安装；以下其余项按现场角色补齐）"
  check_recommended "rsyslogd"
  check_recommended "openssl"
  check_recommended "python3"
  check_recommended "logrotate"
  check_recommended "journalctl"
  check_recommended "logger"
  check_recommended "egrep"
  check_recommended "service"
  check_recommended "killall"
}

check_container_k8s() {
  print_section "检查 7/8：容器与 Kubernetes 相关命令"
  local recommended_cmds=(containerd ctr helm helmfile kubeadm kubectl kubelet)
  local c
  for c in "${recommended_cmds[@]}"; do
    check_recommended "${c}"
  done
  check_recommended "docker"
  check_recommended "podman"
}

check_accelerator_related() {
  print_section "检查 8/8：加速卡相关命令（按需）"
  # GPU 相关命令在未启用 GPU 节点时不应作为失败条件。
  check_recommended "nvidia-smi"
  check_recommended "nvidia-ctk"
  check_recommended "lspci"
}

print_summary_and_exit() {
  print_section "检查结果汇总"
  log_info "通过: ${PASS_COUNT}"
  log_info "告警: ${WARN_COUNT}"
  log_info "失败: ${FAIL_COUNT}"

  if [ "${WARN_COUNT}" -gt 0 ]; then
    log_info "告警项: ${WARN_ITEMS[*]}"
  fi
  if [ "${FAIL_COUNT}" -gt 0 ]; then
    log_error "失败项: ${FAIL_ITEMS[*]}"
    log_error "命令检查未通过，请补齐失败项后重试。"
    exit 1
  fi

  log_info "命令检查通过。"
}

main() {
  print_section "仓库依赖命令检查"
  log_info "OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}"
  check_basic_required
  check_text_required
  check_system_required
  check_network_required
  check_pkg_tooling
  check_rsyslog_30_deploy_related
  check_container_k8s
  check_accelerator_related
  print_summary_and_exit
}

main "$@"
