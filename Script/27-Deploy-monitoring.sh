#!/usr/bin/env bash
################################################################################
## Filename:    27-Deploy-monitoring.sh
## Description: 部署 monitoring（自动识别 vxpu/nvidia/ascend/iluvatar/dcu）
## Usage:
##   bash 27-Deploy-monitoring.sh
## Artifacts:
##   - monitor.chart.kube-prometheus-stack.v72.7.0
##   - monitor.manifest.dcgm-exporter
##   - monitor.image.dcxm-exporter.v1.0.0.1
##   - dcu.image.exporter.v2.0.0.240718
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
##   - dcu.image.exporter.v2.0.0.240718
##   - iluvatar.image.ix-exporter.latest-x86_64
## Env:
##   - MONITOR_ACCELERATOR: 可选，强制 nvidia|ascend|iluvatar|vxpu|dcu（覆盖自动检测）
##   - GRAFANA_INGRESS_HOST: Grafana Ingress 域名，默认 grafana.sensecorex.com
##   - GRAFANA_DEFAULT_LANGUAGE: Grafana 默认语言，默认 zh-Hans（中文简体）
##   - GRAFANA_DEFAULT_THEME: Grafana 默认主题，默认 light（浅色）
##   - GRAFANA_DEFAULT_TIMEZONE: Grafana 默认时区，默认 Asia/Shanghai
##   - GRAFANA_DEFAULT_WEEK_START: Grafana 默认每周起始日，默认 monday（周一）
##   - GRAFANA_ADMIN_PASSWORD: Grafana admin 默认密码，默认 123456
##   - GRAFANA_PROMETHEUS_DATASOURCE_UID: Grafana Prometheus 数据源 uid，默认 prometheus
## Notes:
##   - kube-prometheus-stack chart、dcgm-exporter manifest、镜像 tar 来自 manifests/artifacts.yaml
##   - Ascend / Iluvatar / 昆仑芯 / DCU exporter 清单来自仓库 config
##   - DCU Exporter 上游未发布可直接下载的镜像，需按 README 提前准备离线镜像 tar
##   - 昆仑芯节点上 nvidia-smi 可能是 XPU 兼容命令，检测优先认 xpu-smi / /dev/xpu*
##   - 未识别到加速卡时不会默认部署；可用 MONITOR_ACCELERATOR 强制指定
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
DCU_YAML=""
DCU_DASHBOARD_JSON=""
INGRESS_TMPL=""
SM_YAML=""
HELM_VALUES=""
NVIDIA_DASHBOARD_JSON=""
ASCEND_DASHBOARD_JSON=""
ILUVATAR_DASHBOARD_JSON=""
RUNTIME_ACCELERATOR=""

