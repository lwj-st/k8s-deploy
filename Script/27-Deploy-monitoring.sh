#!/usr/bin/env bash
################################################################################
## Filename:    27-Deploy-monitoring.sh
## Description: 部署 monitoring（自动识别 nvidia/ascend；都无则默认 nvidia）
## Usage:
##   bash 27-Deploy-monitoring.sh
## Artifacts:
##   - monitor.chart.kube-prometheus-stack.v72.7.0
##   - monitor.manifest.dcgm-exporter
## Images:
##   - monitor.image.kube-state-metrics.v2.15.0
##   - monitor.image.grafana.v12.0.0
##   - monitor.image.ingress-nginx.kube-webhook-certgen.v1.5.3
##   - monitor.image.kiwigrid.k8s-sidecar.v1.30.0
##   - monitor.image.prometheus-config-reloader.v0.82.2
##   - monitor.image.prometheus-operator.v0.82.2
##   - monitor.image.alertmanager.v0.28.1
##   - monitor.image.node-exporter.v1.9.1
##   - monitor.image.prometheus.v3.4.0
##   - monitor.image.dcgm-exporter.v4.5.2-4.8.1-distroless
## Notes:
##   - kube-prometheus-stack chart、dcgm-exporter manifest、镜像 tar 来自 manifests/artifacts.yaml
##   - 本脚本会读取仓库 config 下的 npu-exporter、grafana-ingress、service-monitor 配置
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

NS="monitoring"
RELEASE="kube-prom-stack"
CHART=""
DCGM_YAML=""
ASCEND_YAML=""
INGRESS_TMPL=""
SM_YAML=""
RUNTIME_ACCELERATOR=""

################################################################################
# Function: init_env
################################################################################
init_env() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  have helm || die "缺少 helm（请先执行 09-Install-tools.sh）"
  have kubectl || die "缺少 kubectl"
  have ctr || die "缺少 ctr（请先安装 containerd）"
  have openssl || die "缺少 openssl"

  CHART="$(artifact_get_path_by_name "monitor.chart.kube-prometheus-stack.v72.7.0")"
  DCGM_YAML="$(artifact_get_path_by_name "monitor.manifest.dcgm-exporter")"

  ASCEND_YAML="${K8S_DEPLOY_ROOT}/config/npu-exporter.yaml"
  INGRESS_TMPL="${K8S_DEPLOY_ROOT}/config/grafana-ingress.yaml"
  SM_YAML="${K8S_DEPLOY_ROOT}/config/service-monitor.yaml"

  [ -f "${CHART}" ] || die "缺少制品: ${CHART}"
  [ -f "${DCGM_YAML}" ] || die "缺少制品: ${DCGM_YAML}"
  [ -f "${ASCEND_YAML}" ] || log_warn "未找到 ${ASCEND_YAML}，Ascend 分支将不可用"
  [ -f "${INGRESS_TMPL}" ] || die "缺少配置: ${INGRESS_TMPL}"
  [ -f "${SM_YAML}" ] || die "缺少配置: ${SM_YAML}"

  detect_accelerator
}

################################################################################
# Function: detect_accelerator
# Description: 按命令识别加速卡类型；都没有时默认 nvidia
################################################################################
detect_accelerator() {
  if have nvidia-smi; then
    RUNTIME_ACCELERATOR="nvidia"
  elif have npu-smi; then
    RUNTIME_ACCELERATOR="ascend"
  else
    RUNTIME_ACCELERATOR="nvidia"
  fi
  log_info "检测到加速卡类型: ${RUNTIME_ACCELERATOR}"
}

################################################################################
# Function: import_monitor_images
################################################################################
import_monitor_images() {
  log_info "导入 monitoring 所需镜像..."
  import_image_artifacts \
    "monitor.image.kube-state-metrics.v2.15.0" \
    "monitor.image.grafana.v12.0.0" \
    "monitor.image.ingress-nginx.kube-webhook-certgen.v1.5.3" \
    "monitor.image.kiwigrid.k8s-sidecar.v1.30.0" \
    "monitor.image.prometheus-config-reloader.v0.82.2" \
    "monitor.image.prometheus-operator.v0.82.2" \
    "monitor.image.alertmanager.v0.28.1" \
    "monitor.image.node-exporter.v1.9.1" \
    "monitor.image.prometheus.v3.4.0" \
    "monitor.image.dcgm-exporter.v4.5.2-4.8.1-distroless"
}

################################################################################
# Function: ensure_namespace
################################################################################
ensure_namespace() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
}

################################################################################
# Function: helm_install_or_upgrade
################################################################################
helm_install_or_upgrade() {
  log_info "Helm 安装/升级 ${RELEASE}（命名空间 ${NS}）..."
  log_command "helm -n \"${NS}\" upgrade --install \"${RELEASE}\" \"${CHART}\" --create-namespace"
}

