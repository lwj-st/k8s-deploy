#!/usr/bin/env bash
################################################################################
## Filename:    30-Deploy-rsyslog.sh
## Description: 后置配置 Kubernetes 集群 rsyslog 集中日志审计，支持日志服务器和节点复用同一脚本
## Usage:
##   bash 30-Deploy-rsyslog.sh
## Artifacts:
##   - os.dir.tools.<os_id>.<os_version>
##
##   bash 30-Deploy-rsyslog.sh client  #把当前机器配置成日志发送节点。 需要每个节点都执行一次。
##   bash 30-Deploy-rsyslog.sh server  #把当前机器配置成日志服务器。
##   bash 30-Deploy-rsyslog.sh preconfig #只做本机预配置，不配置 rsyslog 推送/接收。
##   bash 30-Deploy-rsyslog.sh enable-audit #在 control-plane 节点开启 kube-apiserver audit。
##   bash 30-Deploy-rsyslog.sh enable-forward  #开启本节点日志外发。
##   bash 30-Deploy-rsyslog.sh disable-forward #关闭本节点日志外发。
##   bash 30-Deploy-rsyslog.sh cleanup        #清理本脚本写入的 server/client 等配置（见 usage）,注意Kubernetes audit 不会被清理
##
## 最简单推荐流程：
##   # 已有日志服务器时，在每个 Kubernetes 节点执行：
##   export RSYSLOG_LOG_SERVER=<log-server-ip>
##   bash 30-Deploy-rsyslog.sh client
##
##   # 没有日志服务器时，先在日志服务器执行：
##   export RSYSLOG_LOG_SERVER=<log-server-ip>
##   bash 30-Deploy-rsyslog.sh server
##
##   # 然后在每个 Kubernetes 节点执行：
##   export RSYSLOG_LOG_SERVER=<log-server-ip>
##   bash 30-Deploy-rsyslog.sh client
##
##   # 后续新增节点时，只需要在新增节点再执行 client。
##
##   # 如果k8s集群已部署且还未开启 Kubernetes audit，在每个 control-plane 节点执行开启审计：
##   bash 30-Deploy-rsyslog.sh enable-audit
##
## 可选环境变量（优先级高于默认值）：
##   RSYSLOG_LOG_SERVER / RSYSLOG_LOG_SERVER_PORT / RSYSLOG_LOG_DIR
##   RSYSLOG_SSL_DIR / RSYSLOG_RSYSLOGD_USER / RSYSLOG_LOCAL_ROTATE_DAYS / RSYSLOG_TRANSPORT / RSYSLOG_TLS_AUTH_MODE
##   RSYSLOG_FORWARD_ENABLE
##   RSYSLOG_AUDIT_MAXAGE / RSYSLOG_AUDIT_MAXBACKUP / RSYSLOG_AUDIT_MAXSIZE
##   RSYSLOG_JOURNAL_SYSTEM_MAX_USE / RSYSLOG_JOURNAL_RUNTIME_MAX_USE / RSYSLOG_JOURNAL_MAX_RETENTION
##   KUBE_APISERVER_MANIFEST_BACKUP_DIR（enable-audit 备份路径，须不在 /etc/kubernetes/manifests/ 下）
##   离线安装 rsyslog 时使用 manifests/artifacts.yaml 中的 OS 工具目录
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

