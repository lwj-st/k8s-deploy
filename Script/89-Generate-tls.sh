#!/usr/bin/env bash
set -euo pipefail

################################################################################
## Filename:    89-Generate-tls.sh
## Description: 生成自签 TLS 证书并批量更新多个命名空间的 kubernetes tls secret
## Usage:
##   bash 89-Generate-tls.sh --domain websense.ai
##
##   bash 89-Generate-tls.sh \
##     --domain websense.ai \
##     --wildcard \
##     --days 365 \
##     --secret-name sensecore-tls \
##     --namespaces "platform,jialing,yangzi-middleware,modelstudio,monitoring"
##
## 可选环境变量（优先级低于命令行参数）：
##   DOMAIN / CERT_DAYS / SECRET_NAME / NAMESPACES / ORG / COUNTRY / OUTPUT_DIR
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
have() { command -v "$1" >/dev/null 2>&1; }
log_info() { echo "[$(ts)] [INFO] $*"; }
log_warn() { echo "[$(ts)] [WARN] $*"; }
log_error() { echo "[$(ts)] [ERROR] $*" >&2; }
die() { log_error "$*"; exit 1; }
log_command() {
  local cmd="$1"
  log_info "执行命令: ${cmd}"
  eval "${cmd}"
}

if ! have openssl; then
  die "缺少 openssl，请先安装"
fi
if ! have kubectl; then
  die "缺少 kubectl，请先安装并配置可访问集群"
fi

DOMAIN="${DOMAIN:-sensecore.ai}"
CERT_DAYS="${CERT_DAYS:-365}"
SECRET_NAME="${SECRET_NAME:-sensecore-tls}"
NAMESPACES="${NAMESPACES:-platform,jialing,yangzi-middleware,modelstudio,monitoring}"
# 默认从 DOMAIN 提取组织名（如 websense.ai -> websense），也可通过 --org/环境变量覆盖
DEFAULT_ORG="${DOMAIN%%.*}"
ORG="${ORG:-${DEFAULT_ORG}}"
COUNTRY="${COUNTRY:-CN}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}}"
INCLUDE_WILDCARD="0"

usage() {
  cat <<'EOF'
用法：
  bash 89-Generate-tls.sh [选项]

选项：
  --domain <域名>            主域名（默认：websense.ai）
  --days <天数>              证书有效期（默认：365）
  --secret-name <名称>       tls secret 名称（默认：sensecore-tls）
  --namespaces <列表>        命名空间，逗号分隔（默认：platform,jialing,yangzi-middleware,modelstudio,monitoring）
  --org <组织名>             证书 O 字段（默认：websense）
  --country <国家码>         证书 C 字段（默认：CN）
  --output-dir <目录>        证书与 san.conf 输出目录（默认：脚本目录）
  --wildcard                 SAN 中额外包含 *.domain
  --no-wildcard              SAN 中不包含 *.domain
  -h, --help                 显示帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --days)
      CERT_DAYS="${2:-}"
      shift 2
      ;;
    --secret-name)
      SECRET_NAME="${2:-}"
      shift 2
      ;;
    --namespaces)
      NAMESPACES="${2:-}"
      shift 2
      ;;
    --org)
      ORG="${2:-}"
      shift 2
      ;;
    --country)
      COUNTRY="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --wildcard)
      INCLUDE_WILDCARD="1"
      shift
      ;;
    --no-wildcard)
      INCLUDE_WILDCARD="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1（使用 --help 查看帮助）"
      ;;
  esac
done

[ -n "${DOMAIN}" ] || die "domain 不能为空"
[[ "${CERT_DAYS}" =~ ^[0-9]+$ ]] || die "days 必须是正整数"
[ -n "${SECRET_NAME}" ] || die "secret-name 不能为空"
[ -n "${NAMESPACES}" ] || die "namespaces 不能为空"
[ -n "${ORG}" ] || die "org 不能为空"
[ -n "${COUNTRY}" ] || die "country 不能为空"

mkdir -p "${OUTPUT_DIR}"

SAN_CONF="${OUTPUT_DIR}/san.conf"
TLS_KEY="${OUTPUT_DIR}/${DOMAIN}.key.pem"
TLS_CERT="${OUTPUT_DIR}/${DOMAIN}.cert.pem"

log_info "生成 SAN 配置: ${SAN_CONF}"
{
  echo "[req]"
  echo "distinguished_name = req_distinguished_name"
  echo "x509_extensions = v3_req"
  echo "prompt = no"
  echo
  echo "[req_distinguished_name]"
  echo "C = ${COUNTRY}"
  echo "O = ${ORG}"
  echo "CN = ${DOMAIN}"
  echo
  echo "[v3_req]"
  echo "subjectAltName = @alt_names"
  echo
  echo "[alt_names]"
  echo "DNS.1 = ${DOMAIN}"
  if [ "${INCLUDE_WILDCARD}" = "1" ]; then
    echo "DNS.2 = *.${DOMAIN}"
  fi
} > "${SAN_CONF}"

log_info "生成私钥: ${TLS_KEY}"
log_command "openssl genrsa -out \"${TLS_KEY}\" 2048"

log_info "生成自签证书: ${TLS_CERT}（有效期 ${CERT_DAYS} 天）"
log_command "openssl req -x509 -new -nodes -key \"${TLS_KEY}\" -sha256 -days \"${CERT_DAYS}\" -out \"${TLS_CERT}\" -config \"${SAN_CONF}\""

IFS=',' read -r -a ns_array <<< "${NAMESPACES}"
[ "${#ns_array[@]}" -gt 0 ] || die "namespaces 解析后为空"

for ns in "${ns_array[@]}"; do
  ns="$(echo "${ns}" | xargs)"
  [ -n "${ns}" ] || continue

  if kubectl get ns "${ns}" >/dev/null 2>&1; then
    log_info "更新命名空间 ${ns} 的 secret/${SECRET_NAME}"
    kubectl delete secret "${SECRET_NAME}" -n "${ns}" >/dev/null 2>&1 || log_warn "secret/${SECRET_NAME} 在 ${ns} 不存在，继续"
    log_command "kubectl create secret tls \"${SECRET_NAME}\" --cert=\"${TLS_CERT}\" --key=\"${TLS_KEY}\" -n \"${ns}\""
  else
    log_warn "命名空间不存在，跳过: ${ns}"
  fi
done

log_command "kubectl rollout restart ds -n ingress-nginx ingress-nginx-controller"

log_info "完成：证书与私钥已生成"
log_info "  cert: ${TLS_CERT}"
log_info "  key : ${TLS_KEY}"
log_info "  san : ${SAN_CONF}"
