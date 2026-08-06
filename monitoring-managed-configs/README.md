# Monitoring Managed Configs

This directory stores project-managed Grafana dashboards, Prometheus alert rules, and Grafana-managed alerting defaults.

Apply dashboards:

```bash
kubectl apply -f monitoring-managed-configs/grafana-dashboards
```

Apply legacy PrometheusRule alert rules:

```bash
APPLY_RULES=1 APPLY_GRAFANA_ALERTING=0 bash monitoring-managed-configs/deploy.sh
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
APPLY_RULES=0 APPLY_GRAFANA_ALERTING=0 bash monitoring-managed-configs/deploy.sh
```

Only apply legacy PrometheusRule alert rules:

```bash
APPLY_DASHBOARDS=0 APPLY_RULES=1 APPLY_GRAFANA_ALERTING=0 bash monitoring-managed-configs/deploy.sh
```

Only apply Grafana alerting:

```bash
APPLY_DASHBOARDS=0 APPLY_RULES=0 bash monitoring-managed-configs/deploy.sh
```

Environment variables:

- `MONITORING_NAMESPACE`: monitoring namespace, default `monitoring`.
- `DRY_RUN`: set to `1` to use `kubectl apply --dry-run=client`.
- `APPLY_DASHBOARDS`: set to `0` to skip Grafana dashboard ConfigMaps.
- `APPLY_RULES`: set to `1` to apply legacy PrometheusRule resources, default `0`.
- `APPLY_GRAFANA_ALERTING`: set to `0` to skip Grafana-managed alert rules.
- `GRAFANA_ALERTING_CONFIG`: Grafana alerting config path, default `grafana-alerting/modelstudio-alerting.yaml`.
- `GRAFANA_SECRET`: Grafana admin Secret name, default `kube-prom-stack-grafana`.
- `GRAFANA_USER` / `GRAFANA_PASSWORD`: optional Grafana credentials. If unset, the script reads `GRAFANA_SECRET`.
- `GRAFANA_RESOURCE`: kubectl port-forward target, default `deploy/kube-prom-stack-grafana`.
- `GRAFANA_LOCAL_PORT`: local port used for temporary port-forward, default `13000`.

Requirements:

- `monitoring` namespace exists.
- `kube-prometheus-stack` is installed.
- Grafana dashboard sidecar watches ConfigMaps with `grafana_dashboard: "1"`.
- Prometheus Operator CRDs are installed before applying `PrometheusRule`.

Notes:

- Dashboard ConfigMaps are imported by Grafana sidecar.
- Grafana-managed alert rules are the default alerting path. Users can pause, edit, or delete these rules in Grafana after initialization.
- Legacy PrometheusRule resources are kept for Kubernetes-native alerting, but are skipped by default to avoid duplicate alerts.
- Grafana-managed alert rules are imported through Grafana HTTP API with provenance disabled, so users can edit them in the Grafana UI after initialization.
- API 5xx, API P99, model replica, and inference queue Grafana alert rules are created as paused placeholders until the exact business metric names and SLA thresholds are confirmed.
- `grafana-alerting/contact-points.example.yaml` is an email notification example. Do not commit real SMTP passwords or private webhook tokens.
