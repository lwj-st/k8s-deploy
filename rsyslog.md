# Kubernetes + rsyslog 集中日志审计 SOP

## 1. 目标

本文档用于在 Kubernetes 集群部署完成后，后置启用集中日志审计。

链路：

```text
Kubernetes 节点 -> 本机 rsyslog 采集 -> TCP 或 TCP/TLS 主动推送 -> 日志服务器集中存储
```

原则：

* Kubernetes 集群部署阶段不决定是否启用 rsyslog。
* 集群部署完成后，如现场需要日志审计，再按本 SOP 配置。
* 每个 Kubernetes 节点都要配置本机日志采集和外发。
* 每个 control-plane 节点额外开启 kube-apiserver audit。
* 节点本地日志短保留，日志服务器集中长保留。

## 2. 需要采集的日志

| 类别 | Ubuntu / Debian | Rocky / CentOS / openEuler | 说明 |
| --- | --- | --- | --- |
| 系统日志 | `/var/log/syslog` | `/var/log/messages` | 系统服务、内核、守护进程日志 |
| 认证日志 | `/var/log/auth.log` | `/var/log/secure` | SSH、sudo、su、登录失败 |
| journald | systemd journal | systemd journal | kubelet、containerd、systemd 服务 |
| Kubernetes audit | `/var/log/kubernetes/audit.log` | `/var/log/kubernetes/audit.log` | Kubernetes API 审计，仅 control-plane 产生 |
| 容器日志 | `/var/log/containers/*.log` | `/var/log/containers/*.log` | Pod 标准输出日志 |

说明：

* 所有节点都需要采集系统日志、认证日志、journald、容器日志。
* control-plane 节点额外采集 Kubernetes audit 日志。
* worker 节点通常没有 kube-apiserver audit 日志，但仍要配置本机日志采集和外发。
* 容器日志建议优先采集 `/var/log/containers/*.log`，不要和 journald 中的同一份容器 stdout 重复采集。

## 3. 部署前确认

| 信息 | 示例 | 说明 |
| --- | --- | --- |
| 是否已有日志服务器 | 有 / 无 | 有则只配置 K8s 节点外发；无则先部署一台日志服务器 |
| 日志服务器 IP | `10.10.10.15` | K8s 节点会把日志推送到该地址 |
| 日志服务器端口 | `6514` / `514` | TLS 常用 `6514`，普通 TCP 常用 `514` |
| 传输方式 | `TCP/TLS` / `TCP` | 如果不能改日志服务器，只能按对方已有能力配置 |
| control-plane 节点 | `kubectl get node` | 每个 control-plane 都要开启 Kubernetes audit |

如果已有日志服务器，需要向管理员确认：

```text
日志服务器 IP 是多少
接收端口是多少
是否支持 TCP/TLS
是否需要 CA 证书或客户端证书
日志服务器上如何查询接收到的日志
```

重要限制：

* 如果已有日志服务器只支持普通 TCP，客户端不能单方面加密。
* 如果已有日志服务器要求证书认证，需要由日志服务器管理员提供 CA、客户端证书或接入规范。
* 如果没有日志服务器，可以按本 SOP 部署一台 rsyslog 日志服务器。

## 4. SOP：手工部署步骤

### 4.1 没有日志服务器时，部署日志服务器

已有日志服务器且不能登录配置时，跳过本节。

安装组件：

```bash
# Ubuntu / Debian
apt update
apt install -y rsyslog rsyslog-gnutls logrotate openssl

# Rocky / CentOS / AlmaLinux / openEuler
dnf install -y rsyslog rsyslog-gnutls logrotate openssl
```

创建目录：

```bash
mkdir -p /etc/rsyslog/ssl /data/logs
chmod 755 /etc/rsyslog/ssl /data/logs
```

创建服务端 TLS 证书：

```bash
cd /etc/rsyslog/ssl
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=rsyslog-ca"
openssl genrsa -out server.key 4096
openssl req -new -key server.key -out server.csr -subj "/CN=$(hostname -f 2>/dev/null || hostname)"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650 -sha256
chmod 600 *.key
chmod 644 *.crt
```

