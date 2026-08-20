#!/usr/bin/env bash
set -euo pipefail

NS="${MONITORING_NAMESPACE:-monitoring}"
GRAFANA_DEPLOYMENT="${GRAFANA_DEPLOYMENT:-kube-prom-stack-grafana}"
SMTP_SECRET="${GRAFANA_SMTP_SECRET:-grafana-smtp-env}"
DRY_RUN="${DRY_RUN:-0}"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: GRAFANA_SMTP_HOST=smtp.example.com:465 GRAFANA_SMTP_FROM_ADDRESS=grafana@example.com bash scripts/apply_grafana_smtp.sh

Environment variables:
  MONITORING_NAMESPACE       Grafana namespace, default: monitoring
  GRAFANA_DEPLOYMENT         Grafana Deployment name, default: kube-prom-stack-grafana
  GRAFANA_SMTP_SECRET        Secret name, default: grafana-smtp-env
  GRAFANA_SMTP_HOST          SMTP host with port, for example smtp.example.com:465
  GRAFANA_SMTP_USER          Optional SMTP username
  GRAFANA_SMTP_PASSWORD      Optional SMTP password
  GRAFANA_SMTP_FROM_ADDRESS  Email sender address
  GRAFANA_SMTP_FROM_NAME     Email sender display name, default: Grafana
  GRAFANA_SMTP_SKIP_VERIFY   Optional, default: false
  GRAFANA_SMTP_STARTTLS_POLICY Optional, for example OpportunisticStartTLS
  DRY_RUN                    Set to 1 to print planned actions only
EOF
}

have() {
  command -v "$1" >/dev/null 2>&1
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  [ -n "${value}" ] || die "${name} is required when applying Grafana SMTP"
}

create_or_update_secret() {
  local args=(
    kubectl -n "${NS}" create secret generic "${SMTP_SECRET}"
    --from-literal=ENABLED=true
    --from-literal=HOST="${GRAFANA_SMTP_HOST}"
    --from-literal=FROM_ADDRESS="${GRAFANA_SMTP_FROM_ADDRESS}"
    --from-literal=FROM_NAME="${GRAFANA_SMTP_FROM_NAME:-Grafana}"
    --from-literal=SKIP_VERIFY="${GRAFANA_SMTP_SKIP_VERIFY:-false}"
  )

  if [ -n "${GRAFANA_SMTP_USER:-}" ]; then
    args+=(--from-literal=USER="${GRAFANA_SMTP_USER}")
  fi
  if [ -n "${GRAFANA_SMTP_PASSWORD:-}" ]; then
    args+=(--from-literal=PASSWORD="${GRAFANA_SMTP_PASSWORD}")
  fi
  if [ -n "${GRAFANA_SMTP_STARTTLS_POLICY:-}" ]; then
    args+=(--from-literal=STARTTLS_POLICY="${GRAFANA_SMTP_STARTTLS_POLICY}")
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    log "Dry run: would create/update Secret ${NS}/${SMTP_SECRET}"
    return 0
  fi

  "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
}

apply_to_deployment() {
  if [ "${DRY_RUN}" = "1" ]; then
    log "Dry run: would set GF_SMTP_* env vars on deployment/${GRAFANA_DEPLOYMENT} from secret/${SMTP_SECRET}"
    log "Dry run: would restart deployment/${GRAFANA_DEPLOYMENT} to reload SMTP secret values"
    return 0
  fi

  kubectl -n "${NS}" set env "deployment/${GRAFANA_DEPLOYMENT}" \
    --from="secret/${SMTP_SECRET}" \
    --prefix=GF_SMTP_

  kubectl -n "${NS}" rollout restart "deployment/${GRAFANA_DEPLOYMENT}"
  kubectl -n "${NS}" rollout status "deployment/${GRAFANA_DEPLOYMENT}" --timeout=180s
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      return 0
      ;;
  esac

  have kubectl || die "kubectl is required"
  require_env GRAFANA_SMTP_HOST
  require_env GRAFANA_SMTP_FROM_ADDRESS

  kubectl get namespace "${NS}" >/dev/null 2>&1 || die "Namespace not found: ${NS}"
  kubectl -n "${NS}" get deployment "${GRAFANA_DEPLOYMENT}" >/dev/null 2>&1 \
    || die "Grafana Deployment not found: ${NS}/${GRAFANA_DEPLOYMENT}"

  log "Apply Grafana SMTP config to ${NS}/${GRAFANA_DEPLOYMENT}"
  create_or_update_secret
  apply_to_deployment
  log "Grafana SMTP config applied. You can test the Email contact point in Grafana now."
}

main "$@"
