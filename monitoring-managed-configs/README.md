# Monitoring Managed Configs

本目录用于管理项目侧维护的 Grafana 仪表盘、Grafana 数据源、PrometheusRule 告警规则，以及 Grafana Alerting 默认告警配置。

## 目录说明

Grafana 仪表盘按用途分组：

```bash
monitoring-managed-configs/grafana-dashboards/platform
monitoring-managed-configs/grafana-dashboards/modelengine
```

- `platform`：平台基础看板。放 Kubernetes / 平台 / 命名空间 / Pod 状态类看板，使用 kube-prometheus 默认 Prometheus 数据源，不依赖 ModelEngine 专用数据源。
- `modelengine`：ModelEngine 专用看板。放依赖 `gpustack-prometheus` 或 `gpustack:*` 指标的 Runtime / Worker 看板。

Grafana 数据源配置放在：

```bash
monitoring-managed-configs/grafana-datasources
```

## 常用命令

只应用 ModelEngine 数据源和仪表盘：

```bash
bash monitoring-managed-configs/scripts/apply_modelengine_grafana.sh apply
```

只应用仪表盘：

```bash
kubectl apply --recursive -f monitoring-managed-configs/grafana-dashboards
```

应用旧版 PrometheusRule 告警规则：

```bash
APPLY_RULES=1 APPLY_GRAFANA_ALERTING=0 bash monitoring-managed-configs/deploy.sh
```

一键部署：

```bash
bash monitoring-managed-configs/deploy.sh
```

Dry run：

```bash
DRY_RUN=1 bash monitoring-managed-configs/deploy.sh
```

只应用仪表盘和数据源，不应用告警：

```bash
APPLY_RULES=0 APPLY_GRAFANA_ALERTING=0 bash monitoring-managed-configs/deploy.sh
```

只应用旧版 PrometheusRule 告警规则：

```bash
APPLY_DASHBOARDS=0 APPLY_RULES=1 APPLY_GRAFANA_ALERTING=0 bash monitoring-managed-configs/deploy.sh
```

只应用 Grafana Alerting 告警：

```bash
APPLY_DASHBOARDS=0 APPLY_RULES=0 bash monitoring-managed-configs/deploy.sh
```

## 使用 Job 导入 Grafana 告警

部署机器没有 Python 环境时，可以使用 Kubernetes Job 在集群内导入 Grafana 告警：

```bash
APPLY_GRAFANA_ALERTING_MODE=job \
GRAFANA_ALERTING_JOB_IMAGE=your-registry/grafana-alerting-applier:python3-pyyaml \
bash monitoring-managed-configs/deploy.sh
```

构建 Job 镜像：

```bash
docker build -t your-registry/grafana-alerting-applier:python3-pyyaml \
  monitoring-managed-configs/images/grafana-alerting-applier
```

Job 镜像只包含运行环境，不包含告警配置。部署脚本会把 Python 脚本和告警 YAML 创建成 ConfigMap，再挂载到 Job 中执行。

## 配置邮件告警 SMTP

Grafana 页面只能配置收件人，SMTP 服务端配置需要在 Grafana 后端设置。可以通过一键脚本配置：

```bash
GRAFANA_SMTP_HOST=smtp.example.com:465 \
GRAFANA_SMTP_USER=grafana@example.com \
GRAFANA_SMTP_PASSWORD='change-me' \
GRAFANA_SMTP_FROM_ADDRESS=grafana@example.com \
bash monitoring-managed-configs/deploy.sh
```

脚本会把 SMTP 配置写入 Kubernetes Secret，并注入 Grafana Deployment 的 `GF_SMTP_*` 环境变量，然后重启 Grafana 使配置生效。

不要把真实 SMTP 密码提交到 Git。建议通过环境变量传入，或提前在集群中创建 Secret。

## 环境变量

