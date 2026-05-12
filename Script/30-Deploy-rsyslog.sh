#!/usr/bin/env bash
################################################################################
## Filename:    30-Deploy-rsyslog.sh
## Description: 后置配置 Kubernetes 集群 rsyslog 集中日志审计，支持日志服务器和节点复用同一脚本
##
## 用法示例：
##   sudo bash 30-Deploy-rsyslog.sh
##
##   sudo bash 30-Deploy-rsyslog.sh client  #把当前机器配置成日志发送节点。 需要每个节点都执行一次。
##   sudo bash 30-Deploy-rsyslog.sh server  #把当前机器配置成日志服务器。
##   sudo bash 30-Deploy-rsyslog.sh preconfig #只做本机预配置，不配置 rsyslog 推送/接收。
##   sudo bash 30-Deploy-rsyslog.sh enable-audit #在 control-plane 节点开启 kube-apiserver audit。
##   sudo bash 30-Deploy-rsyslog.sh enable-forward  #开启本节点日志外发。
##   sudo bash 30-Deploy-rsyslog.sh disable-forward #关闭本节点日志外发。
##
## 最简单推荐流程：
##   # 已有日志服务器时，在每个 Kubernetes 节点执行：
##   export RSYSLOG_LOG_SERVER=<log-server-ip>
##   sudo bash 30-Deploy-rsyslog.sh client
##
##   # 没有日志服务器时，先在日志服务器执行：
##   export RSYSLOG_LOG_SERVER=<log-server-ip>
##   sudo bash 30-Deploy-rsyslog.sh server
##
##   # 然后在每个 Kubernetes 节点执行：
##   export RSYSLOG_LOG_SERVER=<log-server-ip>
##   sudo bash 30-Deploy-rsyslog.sh client
##
##   # 后续新增节点时，只需要在新增节点再执行 client。
##
##   # 如果集群已部署且未开启 Kubernetes audit，在每个 control-plane 节点执行：
##   sudo bash 30-Deploy-rsyslog.sh enable-audit
##
## 可选环境变量（优先级高于默认值）：
##   RSYSLOG_LOG_SERVER / RSYSLOG_LOG_SERVER_PORT / RSYSLOG_LOG_DIR
##   RSYSLOG_SSL_DIR / RSYSLOG_LOCAL_ROTATE_DAYS / RSYSLOG_TRANSPORT / RSYSLOG_TLS_AUTH_MODE
##   RSYSLOG_FORWARD_ENABLE
##   RSYSLOG_AUDIT_MAXAGE / RSYSLOG_AUDIT_MAXBACKUP / RSYSLOG_AUDIT_MAXSIZE
##   RSYSLOG_JOURNAL_SYSTEM_MAX_USE / RSYSLOG_JOURNAL_RUNTIME_MAX_USE / RSYSLOG_JOURNAL_MAX_RETENTION
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

init_framework
require_root

# 日志服务器地址，必须通过 environment.sh 或执行前 export 指定；多个目标用英文逗号分隔。
RSYSLOG_LOG_SERVER="${RSYSLOG_LOG_SERVER:-}"
# 日志服务器 rsyslog TLS 监听端口，也是客户端推送端口。
RSYSLOG_LOG_SERVER_PORT="${RSYSLOG_LOG_SERVER_PORT:-6514}"
# 日志服务器集中保存远端日志的目录。
RSYSLOG_LOG_DIR="${RSYSLOG_LOG_DIR:-/data/logs}"
# rsyslog TLS 证书目录；默认脚本使用 anon TLS 时客户端不强制需要证书。
RSYSLOG_SSL_DIR="${RSYSLOG_SSL_DIR:-/etc/rsyslog/ssl}"
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
RSYSLOG_JOURNAL_MAX_RETENTION="${RSYSLOG_JOURNAL_MAX_RETENTION:-7day}"
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