################################################################################
# Function: create_self_signed_tls_if_needed
# Description:
#   - 若 monitoring/sensecore-tls 已存在则跳过
#   - 未存在则按 GRAFANA_TLS_DOMAIN 生成自签名证书并创建 secret
################################################################################
create_self_signed_tls_if_needed() {
  local host="${GRAFANA_INGRESS_HOST:-grafana.sensecorex.com}"
  local tls_domain
  tls_domain="$(get_tls_domain_from_host "${host}")"
  local cert_days="${GRAFANA_TLS_DAYS:-365}"
  local need_recreate="yes"

  if kubectl -n "${NS}" get secret sensecore-tls >/dev/null 2>&1; then
    local crt current_san
    crt="$(kubectl -n "${NS}" get secret sensecore-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || true)"
    current_san="$(printf '%s' "${crt}" | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
    if printf '%s\n' "${current_san}" | rg -q "DNS:${tls_domain}(,|$)" \
      && printf '%s\n' "${current_san}" | rg -q "DNS:\*\.${tls_domain}(,|$)"; then
      need_recreate="no"
    fi
  fi

  if [ "${need_recreate}" = "no" ]; then
    log_info "检测到 TLS secret 已存在且域名匹配（${tls_domain}），跳过生成"
    return 0
  fi

  if kubectl -n "${NS}" get secret sensecore-tls >/dev/null 2>&1; then
    log_warn "TLS 域名与当前配置不一致，删除旧 secret 后重建（${NS}/sensecore-tls）"
    log_command "kubectl -n \"${NS}\" delete secret sensecore-tls"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d -t monitor-tls.XXXXXX)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  cat > "${tmp_dir}/san.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
C = CN
O = ${tls_domain}
CN = ${tls_domain}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${tls_domain}
DNS.2 = *.${tls_domain}
EOF

  log_info "生成自签名 TLS 证书（domain=${tls_domain}, days=${cert_days}）..."
  log_command "openssl genrsa -out \"${tmp_dir}/${tls_domain}.key.pem\" 2048"
  log_command "openssl req -x509 -new -nodes -key \"${tmp_dir}/${tls_domain}.key.pem\" -sha256 -days \"${cert_days}\" -out \"${tmp_dir}/${tls_domain}.cert.pem\" -config \"${tmp_dir}/san.conf\""

  log_info "创建 TLS secret: ${NS}/sensecore-tls"
  log_command "kubectl -n \"${NS}\" create secret tls sensecore-tls --cert=\"${tmp_dir}/${tls_domain}.cert.pem\" --key=\"${tmp_dir}/${tls_domain}.key.pem\""

  trap - EXIT
  rm -rf "${tmp_dir}"
}

################################################################################
# Function: get_tls_domain_from_host
# Description: 默认取 host 最后两段作为主域名（如 a.b.c.com -> c.com）
################################################################################
get_tls_domain_from_host() {
  local host="$1"
  local d1 d2
  d1="$(awk -F'.' '{print $(NF-1)}' <<< "${host}")"
  d2="$(awk -F'.' '{print $NF}' <<< "${host}")"
  if [ -n "${d1}" ] && [ -n "${d2}" ]; then
    printf '%s.%s\n' "${d1}" "${d2}"
  else
    # 非标准 host（不含点）时兜底直接返回原值
    printf '%s\n' "${host}"
  fi
}

################################################################################
# Function: apply_monitoring_addons
################################################################################
apply_monitoring_addons() {
  local host="${GRAFANA_INGRESS_HOST:-grafana.sensecorex.com}"

  case "${RUNTIME_ACCELERATOR}" in
    nvidia)
      log_info "检测到 nvidia，部署 dcgm-exporter"
      log_command "kubectl apply -n \"${NS}\" -f \"${DCGM_YAML}\""
      log_command "kubectl apply -f \"${SM_YAML}\""
      ;;
    ascend)
      [ -f "${ASCEND_YAML}" ] || die "Ascend 分支需要配置文件: ${ASCEND_YAML}"
      log_info "检测到 ascend，部署 Ascend 相关 YAML: ${ASCEND_YAML}"
      log_command "kubectl apply -n \"${NS}\" -f \"${ASCEND_YAML}\""
      ;;
    *)
      die "未知加速卡类型: ${RUNTIME_ACCELERATOR}"
      ;;
  esac

  local tmp_ing
  tmp_ing="$(mktemp -t grafana-ingress.XXXXXX.yaml)"
  trap 'rm -f "${tmp_ing}"' EXIT

  sed "s/__GRAFANA_HOST__/${host}/g" "${INGRESS_TMPL}" > "${tmp_ing}"
  log_info "应用 Grafana Ingress（host=${host}）..."
  log_command "kubectl apply -f \"${tmp_ing}\""

  trap - EXIT
  rm -f "${tmp_ing}"
}

################################################################################
# Function: show_grafana_password
################################################################################
show_grafana_password() {
  local pwd
  pwd="$(kubectl -n "${NS}" get secret "${RELEASE}-grafana" -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d || true)"
  if [ -n "${pwd}" ]; then
    log_info "Grafana admin 密码: ${pwd}"
  else
    log_warn "暂未获取到 Grafana admin 密码，可稍后执行：kubectl -n ${NS} get secrets ${RELEASE}-grafana -o jsonpath=\"{.data.admin-password}\" | base64 -d ; echo"
  fi
}

################################################################################
# Function: main
################################################################################
main() {
  init_env
  import_monitor_images
  ensure_namespace
  helm_install_or_upgrade
  create_self_signed_tls_if_needed
  apply_monitoring_addons
  show_grafana_password
  log_info "monitoring 部署完成（accelerator=${RUNTIME_ACCELERATOR}）"
}

main "$@"
