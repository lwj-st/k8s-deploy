#!/usr/bin/env bash
set -euo pipefail

CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DEPLOY_ROOT="$(cd "${CHECK_DIR}/.." && pwd)"

# 复用日志/工具函数
# shellcheck disable=SC1091
source "${K8S_DEPLOY_ROOT}/Script/framework.sh"

get_cur_path
init_logging
detect_os

TARGET_NOFILE=65535
INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
INGRESS_LABEL_SELECTOR="${INGRESS_LABEL_SELECTOR:-app.kubernetes.io/component=controller}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

print_solution() {
  local msg="$1"
  log_info ""
  log_info "  [解决方案]"
  echo "$msg" | sed 's/^/  /' | while IFS= read -r line; do
    log_info "  ${line}"
  done
  log_info ""
}

check_shell_ulimit() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 1/4：当前 shell 进程的 nofile 限制（ulimit -n）"

  local cur
  if cur="$(ulimit -n 2>/dev/null)"; then
    log_info "  当前 shell: ulimit -n = ${cur}"
    if [ "${cur}" -lt "${TARGET_NOFILE}" ]; then
      log_error "  ✗ ulimit -n 小于推荐值 ${TARGET_NOFILE}"
      print_solution "临时生效（当前会话，重启失效）：
  ulimit -n ${TARGET_NOFILE}

如需永久生效，请继续参考后续 systemd/limits.conf 检查项。"
    else
      log_info "  ✓ ulimit -n 已达到或超过 ${TARGET_NOFILE}"
    fi
  else
    log_warn "  ⚠ 无法执行 ulimit -n"
  fi
}

check_proc_limits() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 2/4：/proc/self/limits 中的 Max open files（软/硬限制）"

  if [ ! -r /proc/self/limits ]; then
    log_warn "  ⚠ 无法读取 /proc/self/limits"
    return
  fi

  local line soft hard
  line="$(grep -E '^Max open files' /proc/self/limits || true)"
  if [ -z "${line}" ]; then
    log_warn "  ⚠ /proc/self/limits 中未找到 Max open files 项"
    return
  fi

  # Max open files            1024                524288              files
  soft="$(echo "${line}" | awk '{print $4}')"
  hard="$(echo "${line}" | awk '{print $5}')"

  log_info "  Max open files (soft,hard) = (${soft}, ${hard})"

  local fail=0
  if [ "${soft}" != "unlimited" ] && [ "${soft}" -lt "${TARGET_NOFILE}" ]; then
    log_error "  ✗ soft nofile 小于推荐值 ${TARGET_NOFILE}"
    fail=1
  fi
  if [ "${hard}" != "unlimited" ] && [ "${hard}" -lt "${TARGET_NOFILE}" ]; then
    log_error "  ✗ hard nofile 小于推荐值 ${TARGET_NOFILE}"
    fail=1
  fi

  if [ "${fail}" -eq 0 ]; then
    log_info "  ✓ soft/hard nofile 均已达到或超过 ${TARGET_NOFILE}（或为 unlimited）"
  else
    print_solution "建议在 /etc/security/limits.conf（及必要的 limits.d/*.conf）中添加如下行：
  * soft nofile ${TARGET_NOFILE}
  * hard nofile ${TARGET_NOFILE}
  root soft nofile ${TARGET_NOFILE}
  root hard nofile ${TARGET_NOFILE}

修改完成后，需要重新登录会话或重启相关服务，配合 systemd 限制一起生效。"
  fi
}

