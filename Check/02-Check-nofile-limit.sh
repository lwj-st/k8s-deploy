#!/usr/bin/env bash
################################################################################
## Filename:    02-Check-nofile-limit.sh
## Description: nofile（打开文件数）限制检查
##
## 检查范围：
##   1-3  宿主机 / systemd（kubelet、containerd 服务）
##   4    ingress-nginx（Pod 就绪、FD 日志、ConfigMap、容器内 ulimit）
##
## ingress CrashLoop 典型根因（宿主机 nofile 足够时仍可能发生）：
##   容器 soft nofile=1024 + 监听 IPv6 [::]:443 → fd 耗尽
##   推荐修复：ConfigMap disable-ipv6=true
################################################################################
set -euo pipefail

CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DEPLOY_ROOT="$(cd "${CHECK_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${K8S_DEPLOY_ROOT}/Script/framework.sh"

get_cur_path
init_logging
detect_os

readonly TARGET_NOFILE=65535
readonly INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
readonly INGRESS_LABEL_SELECTOR="${INGRESS_LABEL_SELECTOR:-app.kubernetes.io/component=controller}"
readonly FD_LOG_PATTERN='no file descriptors available|socket\(\).*failed \(24:'
readonly CRI_BASE_JSON="/etc/containerd/cri-base.json"

[ -f /etc/kubernetes/admin.conf ] && export KUBECONFIG=/etc/kubernetes/admin.conf

have_cmd() { command -v "$1" >/dev/null 2>&1; }

nofile_ge() {
  local val="$1" threshold="$2"
  [ "${val}" = "unlimited" ] || [ "${val}" -ge "${threshold}" ]
}

print_solution() {
  local msg="$1"
  log_info ""
  log_info "  [解决方案]"
  echo "$msg" | sed 's/^/  /' | while IFS= read -r line; do
    log_info "  ${line}"
  done
  log_info ""
}

print_host_limits_solution() {
  print_solution "在 /etc/security/limits.conf（及 limits.d/*.conf）中添加：
  * soft nofile ${TARGET_NOFILE}
  * hard nofile ${TARGET_NOFILE}
  root soft nofile ${TARGET_NOFILE}
  root hard nofile ${TARGET_NOFILE}

修改后重新登录会话或重启相关服务。"
}

print_systemd_unit_solution() {
  local unit="$1"
  print_solution "提高 ${unit} 的 LimitNOFILE（示例）：
  systemctl edit ${unit}
  # [Service]
  # LimitNOFILE=${TARGET_NOFILE}

  sudo systemctl daemon-reload
  sudo systemctl restart ${unit}"
}

print_ingress_fd_solution() {
  print_solution "典型报错：
  socket() [::]:443 failed (24: No file descriptors available)

根因：宿主机 nofile 足够，但容器 soft nofile 常为 1024；
节点有 IPv6 时 ingress-nginx 默认监听 [::]:443，nginx worker 绑定时 fd 耗尽。

【推荐】ingress ConfigMap 禁用 IPv6（官方 key：disable-ipv6）：
  kubectl -n ${INGRESS_NS} patch configmap ingress-nginx-controller --type merge \\
    -p '{\"data\":{\"disable-ipv6\":\"true\"}}'
  kubectl -n ${INGRESS_NS} delete pod -l ${INGRESS_LABEL_SELECTOR}

【平台级可选】containerd base_runtime_spec 抬高所有容器 nofile：
  1) ctr oci spec > ${CRI_BASE_JSON}
  2) 编辑 ${CRI_BASE_JSON}，process 段设置：
     \"rlimits\": [{\"type\":\"RLIMIT_NOFILE\",\"hard\":${TARGET_NOFILE},\"soft\":${TARGET_NOFILE}}]
  3) /etc/containerd/config.toml 写在 runtimes.runc 段（勿写在 containerd 父段）：
     [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc]
       base_runtime_spec = \"${CRI_BASE_JSON}\"
  4) containerd config dump | grep base_runtime_spec   # runc 段应显示上述路径
  5) systemctl restart containerd && systemctl restart kubelet
  6) 重建 Pod 后验证：kubectl exec <pod> -- sh -c 'ulimit -n'  应 >= ${TARGET_NOFILE}