写入 `/etc/rsyslog.d/10-k8s-deploy-remote-server.conf`：

```bash
cat > /etc/rsyslog.d/10-k8s-deploy-remote-server.conf <<'EOF'
module(load="imtcp")
module(load="gtls")

global(
  DefaultNetstreamDriver="gtls"
  DefaultNetstreamDriverCAFile="/etc/rsyslog/ssl/ca.crt"
  DefaultNetstreamDriverCertFile="/etc/rsyslog/ssl/server.crt"
  DefaultNetstreamDriverKeyFile="/etc/rsyslog/ssl/server.key"
)

template(name="K8sDeployRemoteLogs" type="string"
  string="/data/logs/%HOSTNAME%/%syslogfacility-text%/%PROGRAMNAME%.log")

ruleset(name="k8sDeployRemoteIn") {
  *.* ?K8sDeployRemoteLogs
  stop
}

input(
  type="imtcp"
  port="6514"
  StreamDriver.Name="gtls"
  StreamDriver.Mode="1"
  StreamDriver.AuthMode="anon"
  Ruleset="k8sDeployRemoteIn"
)
EOF
```

配置日志服务器长留存，写入 `/etc/logrotate.d/remote-rsyslog`：

```bash
cat > /etc/logrotate.d/remote-rsyslog <<'EOF'
/data/logs/*/*/*.log {
    daily
    rotate 180
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
    endscript
}
EOF
```

启动并验证：

```bash
rsyslogd -N1
systemctl enable --now rsyslog
systemctl restart rsyslog
ss -lntp | grep 6514
```

如果日志服务器开启了防火墙，放行 K8s 节点访问 TCP `6514`。如果没有启用防火墙，可以跳过。

### 4.2 每个 control-plane 开启 Kubernetes audit

worker 节点不执行本节。

创建 audit 目录和策略文件：

```bash
mkdir -p /etc/kubernetes /var/log/kubernetes
chmod 755 /var/log/kubernetes

cat > /etc/kubernetes/audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets"]

- level: Request
  resources:
  - group: "rbac.authorization.k8s.io"

- level: Metadata
EOF
```

备份 kube-apiserver static pod：

```bash
cp -a /etc/kubernetes/manifests/kube-apiserver.yaml \
  /etc/kubernetes/manifests/kube-apiserver.yaml.bak.$(date +%Y%m%d_%H%M%S)
```

编辑 `/etc/kubernetes/manifests/kube-apiserver.yaml`。

在 `command:` 列表中，找到 `- kube-apiserver`，在后面增加：

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-log-maxage=180
    - --audit-log-maxbackup=30
    - --audit-log-maxsize=100
```

在 `volumeMounts:` 下增加：

```yaml
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes
      name: audit-log
```

在 `volumes:` 下增加：

```yaml
  - hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
    name: audit-policy
  - hostPath:
      path: /var/log/kubernetes
      type: DirectoryOrCreate
    name: audit-log
```

保存后 kubelet 会自动重启 kube-apiserver。等待 1 到 2 分钟后检查：

```bash
kubectl get pod -n kube-system | grep kube-apiserver
tail -n 20 /var/log/kubernetes/audit.log
```

如果 kube-apiserver 异常，优先检查 YAML 缩进、挂载名称、`audit-policy.yaml` 和 `/var/log/kubernetes` 是否存在。

### 4.3 每个 K8s 节点配置本地日志能力

control-plane 和 worker 都执行。

开启 journald 持久化并限制占用：

```bash
mkdir -p /var/log/journal /etc/systemd/journald.conf.d

cat > /etc/systemd/journald.conf.d/10-k8s-deploy-size-limit.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=1G
RuntimeMaxUse=512M
MaxRetentionSec=7day
EOF

