#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
APPLY_DASHBOARDS="${APPLY_DASHBOARDS:-1}"
APPLY_RULES="${APPLY_RULES:-1}"
DRY_RUN="${DRY_RUN:-0}"

DASHBOARDS_DIR="${SCRIPT_DIR}/grafana-dashboards"
RULES_DIR="${SCRIPT_DIR}/prometheus-rules"

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

  kubectl apply "${extra_args[@]}" -f "${path}"
}

has_yaml_files() {
  local dir="$1"
  find "${dir}" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | grep -q .
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

main() {
  have kubectl || die "kubectl is required"

  log_info "Monitoring namespace: ${MONITORING_NAMESPACE}"
  log_info "Dry run: ${DRY_RUN}"

  check_namespace
  apply_dashboards
  apply_rules

  log_info "Monitoring managed configs applied."
}

main "$@"