################################################################################
# Function: init_env
################################################################################
init_env() {
  init_framework
  require_root
  export KUBECONFIG=/etc/kubernetes/admin.conf

  have helm || die "缺少 helm（请先执行 09-Install-tools.sh）"

  CHART="$(artifact_get_path_by_name "monitor.chart.kube-prometheus-stack.v72.7.0")"
  [ -n "${CHART}" ] || die "monitor.chart.kube-prometheus-stack.v72.7.0 的 path 为空，请检查 manifests/artifacts.yaml"
  [ -f "${CHART}" ] || die "缺少制品: ${CHART}"

  have kubectl || die "缺少 kubectl"
  have ctr || die "缺少 ctr（请先安装 containerd）"
  have openssl || die "缺少 openssl"

  ASCEND_YAML="${K8S_DEPLOY_ROOT}/config/npu-exporter.yaml"
  ILUVATAR_YAML="${K8S_DEPLOY_ROOT}/config/ix-exporter.yaml"
  VXPU_YAML="${K8S_DEPLOY_ROOT}/config/dcxm-exporter.yaml"
  VXPU_DASHBOARD_JSON="${K8S_DEPLOY_ROOT}/config/dcxm-exporter-dashboard.json"
  DCU_YAML="${K8S_DEPLOY_ROOT}/config/dcu-exporter.yaml"
  DCU_DASHBOARD_JSON="${K8S_DEPLOY_ROOT}/config/dcu-exporter-dashboard.json"
  INGRESS_TMPL="${K8S_DEPLOY_ROOT}/config/grafana-ingress.yaml"
  SM_YAML="${K8S_DEPLOY_ROOT}/config/service-monitor.yaml"
  HELM_VALUES="${K8S_DEPLOY_ROOT}/config/kube-prometheus-stack-values.yaml"
  NVIDIA_DASHBOARD_JSON="${K8S_DEPLOY_ROOT}/config/dcgm-exporter-dashboard.json"
  ASCEND_DASHBOARD_JSON="${K8S_DEPLOY_ROOT}/config/npu-exporter-dashboard.json"
  ILUVATAR_DASHBOARD_JSON="${K8S_DEPLOY_ROOT}/config/ix-exporter-dashboard.json"

  [ -f "${ASCEND_YAML}" ] || log_warn "未找到 ${ASCEND_YAML}，Ascend 分支将不可用"
  [ -f "${ILUVATAR_YAML}" ] || log_warn "未找到 ${ILUVATAR_YAML}，Iluvatar 分支将不可用"
  [ -f "${VXPU_YAML}" ] || log_warn "未找到 ${VXPU_YAML}，昆仑芯分支将不可用"
  [ -f "${VXPU_DASHBOARD_JSON}" ] || log_warn "未找到 ${VXPU_DASHBOARD_JSON}，昆仑芯 Grafana 仪表盘将不可用"
  [ -f "${NVIDIA_DASHBOARD_JSON}" ] || log_warn "未找到 ${NVIDIA_DASHBOARD_JSON}，nvidia Grafana 面板将跳过"
  [ -f "${ASCEND_DASHBOARD_JSON}" ] || log_warn "未找到 ${ASCEND_DASHBOARD_JSON}，ascend Grafana 面板将跳过"
  [ -f "${ILUVATAR_DASHBOARD_JSON}" ] || log_warn "未找到 ${ILUVATAR_DASHBOARD_JSON}，iluvatar Grafana 面板将跳过"
  [ -f "${DCU_YAML}" ] || log_warn "未找到 ${DCU_YAML}，DCU 分支将不可用"
  [ -f "${DCU_DASHBOARD_JSON}" ] || log_warn "未找到 ${DCU_DASHBOARD_JSON}，DCU Grafana 仪表盘将不可用"
  [ -f "${INGRESS_TMPL}" ] || die "缺少配置: ${INGRESS_TMPL}"
  [ -f "${SM_YAML}" ] || die "缺少配置: ${SM_YAML}"
  [ -f "${HELM_VALUES}" ] || die "缺少配置: ${HELM_VALUES}"

  detect_accelerator

  if [ "${RUNTIME_ACCELERATOR}" = "nvidia" ]; then
    DCGM_YAML="$(artifact_get_path_by_name "monitor.manifest.dcgm-exporter")"
    [ -f "${DCGM_YAML}" ] || die "缺少制品: ${DCGM_YAML}"
  fi
}

