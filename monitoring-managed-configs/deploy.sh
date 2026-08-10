#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
APPLY_DASHBOARDS="${APPLY_DASHBOARDS:-1}"
APPLY_DATASOURCES="${APPLY_DATASOURCES:-1}"
APPLY_RULES="${APPLY_RULES:-0}"
APPLY_GRAFANA_ALERTING="${APPLY_GRAFANA_ALERTING:-1}"
APPLY_GRAFANA_ALERTING_MODE="${APPLY_GRAFANA_ALERTING_MODE:-local}"
APPLY_GRAFANA_SMTP="${APPLY_GRAFANA_SMTP:-1}"
DRY_RUN="${DRY_RUN:-0}"

DASHBOARDS_DIR="${SCRIPT_DIR}/grafana-dashboards"
DATASOURCES_DIR="${SCRIPT_DIR}/grafana-datasources"
RULES_DIR="${SCRIPT_DIR}/prometheus-rules"
GRAFANA_ALERTING_CONFIG="${GRAFANA_ALERTING_CONFIG:-${SCRIPT_DIR}/grafana-alerting/modelstudio-alerting.yaml}"
GRAFANA_ALERTING_APPLIER="${SCRIPT_DIR}/scripts/apply_grafana_alerting.py"
GRAFANA_ALERTING_JOB_NAME="${GRAFANA_ALERTING_JOB_NAME:-grafana-alerting-apply}"
GRAFANA_ALERTING_CONFIGMAP="${GRAFANA_ALERTING_CONFIGMAP:-grafana-alerting-applier-config}"
GRAFANA_ALERTING_JOB_IMAGE="${GRAFANA_ALERTING_JOB_IMAGE:-grafana-alerting-applier:latest}"
GRAFANA_URL="${GRAFANA_URL:-http://kube-prom-stack-grafana.${MONITORING_NAMESPACE}.svc:80}"
GRAFANA_SMTP_APPLIER="${SCRIPT_DIR}/scripts/apply_grafana_smtp.sh"

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

kubectl_apply() {
  local path="$1"
  local extra_args=()

  if [ "${DRY_RUN}" = "1" ]; then
    extra_args+=(--dry-run=client)
  fi

  kubectl apply "${extra_args[@]}" --recursive -f "${path}"
}

has_yaml_files() {
  local dir="$1"
  find "${dir}" -type f \( -name '*.yaml' -o -name '*.yml' \) | grep -q .
}

check_namespace() {
  kubectl get namespace "${MONITORING_NAMESPACE}" >/dev/null 2>&1 \
    || die "Namespace not found: ${MONITORING_NAMESPACE}"
}

check_prometheus_rule_crd() {
  kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1
}

apply_dashboards() {
  if [ "${APPLY_DASHBOARDS}" != "1" ]; then
    log_info "Skip Grafana dashboards because APPLY_DASHBOARDS=${APPLY_DASHBOARDS}"
    return 0
  fi

  [ -d "${DASHBOARDS_DIR}" ] || die "Dashboard directory not found: ${DASHBOARDS_DIR}"
  has_yaml_files "${DASHBOARDS_DIR}" || {
    log_warn "No dashboard yaml files found: ${DASHBOARDS_DIR}"
    return 0
  }

  log_info "Apply Grafana dashboards: ${DASHBOARDS_DIR}"
  kubectl_apply "${DASHBOARDS_DIR}"
}

apply_datasources() {
  if [ "${APPLY_DATASOURCES}" != "1" ]; then
    log_info "Skip Grafana datasources because APPLY_DATASOURCES=${APPLY_DATASOURCES}"
    return 0
  fi

  [ -d "${DATASOURCES_DIR}" ] || {
    log_warn "Datasource directory not found: ${DATASOURCES_DIR}"
    return 0
  }
  has_yaml_files "${DATASOURCES_DIR}" || {
    log_warn "No datasource yaml files found: ${DATASOURCES_DIR}"
    return 0
  }

  log_info "Apply Grafana datasources: ${DATASOURCES_DIR}"
  kubectl_apply "${DATASOURCES_DIR}"
}

apply_rules() {
  if [ "${APPLY_RULES}" != "1" ]; then
    log_info "Skip Prometheus rules because APPLY_RULES=${APPLY_RULES}"
    return 0
  fi

  [ -d "${RULES_DIR}" ] || die "Prometheus rule directory not found: ${RULES_DIR}"
  has_yaml_files "${RULES_DIR}" || {
    log_warn "No PrometheusRule yaml files found: ${RULES_DIR}"
    return 0
  }

  if ! check_prometheus_rule_crd; then
    die "PrometheusRule CRD not found. Install kube-prometheus-stack / Prometheus Operator first."
  fi

  log_info "Apply Prometheus alert rules: ${RULES_DIR}"
  kubectl_apply "${RULES_DIR}"
}