usage() {
  cat <<EOF
用法:
  sudo bash 30-Deploy-rsyslog.sh [auto|server|client|preconfig|enable-audit|enable-forward|disable-forward]

默认 auto:
  本机 IP 命中 RSYSLOG_LOG_SERVER 时配置日志服务器，否则配置客户端。

变量来自 Script/environment.sh，可手动覆盖:
  RSYSLOG_LOG_SERVER       客户端外发时必填，日志服务器 IP/域名；多个推送目标用英文逗号分隔
  RSYSLOG_LOG_SERVER_PORT  默认 6514
  RSYSLOG_LOG_DIR          默认 /data/logs
  RSYSLOG_LOCAL_ROTATE_DAYS 默认 7
  RSYSLOG_FORWARD_ENABLE   默认 yes；设置 no 时 client 模式只做本机预配置并关闭外发
  RSYSLOG_TRANSPORT        默认 tls；已有服务器只支持普通 TCP 时设置 plain
  RSYSLOG_TLS_AUTH_MODE    默认 anon，简单稳定；如需双向证书认证需手工改为 x509/name 并分发证书
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

offline_rsyslog_dir() {
  case "${OS_ID:-}" in
    ubuntu|debian)
      printf '%s\n' "${DOWNLOAD_DIR}/packages/ubuntu/tools/rsyslog"
      ;;
    centos)
      printf '%s\n' "${DOWNLOAD_DIR}/packages/centos/tools/rsyslog"
      ;;
    rocky)
      printf '%s\n' "${DOWNLOAD_DIR}/packages/rocky/tools/rsyslog"
      ;;
    openeuler)
      printf '%s\n' "${DOWNLOAD_DIR}/packages/openeuler/tools/rsyslog"
      ;;
    kylin*)
      printf '%s\n' "${DOWNLOAD_DIR}/packages/kylin/tools/rsyslog"
      ;;
    *)
      die "未识别的 OS_ID=${OS_ID:-unknown}，无法确定 rsyslog 离线包目录。请手动在 ${DOWNLOAD_DIR}/packages/<os>/tools/rsyslog 放置离线包。"
      ;;
  esac
}

offline_rsyslog_hint() {
  local dir="$1"
  log_error "rsyslog 在线安装失败，现场可能是断网环境。"
  log_error "请在离线制品目录准备 rsyslog 安装包: ${dir}"
  case "${OS_ID:-}" in
    ubuntu|debian)
      log_error "目录内需要放置 .deb 包，例如 rsyslog、rsyslog-gnutls、logrotate、openssl 及其依赖。"
      ;;
    *)
      log_error "目录内需要放置 .rpm 包，例如 rsyslog、rsyslog-gnutls、logrotate、openssl 及其依赖。"
      ;;
  esac
}

