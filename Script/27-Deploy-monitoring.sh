#!/usr/bin/env bash
################################################################################
## Filename:    27-Deploy-monitoring.sh
## Description: 部署 monitoring（自动识别 vxpu/nvidia/ascend/iluvatar；都无则默认 nvidia）
## Usage:
##   bash 27-Deploy-monitoring.sh
## Artifacts:
##   - monitor.chart.kube-prometheus-stack.v72.7.0
##   - monitor.manifest.dcgm-exporter
##   - monitor.image.dcxm-exporter.v1.0.0.1
##   - iluvatar.image.ix-exporter.latest-x86_64
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
##   - monitor.image.dcxm-exporter.v1.0.0.1
##   - iluvatar.image.ix-exporter.latest-x86_64
## Env:
##   - MONITOR_ACCELERATOR: 可选，强制 nvidia|ascend|iluvatar|vxpu（覆盖自动检测）
##   - GRAFANA_INGRESS_HOST: Grafana Ingress 域名，默认 grafana.sensecorex.com
##   - GRAFANA_PROMETHEUS_DATASOURCE_UID: Grafana Prometheus 数据源 uid，默认 prometheus
## Notes:
##   - kube-prometheus-stack chart、dcgm-exporter manifest、镜像 tar 来自 manifests/artifacts.yaml
##   - Ascend / Iluvatar / 昆仑芯 exporter 清单来自仓库 config
##   - 昆仑芯节点上 nvidia-smi 可能是 XPU 兼容命令，检测优先认 xpu-smi / /dev/xpu*
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

NS="monitoring"
RELEASE="kube-prom-stack"
CHART=""
DCGM_YAML=""
ASCEND_YAML=""
ILUVATAR_YAML=""
VXPU_YAML=""
VXPU_DASHBOARD_JSON=""
INGRESS_TMPL=""
SM_YAML=""
HELM_VALUES=""
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
  ILUVATAR_YAML="${K8S_DEPLOY_ROOT}/config/ix-exporter.yaml"
  VXPU_YAML="${K8S_DEPLOY_ROOT}/config/dcxm-exporter.yaml"
  VXPU_DASHBOARD_JSON="${K8S_DEPLOY_ROOT}/config/dcxm-exporter-dashboard.json"
  INGRESS_TMPL="${K8S_DEPLOY_ROOT}/config/grafana-ingress.yaml"
  SM_YAML="${K8S_DEPLOY_ROOT}/config/service-monitor.yaml"
  HELM_VALUES="${K8S_DEPLOY_ROOT}/config/kube-prometheus-stack-values.yaml"

  [ -f "${CHART}" ] || die "缺少制品: ${CHART}"
  [ -f "${DCGM_YAML}" ] || die "缺少制品: ${DCGM_YAML}"
  [ -f "${ASCEND_YAML}" ] || log_warn "未找到 ${ASCEND_YAML}，Ascend 分支将不可用"
  [ -f "${ILUVATAR_YAML}" ] || log_warn "未找到 ${ILUVATAR_YAML}，Iluvatar 分支将不可用"
  [ -f "${VXPU_YAML}" ] || log_warn "未找到 ${VXPU_YAML}，昆仑芯分支将不可用"
  [ -f "${VXPU_DASHBOARD_JSON}" ] || log_warn "未找到 ${VXPU_DASHBOARD_JSON}，昆仑芯 Grafana 仪表盘将不可用"
  [ -f "${INGRESS_TMPL}" ] || die "缺少配置: ${INGRESS_TMPL}"
  [ -f "${SM_YAML}" ] || die "缺少配置: ${SM_YAML}"
  [ -f "${HELM_VALUES}" ] || die "缺少配置: ${HELM_VALUES}"

  detect_accelerator
}

