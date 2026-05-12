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
* 每个 control-plane 节点额外开启 kube-apiserver audit（**须单独执行** `30-Deploy-rsyslog.sh enable-audit` 或按 §4.2 手工改静态 Pod）；仅执行 `client` / `auto` 不会打开 apiserver 审计，也不会生成 `/var/log/kubernetes/audit.log`，集中端因此无 `local1` 目录属预期。**勿在 `/etc/kubernetes/manifests/` 内存放第二份 kube-apiserver 清单备份**，详见 §4.0。
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

### 4.0 推荐顺序与全局注意（请先读）

建议按下面顺序执行，可减少「清单已改但 apiserver 不带审计参数」「日志服务器没有 local1」等问题。

| 顺序 | 步骤 | 谁执行 |
| --- | --- | --- |
| 1 | 部署或确认日志服务器（§4.1），放行节点到接收端口 | 日志服务器 |
| 2 | **每个 control-plane** 开启 Kubernetes audit（§4.2） | 仅 control-plane |
| 3 | **每个节点** 做 journald / logrotate（§4.3） | 全部节点 |
| 4 | **每个节点** 配置外发（§4.4） | 全部节点 |
| 5 | 验收（§4.6，并结合 §7.2） | 全部节点 + 日志服务器 |

全局注意：

* **全程在目标节点以 root 执行**（`sudo -i` 或 `sudo bash`）；涉及 `systemctl`、`/etc/kubernetes` 的操作不可省略权限。
* **不要在 `/etc/kubernetes/manifests/` 里保留第二份 `kube-apiserver` Pod YAML**（例如 `kube-apiserver.yaml.bak`、`kube-apiserver.yaml.k8s-deploy.*`）。kubelet 会扫描该目录下多份清单；主文件若被编辑器「原地保存」时 kubelet 偶发读到空文件，journal 会出现 `Kind is missing in 'null'`，结果常表现为**磁盘清单里已有 `--audit-*`，实际进程却没有**，`/var/log/kubernetes/audit.log` 不出现，日志服务器上也看不到 `local1`。备份请放到**目录外**，例如 `/var/backups/k8s-deploy-manifests/`。
* **不要用 `kubectl replace -f /etc/kubernetes/manifests/kube-apiserver.yaml` 去「刷新」静态 Pod**。那会按「普通 Pod」在集群里多建一个错误资源；静态 Pod 只能由 **kubelet 读本地文件** 驱动。需要滚动时，应改文件并等待 kubelet，或按运维规范删除对应 mirror Pod（且 `kubectl` 建议能连本机 apiserver，例如 `https://127.0.0.1:6443`）。
* **外发配置里引用了 `/var/log/kubernetes/audit.log`**（facility `local1`）。该文件**仅 control-plane 且 audit 真正生效后**才有内容；worker 上通常不存在。若 imfile 因缺文件报错，可在 worker 上执行：`mkdir -p /var/log/kubernetes && : >> /var/log/kubernetes/audit.log && chmod 644 /var/log/kubernetes/audit.log`（空文件占位，仅占 inode；或按现场规范从 worker 的外发配置中去掉 audit 行）。
* `audit-policy.yaml` 使用 hostPath **type: File** 时，**必须先有文件再滚动 apiserver**，否则 Pod 起不来。

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

备份 kube-apiserver 静态 Pod 清单（**必须放在 manifests 目录之外**，见 §4.0）：

```bash
mkdir -p /var/backups/k8s-deploy-manifests
cp -a /etc/kubernetes/manifests/kube-apiserver.yaml \
  "/var/backups/k8s-deploy-manifests/kube-apiserver.yaml.bak.$(date +%Y%m%d_%H%M%S)"
```

若历史上曾把 `*.bak` / `*.k8s-deploy.*` 留在 `/etc/kubernetes/manifests/` 内，请先**移走或删除**再改主文件，否则 kubelet 可能一直加载旧副本。

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

保存后 kubelet 会自动重启 kube-apiserver。建议用编辑器**原子保存**（先写临时文件再 `mv` 覆盖），减少 kubelet 读到半截 YAML 的概率。