install_rsyslog_offline() {
  local dir
  dir="$(offline_rsyslog_dir)"
  offline_rsyslog_hint "${dir}"
  [ -d "${dir}" ] || die "离线包目录不存在: ${dir}"

  case "${OS_ID:-}" in
    ubuntu|debian)
      shopt -s nullglob
      local debs=("${dir}"/*.deb)
      shopt -u nullglob
      [ "${#debs[@]}" -gt 0 ] || die "离线包目录为空或没有 .deb 文件: ${dir}"
      log_command "dpkg -i \"${dir}\"/*.deb"
      ;;
    *)
      shopt -s nullglob
      local rpms=("${dir}"/*.rpm)
      shopt -u nullglob
      [ "${#rpms[@]}" -gt 0 ] || die "离线包目录为空或没有 .rpm 文件: ${dir}"
      if have dnf; then
        log_command "dnf -y install \"${dir}\"/*.rpm"
      else
        log_command "yum -y localinstall \"${dir}\"/*.rpm"
      fi
      ;;
  esac
}

install_packages() {
  local pm
  pm="$(detect_pkg_manager)"
  if have rsyslogd && rsyslogd -v 2>/dev/null | grep -qi gnutls; then
    log_info "rsyslog 和 gnutls 支持已存在，跳过安装"
    return 0
  fi

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

  have rsyslogd || die "rsyslog 安装后仍未找到 rsyslogd"
  rsyslogd -v 2>/dev/null | grep -qi gnutls || die "rsyslog 未检测到 gnutls 支持，请检查 rsyslog-gnutls 包"
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
  [ -n "${RSYSLOG_LOG_SERVER}" ] || die "RSYSLOG_LOG_SERVER 为空。需要开启外发时，请先在 environment.sh 设置，或执行前 export RSYSLOG_LOG_SERVER=<日志服务器IP>"
}

os_family() {
  case "${OS_ID:-}" in
    ubuntu|debian) printf '%s\n' "debian" ;;
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

  chmod 600 "${RSYSLOG_SSL_DIR}"/*.key
  chmod 644 "${RSYSLOG_SSL_DIR}"/*.crt
}

write_server_conf() {
  mkdir -p "${RSYSLOG_LOG_DIR}"
  chmod 0755 "${RSYSLOG_LOG_DIR}"

  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
module(load="imtcp")
EOF
  if [ "${RSYSLOG_TRANSPORT}" = "tls" ]; then
    cat >>"${tmp}" <<EOF
module(load="gtls")

global(
  DefaultNetstreamDriver="gtls"
  DefaultNetstreamDriverCAFile="${RSYSLOG_SSL_DIR}/ca.crt"
  DefaultNetstreamDriverCertFile="${RSYSLOG_SSL_DIR}/server.crt"
  DefaultNetstreamDriverKeyFile="${RSYSLOG_SSL_DIR}/server.key"
)
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
EOF
  if [ "${RSYSLOG_TRANSPORT}" = "tls" ]; then
    cat >>"${tmp}" <<EOF
  StreamDriver.Name="gtls"
  StreamDriver.Mode="1"
  StreamDriver.AuthMode="${RSYSLOG_TLS_AUTH_MODE}"
EOF
  fi
  cat >>"${tmp}" <<EOF
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
        systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
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

enable_kube_apiserver_audit() {
  local manifest="/etc/kubernetes/manifests/kube-apiserver.yaml"
  [ -f "${manifest}" ] || die "未找到 ${manifest}。该操作只需要在 control-plane 节点执行；worker 节点不用执行 enable-audit。"
  have python3 || die "缺少 python3，无法安全修改 ${manifest}"

  write_audit_policy

  if grep -q -- "--audit-policy-file=${AUDIT_POLICY_FILE}" "${manifest}" &&
     grep -q -- "name: audit-policy" "${manifest}" &&
     grep -q -- "name: audit-log" "${manifest}"; then
    log_info "kube-apiserver audit 已配置，跳过修改: ${manifest}"
    return 0
  fi

  local backup="${manifest}.k8s-deploy.$(ts)"
  cp -a "${manifest}" "${backup}"
  printf '%s\t%s\n' "${manifest}" "${backup}" >> "${BACKUPS_FILE}"
  log_warn "已备份 kube-apiserver manifest: ${manifest} -> ${backup}"

  python3 - "$manifest" "$AUDIT_POLICY_FILE" "$RSYSLOG_AUDIT_MAXAGE" "$RSYSLOG_AUDIT_MAXBACKUP" "$RSYSLOG_AUDIT_MAXSIZE" <<'PY'
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

if not has(f"--audit-policy-file={policy}"):
    audit_args = [
        f"    - --audit-policy-file={policy}",
        "    - --audit-log-path=/var/log/kubernetes/audit.log",
        f"    - --audit-log-maxage={maxage}",
        f"    - --audit-log-maxbackup={maxbackup}",
        f"    - --audit-log-maxsize={maxsize}",
    ]
    insert_after(lambda l: l.strip() == "- kube-apiserver", audit_args, "kube-apiserver command")

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

  log_command "grep -n -- '--audit-policy-file\\|audit-policy\\|audit-log' \"${manifest}\""
  log_info "已更新 kube-apiserver audit 配置。kubelet 会自动重启 kube-apiserver，请稍后检查控制面状态。"
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
  log_command "systemctl restart systemd-journald"
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
  printf '%s' "${RSYSLOG_LOG_SERVER}" | tr ',' '\n' | while IFS= read -r raw; do
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
module(load="imfile" PollingInterval="10")
EOF
  if [ "${RSYSLOG_TRANSPORT}" = "tls" ]; then
    cat >>"${tmp}" <<EOF
module(load="gtls")

global(
  MaxMessageSize="64k"
  DefaultNetstreamDriver="gtls"
EOF
    if [ "${RSYSLOG_TLS_AUTH_MODE}" = "x509/name" ]; then
      cat >>"${tmp}" <<EOF
  DefaultNetstreamDriverCAFile="${RSYSLOG_SSL_DIR}/ca.crt"
EOF
    fi
    cat >>"${tmp}" <<EOF
)
EOF
  else
    cat >>"${tmp}" <<EOF

global(
  MaxMessageSize="64k"
)
EOF
  fi
  cat >>"${tmp}" <<EOF

ruleset(name="k8sDeployRemoteForward") {
$(build_forward_actions)
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

restart_rsyslog() {
  log_command "rsyslogd -N1"
  log_command "systemctl enable --now rsyslog"
  log_command "systemctl restart rsyslog"
}

disable_forward() {
  if [ -f "${CLIENT_CONF}" ]; then
    backup_if_exists "${CLIENT_CONF}"
    log_info "已关闭本节点日志外发配置: ${CLIENT_CONF}"
  else
    log_info "未发现本节点日志外发配置，跳过关闭: ${CLIENT_CONF}"
  fi
  if have systemctl && have rsyslogd; then
    restart_rsyslog
  fi
}

enable_forward() {
  require_log_server
  install_packages
  mkdir -p "${RSYSLOG_SSL_DIR}"
  ensure_client_ca
  write_client_conf
  restart_rsyslog
  log_command "logger \"rsyslog client test from $(hostname)\""
  log_info "节点日志外发已开启，目标: ${RSYSLOG_LOG_SERVER}"
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