# 本脚本需要在初始化早期读取父进程环境，因此不直接调用 init_framework。
get_cur_path
init_logging
if [ -f "${SCRIPT_DIR}/environment.sh" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/environment.sh"
fi
detect_os
require_target_platform
log_info "OS: ${OS_ID} ${OS_VERSION_DETECTED}（目标离线包版本: ${TARGET_OS_VERSION}）"
require_root

# 若当前进程未带 RSYSLOG_LOG_SERVER（例如从非 root 经 su 进入 root 时父 shell 曾 export），从父进程链 /proc/*/environ 尝试读取（仅 Linux）。
inherit_rsyslog_log_server_from_ancestors() {
  [ -n "${RSYSLOG_LOG_SERVER}" ] && return 0
  [ -d /proc ] || return 1
  local pid ppid d max val
  pid=$$
  max=24
  for ((d = 0; d < max; d++)); do
    [ -r "/proc/${pid}/status" ] || return 1
    ppid="$(awk '/^PPid:/ {print $2}' "/proc/${pid}/status")"
    [ -z "${ppid}" ] || [ "${ppid}" = "0" ] && return 1
    if [ -r "/proc/${ppid}/environ" ]; then
      val="$(tr '\0' '\n' <"/proc/${ppid}/environ" | sed -n 's/^RSYSLOG_LOG_SERVER=//p' | head -n1)"
      if [ -n "${val}" ]; then
        RSYSLOG_LOG_SERVER="${val}"
        export RSYSLOG_LOG_SERVER
        log_info "已从调用链进程环境读取 RSYSLOG_LOG_SERVER（兼容父 shell 已 export 但未传入当前进程的场景）"
        return 0
      fi
    fi
    [ "${ppid}" = "1" ] && return 1
    pid=${ppid}
  done
  return 1
}

# 日志服务器地址；client/auto 等需要外发时必填。多个目标用英文逗号分隔。
RSYSLOG_LOG_SERVER="${RSYSLOG_LOG_SERVER:-}"
inherit_rsyslog_log_server_from_ancestors || true
# 日志服务器 rsyslog TLS 监听端口，也是客户端推送端口。
RSYSLOG_LOG_SERVER_PORT="${RSYSLOG_LOG_SERVER_PORT:-6514}"
# 日志服务器集中保存远端日志的目录。
RSYSLOG_LOG_DIR="${RSYSLOG_LOG_DIR:-/data/logs}"
# rsyslog TLS 证书目录；默认脚本使用 anon TLS 时客户端不强制需要证书。
RSYSLOG_SSL_DIR="${RSYSLOG_SSL_DIR:-/etc/rsyslog/ssl}"
# rsyslog 运行用户，仅用于配置 TLS 私钥属组等，实际 systemd/User 以发行版默认为准（通常为 syslog）。
RSYSLOG_RSYSLOGD_USER="${RSYSLOG_RSYSLOGD_USER:-syslog}"
# Kubernetes 节点本地日志保留天数；集中留存在日志服务器，本地只短保留。
RSYSLOG_LOCAL_ROTATE_DAYS="${RSYSLOG_LOCAL_ROTATE_DAYS:-7}"
# kube-apiserver audit 本地日志保留天数。
RSYSLOG_AUDIT_MAXAGE="${RSYSLOG_AUDIT_MAXAGE:-180}"
# kube-apiserver audit 本地最多保留的轮转文件数量。
RSYSLOG_AUDIT_MAXBACKUP="${RSYSLOG_AUDIT_MAXBACKUP:-30}"
# kube-apiserver audit 单个日志文件最大大小，单位 MB。
RSYSLOG_AUDIT_MAXSIZE="${RSYSLOG_AUDIT_MAXSIZE:-100}"
# journald 持久化日志最大磁盘占用。
RSYSLOG_JOURNAL_SYSTEM_MAX_USE="${RSYSLOG_JOURNAL_SYSTEM_MAX_USE:-1G}"
# journald 运行时日志最大磁盘占用。
RSYSLOG_JOURNAL_RUNTIME_MAX_USE="${RSYSLOG_JOURNAL_RUNTIME_MAX_USE:-512M}"
# journald 本地日志最长保留时间。
RSYSLOG_JOURNAL_MAX_RETENTION="${RSYSLOG_JOURNAL_MAX_RETENTION:-7d}"
# 外发传输模式：tls 使用 TCP/TLS；plain 使用普通 TCP，适配已有日志服务器不支持 TLS 的场景。
RSYSLOG_TRANSPORT="${RSYSLOG_TRANSPORT:-tls}"
# TLS 认证模式：anon 部署简单只加密；x509/name 更严格但需要额外分发证书。
RSYSLOG_TLS_AUTH_MODE="${RSYSLOG_TLS_AUTH_MODE:-anon}"
# 是否开启节点日志外发：yes 写入并启用外发配置；no 仅保留本机预配置并关闭外发配置。
RSYSLOG_FORWARD_ENABLE="${RSYSLOG_FORWARD_ENABLE:-yes}"

SERVER_CONF="/etc/rsyslog.d/10-k8s-deploy-remote-server.conf"
CLIENT_CONF="/etc/rsyslog.d/20-k8s-deploy-forward.conf"
REMOTE_ROTATE_FILE="/etc/logrotate.d/remote-rsyslog"
LOCAL_ROTATE_FILE="/etc/logrotate.d/local-k8s-logs"
AUDIT_POLICY_FILE="/etc/kubernetes/audit-policy.yaml"
JOURNALD_LIMIT_FILE="/etc/systemd/journald.conf.d/10-k8s-deploy-size-limit.conf"
# kube-apiserver 静态清单备份目录：不可放在 /etc/kubernetes/manifests/ 内，否则 kubelet 会把 *.k8s-deploy.* 当作第二份 Pod 清单一并加载，主文件写入瞬间若被读成空 YAML 会报 Kind=null，长期只剩无 audit 的旧副本。
KUBE_APISERVER_MANIFEST_BACKUP_DIR="${KUBE_APISERVER_MANIFEST_BACKUP_DIR:-/var/backups/k8s-deploy-manifests}"

# 配置成功后输出手工验证步骤（不自动执行；整块多行输出便于阅读与复制）。
print_verification_hints_log_server() {
  cat <<EOF

======== 日志服务器 · 手工验证（本机 root，按顺序执行）========
# 以下假设已安装 systemd（systemctl / journalctl）；无则跳过对应命令。

【服务 / 配置】
  rsyslogd -N1
  systemctl status rsyslog --no-pager

【监听】当前端口 RSYSLOG_LOG_SERVER_PORT=${RSYSLOG_LOG_SERVER_PORT}
  ss -lntp 2>/dev/null | grep -E ':${RSYSLOG_LOG_SERVER_PORT}\\b' || ss -lntp 2>/dev/null || true
  # 若无 iproute 的 ss，可试: netstat -lntp 2>/dev/null | grep -E ':${RSYSLOG_LOG_SERVER_PORT}\\b'

【本机日志是否正常】（先筛错误相关，再去掉管道看完整）
  journalctl -u rsyslog --since '10 min ago' --no-pager | egrep -i 'imtcp|gtls|error|fail|${RSYSLOG_LOG_SERVER_PORT}' || true
  journalctl -u rsyslog --since '10 min ago' --no-pager

【端到端】在任一已外发节点执行发送，再在日志服务器本机查集中目录 RSYSLOG_LOG_DIR=${RSYSLOG_LOG_DIR}
  TAG=k8s-rsyslog-verify-\$(date +%s); logger -t "\$TAG" "hello-from-rsyslog-test"
  sleep 3
  grep -R "k8s-rsyslog-verify" "${RSYSLOG_LOG_DIR}" 2>/dev/null || true
EOF
}

print_verification_hints_log_client_forward() {
  cat <<EOF

======== 日志外发客户端 · 手工验证（本机 root，按顺序执行）========
# 以下假设已安装 systemd（systemctl / journalctl）；无则跳过对应命令。

【配置是否含转发】
  grep -nE 'omfwd|target=|StreamDriver' "${CLIENT_CONF}"

【服务 / 配置】
  rsyslogd -N1
  systemctl status rsyslog --no-pager

【本机日志是否正常】（转发 / TLS / 重连）
  journalctl -u rsyslog --since '10 min ago' --no-pager | egrep -i 'omfwd|gtls|gnutls|suspend|resume|error|fail|${RSYSLOG_LOG_SERVER_PORT}' || true
  journalctl -u rsyslog --since '10 min ago' --no-pager

【端到端】本机发测试 → 到日志服务器 RSYSLOG_LOG_SERVER=${RSYSLOG_LOG_SERVER} 上查目录 ${RSYSLOG_LOG_DIR}（同机则仍在下面本机执行）
  TAG=k8s-rsyslog-verify-\$(date +%s); logger -t "\$TAG" "hello-from-\$(hostname)"
  sleep 3
  grep -R "k8s-rsyslog-verify" "${RSYSLOG_LOG_DIR}" 2>/dev/null || true
EOF
}

print_verification_hints_disable_forward() {
  cat <<EOF

======== 外发已关闭 · 手工验证（本机 root，按顺序执行）========
# 以下假设已安装 systemd（systemctl / journalctl）；无则跳过对应命令。

【外发配置文件】
  test ! -f "${CLIENT_CONF}" && echo "ok: ${CLIENT_CONF} 不存在" || ls -l "${CLIENT_CONF}"

【服务 / 配置】
  rsyslogd -N1
  systemctl status rsyslog --no-pager

【本机日志】
  journalctl -u rsyslog --since '10 min ago' --no-pager
EOF
}

usage() {
  cat <<EOF
用法（须 root）:
  bash 30-Deploy-rsyslog.sh [auto|server|client|preconfig|enable-audit|enable-forward|disable-forward|cleanup]

  cleanup  移除本脚本部署的 rsyslog 接收/外发、logrotate、journald 片段等（备份后删除）。
           可选: RSYSLOG_CLEANUP_AUDIT_POLICY=yes 同时备份并删除 ${AUDIT_POLICY_FILE}（若 apiserver 仍引用须手工改 manifest）
           可选: RSYSLOG_CLEANUP_SSL=yes 备份并移除整个 ${RSYSLOG_SSL_DIR} 目录
           可选: RSYSLOG_CLEANUP_LOG_DATA=yes 清空 ${RSYSLOG_LOG_DIR} 下内容（目录非 /）

默认 auto:
  本机 IP 命中 RSYSLOG_LOG_SERVER 时配置日志服务器，否则配置客户端。

环境变量（export、或 RSYSLOG_LOG_SERVER=... bash；若未传入当前进程，脚本会尝试从父进程链环境读取）:
  RSYSLOG_LOG_SERVER       客户端外发时必填，日志服务器 IP/域名；多个推送目标用英文逗号分隔
  RSYSLOG_LOG_SERVER_PORT  默认 6514
  RSYSLOG_LOG_DIR          默认 /data/logs
  RSYSLOG_LOCAL_ROTATE_DAYS 默认 7
  RSYSLOG_FORWARD_ENABLE   默认 yes；设置 no 时 client 模式只做本机预配置并关闭外发
  RSYSLOG_TRANSPORT        默认 tls；已有服务器只支持普通 TCP 时设置 plain
  RSYSLOG_TLS_AUTH_MODE    默认 anon，简单稳定；如需双向证书认证需手工改为 x509/name 并分发证书
  RSYSLOG_SSL_DIR          默认 /etc/rsyslog/ssl
  RSYSLOG_RSYSLOGD_USER    默认 syslog；用于 TLS 私钥属组、集中日志目录权限等（实际运行用户以 systemd/发行版配置为准）
  RSYSLOG_CLEANUP_*        仅 cleanup 模式使用，见上文
EOF
}

write_if_changed() {
  local path="$1" tmp="$2" mode="${3:-0644}"
  [ -f "${tmp}" ] || die "临时文件不存在: ${tmp}"
  if [ -f "${path}" ] && cmp -s "${path}" "${tmp}"; then
    log_info "文件无变化，跳过写入: ${path}"
    rm -f "${tmp}"
    return 0
  fi
  if [ -e "${path}" ]; then
    backup_if_exists "${path}"
  fi
  install -m "${mode}" "${tmp}" "${path}"
  rm -f "${tmp}"
  log_info "已写入配置: ${path}"
}

detect_pkg_manager() {
  if have apt-get; then
    printf '%s\n' "apt"
  elif have dnf; then
    printf '%s\n' "dnf"
  elif have yum; then
    printf '%s\n' "yum"
  else
    die "未找到 apt-get/dnf/yum，无法自动安装 rsyslog"
  fi
}

# 离线目录必须与 manifests/artifacts.yaml 中的精确 OS 版本条目一致。
offline_rsyslog_dir() {
  local base
  case "${OS_ID:-}" in
    ubuntu|centos|rocky|openeuler|kylin)
      base="$(artifact_get_os_tools_dir "${OS_ID}" "${TARGET_OS_VERSION}")"
      ;;
    *)
      die "未识别的 OS_ID=${OS_ID:-unknown}，无法确定 rsyslog 离线包目录。请补充 manifests/artifacts.yaml 中的 OS 工具目录，或扩展本脚本的 OS 映射。"
      ;;
  esac
  printf '%s\n' "${base}/rsyslog"
}