等待 1～2 分钟后检查（**不要只看 `kubectl get pod` 为 Running**：mirror Pod 与磁盘清单可能短暂不一致，要以**进程参数**为准）：

```bash
kubectl get pod -n kube-system | grep kube-apiserver
# 以下二选一：能看到 --audit-log-path 即表示 apiserver 进程已带审计参数
pgrep -af 'kube-apiserver' | head -3
# 或（已安装 crictl 时）对 Running 的 kube-apiserver 容器 ID 执行 crictl inspect，查看 process.args 是否含 audit
tail -n 5 /var/log/kubernetes/audit.log
```

若 `kubectl` 访问 VIP 失败，可在 control-plane 本机尝试：`kubectl --server=https://127.0.0.1:6443 --insecure-skip-tls-verify get pod -n kube-system`。

如果 kube-apiserver 异常，优先检查 YAML 缩进、挂载名称、`audit-policy.yaml` 和 `/var/log/kubernetes` 是否存在；并执行 `journalctl -u kubelet --since '30 min ago' --no-pager | grep -F kube-apiserver.yaml` 是否仍有 `couldn't parse as pod` / `Kind is missing`。

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

**说明**：下面片段中的 `imfile` 会监视 `/var/log/kubernetes/audit.log`。该路径在 **worker 或尚未成功开启 audit 的 control-plane** 上可能尚不存在，参见 §4.0 的占位或裁剪建议。

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

每个 control-plane 检查 audit（与 §4.2 一致，**核对进程参数**）：

```bash
pgrep -af 'kube-apiserver' | grep -E 'audit-log-path|audit-policy-file' || true
tail -n 20 /var/log/kubernetes/audit.log
kubectl get pod -A
```

若 `grep` 无输出但清单里已写 `--audit-*`，回到 §4.0：查 manifests 目录内是否还有第二份 `kube-apiserver` YAML、以及 kubelet 日志中的解析错误。

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

本节对应仓库 `Script/30-Deploy-rsyslog.sh`，与 §4 手工步骤等价；**现场若以等保/交付文档为准，仍以 §4 为 SOP**，本节供已熟悉脚本的人员按变量快速落地，并避免与手工相同的踩坑。

### 5.1 前置条件

* **root**：脚本会写 `/etc/rsyslog.d`、`/etc/logrotate.d`、`/etc/kubernetes` 等，须 `sudo bash` 或 root shell。
* **工作目录**：在仓库脚本目录执行（路径按实际克隆位置调整）：

```bash
cd /data/k8s-deploy/Script
```

* **客户端必填环境变量**：`RSYSLOG_LOG_SERVER`（日志服务器 IP/域名；多个目标用英文逗号分隔）。未传入时脚本会尝试从父进程链环境继承，不可靠，**建议在一条命令里写出**：`RSYSLOG_LOG_SERVER=10.x.x.x sudo -E bash 30-Deploy-rsyslog.sh client`。

### 5.2 推荐执行顺序（与 §4.0 对齐）

| 步骤 | 命令 | 说明 |
| --- | --- | --- |
| 1 | `sudo bash 30-Deploy-rsyslog.sh server` | 仅在**日志服务器**上执行。`RSYSLOG_LOG_SERVER` 在**只跑 `server`** 时脚本不强制校验，但建议仍 `export` 为本机对外 IP，便于与文档及后续 `auto` 一致；执行 **`auto` 时必填**，且须与本机可达 IP 匹配以便识别「本机即日志服务器」。 |
| 2 | 每个 **control-plane**：`sudo bash 30-Deploy-rsyslog.sh enable-audit` | 写 `audit-policy.yaml`、改静态 Pod；**备份默认写到** `KUBE_APISERVER_MANIFEST_BACKUP_DIR`（默认 `/var/backups/k8s-deploy-manifests/`，**不会**再放到 `manifests` 目录，避免 kubelet 加载双份清单）。若节点上仍有历史遗留的 `manifests/kube-apiserver.yaml.*` 备份，脚本会在 `enable-audit` 时**自动迁出**。 |
| 3 | **全部节点**（含 worker）：`sudo bash 30-Deploy-rsyslog.sh client` 或 `auto` | `client`：写 journald 片段、logrotate、外发配置；`RSYSLOG_FORWARD_ENABLE=no` 时只做本机预配置并关闭外发。`auto`：若本机 IP 命中 `RSYSLOG_LOG_SERVER` 则走 `server`，否则走 `client`。 |
| 4 | 验收 | 对照 §4.6、§7.2；control-plane 上建议 `pgrep -af kube-apiserver | grep audit-log-path`。 |