systemctl restart systemd-journald
```

配置本地日志短保留。

Ubuntu / Debian 写入 `/etc/logrotate.d/local-k8s-logs`：

```bash
cat > /etc/logrotate.d/local-k8s-logs <<'EOF'
/var/log/syslog
/var/log/auth.log
/var/log/kubernetes/audit.log
/var/log/containers/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
```

Rocky / CentOS / AlmaLinux / openEuler 写入 `/etc/logrotate.d/local-k8s-logs`：

```bash
cat > /etc/logrotate.d/local-k8s-logs <<'EOF'
/var/log/messages
/var/log/secure
/var/log/kubernetes/audit.log
/var/log/containers/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
```

### 4.4 每个 K8s 节点配置日志外发

control-plane 和 worker 都执行。

安装组件：

```bash
# Ubuntu / Debian
apt update
apt install -y rsyslog rsyslog-gnutls logrotate

# Rocky / CentOS / AlmaLinux / openEuler
dnf install -y rsyslog rsyslog-gnutls logrotate
```

设置日志服务器变量：

```bash
LOG_SERVER_IP="<日志服务器IP>"
LOG_SERVER_PORT="6514"
```

如果已有日志服务器只支持普通 TCP，把端口改成实际端口，例如：

```bash
LOG_SERVER_PORT="514"
```

根据发行版设置本机日志路径：

```bash
# Ubuntu / Debian
SYS_LOG="/var/log/syslog"
AUTH_LOG="/var/log/auth.log"

# Rocky / CentOS / AlmaLinux / openEuler
SYS_LOG="/var/log/messages"
AUTH_LOG="/var/log/secure"
```

如果日志服务器支持 TCP/TLS，写入 `/etc/rsyslog.d/20-k8s-deploy-forward.conf`：

```bash
cat > /etc/rsyslog.d/20-k8s-deploy-forward.conf <<EOF
module(load="imfile" PollingInterval="10")
module(load="gtls")

global(
  MaxMessageSize="64k"
  DefaultNetstreamDriver="gtls"
)

ruleset(name="k8sDeployRemoteForward") {
  action(
    type="omfwd"
    target="${LOG_SERVER_IP}"
    port="${LOG_SERVER_PORT}"
    protocol="tcp"
    StreamDriver="gtls"
    StreamDriverMode="1"
    StreamDriverAuthMode="anon"
    queue.type="LinkedList"
    queue.filename="k8s_remote_forward"
    queue.maxdiskspace="10g"
    queue.saveonshutdown="on"
    action.resumeRetryCount="-1"
  )
}

input(type="imfile" File="${SYS_LOG}" Tag="system" Facility="local0" Severity="info" Ruleset="k8sDeployRemoteForward")
input(type="imfile" File="${AUTH_LOG}" Tag="auth" Facility="authpriv" Severity="info" Ruleset="k8sDeployRemoteForward")
input(type="imfile" File="/var/log/kubernetes/audit.log" Tag="k8s-audit" Facility="local1" Severity="info" Ruleset="k8sDeployRemoteForward")
input(type="imfile" File="/var/log/containers/*.log" Tag="container" Facility="local2" Severity="info" Ruleset="k8sDeployRemoteForward")

*.* call k8sDeployRemoteForward
EOF
```

如果已有日志服务器只支持普通 TCP，不支持 TLS，写入 `/etc/rsyslog.d/20-k8s-deploy-forward.conf`：

```bash
cat > /etc/rsyslog.d/20-k8s-deploy-forward.conf <<EOF
module(load="imfile" PollingInterval="10")

global(
  MaxMessageSize="64k"
)

ruleset(name="k8sDeployRemoteForward") {
  action(
    type="omfwd"
    target="${LOG_SERVER_IP}"
    port="${LOG_SERVER_PORT}"
    protocol="tcp"
    queue.type="LinkedList"
    queue.filename="k8s_remote_forward"
    queue.maxdiskspace="10g"
    queue.saveonshutdown="on"
    action.resumeRetryCount="-1"
  )
}

input(type="imfile" File="${SYS_LOG}" Tag="system" Facility="local0" Severity="info" Ruleset="k8sDeployRemoteForward")
input(type="imfile" File="${AUTH_LOG}" Tag="auth" Facility="authpriv" Severity="info" Ruleset="k8sDeployRemoteForward")
input(type="imfile" File="/var/log/kubernetes/audit.log" Tag="k8s-audit" Facility="local1" Severity="info" Ruleset="k8sDeployRemoteForward")
input(type="imfile" File="/var/log/containers/*.log" Tag="container" Facility="local2" Severity="info" Ruleset="k8sDeployRemoteForward")