- `MONITORING_NAMESPACE`：监控命名空间，默认 `monitoring`。
- `DRY_RUN`：设置为 `1` 时使用 `kubectl apply --dry-run=client`。
- `APPLY_DASHBOARDS`：设置为 `0` 时跳过 Grafana 仪表盘 ConfigMap。
- `APPLY_DATASOURCES`：设置为 `0` 时跳过 Grafana 数据源 ConfigMap。
- `APPLY_RULES`：设置为 `1` 时应用旧版 PrometheusRule，默认 `0`。
- `APPLY_GRAFANA_ALERTING`：设置为 `0` 时跳过 Grafana Alerting 告警规则。
- `APPLY_GRAFANA_ALERTING_MODE`：`local` 或 `job`，默认 `local`。部署机器没有 Python 时使用 `job`。
- `GRAFANA_ALERTING_JOB_IMAGE`：Grafana Alerting Job 使用的镜像，默认 `grafana-alerting-applier:latest`。
- `GRAFANA_ALERTING_JOB_NAME`：Grafana Alerting Job 名称，默认 `grafana-alerting-apply`。
- `GRAFANA_ALERTING_CONFIGMAP`：Grafana Alerting Job 使用的 ConfigMap 名称，默认 `grafana-alerting-applier-config`。
- `GRAFANA_URL`：Job 模式访问 Grafana 的地址，默认 `http://kube-prom-stack-grafana.${MONITORING_NAMESPACE}.svc:80`。
- `APPLY_GRAFANA_SMTP`：设置为 `0` 时跳过 Grafana SMTP 配置。
- `GRAFANA_ALERTING_CONFIG`：Grafana Alerting 配置文件路径，默认 `grafana-alerting/modelstudio-alerting.yaml`。
- `GRAFANA_SECRET`：Grafana admin Secret 名称，默认 `kube-prom-stack-grafana`。
- `GRAFANA_USER` / `GRAFANA_PASSWORD`：可选 Grafana 登录凭据。不设置时脚本读取 `GRAFANA_SECRET`。
- `GRAFANA_RESOURCE`：本地模式 port-forward 目标，默认 `deploy/kube-prom-stack-grafana`。
- `GRAFANA_LOCAL_PORT`：本地模式临时 port-forward 端口，默认 `13000`。
- `GRAFANA_DEPLOYMENT`：用于注入 SMTP 环境变量的 Grafana Deployment 名称，默认 `kube-prom-stack-grafana`。
- `GRAFANA_SMTP_SECRET`：保存 SMTP 配置的 Secret 名称，默认 `grafana-smtp-env`。
- `GRAFANA_SMTP_HOST`：SMTP 地址和端口。不设置时跳过 SMTP 配置。
- `GRAFANA_SMTP_USER` / `GRAFANA_SMTP_PASSWORD`：可选 SMTP 用户名和密码。
- `GRAFANA_SMTP_FROM_ADDRESS`：发件人邮箱。设置 `GRAFANA_SMTP_HOST` 时必填。
- `GRAFANA_SMTP_FROM_NAME`：发件人展示名称，默认 `Grafana`。
- `GRAFANA_SMTP_SKIP_VERIFY`：是否跳过 TLS 校验，默认 `false`。
- `GRAFANA_SMTP_STARTTLS_POLICY`：可选 STARTTLS 策略，例如 `OpportunisticStartTLS`。

## 前置要求

- `monitoring` 命名空间已存在，或通过环境变量指定正确命名空间。
- 已安装 `kube-prometheus-stack`。
- Grafana dashboard sidecar 会监听带有 `grafana_dashboard: "1"` 标签的 ConfigMap。
- Grafana datasource sidecar 会监听带有 `grafana_datasource: "1"` 标签的 ConfigMap。
- 如需应用 PrometheusRule，集群内必须已安装 Prometheus Operator CRD。
- Job 模式需要集群能拉取 `GRAFANA_ALERTING_JOB_IMAGE` 指定的镜像。

## 注意事项

- 仪表盘 ConfigMap 会由 Grafana sidecar 自动导入。
- Grafana Alerting 是当前默认告警方式。初始化后，用户可以在 Grafana 页面暂停、编辑或删除告警规则。
- 旧版 PrometheusRule 仍保留，用于 Kubernetes 原生告警场景；默认不启用，避免重复告警。
- Grafana Alerting 通过 Grafana HTTP API 导入，并关闭 provenance，因此页面上可以继续编辑。
- `local` 模式需要部署机器有 `python3`、`PyYAML`，并能执行 `kubectl port-forward`。
- `job` 模式不需要部署机器有 Python。脚本会创建 ConfigMap、重建 Job，并由 Job 访问集群内 Grafana Service。
- API 5xx、API P99、模型实例数、推理队列等规则依赖具体业务指标；未确认指标前不要随意开启占位规则。
- `grafana-alerting/contact-points.example.yaml` 只是邮件通知示例，不要提交真实 SMTP 密码或私有 webhook token。