**说明**：`enable-audit` **只处理 apiserver 审计**，不写 rsyslog；`client` 会配置 `imfile(/var/log/kubernetes/audit.log)`。因此 **control-plane 上宜先 `enable-audit` 再 `client`**，或保证 audit 已生效，否则 audit 文件晚出现仅影响「何时开始有 local1 流量」，worker 若缺文件见 §4.0 占位说明。

### 5.3 常用命令模板

已有日志服务器，只配置 K8s 节点（TLS，默认端口 6514）：

```bash
cd /data/k8s-deploy/Script
export RSYSLOG_LOG_SERVER=<日志服务器IP>
export RSYSLOG_LOG_SERVER_PORT=6514
sudo -E bash 30-Deploy-rsyslog.sh client
```

已有日志服务器只支持普通 TCP：

```bash
cd /data/k8s-deploy/Script
export RSYSLOG_LOG_SERVER=<日志服务器IP>
export RSYSLOG_LOG_SERVER_PORT=514
export RSYSLOG_TRANSPORT=plain
sudo -E bash 30-Deploy-rsyslog.sh client
```

没有日志服务器，先在**拟作为日志服务器的主机**上执行（`RSYSLOG_LOG_SERVER` 填本机可被节点访问的 IP）：

```bash
cd /data/k8s-deploy/Script
export RSYSLOG_LOG_SERVER=<本机IP>
sudo -E bash 30-Deploy-rsyslog.sh server
```

每个 **control-plane** 开启 Kubernetes audit：

```bash
cd /data/k8s-deploy/Script
sudo bash 30-Deploy-rsyslog.sh enable-audit
```

可选：自定义 apiserver 清单备份目录（须**不在** `/etc/kubernetes/manifests/` 下）：

```bash
export KUBE_APISERVER_MANIFEST_BACKUP_DIR=/var/backups/k8s-deploy-manifests
sudo -E bash 30-Deploy-rsyslog.sh enable-audit
```

### 5.4 其他子命令与清理边界

| 模式 | 作用 |
| --- | --- |
| `preconfig` | 仅 journald + logrotate 等本机预配置，不启用外发（与 `RSYSLOG_FORWARD_ENABLE=no` 搭配场景见脚本 `usage`）。 |
| `enable-forward` | 在已预配置基础上只打开/重写外发片段。 |
| `disable-forward` | 关闭外发（等价于将外发配置移出并重载 rsyslog）。 |
| `cleanup` | 删除/备份脚本管理的 rsyslog、logrotate、journald 片段等。**默认不会**修改 `/etc/kubernetes/manifests/kube-apiserver.yaml`，**也不会**关闭 apiserver 审计参数。仅当设置 `RSYSLOG_CLEANUP_AUDIT_POLICY=yes` 时才会备份并删除 `/etc/kubernetes/audit-policy.yaml`；若 apiserver 仍挂载该路径，须**手工**改 manifest 或从备份恢复。可选 `RSYSLOG_CLEANUP_SSL=yes`、`RSYSLOG_CLEANUP_LOG_DATA=yes` 见脚本 `bash 30-Deploy-rsyslog.sh --help` / `usage` 输出。 |

关闭某个节点外发：

```bash
cd /data/k8s-deploy/Script
sudo bash 30-Deploy-rsyslog.sh disable-forward
```

### 5.5 离线安装与自检

* 在线 `dnf`/`apt` 失败时，可按脚本提示使用离线包目录 **`DOWNLOAD_DIR`**（默认 `/data/download`），具体包名与准备方式与同仓库下载脚本一致。
* 脚本执行成功后会打印「手工验证」提示；发送端证据链仍以 **§7.2** 为准。
* **勿用** `kubectl replace -f` 指向静态 Pod 清单来「修复」apiserver（见 §4.0）。

