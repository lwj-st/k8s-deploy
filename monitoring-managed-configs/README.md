# Monitoring Managed Configs

This directory stores project-managed Grafana dashboards and Prometheus alert rules.

Apply dashboards:

```bash
kubectl apply -f monitoring-managed-configs/grafana-dashboards
```

Apply alert rules:

```bash
kubectl apply -f monitoring-managed-configs/prometheus-rules
```

Or use the deployment script:

```bash
bash monitoring-managed-configs/deploy.sh
```

Dry-run:

```bash
DRY_RUN=1 bash monitoring-managed-configs/deploy.sh
```

Only apply dashboards:

```bash
APPLY_RULES=0 bash monitoring-managed-configs/deploy.sh
```

Only apply alert rules:

```bash
APPLY_DASHBOARDS=0 bash monitoring-managed-configs/deploy.sh
```

Environment variables:

- `MONITORING_NAMESPACE`: monitoring namespace, default `monitoring`.
- `DRY_RUN`: set to `1` to use `kubectl apply --dry-run=client`.
- `APPLY_DASHBOARDS`: set to `0` to skip Grafana dashboard ConfigMaps.
- `APPLY_RULES`: set to `0` to skip PrometheusRule resources.

Requirements:

- `monitoring` namespace exists.
- `kube-prometheus-stack` is installed.
- Grafana dashboard sidecar watches ConfigMaps with `grafana_dashboard: "1"`.
- Prometheus Operator CRDs are installed before applying `PrometheusRule`.

Notes:

- Dashboard ConfigMaps are imported by Grafana sidecar.
- Alert rules are evaluated by Prometheus and routed to Alertmanager.
- API 5xx, API P99, model replica, and inference queue alerts should be added after the exact business metric names are confirmed.