################################################################################
# Function: detect_accelerator
# Description: 按命令识别加速卡类型；都没有时默认 nvidia
################################################################################
detect_accelerator() {
  if [ -n "${MONITOR_ACCELERATOR:-}" ]; then
    case "${MONITOR_ACCELERATOR}" in
      nvidia|ascend|iluvatar|vxpu)
        RUNTIME_ACCELERATOR="${MONITOR_ACCELERATOR}"
        log_info "使用环境变量强制加速卡类型: ${RUNTIME_ACCELERATOR}"
        return 0
        ;;
      *)
        die "MONITOR_ACCELERATOR 仅支持 nvidia|ascend|iluvatar|vxpu，当前=${MONITOR_ACCELERATOR}"
        ;;
    esac
  fi

  # 昆仑芯节点上常带 nvidia-smi 兼容命令，必须先认 XPU，否则会误部署 DCGM。
  if have xpu-smi || have xpumcli || [ -e /dev/xpuctl ] || [ -e /dev/xpuctrl ] || [ -e /dev/xpu0 ]; then
    RUNTIME_ACCELERATOR="vxpu"
  elif have nvidia-smi; then
    RUNTIME_ACCELERATOR="nvidia"
  elif have ixsmi || [ -d /sys/bus/pci/drivers/iluvatar ]; then
    RUNTIME_ACCELERATOR="iluvatar"
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
    "monitor.image.prometheus.v3.4.0"

  case "${RUNTIME_ACCELERATOR}" in
    nvidia)
      import_image_artifact "monitor.image.dcgm-exporter.v4.5.2-4.8.1-distroless"
      ;;
    vxpu)
      import_image_artifact "monitor.image.dcxm-exporter.v1.0.0.1"
      ;;
    iluvatar)
      import_image_artifact "iluvatar.image.ix-exporter.latest-x86_64"
      ;;
  esac
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
  log_info "Helm 安装/升级 ${RELEASE}（命名空间 ${NS}，values=${HELM_VALUES}）..."
  log_command "helm -n \"${NS}\" upgrade --install \"${RELEASE}\" \"${CHART}\" --create-namespace -f \"${HELM_VALUES}\""
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
# Function: apply_grafana_dashboard_json
# Description: 将裸 Grafana dashboard JSON 包装为 sidecar 可自动导入的 ConfigMap
################################################################################
apply_grafana_dashboard_json() {
  local dashboard_file="$1"
  local configmap_name="$2"
  local datasource_uid="${GRAFANA_PROMETHEUS_DATASOURCE_UID:-prometheus}"
  local data_key tmp_json

  [ -f "${dashboard_file}" ] || die "缺少 Grafana 仪表盘: ${dashboard_file}"

  data_key="$(basename "${dashboard_file}")"
  tmp_json="$(mktemp -t "${configmap_name}.XXXXXX")"

  sed "s/\\\${DS_PROMETHEUS}/${datasource_uid}/g" "${dashboard_file}" > "${tmp_json}"

  log_info "导入 Grafana 面板: ${dashboard_file}（datasource uid=${datasource_uid}）"
  log_command "kubectl -n \"${NS}\" create configmap \"${configmap_name}\" --from-file=\"${data_key}=${tmp_json}\" --dry-run=client -o yaml | kubectl apply -f -"
  log_command "kubectl -n \"${NS}\" label configmap \"${configmap_name}\" grafana_dashboard=1 app.kubernetes.io/managed-by=k8s-deploy --overwrite"

  rm -f "${tmp_json}"
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
    vxpu)
      [ -f "${VXPU_YAML}" ] || die "昆仑芯分支需要配置文件: ${VXPU_YAML}"
      log_info "检测到昆仑芯，部署 dcxm-exporter: ${VXPU_YAML}"
      log_command "kubectl -n \"${NS}\" delete daemonset,svc,servicemonitor dcgm-exporter --ignore-not-found=true"
      log_command "kubectl apply -n \"${NS}\" -f \"${VXPU_YAML}\""
      apply_grafana_dashboard_json "${VXPU_DASHBOARD_JSON}" "dcxm-exporter-dashboard"
      ;;
    ascend)
      [ -f "${ASCEND_YAML}" ] || die "Ascend 分支需要配置文件: ${ASCEND_YAML}"
      log_info "检测到 ascend，部署 Ascend 相关 YAML: ${ASCEND_YAML}"
      log_command "kubectl apply -n \"${NS}\" -f \"${ASCEND_YAML}\""
      ;;
    iluvatar)
      [ -f "${ILUVATAR_YAML}" ] || die "Iluvatar 分支需要配置文件: ${ILUVATAR_YAML}"
      log_info "检测到 iluvatar，部署 ix-exporter: ${ILUVATAR_YAML}"
      log_command "kubectl apply -f \"${ILUVATAR_YAML}\""
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