### 5.6 与手工 SOP 的对应关系

| §4 小节 | 脚本模式 |
| --- | --- |
| §4.1 | `server` |
| §4.2 | `enable-audit` |
| §4.3 + §4.4 | `client` / `auto`（含 journald、logrotate、外发） |
| §4.5 | `disable-forward` |
| 删除脚本写入的配置 | `cleanup`（注意 §5.4 边界） |

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

## 7. 日志外发：如何验收「推送成功」

### 7.1 推送与接收是两件事

| 视角 | 能说明什么 |
| --- | --- |
| **发送端（集群节点）** | 本机 rsyslog 是否按配置向目标地址/端口建立连接、TLS 是否正常、队列与重试是否报错。只能说明**推送链路在节点侧工作正常**，不能单独证明对方业务系统一定已入库或已索引。 |
| **接收端（日志服务器）** | 若可登录或由客户配合查询，在接收端看到来自集群的日志流或测试消息，才是**「对方已收到」**的最终证据。 |

实际部署中客户常使用**自有日志服务器**（或 SIEM），你可能**没有接收机权限**；此时验收应以**发送端可观测证据**为主，接收端由客户在其侧确认或双方约定一次联调窗口。

### 7.2 发送端可独立完成的校验（推荐写入交付/测试说明）

以下在**已配置外发的节点**上以 **root** 执行（无 root 时在命令前加 `sudo`）。请先记下联调用的**日志服务器地址**与**端口**（与部署时一致；脚本里对应 `RSYSLOG_LOG_SERVER`、首个目标端口即 `RSYSLOG_LOG_SERVER_PORT`，默认 TLS **6514**，明文 **514**）。下文用占位符表示：

- `LOG_SERVER`：日志服务器 IP 或域名（与 `RSYSLOG_LOG_SERVER` 中第一个目标一致即可）
- `LOG_PORT`：外发端口（与 `RSYSLOG_LOG_SERVER_PORT` 一致）

**1. 配置语法（必须通过）**

```bash
rsyslogd -N1
```

- **期望**：命令结束且退出码为 0，终端无 `error` / `failed` 等严重报错。
- **若失败**：说明 `/etc/rsyslog.d/` 下配置有语法或模块问题，需先修正后再测外发。

**2. 服务是否在跑**

```bash
systemctl status rsyslog --no-pager
```

- **期望**：`Active: active (running)`；若系统无 systemd，用 `ps aux | grep rsyslog` 确认 `rsyslogd` 进程存在即可。

**3. 本机 rsyslog 是否报错、是否在尝试转发（最关键）**

先看最近 15 分钟与转发、TLS、连接相关的日志：

```bash
journalctl -u rsyslog --since '15 min ago' --no-pager | grep -iE 'omfwd|gtls|gnutls|suspend|resume|error|fail' || true
```

若无输出，再看同时间段完整日志便于人工扫一眼：

```bash
journalctl -u rsyslog --since '15 min ago' --no-pager
```

- **期望**：无持续性的 `error` / `fail` / 证书或 TLS 握手失败；若偶发断线后出现 `resume` 类恢复也属常见。
- **若大量报错**：优先核对对端地址、端口、`RSYSLOG_TRANSPORT`（tls 与 plain）、防火墙与证书（x509 模式时）。

**4. 网络是否已连到日志服务器（可选但直观）**

先在同一终端里填入实际地址与端口（与部署时一致），再执行后面的 `ss` / `tcpdump`：

```bash
export LOG_SERVER=你的日志服务器IP或域名
export LOG_PORT=6514
ss -ntp 2>/dev/null | grep "${LOG_SERVER}" | grep "${LOG_PORT}" || true
ss -ntp 2>/dev/null | head -40
```

- **期望**：在含 `LOG_SERVER` 与 `LOG_PORT` 的行里能看到 **`ESTAB`**（已建立 TCP）；若没有 `ss`，可试：`netstat -ntp 2>/dev/null | grep "${LOG_PORT}"`（需已安装 net-tools）。