apply_grafana_alerting() {
  if [ "${APPLY_GRAFANA_ALERTING}" != "1" ]; then
    log_info "Skip Grafana alerting because APPLY_GRAFANA_ALERTING=${APPLY_GRAFANA_ALERTING}"
    return 0
  fi

  [ -f "${GRAFANA_ALERTING_CONFIG}" ] || {
    log_warn "Grafana alerting config not found: ${GRAFANA_ALERTING_CONFIG}"
    return 0
  }
  [ -f "${GRAFANA_ALERTING_APPLIER}" ] || die "Grafana alerting applier not found: ${GRAFANA_ALERTING_APPLIER}"

  case "${APPLY_GRAFANA_ALERTING_MODE}" in
    local)
      apply_grafana_alerting_local
      ;;
    job)
      apply_grafana_alerting_job
      ;;
    *)
      die "APPLY_GRAFANA_ALERTING_MODE must be local or job, current=${APPLY_GRAFANA_ALERTING_MODE}"
      ;;
  esac
}

apply_grafana_alerting_local() {
  have python3 || die "python3 is required to apply Grafana alerting"

  log_info "Apply Grafana alerting: ${GRAFANA_ALERTING_CONFIG}"
  if [ "${DRY_RUN}" = "1" ]; then
    python3 "${GRAFANA_ALERTING_APPLIER}" --config "${GRAFANA_ALERTING_CONFIG}" --namespace "${MONITORING_NAMESPACE}" --dry-run
  else
    python3 "${GRAFANA_ALERTING_APPLIER}" --config "${GRAFANA_ALERTING_CONFIG}" --namespace "${MONITORING_NAMESPACE}"
  fi
}

apply_grafana_alerting_job() {
  local applier_key config_key grafana_secret

  applier_key="$(basename "${GRAFANA_ALERTING_APPLIER}")"
  config_key="$(basename "${GRAFANA_ALERTING_CONFIG}")"
  grafana_secret="${GRAFANA_SECRET:-kube-prom-stack-grafana}"

  log_info "Apply Grafana alerting by Kubernetes Job: ${GRAFANA_ALERTING_JOB_NAME}"
  log_info "Grafana URL: ${GRAFANA_URL}"
  log_info "Job image: ${GRAFANA_ALERTING_JOB_IMAGE}"

  if [ "${DRY_RUN}" = "1" ]; then
    log_info "Dry run: would create/update ConfigMap ${MONITORING_NAMESPACE}/${GRAFANA_ALERTING_CONFIGMAP}"
    log_info "Dry run: would recreate Job ${MONITORING_NAMESPACE}/${GRAFANA_ALERTING_JOB_NAME}"
    return 0
  fi

  kubectl -n "${MONITORING_NAMESPACE}" create configmap "${GRAFANA_ALERTING_CONFIGMAP}" \
    --from-file="${applier_key}=${GRAFANA_ALERTING_APPLIER}" \
    --from-file="${config_key}=${GRAFANA_ALERTING_CONFIG}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${MONITORING_NAMESPACE}" delete job "${GRAFANA_ALERTING_JOB_NAME}" --ignore-not-found --wait=true

  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${GRAFANA_ALERTING_JOB_NAME}
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app.kubernetes.io/name: grafana-alerting-applier
    app.kubernetes.io/managed-by: monitoring-managed-configs
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: grafana-alerting-applier
    spec:
      restartPolicy: Never
      containers:
        - name: apply
          image: ${GRAFANA_ALERTING_JOB_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: GRAFANA_URL
              value: ${GRAFANA_URL}
            - name: GRAFANA_USER
              valueFrom:
                secretKeyRef:
                  name: ${grafana_secret}
                  key: admin-user
            - name: GRAFANA_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${grafana_secret}
                  key: admin-password
          volumeMounts:
            - name: config
              mountPath: /configs
              readOnly: true
          command:
            - python3
            - /configs/${applier_key}
          args:
            - --config
            - /configs/${config_key}
            - --grafana-url
            - ${GRAFANA_URL}
      volumes:
        - name: config
          configMap:
            name: ${GRAFANA_ALERTING_CONFIGMAP}
EOF

  kubectl -n "${MONITORING_NAMESPACE}" wait --for=condition=complete "job/${GRAFANA_ALERTING_JOB_NAME}" --timeout=180s
  kubectl -n "${MONITORING_NAMESPACE}" logs "job/${GRAFANA_ALERTING_JOB_NAME}"
}

apply_grafana_smtp() {
  if [ "${APPLY_GRAFANA_SMTP}" != "1" ]; then
    log_info "Skip Grafana SMTP because APPLY_GRAFANA_SMTP=${APPLY_GRAFANA_SMTP}"
    return 0
  fi

  if [ -z "${GRAFANA_SMTP_HOST:-}" ]; then
    log_info "Skip Grafana SMTP because GRAFANA_SMTP_HOST is not set"
    return 0
  fi

  [ -f "${GRAFANA_SMTP_APPLIER}" ] || die "Grafana SMTP applier not found: ${GRAFANA_SMTP_APPLIER}"
  [ -n "${GRAFANA_SMTP_FROM_ADDRESS:-}" ] || die "GRAFANA_SMTP_FROM_ADDRESS is required when GRAFANA_SMTP_HOST is set"

  log_info "Apply Grafana SMTP config"
  bash "${GRAFANA_SMTP_APPLIER}"
}

main() {
  have kubectl || die "kubectl is required"

  log_info "Monitoring namespace: ${MONITORING_NAMESPACE}"
  log_info "Dry run: ${DRY_RUN}"

  check_namespace
  apply_datasources
  apply_dashboards
  apply_grafana_smtp
  apply_rules
  apply_grafana_alerting

  log_info "Monitoring managed configs applied."
}

main "$@"