注意：config.toml 中的 default_ulimits 在 containerd 1.7.x 常被静默忽略，请勿依赖。

【验证 ingress】
  kubectl -n ${INGRESS_NS} get pod -l ${INGRESS_LABEL_SELECTOR}
  kubectl -n ${INGRESS_NS} exec <pod> -- grep '\\[::\\]' /etc/nginx/nginx.conf   # 应无输出
  kubectl -n ${INGRESS_NS} exec <pod> -- curl -sf http://127.0.0.1:10254/healthz"
}

kubectl_ready() {
  have_cmd kubectl && kubectl version --request-timeout=3s >/dev/null 2>&1
}

ingress_logs_have_fd_error() {
  local pod="$1"
  shift || true
  local logs
  logs="$(kubectl -n "${INGRESS_NS}" logs "${pod}" "$@" --tail=300 2>/dev/null || true)"
  [ -n "${logs}" ] && echo "${logs}" | grep -qiE "${FD_LOG_PATTERN}"
}

check_shell_ulimit() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 1/4：宿主机 shell ulimit（ulimit -n）"

  local cur
  if ! cur="$(ulimit -n 2>/dev/null)"; then
    log_warn "  ⚠ 无法执行 ulimit -n"
    return
  fi

  log_info "  当前 shell: ulimit -n = ${cur}"
  if nofile_ge "${cur}" "${TARGET_NOFILE}"; then
    log_info "  ✓ 已达到或超过 ${TARGET_NOFILE}"
  else
    log_error "  ✗ 小于推荐值 ${TARGET_NOFILE}"
    print_solution "临时生效（当前会话）：
  ulimit -n ${TARGET_NOFILE}"
  fi
}

check_proc_limits() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 2/4：宿主机 /proc/self/limits（Max open files）"

  if [ ! -r /proc/self/limits ]; then
    log_warn "  ⚠ 无法读取 /proc/self/limits"
    return
  fi

  local line soft hard fail=0
  line="$(grep -E '^Max open files' /proc/self/limits || true)"
  if [ -z "${line}" ]; then
    log_warn "  ⚠ 未找到 Max open files 项"
    return
  fi

  soft="$(echo "${line}" | awk '{print $4}')"
  hard="$(echo "${line}" | awk '{print $5}')"
  log_info "  Max open files (soft,hard) = (${soft}, ${hard})"

  if ! nofile_ge "${soft}" "${TARGET_NOFILE}"; then
    log_error "  ✗ soft nofile 小于 ${TARGET_NOFILE}"
    fail=1
  fi
  if ! nofile_ge "${hard}" "${TARGET_NOFILE}"; then
    log_error "  ✗ hard nofile 小于 ${TARGET_NOFILE}"
    fail=1
  fi

  if [ "${fail}" -eq 0 ]; then
    log_info "  ✓ soft/hard nofile 均已达到或超过 ${TARGET_NOFILE}"
  else
    print_host_limits_solution
  fi
}

check_systemd_limits() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 3/4：systemd LimitNOFILE（kubelet / containerd 服务）"

  if ! have_cmd systemctl; then
    log_warn "  ⚠ 未发现 systemctl，跳过"
    return
  fi

  local unit limit
  for unit in kubelet.service containerd.service; do
    if ! systemctl status "${unit}" >/dev/null 2>&1; then
      log_warn "  ⚠ 未发现 ${unit}，跳过"
      continue
    fi
    limit="$(systemctl show "${unit}" -p LimitNOFILE 2>/dev/null | cut -d= -f2 || true)"
    if [ -z "${limit}" ]; then
      log_warn "  ⚠ ${unit}: 未获取到 LimitNOFILE"
      continue
    fi
    log_info "  ${unit}: LimitNOFILE=${limit}"
    if [ "${limit}" != "infinity" ] && [ "${limit}" -lt "${TARGET_NOFILE}" ]; then
      log_error "  ✗ ${unit} LimitNOFILE 小于 ${TARGET_NOFILE}"
      print_systemd_unit_solution "${unit}"
    fi
  done
}