*.* call k8sDeployRemoteForward
EOF
```

检查配置并重启：

```bash
rsyslogd -N1
systemctl enable --now rsyslog
systemctl restart rsyslog
logger "manual check from $(hostname)"
```

### 4.5 关闭某个节点外发

如果某个节点暂时不需要外发：

```bash
mv /etc/rsyslog.d/20-k8s-deploy-forward.conf \
  /etc/rsyslog.d/20-k8s-deploy-forward.conf.disabled.$(date +%Y%m%d_%H%M%S)
rsyslogd -N1
systemctl restart rsyslog
```

### 4.6 验收

每个 K8s 节点检查：

```bash
systemctl status rsyslog --no-pager
rsyslogd -N1
logger "manual check from $(hostname)"
```

每个 control-plane 检查 audit：

```bash
tail -n 20 /var/log/kubernetes/audit.log
kubectl get pod -A
```

日志服务器检查是否收到日志：

```bash
find /data/logs -type f | sort
grep -R "manual check" /data/logs
```

最终确认：

* 每个节点都有系统日志、认证日志、容器日志上送。
* 每个 control-plane 都有 Kubernetes audit 日志上送。
* 节点本地日志只短保留，避免占满磁盘。
* 日志服务器集中留存满足等保要求。

## 5. 脚本辅助流程（可选，非 SOP）

本节只是把上面的手工步骤映射到 `30-Deploy-rsyslog.sh`，用于熟悉脚本的人快速执行；现场 SOP 以第 4 节手工步骤为准。

已有日志服务器，只配置 K8s 节点：

```bash
cd /data/k8s-deploy/Script
export RSYSLOG_LOG_SERVER=<日志服务器IP>
export RSYSLOG_LOG_SERVER_PORT=6514
sudo bash 30-Deploy-rsyslog.sh client
```

已有日志服务器只支持普通 TCP：

```bash
cd /data/k8s-deploy/Script
export RSYSLOG_LOG_SERVER=<日志服务器IP>
export RSYSLOG_LOG_SERVER_PORT=514
export RSYSLOG_TRANSPORT=plain
sudo bash 30-Deploy-rsyslog.sh client
```

没有日志服务器，先在日志服务器执行：

```bash
cd /data/k8s-deploy/Script
export RSYSLOG_LOG_SERVER=<本机IP>
sudo bash 30-Deploy-rsyslog.sh server
```

每个 control-plane 开启 Kubernetes audit：

```bash
cd /data/k8s-deploy/Script
sudo bash 30-Deploy-rsyslog.sh enable-audit
```

关闭某个节点外发：

```bash
cd /data/k8s-deploy/Script
sudo bash 30-Deploy-rsyslog.sh disable-forward
```

## 6. 等保二级检查点

| 项目 | 建议 |
| --- | --- |
| 日志集中存储 | 必须 |
| 日志服务器留存 | 不少于 180 天，按当地测评要求确认 |
| 节点本地留存 | 短期即可，建议 7 到 14 天或按磁盘容量调整 |
| 时间同步 | 所有节点和日志服务器必须开启 |
| 传输安全 | 优先 TCP/TLS；已有服务器只支持普通 TCP 时需由网络隔离兜底 |
| 访问控制 | 日志服务器仅授权安全管理员和审计管理员访问 |
| 防篡改 | 建议对象存储归档、WORM、定期快照或只追加存储 |
| 备份 | 建议每日备份，异机或对象存储归档 |
| 查询能力 | 至少具备按主机、时间、关键字检索 |
| 告警能力 | 建议对登录失败、sudo、RBAC 拒绝、异常删除资源配置告警 |

rsyslog 负责采集和集中落盘；检索、告警、报表、防篡改通常需要配合 Loki、Elasticsearch、Wazuh、SIEM、对象存储或备份系统完成。