offline_rsyslog_hint() {
  local dir="$1"
  log_error "请在离线制品目录准备 rsyslog 安装包: ${dir}"
  case "${OS_ID:-}" in
    ubuntu)
      log_error "目录内需有 .deb；脚本会自动合并同级工具目录下的包: rsyslog/、rsyslog-gnutls/、logrotate/、openssl/（与 00-Download-tools-packages 按工具分子目录的布局一致）。"
      log_error "若仍有缺依赖，请把对应 .deb 放进上述任一目录后重跑。"
      ;;
    *)
      log_error "目录内需有 .rpm；脚本会自动合并同级工具目录: rsyslog/、rsyslog-gnutls/、logrotate/、openssl/ 下的 *.rpm。"
      log_error "若仍有缺依赖，请把对应 .rpm 放进上述任一目录后重跑。"
      ;;
  esac
}

# 多个工具目录通过 --resolve 下载时可能包含同名依赖；同一路径只能传给包管理器一次。
dedupe_pkg_paths_by_basename() {
  local -n input_paths="$1"
  local -n output_paths="$2"
  local -A seen=()
  local path base
  output_paths=()
  for path in "${input_paths[@]}"; do
    [ -n "${path}" ] || continue
    base="$(basename "${path}")"
    [ -n "${seen[${base}]+x}" ] && continue
    seen["${base}"]=1
    output_paths+=("${path}")
  done
}