################################################################################
# Function: detect_accelerator
# Description: 按命令识别加速卡类型；都没有时提示用户显式指定
################################################################################
detect_accelerator() {
  if [ -n "${MONITOR_ACCELERATOR:-}" ]; then
    case "${MONITOR_ACCELERATOR}" in
      nvidia|ascend|iluvatar|vxpu|dcu)
        RUNTIME_ACCELERATOR="${MONITOR_ACCELERATOR}"
        log_info "使用环境变量强制加速卡类型: ${RUNTIME_ACCELERATOR}"
        return 0
        ;;
      *)
        die "MONITOR_ACCELERATOR 仅支持 nvidia|ascend|iluvatar|vxpu|dcu，当前=${MONITOR_ACCELERATOR}"
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
  elif have hy-smi || have rocm-smi || [ -e /dev/kfd ] || [ -e /dev/mkfd ]; then
    RUNTIME_ACCELERATOR="dcu"
  elif have npu-smi; then
    RUNTIME_ACCELERATOR="ascend"
  else
    die "未自动识别到加速卡类型；如需继续，请显式指定：MONITOR_ACCELERATOR=vxpu|nvidia|ascend|iluvatar|dcu bash 27-Deploy-monitoring.sh"
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
    dcu)
      local dcu_image_tar
      dcu_image_tar="$(artifact_get_path_by_name "dcu.image.exporter.v2.0.0.240718")"
      [ -f "${dcu_image_tar}" ] || die "缺少 DCU Exporter 离线镜像: ${dcu_image_tar}；请按 README 的「DCU Exporter 离线镜像」说明提前构建并放置"
      import_image_artifact "dcu.image.exporter.v2.0.0.240718"
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
helm_install_or_upgrade() (
  local grafana_language="${GRAFANA_DEFAULT_LANGUAGE:-zh-Hans}"
  local grafana_theme="${GRAFANA_DEFAULT_THEME:-light}"
  local grafana_timezone="${GRAFANA_DEFAULT_TIMEZONE:-Asia/Shanghai}"
  local grafana_week_start="${GRAFANA_DEFAULT_WEEK_START:-monday}"
  local grafana_admin_password="${GRAFANA_ADMIN_PASSWORD:-123456}"
  local password_file=""
  local -a helm_cmd

  trap 'if [ -n "${password_file}" ]; then rm -f "${password_file}"; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  [ -n "${CHART}" ] || die "CHART 为空，无法执行 Helm 安装/升级"
  [ -f "${CHART}" ] || die "缺少制品: ${CHART}"

  log_info "Helm 安装/升级 ${RELEASE}（命名空间 ${NS}，values=${HELM_VALUES}，Grafana 默认语言=${grafana_language}，默认主题=${grafana_theme}，默认时区=${grafana_timezone}，默认每周起始日=${grafana_week_start}）..."
  password_file="$(mktemp -t grafana-admin-password.XXXXXX)"
  chmod 600 "${password_file}"
  printf '%s' "${grafana_admin_password}" > "${password_file}"

  helm_cmd=(
    helm -n "${NS}" upgrade --install "${RELEASE}" "${CHART}"
    --create-namespace
    -f "${HELM_VALUES}"
    --set-file "grafana.adminPassword=${password_file}"
    --set-string "grafana.env.GF_USERS_DEFAULT_LANGUAGE=${grafana_language}"
    --set-string "grafana.env.GF_USERS_DEFAULT_THEME=${grafana_theme}"
    --set-string "grafana.env.GF_DATE_FORMATS_DEFAULT_TIMEZONE=${grafana_timezone}"
    --set-string "grafana.env.GF_DATE_FORMATS_DEFAULT_WEEK_START=${grafana_week_start}"
    --set-string "grafana.defaultDashboardsTimezone=${grafana_timezone}"
  )

  log_info "执行 Helm 安装/升级命令（Grafana admin 密码=${grafana_admin_password}）"
  if "${helm_cmd[@]}"; then
    log_info "Helm 安装/升级成功"
  else
    die "Helm 安装/升级失败"
  fi
)