check_ingress_nginx() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查 4/4：ingress-nginx（Pod / 日志 / ConfigMap / 容器 nofile）"

  if ! have_cmd kubectl; then
    log_warn "  ⚠ 未发现 kubectl，跳过"
    return
  fi
  if ! kubectl_ready; then
    log_warn "  ⚠ 集群不可达，跳过"
    return
  fi

  local pods
  pods="$(kubectl -n "${INGRESS_NS}" get pod -l "${INGRESS_LABEL_SELECTOR}" -o name 2>/dev/null || true)"
  if [ -z "${pods}" ]; then
    log_warn "  ⚠ 未找到 controller Pod（ns=${INGRESS_NS}）"
    return
  fi

  # ConfigMap：disable-ipv6
  local disable_ipv6
  disable_ipv6="$(kubectl -n "${INGRESS_NS}" get configmap ingress-nginx-controller \
    -o jsonpath='{.data.disable-ipv6}' 2>/dev/null || true)"
  if [ "${disable_ipv6}" = "true" ]; then
    log_info "  ConfigMap disable-ipv6 = true"
  else
    log_warn "  ⚠ ConfigMap 未设置 disable-ipv6=true（IPv6 节点上易触发 [::]:443 fd 错误）"
  fi

  local fail=0 pod name ready restarts phase container_ulimit

  for pod in ${pods}; do
    name="${pod#pod/}"
    ready="$(kubectl -n "${INGRESS_NS}" get pod "${name}" \
      -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
    restarts="$(kubectl -n "${INGRESS_NS}" get pod "${name}" \
      -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
    phase="$(kubectl -n "${INGRESS_NS}" get pod "${name}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"

    log_info "  ── Pod ${name} ──"
    log_info "    phase=${phase:-unknown} ready=${ready:-unknown} restarts=${restarts:-0}"

    if [ "${ready}" != "true" ]; then
      log_error "    ✗ 未就绪"
      fail=1
    else
      log_info "    ✓ 已就绪"
    fi

    if ingress_logs_have_fd_error "${name}"; then
      log_error "    ✗ 当前容器日志命中 FD 耗尽关键字"
      fail=1
    elif ingress_logs_have_fd_error "${name}" --previous; then
      log_error "    ✗ 上一次容器日志命中 FD 耗尽关键字"
      fail=1
    else
      log_info "    ✓ 当前/上一次日志未命中 FD 耗尽关键字"
    fi

    container_ulimit="$(kubectl -n "${INGRESS_NS}" exec "${name}" --request-timeout=10s -- \
      sh -c 'ulimit -n' 2>/dev/null || true)"
    if [ -n "${container_ulimit}" ]; then
      log_info "    容器内 ulimit -n = ${container_ulimit}"
      if ! nofile_ge "${container_ulimit}" "${TARGET_NOFILE}"; then
        log_warn "    ⚠ 容器 soft nofile (${container_ulimit}) < ${TARGET_NOFILE}（宿主机足够时仍可能导致 ingress 异常）"
        [ "${disable_ipv6}" != "true" ] && fail=1
      else
        log_info "    ✓ 容器 soft nofile 已达到或超过 ${TARGET_NOFILE}"
      fi
    else
      log_warn "    ⚠ 无法 exec 读取容器 ulimit（Pod 可能未 Running）"
    fi
  done

  if [ "${fail}" -eq 1 ]; then
    print_ingress_fd_solution
  fi
}

main() {
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "nofile（打开文件数）限制检查"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}"
  log_info "推荐值：nofile >= ${TARGET_NOFILE}"
  log_info "说明：检查 1-3 为宿主机；检查 4 针对 ingress-nginx（与宿主机结果可不一致）"

  check_shell_ulimit
  check_proc_limits
  check_systemd_limits
  check_ingress_nginx

  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "检查完成（如有 ✗ 项，请按对应 [解决方案] 调整后重试）"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