需要抓包时（确认本机是否向对端发包）：

```bash
tcpdump -nn -i any host "${LOG_SERVER}" and port "${LOG_PORT}" -c 20
```

- **期望**：能看到发往 `LOG_SERVER:LOG_PORT` 的报文（TLS 时为加密流量也属正常）。

**5. 外发配置是否已写入且含转发动作**

```bash
grep -nE 'omfwd|target=|StreamDriver' /etc/rsyslog.d/20-k8s-deploy-forward.conf
```

- **期望**：能看到 `type="omfwd"`、`target="..."` 指向你的日志服务器；TLS 模式下还能看到 `StreamDriver` 等行。

脚本执行成功后会再打印一块「手工验证」提示；**无接收机权限时**，建议以 **本步骤 1 + 3 + 5** 为最低通过线，**步骤 4** 作为加强证据。

### 7.3 有接收机或客户配合时的端到端校验

**步骤 A：在已外发的节点打一条唯一标记的测试日志**

```bash
TAG=k8s-rsyslog-verify-$(date +%s); echo "本次测试 TAG=${TAG}"; logger -t "$TAG" "hello-from-$(hostname)"
```

请**复制终端里打印的 `TAG=` 后面的整串名字**（或记下 `echo` 输出的 `TAG`），后面搜索要用。

**步骤 B：在发送节点确认 logger 已进本机 syslog（可选）**

RHEL/Rocky 等常见为 `/var/log/messages`，Debian/Ubuntu 常见为 `/var/log/syslog`：

```bash
# 须与步骤 A 在同一 shell 中执行（这样 $TAG 才有值）；若已新开终端，请把 $TAG 改成步骤 A 记下的完整字符串
grep -F "$TAG" /var/log/messages 2>/dev/null || grep -F "$TAG" /var/log/syslog 2>/dev/null || journalctl -t "$TAG" --since '2 min ago' --no-pager
```

- **期望**：能看到带该 `TAG` 的一行。若此处都没有，说明消息未进传统 syslog 管道，应先查本机 rsyslog 的 `imfile` 与路径配置，不必先去对端查。

**步骤 C：在「能访问接收端」时如何验证「对方收到了」**

- **若接收端是本仓库脚本部署的集中日志服务器**（日志落在 `RSYSLOG_LOG_DIR`，默认 `/data/logs`）：在**日志服务器**上执行（将 `TAG` 换成步骤 A 中的实际值）：

```bash
# 在日志服务器上，将 YOUR_TAG 替换为步骤 A 里 echo 打印的完整 TAG（如 k8s-rsyslog-verify-1715510400）
grep -R --include='*.log' -F "$TAG" /data/logs 2>/dev/null | head -20
```

若部署时改过集中目录，把 `/data/logs` 换成实际的 `RSYSLOG_LOG_DIR`。

- **若接收端是客户自有平台（SIEM、Syslog 网关等）**：把 **`TAG` 的字符串**、**发送节点主机名**、**大致时间**发给客户，请其在检索界面按 **关键字 = TAG** 或 **program / tag** 过滤；客户在自家界面搜到同一条即表示**端到端收到**。

**步骤 D：只有发送端权限时的折中验证**

执行完步骤 A 后等待约 **10～30 秒**，再在节点上重复 **7.2 的步骤 3**，看 `journalctl -u rsyslog` 中该时间段是否仍无转发相关致命错误；这不能等价于「对端已入库」，但能佐证**本机在持续尝试外发且未因配置崩溃**。

### 7.4 与客户验收时的责任边界建议

- **实施方（节点侧）**：完成并保留 7.2 中发送端证据（必要时截图或日志片段），说明外发已按设计指向客户提供的地址与端口、传输模式（`RSYSLOG_TRANSPORT`：tls / plain）与脚本配置一致。
- **客户（接收侧）**：在其日志平台或落盘路径中确认来自集群 IP/主机名的日志及联调测试消息。

若客户仅支持明文 TCP、非标准端口或与当前 `RSYSLOG_TRANSPORT` / 端口不一致，发送端 journal 中通常会很快出现连接或协议相关错误，应先对齐参数再重复 7.2。