install_rsyslog_offline() {
  local dir
  dir="$(offline_rsyslog_dir)"
  if [ ! -d "${dir}" ]; then
    offline_rsyslog_hint "${dir}"
    die "离线包目录不存在: ${dir}"
  fi

  case "${OS_ID:-}" in
    ubuntu)
      local tools_parent sd d
      tools_parent="$(dirname "${dir}")"
      declare -a deb_dirs=("${dir}")
      for sd in rsyslog-gnutls logrotate openssl; do
        [ -d "${tools_parent}/${sd}" ] && deb_dirs+=("${tools_parent}/${sd}")
      done
      declare -a debs_raw=() debs=()
      shopt -s nullglob
      for d in "${deb_dirs[@]}"; do
        debs_raw+=("${d}"/*.deb)
      done
      shopt -u nullglob
      dedupe_pkg_paths_by_basename debs_raw debs
      if [ "${#debs[@]}" -eq 0 ]; then
        offline_rsyslog_hint "${dir}"
        die "离线未找到 .deb：已检查 ${deb_dirs[*]}（至少需要 ${dir} 内有 rsyslog 相关 .deb）"
      fi
      log_info "离线安装：dpkg -i 共 ${#debs[@]} 个 .deb（目录: ${deb_dirs[*]}）"
      if ! dpkg -i "${debs[@]}"; then
        log_warn "首次 dpkg -i 未完全成功（常见为依赖顺序或未配置包），将再执行一次"
        dpkg -i "${debs[@]}" || die "dpkg -i 仍失败：请补齐 rsyslog-gnutls 等依赖的 .deb 到 tools 下对应子目录，或在有网环境 apt-get download 后拷入"
      fi
      ;;
    *)
      local tools_parent sd d
      tools_parent="$(dirname "${dir}")"
      declare -a rpm_dirs=("${dir}")
      for sd in rsyslog-gnutls logrotate openssl; do
        [ -d "${tools_parent}/${sd}" ] && rpm_dirs+=("${tools_parent}/${sd}")
      done
      declare -a rpms_raw=() rpms=()
      shopt -s nullglob
      for d in "${rpm_dirs[@]}"; do
        rpms_raw+=("${d}"/*.rpm)
      done
      shopt -u nullglob
      dedupe_pkg_paths_by_basename rpms_raw rpms
      if [ "${#rpms[@]}" -eq 0 ]; then
        offline_rsyslog_hint "${dir}"
        die "离线未找到 .rpm：已检查 ${rpm_dirs[*]}"
      fi
      log_info "离线安装：共 ${#rpms[@]} 个 .rpm（目录: ${rpm_dirs[*]}）"
      if have dnf; then
        dnf -y install --disablerepo='*' --setopt=install_weak_deps=False "${rpms[@]}" || die "dnf localinstall 失败，请补齐依赖 .rpm"
      else
        yum -y localinstall --disablerepo='*' "${rpms[@]}" || die "yum localinstall 失败，请补齐依赖 .rpm"
      fi
      ;;
  esac
}

# 常见 rsyslog 模块目录（RPM 系、Debian multiarch 等）；用于判断是否已安装 GnuTLS 网流驱动相关文件。
# 注意：不要写 module(load="lmnsd_gtls")——lmnsd_* 为内部库模块，手动加载会导致 rsyslogd 段错误（上游说明）。
rsyslog_moddirs_probe() {
  printf '%s\n' \
    /usr/lib64/rsyslog \
    /usr/lib/rsyslog \
    /usr/lib/x86_64-linux-gnu/rsyslog \
    /usr/lib/aarch64-linux-gnu/rsyslog \
    /usr/lib/s390x-linux-gnu/rsyslog
}

# RHEL 9+ 等：TLS 为子包动态模块，rsyslogd -v 不一定出现 “gnutls” 字样。
rsyslog_gnutls_available() {
  if have rsyslogd && rsyslogd -v 2>/dev/null | grep -qiE 'gnutls|GnuTLS'; then
    return 0
  fi
  if have rpm && rpm -q rsyslog-gnutls >/dev/null 2>&1; then
    return 0
  fi
  if have dpkg-query; then
    local st
    st="$(dpkg-query -W -f='${Status}' rsyslog-gnutls 2>/dev/null || true)"
    [[ "${st}" == *'install ok installed'* ]] && return 0
  fi
  local d
  while IFS= read -r d; do
    [ -n "${d}" ] || continue
    if [ -f "${d}/lmnsd_gtls.so" ] || [ -f "${d}/gtls.so" ]; then
      return 0
    fi
  done < <(rsyslog_moddirs_probe)
  return 1
}

install_packages() {
  local pm
  pm="$(detect_pkg_manager)"
  if have rsyslogd && rsyslog_gnutls_available; then
    log_info "rsyslog 和 gnutls 支持已存在，跳过安装"
    return 0
  fi

  if [ "${ALLOW_ONLINE:-no}" != "yes" ]; then
    install_rsyslog_offline
  else
    case "${pm}" in
      apt)
        if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y rsyslog rsyslog-gnutls logrotate openssl; then
          log_info "rsyslog 在线安装成功"
        else
          install_rsyslog_offline
        fi
        ;;
      dnf)
        if dnf install -y rsyslog rsyslog-gnutls logrotate openssl; then
          log_info "rsyslog 在线安装成功"
        else
          install_rsyslog_offline
        fi
        ;;
      yum)
        if yum install -y rsyslog rsyslog-gnutls logrotate openssl; then
          log_info "rsyslog 在线安装成功"
        else
          install_rsyslog_offline
        fi
        ;;
    esac
  fi

  have rsyslogd || die "rsyslog 安装后仍未找到 rsyslogd"
  if [ "${RSYSLOG_TRANSPORT}" != "tls" ]; then
    if ! rsyslog_gnutls_available; then
      log_warn "当前 RSYSLOG_TRANSPORT=${RSYSLOG_TRANSPORT}，未安装 rsyslog-gnutls 仍可继续；若日后改为 tls 请在有网节点 apt/dnf 补装 rsyslog-gnutls 或补齐离线 .deb/.rpm。"
    fi
    return 0
  fi
  if ! rsyslog_gnutls_available; then
    case "${OS_ID:-}" in
      ubuntu)
        die "rsyslog 未检测到 GnuTLS 支持（TLS 须安装 rsyslog-gnutls）。离线时请保证 tools/rsyslog-gnutls/ 下有对应 .deb（脚本会与 tools/rsyslog/、logrotate/、openssl/ 一并 dpkg -i）。有网机器可在该目录执行: apt-get download rsyslog-gnutls 及依赖。仅需明文 TCP 时可设 RSYSLOG_TRANSPORT=plain。"
        ;;
      *)
        die "rsyslog 未检测到 GnuTLS 支持（TLS 须安装 rsyslog-gnutls）。离线时请保证 tools/rsyslog-gnutls/ 下有对应 .rpm（脚本会与 rsyslog/、logrotate/、openssl/ 一并安装）。仅需明文 TCP 时可设 RSYSLOG_TRANSPORT=plain。"
        ;;
    esac
  fi
}

primary_ip() {
  if have ip; then
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}'
  else
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

host_ips() {
  if have hostname; then
    hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
  fi
  primary_ip || true
}

first_log_server() {
  printf '%s' "${RSYSLOG_LOG_SERVER}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | head -n1
}

is_this_log_server() {
  local target ip hn fhn
  hn="$(hostname)"
  fhn="$(hostname -f 2>/dev/null || hostname)"
  [ -n "$(first_log_server)" ] || return 1
  while IFS= read -r target; do
    [ -n "${target}" ] || continue
    while IFS= read -r ip; do
      [ "${ip}" = "${target}" ] && return 0
    done < <(host_ips)
    [ "${hn}" = "${target}" ] && return 0
    [ "${fhn}" = "${target}" ] && return 0
  done < <(printf '%s' "${RSYSLOG_LOG_SERVER}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')
  return 1
}

first_log_server_name() {
  local first
  first="$(first_log_server)"
  while IFS= read -r ip; do
    if [ "${ip}" = "${first}" ]; then
      hostname -f 2>/dev/null || hostname
      return 0
    fi
  done < <(host_ips)
  printf '%s\n' "${first}"
}

require_log_server() {
  [ -n "${RSYSLOG_LOG_SERVER}" ] || die "RSYSLOG_LOG_SERVER 为空。请以 root 设置后执行，例如: export RSYSLOG_LOG_SERVER=<IP>；或 RSYSLOG_LOG_SERVER=<IP> bash 本脚本；脚本也会尝试从父进程环境读取"
}

os_family() {
  case "${OS_ID:-}" in
    ubuntu) printf '%s\n' "debian" ;;
    *) printf '%s\n' "rhel" ;;
  esac
}

ensure_server_certs() {
  local server_name server_ip cnf
  server_name="$(hostname -f 2>/dev/null || hostname)"
  server_ip="$(primary_ip || true)"

  mkdir -p "${RSYSLOG_SSL_DIR}"
  chmod 0755 "${RSYSLOG_SSL_DIR}"

  if [ ! -f "${RSYSLOG_SSL_DIR}/ca.key" ] || [ ! -f "${RSYSLOG_SSL_DIR}/ca.crt" ]; then
    log_command "openssl genrsa -out \"${RSYSLOG_SSL_DIR}/ca.key\" 4096"
    log_command "openssl req -x509 -new -nodes -key \"${RSYSLOG_SSL_DIR}/ca.key\" -sha256 -days 3650 -out \"${RSYSLOG_SSL_DIR}/ca.crt\" -subj \"/CN=rsyslog-ca\""
  else
    log_info "CA 已存在，跳过创建"
  fi

  if [ ! -f "${RSYSLOG_SSL_DIR}/server.key" ] || [ ! -f "${RSYSLOG_SSL_DIR}/server.crt" ]; then
    cnf="$(mktemp)"
    cat >"${cnf}" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${server_name}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${server_name}
IP.1 = ${server_ip}
EOF
    log_command "openssl genrsa -out \"${RSYSLOG_SSL_DIR}/server.key\" 4096"
    log_command "openssl req -new -key \"${RSYSLOG_SSL_DIR}/server.key\" -out \"${RSYSLOG_SSL_DIR}/server.csr\" -config \"${cnf}\""
    log_command "openssl x509 -req -in \"${RSYSLOG_SSL_DIR}/server.csr\" -CA \"${RSYSLOG_SSL_DIR}/ca.crt\" -CAkey \"${RSYSLOG_SSL_DIR}/ca.key\" -CAcreateserial -out \"${RSYSLOG_SSL_DIR}/server.crt\" -days 3650 -sha256 -extensions v3_req -extfile \"${cnf}\""
    rm -f "${cnf}"
  else
    log_info "服务端证书已存在，跳过创建"
  fi

  # ca.key 仅 root；server.key 须被 rsyslog 进程用户读取（脚本曾 chmod 600 *.key 会导致 GnuTLS「Error while reading file」）
  if [ -f "${RSYSLOG_SSL_DIR}/ca.key" ]; then
    chown root:root "${RSYSLOG_SSL_DIR}/ca.key" 2>/dev/null || true
    chmod 600 "${RSYSLOG_SSL_DIR}/ca.key" || true
  fi
  if [ -f "${RSYSLOG_SSL_DIR}/server.key" ]; then
    if id -u "${RSYSLOG_RSYSLOGD_USER}" >/dev/null 2>&1; then
      chown "root:${RSYSLOG_RSYSLOGD_USER}" "${RSYSLOG_SSL_DIR}/server.key" || die "无法 chown server.key 为 root:${RSYSLOG_RSYSLOGD_USER}"
      chmod 640 "${RSYSLOG_SSL_DIR}/server.key" || die "无法 chmod 640 ${RSYSLOG_SSL_DIR}/server.key"
    else
      log_warn "系统无用户 ${RSYSLOG_RSYSLOGD_USER}，未调整 server.key 属组；若 rsyslog 非 root 运行将无法读私钥，请设置 RSYSLOG_RSYSLOGD_USER 或手工 chown/chmod。"
      chmod 600 "${RSYSLOG_SSL_DIR}/server.key" || true
    fi
  fi
  chmod 644 "${RSYSLOG_SSL_DIR}"/*.crt 2>/dev/null || true
}

write_server_conf() {
  mkdir -p "${RSYSLOG_LOG_DIR}"
  # rsyslogd 常以 syslog 运行，须在集中目录下创建 %HOSTNAME%/facility/ 子目录；仅 0755+root 会导致 Permission denied
  if getent group adm >/dev/null 2>&1; then
    chown root:adm "${RSYSLOG_LOG_DIR}" 2>/dev/null || true
    chmod 2775 "${RSYSLOG_LOG_DIR}" || true
  elif id -u "${RSYSLOG_RSYSLOGD_USER}" >/dev/null 2>&1; then
    chown "root:${RSYSLOG_RSYSLOGD_USER}" "${RSYSLOG_LOG_DIR}" 2>/dev/null || true
    chmod 2775 "${RSYSLOG_LOG_DIR}" 2>/dev/null || chmod 0775 "${RSYSLOG_LOG_DIR}" 2>/dev/null || true
  else
    log_warn "未找到 adm 组且无法解析 ${RSYSLOG_RSYSLOGD_USER}；${RSYSLOG_LOG_DIR} 保持 0755，rsyslog 可能无法创建子目录，请手工 chown/chmod。"
    chmod 0755 "${RSYSLOG_LOG_DIR}" || true
  fi

  local tmp
  tmp="$(mktemp)"
  if [ "${RSYSLOG_TRANSPORT}" = "tls" ]; then
    cat >"${tmp}" <<EOF
\$DefaultNetstreamDriver gtls
\$DefaultNetstreamDriverCAFile ${RSYSLOG_SSL_DIR}/ca.crt
\$DefaultNetstreamDriverCertFile ${RSYSLOG_SSL_DIR}/server.crt
\$DefaultNetstreamDriverKeyFile ${RSYSLOG_SSL_DIR}/server.key

module(load="imtcp"
  StreamDriver.Name="gtls"
  StreamDriver.Mode="1"
  StreamDriver.AuthMode="${RSYSLOG_TLS_AUTH_MODE}"
)
EOF
  else
    cat >"${tmp}" <<EOF
module(load="imtcp")
EOF
  fi
  cat >>"${tmp}" <<EOF

template(name="K8sDeployRemoteLogs" type="string"
  string="${RSYSLOG_LOG_DIR}/%HOSTNAME%/%syslogfacility-text%/%PROGRAMNAME%.log")

ruleset(name="k8sDeployRemoteIn") {
  *.* ?K8sDeployRemoteLogs
  stop
}

input(
  type="imtcp"
  port="${RSYSLOG_LOG_SERVER_PORT}"
  Ruleset="k8sDeployRemoteIn"
)
EOF
  write_if_changed "${SERVER_CONF}" "${tmp}"
}

write_remote_logrotate() {
  local tmp create_group
  if getent group adm >/dev/null 2>&1; then
    create_group="adm"
  else
    create_group="root"
  fi
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
${RSYSLOG_LOG_DIR}/*/*/*.log {
    daily
    rotate 180
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root ${create_group}
    sharedscripts
    postrotate
        systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || service rsyslog reload >/dev/null 2>&1 || killall -HUP rsyslogd >/dev/null 2>&1 || true
    endscript
}
EOF
  write_if_changed "${REMOTE_ROTATE_FILE}" "${tmp}"
}

write_audit_policy() {
  mkdir -p /etc/kubernetes /var/log/kubernetes
  chmod 0755 /var/log/kubernetes

  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets"]

- level: Request
  resources:
  - group: "rbac.authorization.k8s.io"

- level: Metadata
EOF
  write_if_changed "${AUDIT_POLICY_FILE}" "${tmp}"
}

# 历史版本曾把备份写在 /etc/kubernetes/manifests/ 下；kubelet 会 glob 到第二份 kube-apiserver Pod，主清单写入瞬间还可能解析失败（journal 中 Kind=null），导致 apiserver 长期不带 --audit-*。
migrate_legacy_kube_apiserver_backups_out_of_manifests_dir() {
  local static_dir="/etc/kubernetes/manifests"
  mkdir -p "${KUBE_APISERVER_MANIFEST_BACKUP_DIR}"
  local f moved=0
  shopt -s nullglob
  for f in "${static_dir}/kube-apiserver.yaml.k8s-deploy."*; do
    log_warn "将误放在静态 Pod 目录内的备份移出（避免 kubelet 重复加载）: ${f} -> ${KUBE_APISERVER_MANIFEST_BACKUP_DIR}/"
    mv -f "${f}" "${KUBE_APISERVER_MANIFEST_BACKUP_DIR}/"
    printf '%s\t%s\n' "${f}" "${KUBE_APISERVER_MANIFEST_BACKUP_DIR}/$(basename "${f}")" >>"${BACKUPS_FILE}"
    moved=1
  done
  shopt -u nullglob
  if [ "${moved}" = 1 ]; then
    log_info "kubelet 将在数秒至数十秒内重扫静态清单；若 apiserver 短暂不可用属预期。"
  fi
}

enable_kube_apiserver_audit() {
  local manifest="/etc/kubernetes/manifests/kube-apiserver.yaml"
  [ -f "${manifest}" ] || die "未找到 ${manifest}。该操作只需要在 control-plane 节点执行；worker 节点不用执行 enable-audit。"
  if ! have python3; then
    local sop_root="${K8S_DEPLOY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
    die "缺少 python3，无法自动安全修改 ${manifest}。可选：(1) 安装 python3 后重试：bash ${SCRIPT_DIR}/30-Deploy-rsyslog.sh enable-audit；(2) 按 SOP 手工操作：打开 ${sop_root}/rsyslog.md，按「4.2 每个 control-plane 开启 Kubernetes audit」备份并编辑 ${manifest}，完成 audit 参数与 volumeMounts/volumes。"
  fi

  write_audit_policy
  log_info "audit 策略文件已就绪，继续处理 apiserver 静态 Pod 清单: ${manifest}"
  migrate_legacy_kube_apiserver_backups_out_of_manifests_dir
  log_info "已检查 manifests 目录内误放的 kube-apiserver 备份（若有则已移出到 ${KUBE_APISERVER_MANIFEST_BACKUP_DIR}）。"

  if grep -q -- "--audit-policy-file=${AUDIT_POLICY_FILE}" "${manifest}" &&
     grep -q -- "name: audit-policy" "${manifest}" &&
     grep -q -- "name: audit-log" "${manifest}"; then
    log_info "kube-apiserver audit 已配置，跳过修改: ${manifest}"
    relax_kubernetes_audit_log_for_rsyslog_imfile
    return 0
  fi

  mkdir -p "${KUBE_APISERVER_MANIFEST_BACKUP_DIR}" ||
    die "无法创建 kube-apiserver manifest 备份目录: ${KUBE_APISERVER_MANIFEST_BACKUP_DIR}"
  local ts_stamp
  ts_stamp=$(ts)
  local backup
  backup="${KUBE_APISERVER_MANIFEST_BACKUP_DIR}/$(basename "${manifest}").k8s-deploy.${ts_stamp}"
  cp -a "${manifest}" "${backup}" ||
    die "无法备份 manifest（请检查权限与磁盘）: ${manifest} -> ${backup}"
  printf '%s\t%s\n' "${manifest}" "${backup}" >>"${BACKUPS_FILE}" ||
    die "无法写入备份清单记录: ${BACKUPS_FILE}"
  log_warn "已备份 kube-apiserver manifest: ${manifest} -> ${backup}"

  if ! python3 - "$manifest" "$AUDIT_POLICY_FILE" "$RSYSLOG_AUDIT_MAXAGE" "$RSYSLOG_AUDIT_MAXBACKUP" "$RSYSLOG_AUDIT_MAXSIZE" <<'PY'
from pathlib import Path
import sys

manifest = Path(sys.argv[1])
policy = sys.argv[2]
maxage = sys.argv[3]
maxbackup = sys.argv[4]
maxsize = sys.argv[5]

lines = manifest.read_text().splitlines()

def has(text):
    return any(text in line for line in lines)

def insert_after(predicate, new_lines, label):
    for i, line in enumerate(lines):
        if predicate(line):
            lines[i + 1:i + 1] = new_lines
            return
    raise SystemExit(f"未找到可插入位置: {label}")


def is_apiserver_command_line(line):
    """匹配 command 首参：常见为 - kube-apiserver 或 - /usr/local/bin/kube-apiserver 等。"""
    s = line.strip()
    if s == "- kube-apiserver":
        return True
    if s.startswith("- ") and s.endswith("kube-apiserver") and "/" in s:
        return True
    return False


if not has(f"--audit-policy-file={policy}"):
    audit_args = [
        f"    - --audit-policy-file={policy}",
        "    - --audit-log-path=/var/log/kubernetes/audit.log",
        f"    - --audit-log-maxage={maxage}",
        f"    - --audit-log-maxbackup={maxbackup}",
        f"    - --audit-log-maxsize={maxsize}",
    ]
    insert_after(is_apiserver_command_line, audit_args, "kube-apiserver command")

if not has(f"mountPath: {policy}") or not has("mountPath: /var/log/kubernetes"):
    volume_mounts = [
        f"    - mountPath: {policy}",
        "      name: audit-policy",
        "      readOnly: true",
        "    - mountPath: /var/log/kubernetes",
        "      name: audit-log",
    ]
    insert_after(lambda l: l.strip() == "volumeMounts:", volume_mounts, "volumeMounts")

if not has(f"path: {policy}") or not has("path: /var/log/kubernetes"):
    volumes = [
        "  - hostPath:",
        f"      path: {policy}",
        "      type: File",
        "    name: audit-policy",
        "  - hostPath:",
        "      path: /var/log/kubernetes",
        "      type: DirectoryOrCreate",
        "    name: audit-log",
    ]
    insert_after(lambda l: l.strip() == "volumes:", volumes, "volumes")

manifest.write_text("\n".join(lines) + "\n")
PY
  then
    local sop_root="${K8S_DEPLOY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
    die "自动修改 ${manifest} 失败（python3 非零退出，原因见上一段报错）。请核对 manifest 中 command 首行是否为 kube-apiserver；或按 ${sop_root}/rsyslog.md §4.2 手工编辑。"
  fi

  log_command "grep -n -- '--audit-policy-file\\|audit-policy\\|audit-log' \"${manifest}\""
  log_info "已更新 kube-apiserver audit 配置。kubelet 会自动重启 kube-apiserver，请稍后检查控制面状态。"
  relax_kubernetes_audit_log_for_rsyslog_imfile

  if [ ! -f /var/log/kubernetes/audit.log ]; then
    log_warn "当前主机上尚未出现 /var/log/kubernetes/audit.log（已改静态 Pod 清单不代表 apiserver 已成功启动并写盘）。请按序排查："
    log_warn "  1) kubectl get pods -n kube-system 2>/dev/null | grep apiserver — 是否为 Running、是否 CrashLoopBackOff。"
    log_warn "  2) journalctl -u kubelet --since '15 min ago' --no-pager | grep -iE 'apiserver|Error|Failed' — kubelet 拉静态 Pod 是否报错。"
    log_warn "  3) crictl ps -a |grep kube-apiserver 找到 kube-apiserver 容器后: crictl logs <容器ID> — apiserver 是否报 audit 策略/挂载/权限错误。"
    log_warn "  4) ls -ld /var/log/kubernetes /etc/kubernetes/audit-policy.yaml — 目录与策略文件是否存在、策略文件对 apiserver 可读。"
    log_warn "  5) 打开 ${manifest}，在 volumes 里找到 name: audit-log 的 hostPath：path 应为 /var/log/kubernetes、type 应为 DirectoryOrCreate；在 volumeMounts 里对应挂载不要设 readOnly（否则无法写 audit.log）。"
  fi
}

write_journald_config() {
  mkdir -p /var/log/journal /etc/systemd/journald.conf.d
  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
[Journal]
Storage=persistent
SystemMaxUse=${RSYSLOG_JOURNAL_SYSTEM_MAX_USE}
RuntimeMaxUse=${RSYSLOG_JOURNAL_RUNTIME_MAX_USE}
MaxRetentionSec=${RSYSLOG_JOURNAL_MAX_RETENTION}
EOF
  write_if_changed "${JOURNALD_LIMIT_FILE}" "${tmp}"
  if have systemctl; then
    log_command "systemctl restart systemd-journald"
  else
    log_warn "未找到 systemctl，请手动重载 journald 使 ${JOURNALD_LIMIT_FILE} 生效"
  fi
}

write_local_logrotate() {
  local family tmp sys_file auth_file
  family="$(os_family)"
  if [ "${family}" = "debian" ]; then
    sys_file="/var/log/syslog"
    auth_file="/var/log/auth.log"
  else
    sys_file="/var/log/messages"
    auth_file="/var/log/secure"
  fi

  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
${sys_file}
${auth_file}
/var/log/kubernetes/audit.log
/var/log/containers/*.log {
    daily
    rotate ${RSYSLOG_LOCAL_ROTATE_DAYS}
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
  write_if_changed "${LOCAL_ROTATE_FILE}" "${tmp}"
}

build_forward_actions() {
  local raw target safe permitted_peer
  permitted_peer="$(first_log_server_name)"
  printf '%s\n' "${RSYSLOG_LOG_SERVER}" | tr ',' '\n' | while IFS= read -r raw; do
    target="$(printf '%s' "${raw}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "${target}" ] || continue
    safe="$(printf '%s' "${target}" | tr -c 'A-Za-z0-9_' '_')"
    cat <<EOF
  action(
    type="omfwd"
    target="${target}"
    port="${RSYSLOG_LOG_SERVER_PORT}"
    protocol="tcp"
EOF
    if [ "${RSYSLOG_TRANSPORT}" = "tls" ]; then
      cat <<EOF
    StreamDriver="gtls"
    StreamDriverMode="1"
    StreamDriverAuthMode="${RSYSLOG_TLS_AUTH_MODE}"
EOF
      if [ "${RSYSLOG_TLS_AUTH_MODE}" = "x509/name" ]; then
        cat <<EOF
    StreamDriver.CAFile="${RSYSLOG_SSL_DIR}/ca.crt"
    StreamDriverPermittedPeers="${permitted_peer}"
EOF
      fi
    fi
    cat <<EOF
    queue.type="LinkedList"
    queue.filename="k8s_remote_forward_${safe}"
    queue.maxdiskspace="10g"
    queue.saveonshutdown="on"
    action.resumeRetryCount="-1"
  )
EOF
  done
}

write_client_conf() {
  local family tmp sys_file auth_file forward_actions
  family="$(os_family)"
  if [ "${family}" = "debian" ]; then
    sys_file="/var/log/syslog"
    auth_file="/var/log/auth.log"
  else
    sys_file="/var/log/messages"
    auth_file="/var/log/secure"
  fi

  forward_actions="$(build_forward_actions)"
  if [ "${RSYSLOG_FORWARD_ENABLE}" != "no" ] && [ "${RSYSLOG_FORWARD_ENABLE}" != "false" ] && [ "${RSYSLOG_FORWARD_ENABLE}" != "0" ]; then
    printf '%s\n' "${forward_actions}" | grep -q 'type="omfwd"' || die "未生成 rsyslog 外发动作，请检查 RSYSLOG_LOG_SERVER=${RSYSLOG_LOG_SERVER}"
  fi

  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
module(load="imfile" PollingInterval="10")
\$MaxMessageSize 64k
EOF
  cat >>"${tmp}" <<EOF

ruleset(name="k8sDeployRemoteForward") {
${forward_actions}
}

input(type="imfile"
  File="${sys_file}"
  Tag="system"
  Facility="local0"
  Severity="info"
  Ruleset="k8sDeployRemoteForward")

input(type="imfile"
  File="${auth_file}"
  Tag="auth"
  Facility="authpriv"
  Severity="info"
  Ruleset="k8sDeployRemoteForward")

input(type="imfile"
  File="/var/log/kubernetes/audit.log"
  Tag="k8s-audit"
  Facility="local1"
  Severity="info"
  Ruleset="k8sDeployRemoteForward")

input(type="imfile"
  File="/var/log/containers/*.log"
  Tag="container"
  Facility="local2"
  Severity="info"
  Ruleset="k8sDeployRemoteForward")

*.* call k8sDeployRemoteForward
EOF
  write_if_changed "${CLIENT_CONF}" "${tmp}"
}

ensure_client_ca() {
  if [ "${RSYSLOG_TRANSPORT}" != "tls" ]; then
    log_info "当前 RSYSLOG_TRANSPORT=${RSYSLOG_TRANSPORT}，客户端不检查 TLS CA"
    return 0
  fi
  if [ "${RSYSLOG_TLS_AUTH_MODE}" != "x509/name" ]; then
    log_info "当前 RSYSLOG_TLS_AUTH_MODE=${RSYSLOG_TLS_AUTH_MODE}，客户端不强制检查 CA"
    return 0
  fi
  if [ -f "${RSYSLOG_SSL_DIR}/ca.crt" ]; then
    log_info "客户端 CA 已存在: ${RSYSLOG_SSL_DIR}/ca.crt"
    return 0
  fi
  die "缺少 ${RSYSLOG_SSL_DIR}/ca.crt。RSYSLOG_TLS_AUTH_MODE=x509/name 时，请先在日志服务器执行本脚本生成 CA，再复制 ca.crt 到每个节点 ${RSYSLOG_SSL_DIR}/"
}

# Ubuntu AppArmor 默认 rsyslogd profile 不放行自定义 TLS 目录与非 /var/log 落盘目录，
# 会导致 rsyslogd -N1 / 启动时报 Permission denied（dmesg 可见 apparmor="DENIED"）。
ensure_rsyslog_apparmor() {
  local profile="/etc/apparmor.d/usr.sbin.rsyslogd"
  local local_override="/etc/apparmor.d/local/usr.sbin.rsyslogd"
  local begin="# BEGIN k8s-deploy rsyslog paths"
  local end="# END k8s-deploy rsyslog paths"
  local tmp

  [ -f "${profile}" ] || return 0
  have apparmor_parser || return 0

  # 使用 Ubuntu 站点本地覆盖约定；profile 中必须包含该 local override。
  if ! grep -Eq '^[[:space:]]*#include[[:space:]]+<local/usr\.sbin\.rsyslogd>' "${profile}"; then
    log_warn "AppArmor profile 未包含 local/usr.sbin.rsyslogd，无法自动放行 ${RSYSLOG_SSL_DIR}；请检查 ${profile}"
    return 0
  fi

  mkdir -p "$(dirname "${local_override}")"
  tmp="$(mktemp)"
  if [ -f "${local_override}" ]; then
    awk -v begin="${begin}" -v end="${end}" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "${local_override}" >"${tmp}"
  fi
  cat >>"${tmp}" <<EOF
${begin}
  ${RSYSLOG_SSL_DIR}/ r,
  ${RSYSLOG_SSL_DIR}/** r,
  ${RSYSLOG_LOG_DIR}/ rw,
  ${RSYSLOG_LOG_DIR}/** rw,
${end}
EOF

  if [ ! -f "${local_override}" ] || ! cmp -s "${local_override}" "${tmp}"; then
    install -m 0644 "${tmp}" "${local_override}"
    log_info "已更新 AppArmor rsyslogd 本地规则: ${local_override}"
  fi
  rm -f "${tmp}"

  if apparmor_parser -r "${profile}" 2>/dev/null; then
    log_info "已刷新 AppArmor rsyslogd 规则（放行 ${RSYSLOG_SSL_DIR} 与 ${RSYSLOG_LOG_DIR}）"
  else
    log_warn "apparmor_parser -r ${profile} 失败；若仍遇 TLS/日志目录 Permission denied，请手工检查 AppArmor"
  fi
}

restart_rsyslog() {
  ensure_rsyslog_apparmor
  log_command "rsyslogd -N1"
  if have systemctl; then
    log_command "systemctl enable --now rsyslog"
    log_command "systemctl restart rsyslog"
  elif have service; then
    log_command "service rsyslog restart"
  else
    log_warn "未找到 systemctl 与 service，请在本机手动重启 rsyslog 使配置生效"
  fi
}

disable_forward() {
  if [ -f "${CLIENT_CONF}" ]; then
    backup_if_exists "${CLIENT_CONF}"
    log_info "已关闭本节点日志外发配置: ${CLIENT_CONF}"
  else
    log_info "未发现本节点日志外发配置，跳过关闭: ${CLIENT_CONF}"
  fi
  if have rsyslogd; then
    restart_rsyslog
  fi
  print_verification_hints_disable_forward
}

# kube-apiserver 写的 audit.log 多为 root:root 0600；rsyslog 若以 syslog 运行则 imfile 无法读，集中端不会出现 local1。
relax_kubernetes_audit_log_for_rsyslog_imfile() {
  [ -d /var/log/kubernetes ] || return 0
  if ! id -u "${RSYSLOG_RSYSLOGD_USER}" >/dev/null 2>&1; then
    log_info "无系统用户 ${RSYSLOG_RSYSLOGD_USER}，假定 rsyslog 以 root 运行，跳过 audit 日志读权限调整"
    return 0
  fi
  if getent group adm >/dev/null 2>&1; then
    # 默认依赖 syslog 在 adm 组（Ubuntu/Debian 常见），避免引入 setfacl/acl 包依赖。
    # 注意：该方式会让 adm 组成员也能读取 audit 日志，需按现场安全要求评估。
    if [ -f /var/log/kubernetes/audit.log ]; then
      chgrp adm /var/log/kubernetes/audit.log 2>/dev/null || true
      chmod 640 /var/log/kubernetes/audit.log 2>/dev/null || true
    fi
    # 轮转文件与目录（尽量兼容；若 apiserver 后续再把权限改回 600，需结合 logrotate 或 cron 再修一次）
    chgrp adm /var/log/kubernetes 2>/dev/null || true
    chmod 0750 /var/log/kubernetes 2>/dev/null || true
    shopt -s nullglob
    local af
    for af in /var/log/kubernetes/audit-*.log; do
      chgrp adm "${af}" 2>/dev/null || true
      chmod 640 "${af}" 2>/dev/null || true
    done
    shopt -u nullglob
    log_info "已将 /var/log/kubernetes/audit*.log 设置为 root:adm 640（便于 ${RSYSLOG_RSYSLOGD_USER} 读取并外发 local1）"
  else
    log_warn "系统无 adm 组，且本脚本不使用 setfacl；请手工放宽 /var/log/kubernetes/audit*.log 的读取权限（例如改为 syslog 可读），否则集中端无 local1 审计日志。"
  fi
}

# /var/log/containers/*.log 多为指向 /var/log/pods/.../0.log 的符号链接；真实文件常为 root:root 640，syslog 无法读则集中端无 local2。
relax_pod_logs_for_rsyslog_imfile() {
  [ -d /var/log/pods ] || return 0
  if ! id -u "${RSYSLOG_RSYSLOGD_USER}" >/dev/null 2>&1; then
    return 0
  fi
  if ! getent group adm >/dev/null 2>&1; then
    log_warn "系统无 adm 组：无法自动放宽 /var/log/pods 供 ${RSYSLOG_RSYSLOGD_USER} 读取，集中端可能无 local2 容器日志。"
    return 0
  fi
  chgrp -R adm /var/log/pods 2>/dev/null || log_warn "部分 /var/log/pods 无法 chgrp adm，local2 外发可能仍不完整"
  if have find; then
    find /var/log/pods -type d -exec chmod 750 {} + 2>/dev/null || true
    find /var/log/pods -type f -name '*.log' -exec chmod 640 {} + 2>/dev/null || true
  else
    log_warn "未找到 find，跳过对 /var/log/pods 的批量 chmod；请安装 findutils 或手工放宽权限。"
  fi
  log_info "已放宽 /var/log/pods（root:adm，目录 750、*.log 640）供 imfile 读取并外发 local2；kubelet 新建日志后若又变回仅 root 可读，可重跑 client/enable-forward 或配定时任务再执行本步骤"
}

# client 外发里配置了 imfile(/var/log/kubernetes/audit.log) → facility local1；该文件仅当 kube-apiserver 启用审计后才会出现。
hint_kube_audit_for_rsyslog_forward() {
  local manifest="/etc/kubernetes/manifests/kube-apiserver.yaml"
  [ -f "${manifest}" ] || return 0
  if grep -q -- '--audit-log-path=/var/log/kubernetes/audit.log' "${manifest}" &&
     grep -q -- '--audit-policy-file=' "${manifest}"; then
    if [ ! -f /var/log/kubernetes/audit.log ]; then
      log_warn "kube-apiserver 已配置审计写出，但 /var/log/kubernetes/audit.log 尚不存在；kubelet 滚动 apiserver 后数分钟内应生成。若长时间仍无文件请检查 apiserver Pod 与 volume 挂载。"
    fi
    return 0
  fi
  log_warn "本机为 control-plane（存在 ${manifest}），但 apiserver 尚未配置审计日志写出，不会生成 /var/log/kubernetes/audit.log。"
  log_warn "外发配置仍会尝试 imfile 读取该文件（无则 rsyslog 启动时可能有 imfile 提示）；集中端将缺少 local1 下的 k8s 审计日志。"
  log_warn "需要 API 审计时请执行: bash ${SCRIPT_DIR}/30-Deploy-rsyslog.sh enable-audit"
}

enable_forward() {
  require_log_server
  install_packages
  mkdir -p "${RSYSLOG_SSL_DIR}"
  ensure_client_ca
  write_client_conf
  relax_kubernetes_audit_log_for_rsyslog_imfile
  relax_pod_logs_for_rsyslog_imfile
  restart_rsyslog
  hint_kube_audit_for_rsyslog_forward
  log_command "logger \"rsyslog client test from $(hostname)\""
  log_info "节点日志外发已开启，目标: ${RSYSLOG_LOG_SERVER}"
  print_verification_hints_log_client_forward
}

preconfig_node() {
  write_audit_policy
  write_journald_config
  write_local_logrotate
}

configure_server() {
  log_info "开始配置 rsyslog 日志服务器"
  install_packages
  case "${RSYSLOG_TRANSPORT}" in
    tls)
      have openssl || die "缺少 openssl"
      ensure_server_certs
      ;;
    plain)
      log_warn "RSYSLOG_TRANSPORT=plain，日志服务器将使用普通 TCP 接收，不启用 TLS"
      ;;
    *)
      die "RSYSLOG_TRANSPORT 只能是 tls 或 plain，当前: ${RSYSLOG_TRANSPORT}"
      ;;
  esac
  write_server_conf
  write_remote_logrotate
  restart_rsyslog
  log_info "日志服务器配置完成: TCP ${RSYSLOG_LOG_SERVER_PORT}, 日志目录 ${RSYSLOG_LOG_DIR}"
  if [ "${RSYSLOG_TLS_AUTH_MODE}" = "x509/name" ]; then
    log_info "请复制 ${RSYSLOG_SSL_DIR}/ca.crt 到每个 Kubernetes 节点的 ${RSYSLOG_SSL_DIR}/ca.crt"
  fi
  print_verification_hints_log_server
}

configure_client() {
  log_info "开始配置 rsyslog 客户端节点"
  case "${RSYSLOG_TRANSPORT}" in
    tls|plain) : ;;
    *) die "RSYSLOG_TRANSPORT 只能是 tls 或 plain，当前: ${RSYSLOG_TRANSPORT}" ;;
  esac
  install_packages
  preconfig_node
  case "${RSYSLOG_FORWARD_ENABLE}" in
    yes|true|1)
      enable_forward
      ;;
    no|false|0)
      disable_forward
      log_info "节点本机日志预配置完成，日志外发保持关闭"
      ;;
    *)
      die "RSYSLOG_FORWARD_ENABLE 只能是 yes/no/true/false/1/0，当前: ${RSYSLOG_FORWARD_ENABLE}"
      ;;
  esac
}

# 清理本脚本写入的配置，便于从零重新部署 server/client（文件先备份再删，见 framework backup_if_exists）。
cleanup_deploy_rsyslog() {
  log_info "开始 cleanup：移除本脚本管理的 rsyslog / logrotate / journald 配置片段"
  local f
  for f in "${SERVER_CONF}" "${CLIENT_CONF}" "${REMOTE_ROTATE_FILE}" "${LOCAL_ROTATE_FILE}" "${JOURNALD_LIMIT_FILE}"; do
    if [ -e "${f}" ]; then
      backup_if_exists "${f}"
      log_info "已移除: ${f}"
    else
      log_info "不存在，跳过: ${f}"
    fi
  done

  case "${RSYSLOG_CLEANUP_AUDIT_POLICY:-}" in
    yes|true|1)
      if [ -e "${AUDIT_POLICY_FILE}" ]; then
        backup_if_exists "${AUDIT_POLICY_FILE}"
        log_info "已移除 audit 策略: ${AUDIT_POLICY_FILE}"
      fi
      log_warn "若 kube-apiserver 仍挂载/引用该策略，请编辑 /etc/kubernetes/manifests/kube-apiserver.yaml 删除 audit 相关参数与 volume，或从 ${KUBE_APISERVER_MANIFEST_BACKUP_DIR} 下 kube-apiserver.yaml.k8s-deploy.* 备份恢复 manifest（勿将备份留在 manifests 目录内）。"
      ;;
    *)
      log_info "未设置 RSYSLOG_CLEANUP_AUDIT_POLICY=yes，保留 ${AUDIT_POLICY_FILE}"
      ;;
  esac

  case "${RSYSLOG_CLEANUP_SSL:-}" in
    yes|true|1)
      if [ -e "${RSYSLOG_SSL_DIR}" ]; then
        backup_if_exists "${RSYSLOG_SSL_DIR}"
        log_info "已备份并移除 TLS 目录: ${RSYSLOG_SSL_DIR}"
      fi
      ;;
    *)
      log_info "未设置 RSYSLOG_CLEANUP_SSL=yes，保留 ${RSYSLOG_SSL_DIR}"
      ;;
  esac

  case "${RSYSLOG_CLEANUP_LOG_DATA:-}" in
    yes|true|1)
      if [ -z "${RSYSLOG_LOG_DIR}" ] || [ "${RSYSLOG_LOG_DIR}" = "/" ]; then
        die "RSYSLOG_LOG_DIR 异常，拒绝清空"
      fi
      if [ -d "${RSYSLOG_LOG_DIR}" ]; then
        log_warn "将清空集中日志目录内容: ${RSYSLOG_LOG_DIR}"
        find "${RSYSLOG_LOG_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      fi
      ;;
    *)
      log_info "未设置 RSYSLOG_CLEANUP_LOG_DATA=yes，保留 ${RSYSLOG_LOG_DIR} 下已有文件"
      ;;
  esac

  if have rsyslogd; then
    restart_rsyslog
  fi
  if have systemctl; then
    log_command "systemctl restart systemd-journald" || true
  fi

  cat <<EOF

======== cleanup 完成 · 可重新部署 ========
  bash 30-Deploy-rsyslog.sh server   # 或 client / auto
EOF
}

main() {
  local mode="${1:-auto}"
  if [ "${mode}" = "-h" ] || [ "${mode}" = "--help" ]; then
    usage
    exit 0
  fi

  case "${mode}" in
    preconfig)
      preconfig_node
      ;;
    enable-audit)
      enable_kube_apiserver_audit
      ;;
    server)
      configure_server
      ;;
    client)
      configure_client
      ;;
    enable-forward)
      preconfig_node
      enable_forward
      ;;
    disable-forward)
      disable_forward
      ;;
    cleanup)
      cleanup_deploy_rsyslog
      ;;
    auto)
      require_log_server
      if is_this_log_server; then
        configure_server
      else
        configure_client
      fi
      ;;
    *)
      usage
      die "未知模式: ${mode}"
      ;;
  esac
}

main "$@"
