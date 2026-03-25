#!/usr/bin/env bash
# K8s 前置条件：节点应关闭 swap（运行时与 fstab 均不应启用 swap）

CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DEPLOY_ROOT="$(cd "${CHECK_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${K8S_DEPLOY_ROOT}/Script/framework.sh"

get_cur_path
init_logging
detect_os

SWAP_ACTIVE=0
SWAP_FSTAB=0

print_solution() {
  local msg="$1"
  log_info ""
  log_info "  [解决方案]"
  echo "$msg" | sed 's/^/  /' | while IFS= read -r line; do
    log_info "  ${line}"
  done
  log_info ""
}

check_runtime_swap() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 1/2：当前运行时是否启用 swap（swapon）"

  if ! have swapon; then
    log_warn "  ⚠ 未找到 swapon 命令，跳过运行时 swap 检查"
    return 0
  fi

  if swapon --show 2>/dev/null | grep -q .; then
    log_error "  ✗ 当前已启用 swap（Kubernetes 要求关闭）"
    swapon --show 2>/dev/null | sed 's/^/  /' | while IFS= read -r line; do
      log_info "  ${line}"
    done
    SWAP_ACTIVE=1
  else
    log_info "  ✓ 运行时未启用 swap"
  fi
}

check_fstab_swap() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 2/2：/etc/fstab 是否存在未注释的 swap 条目"

  if [ ! -r /etc/fstab ]; then
    log_warn "  ⚠ 无法读取 /etc/fstab，跳过 fstab 检查"
    return 0
  fi

  if grep -E '^[^#].*\sswap\s' /etc/fstab >/dev/null 2>&1; then
    log_error "  ✗ /etc/fstab 中存在 swap 条目（重启后可能再次启用 swap）"
    grep -E '^[^#].*\sswap\s' /etc/fstab | sed 's/^/  /' | while IFS= read -r line; do
      log_info "  ${line}"
    done
    SWAP_FSTAB=1
  else
    log_info "  ✓ /etc/fstab 中无有效 swap 挂载行"
  fi
}

main() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "Kubernetes 节点 Swap 检查"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}"
  log_info ""

  check_runtime_swap
  check_fstab_swap

  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查结果汇总"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ $SWAP_ACTIVE -eq 0 && $SWAP_FSTAB -eq 0 ]]; then
    log_info "  ✓ 通过：swap 已完全关闭，符合 Kubernetes 节点要求"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "检查完成"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
  fi

  log_warn "  ✗ 未通过：swap 未完全关闭"

  if [[ $SWAP_ACTIVE -eq 1 ]]; then
    print_solution "立即关闭 swap（当前会话生效）：
  sudo swapoff -a"
  fi

  if [[ $SWAP_FSTAB -eq 1 ]]; then
    print_solution "永久关闭 swap（避免重启后再次挂载）：
  1. 编辑 /etc/fstab
  2. 将含 swap 的行在行首加 # 注释掉
  示例：
  # /swap.img none swap sw 0 0"
  fi

  log_info "修复后请重新执行本脚本以确认。"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查完成（存在待处理问题）"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
}

main "$@"
