# Monitoring Managed Configs

This directory stores project-managed Grafana dashboards, datasources, Prometheus alert rules, and Grafana-managed alerting defaults.

Grafana dashboards are grouped by scope:

```bash
monitoring-managed-configs/grafana-dashboards/platform
monitoring-managed-configs/grafana-dashboards/modelengine
```

- `platform`: platform/basic dashboards. Put Kubernetes / platform / namespace / pod status dashboards here. These dashboards use the default kube-prometheus datasource and do not depend on the ModelEngine Prometheus datasource.
- `modelengine`: ModelEngine runtime/worker dashboards. Put dashboards that use `gpustack-prometheus` or `gpustack:*` metrics here.

Grafana datasources are stored under:

```bash
monitoring-managed-configs/grafana-datasources
```

Apply ModelEngine datasource and dashboards only:

```bash
bash monitoring-managed-configs/scripts/apply_modelengine_grafana.sh apply
```

Apply dashboards:

```bash
kubectl apply --recursive -f monitoring-managed-configs/grafana-dashboards
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

Apply Grafana alerting by Kubernetes Job, without local Python:

```bash
APPLY_GRAFANA_ALERTING_MODE=job \
GRAFANA_ALERTING_JOB_IMAGE=your-registry/grafana-alerting-applier:python3-pyyaml \
bash monitoring-managed-configs/deploy.sh
```

Build the Job image:

```bash
docker build -t your-registry/grafana-alerting-applier:python3-pyyaml \
  monitoring-managed-configs/images/grafana-alerting-applier
```

Apply Grafana SMTP for email notifications:

```bash
GRAFANA_SMTP_HOST=smtp.example.com:465 \
GRAFANA_SMTP_USER=grafana@example.com \
GRAFANA_SMTP_PASSWORD='change-me' \
GRAFANA_SMTP_FROM_ADDRESS=grafana@example.com \
bash monitoring-managed-configs/deploy.sh
```

The script stores SMTP values in a Kubernetes Secret and injects them into the Grafana Deployment as `GF_SMTP_*` environment variables.

Environment variables:

- `MONITORING_NAMESPACE`: monitoring namespace, default `monitoring`.
- `DRY_RUN`: set to `1` to use `kubectl apply --dry-run=client`.
- `APPLY_DASHBOARDS`: set to `0` to skip Grafana dashboard ConfigMaps.
- `APPLY_DATASOURCES`: set to `0` to skip Grafana datasource ConfigMaps.
- `APPLY_RULES`: set to `1` to apply legacy PrometheusRule resources, default `0`.
- `APPLY_GRAFANA_ALERTING`: set to `0` to skip Grafana-managed alert rules.
- `APPLY_GRAFANA_ALERTING_MODE`: `local` or `job`, default `local`. Use `job` when the deploy host has no Python.
- `GRAFANA_ALERTING_JOB_IMAGE`: image used by Grafana alerting Job, default `grafana-alerting-applier:latest`.
- `GRAFANA_ALERTING_JOB_NAME`: Grafana alerting Job name, default `grafana-alerting-apply`.
- `GRAFANA_ALERTING_CONFIGMAP`: ConfigMap used by Grafana alerting Job, default `grafana-alerting-applier-config`.
- `GRAFANA_URL`: Grafana URL used by Job mode, default `http://kube-prom-stack-grafana.${MONITORING_NAMESPACE}.svc:80`.
- `APPLY_GRAFANA_SMTP`: set to `0` to skip Grafana SMTP configuration.
- `GRAFANA_ALERTING_CONFIG`: Grafana alerting config path, default `grafana-alerting/modelstudio-alerting.yaml`.
- `GRAFANA_SECRET`: Grafana admin Secret name, default `kube-prom-stack-grafana`.
- `GRAFANA_USER` / `GRAFANA_PASSWORD`: optional Grafana credentials. If unset, the script reads `GRAFANA_SECRET`.
- `GRAFANA_RESOURCE`: kubectl port-forward target, default `deploy/kube-prom-stack-grafana`.
- `GRAFANA_LOCAL_PORT`: local port used for temporary port-forward, default `13000`.
- `GRAFANA_DEPLOYMENT`: Grafana Deployment name for SMTP env injection, default `kube-prom-stack-grafana`.
- `GRAFANA_SMTP_SECRET`: Secret name used to store SMTP config, default `grafana-smtp-env`.
- `GRAFANA_SMTP_HOST`: SMTP host with port. If unset, SMTP configuration is skipped.
- `GRAFANA_SMTP_USER` / `GRAFANA_SMTP_PASSWORD`: optional SMTP credentials.
- `GRAFANA_SMTP_FROM_ADDRESS`: required when `GRAFANA_SMTP_HOST` is set.
- `GRAFANA_SMTP_FROM_NAME`: SMTP sender display name, default `Grafana`.
- `GRAFANA_SMTP_SKIP_VERIFY`: optional TLS skip verify flag, default `false`.
- `GRAFANA_SMTP_STARTTLS_POLICY`: optional STARTTLS policy, for example `OpportunisticStartTLS`.

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
- In `local` mode, Grafana alerting requires `python3`, `PyYAML`, and local `kubectl port-forward`.
- In `job` mode, Grafana alerting does not require local Python. The script stores the Python applier and alerting YAML in a ConfigMap, recreates a Kubernetes Job, and the Job calls Grafana through the in-cluster Service.
- API 5xx, API P99, model replica, and inference queue Grafana alert rules are created as paused placeholders until the exact business metric names and SLA thresholds are confirmed.
- `grafana-alerting/contact-points.example.yaml` is an email notification example. Do not commit real SMTP passwords or private webhook tokens.
- Do not commit real SMTP passwords. Pass them through environment variables or create the Secret outside Git.