check_systemd_limits() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 3/4：systemd 级别的 NOFILE 限制（全局 + kubelet/containerd 单元）"

  if ! have_cmd systemctl; then
    log_warn "  ⚠ 未发现 systemctl，跳过 systemd 相关检查"
    return
  fi

  # 全局 DefaultLimitNOFILE
  local sys_conf user_conf
  sys_conf="$(grep -E '^[[:space:]]*DefaultLimitNOFILE=' /etc/systemd/system.conf 2>/dev/null || true)"
  user_conf="$(grep -E '^[[:space:]]*DefaultLimitNOFILE=' /etc/systemd/user.conf 2>/dev/null || true)"

  if [ -n "${sys_conf}${user_conf}" ]; then
    log_info "  system.conf 中的 DefaultLimitNOFILE 行：${sys_conf:-<未设置>}"
    log_info "  user.conf   中的 DefaultLimitNOFILE 行：${user_conf:-<未设置>}"
  else
    log_info "  未在 system.conf/user.conf 中显式设置 DefaultLimitNOFILE（将使用系统默认值，这通常是可以接受的）"
  fi

  # 检查 kubelet/containerd 的实际 LimitNOFILE
  local unit
  for unit in kubelet.service containerd.service; do
    if systemctl status "${unit}" >/dev/null 2>&1; then
      local limit
      limit="$(systemctl show "${unit}" -p LimitNOFILE 2>/dev/null | cut -d= -f2 || true)"
      if [ -z "${limit}" ]; then
        log_warn "  ⚠ ${unit}: 未获取到 LimitNOFILE"
        continue
      fi
      log_info "  ${unit}: LimitNOFILE=${limit}"

      if [ "${limit}" != "infinity" ] && [ "${limit}" -lt "${TARGET_NOFILE}" ]; then
        log_error "  ✗ ${unit} 的 LimitNOFILE 小于推荐值 ${TARGET_NOFILE}"
        print_solution "典型报错表现（示例）：
  - ingress-nginx-controller 日志中出现：\"no file descriptors available\"
  - 业务 Pod 无法建立新连接、偶发 I/O 失败

建议：
1) 编辑 /etc/systemd/system.conf 和 /etc/systemd/user.conf，取消注释或添加：
   DefaultLimitNOFILE=${TARGET_NOFILE}

2) 如有针对此服务的 override 文件（systemctl edit ${unit}），可在 [Service] 中显式设置：
   LimitNOFILE=${TARGET_NOFILE}

3) 重新加载 systemd 配置并重启服务（会重启节点上 Pod，请在维护窗口操作）：
   sudo systemctl daemon-reexec
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   sudo systemctl restart containerd

4) 重启后，删除相关 Pod 让其重新拉起（例如 ingress-nginx-controller）：
   kubectl -n ${INGRESS_NS} delete pod -l ${INGRESS_LABEL_SELECTOR}"
      fi
    else
      log_warn "  ⚠ 未发现 systemd 单元：${unit}，跳过该服务的 LimitNOFILE 检查"
    fi
  done
}

check_ingress_fd_keyword() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 4/4：ingress-nginx 日志关键字（No file descriptors available）"

  if ! have_cmd kubectl; then
    log_warn "  ⚠ 未发现 kubectl，跳过 ingress 日志关键字检查"
    return
  fi
  if ! kubectl version --request-timeout=3s >/dev/null 2>&1; then
    log_warn "  ⚠ 集群不可达，跳过 ingress 日志关键字检查"
    return
  fi

  local pods
  pods="$(kubectl -n "${INGRESS_NS}" get pod -l "${INGRESS_LABEL_SELECTOR}" -o name 2>/dev/null || true)"
  if [ -z "${pods}" ]; then
    log_warn "  ⚠ 未找到 ingress controller Pod（ns=${INGRESS_NS}, selector=${INGRESS_LABEL_SELECTOR}）"
    return
  fi

  local hit=0
  local pod
  for pod in ${pods}; do
    if kubectl -n "${INGRESS_NS}" logs "${pod#pod/}" --tail=300 2>/dev/null | grep -qiE 'no file descriptors available|socket\(\).*failed \(24:'; then
      log_error "  ✗ 在 ${pod} 日志中命中 FD 耗尽关键字"
      hit=1
    else
      log_info "  ✓ ${pod} 最近日志未命中 FD 耗尽关键字"
    fi
  done

  if [ "${hit}" -eq 1 ]; then
    print_solution "典型报错表现（示例）：
  - ingress-nginx-controller 日志中出现：\"no file descriptors available\"
  - 业务 Pod 无法建立新连接、偶发 I/O 失败

建议：
1) 编辑 /etc/systemd/system.conf ，取消注释或添加：
   DefaultLimitNOFILE=${TARGET_NOFILE}

2) 重新加载 systemd 配置并重启服务（会重启节点上 Pod，请在维护窗口操作）：
   systemctl daemon-reexec
   systemctl daemon-reload
   systemctl restart containerd

4) 重启后，删除相关 Pod 让其重新拉起（例如 ingress-nginx-controller）：
   kubectl -n ${INGRESS_NS} delete pod -l ${INGRESS_LABEL_SELECTOR}"
  fi
}

main() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "nofile（打开文件数）限制检查"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}"
  log_info "推荐值：nofile >= ${TARGET_NOFILE}"

  check_shell_ulimit
  check_proc_limits
  check_systemd_limits
  check_ingress_fd_keyword

  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查完成（如有 ✗ 项，请按对应 [解决方案] 调整后重试）"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