################################################################################
# Function: pick_free_local_port
################################################################################
pick_free_local_port() {
  local port
  for port in $(seq 39000 39100); do
    if ! (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
      printf '%s\n' "${port}"
      return 0
    fi
  done
  return 1
}

################################################################################
# Function: configure_grafana_org_preferences
# Description: 服务端默认时区不会覆盖已有组织偏好；这里同步设置默认组织偏好
################################################################################
configure_grafana_org_preferences() (
  local grafana_theme="${GRAFANA_DEFAULT_THEME:-light}"
  local grafana_timezone="${GRAFANA_DEFAULT_TIMEZONE:-Asia/Shanghai}"
  local grafana_week_start="${GRAFANA_DEFAULT_WEEK_START:-monday}"
  local pf_pid=""
  local pf_log=""

  trap '
    if [ -n "${pf_pid}" ] && kill -0 "${pf_pid}" >/dev/null 2>&1; then
      kill "${pf_pid}" >/dev/null 2>&1 || true
      wait "${pf_pid}" >/dev/null 2>&1 || true
    fi
    if [ -n "${pf_log}" ]; then
      rm -f "${pf_log}"
    fi
  ' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! have curl; then
    log_warn "缺少 curl，跳过 Grafana 组织默认偏好设置（timezone=${grafana_timezone}）"
    return 0
  fi

  local pwd
  pwd="$(kubectl -n "${NS}" get secret "${RELEASE}-grafana" -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d || true)"
  if [ -z "${pwd}" ]; then
    log_warn "暂未获取到 Grafana admin 密码，跳过组织默认偏好设置"
    return 0
  fi

  log_command "kubectl -n \"${NS}\" rollout status \"deployment/${RELEASE}-grafana\" --timeout=180s"

  local local_port
  local_port="$(pick_free_local_port)" || die "未找到可用本地端口，无法设置 Grafana 组织默认偏好"
  pf_log="$(mktemp -t grafana-port-forward.XXXXXX.log)"

  kubectl -n "${NS}" port-forward --address 127.0.0.1 "svc/${RELEASE}-grafana" "${local_port}:80" >"${pf_log}" 2>&1 &
  pf_pid=$!

  local ready="no"
  local _
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${local_port}/api/health" >/dev/null 2>&1; then
      ready="yes"
      break
    fi
    if ! kill -0 "${pf_pid}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if [ "${ready}" != "yes" ]; then
    log_warn "Grafana port-forward 未就绪，跳过组织默认偏好设置"
    return 0
  fi

  local payload
  payload="$(printf '{"timezone":"%s","weekStart":"%s","theme":"%s"}' "${grafana_timezone}" "${grafana_week_start}" "${grafana_theme}")"

  if curl -fsS -u "admin:${pwd}" \
    -H "Content-Type: application/json" \
    -X PATCH \
    --data "${payload}" \
    "http://127.0.0.1:${local_port}/api/org/preferences" >/dev/null; then
    log_info "已设置 Grafana 组织默认偏好（timezone=${grafana_timezone}, weekStart=${grafana_week_start}, theme=${grafana_theme}）"
  else
    log_warn "设置 Grafana 组织默认偏好失败，请登录 Grafana 后检查 Administration -> General -> Default preferences"
  fi
)

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

  if [ ! -f "${dashboard_file}" ]; then
    log_warn "未找到 Grafana 面板 JSON，跳过: ${dashboard_file}"
    return 0
  fi

  local data_key tmp_json
  data_key="$(basename "${dashboard_file}")"
  tmp_json="$(mktemp -t "${configmap_name}.XXXXXX.json")"

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
      apply_grafana_dashboard_json "${NVIDIA_DASHBOARD_JSON}" "grafana-dashboard-dcgm-exporter"
      ;;
    vxpu)
      [ -f "${VXPU_YAML}" ] || die "昆仑芯分支需要配置文件: ${VXPU_YAML}"
      log_info "检测到昆仑芯，部署 dcxm-exporter: ${VXPU_YAML}"
      log_command "kubectl -n \"${NS}\" delete daemonset,svc,servicemonitor dcgm-exporter --ignore-not-found=true"
      log_command "kubectl apply -n \"${NS}\" -f \"${VXPU_YAML}\""
      apply_grafana_dashboard_json "${VXPU_DASHBOARD_JSON}" "dcxm-exporter-dashboard"
      ;;
    dcu)
      [ -f "${DCU_YAML}" ] || die "DCU 分支需要配置文件: ${DCU_YAML}"
      log_info "检测到 DCU，部署 dcu-exporter: ${DCU_YAML}"
      log_command "kubectl apply -f \"${DCU_YAML}\""
      apply_grafana_dashboard_json "${DCU_DASHBOARD_JSON}" "dcu-exporter-dashboard"
      ;;
    ascend)
      [ -f "${ASCEND_YAML}" ] || die "Ascend 分支需要配置文件: ${ASCEND_YAML}"
      log_info "检测到 ascend，部署 Ascend 相关 YAML: ${ASCEND_YAML}"
      log_command "kubectl apply -n \"${NS}\" -f \"${ASCEND_YAML}\""
      apply_grafana_dashboard_json "${ASCEND_DASHBOARD_JSON}" "grafana-dashboard-npu-exporter"
      ;;
    iluvatar)
      [ -f "${ILUVATAR_YAML}" ] || die "Iluvatar 分支需要配置文件: ${ILUVATAR_YAML}"
      log_info "检测到 iluvatar，部署 ix-exporter: ${ILUVATAR_YAML}"
      log_command "kubectl apply -f \"${ILUVATAR_YAML}\""
      apply_grafana_dashboard_json "${ILUVATAR_DASHBOARD_JSON}" "grafana-dashboard-ix-exporter"
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
  configure_grafana_org_preferences
  create_self_signed_tls_if_needed
  apply_monitoring_addons
  show_grafana_password
  log_info "monitoring 部署完成（accelerator=${RUNTIME_ACCELERATOR}）"
}

main "$@"
