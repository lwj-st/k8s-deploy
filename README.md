# k8s-deploy（x86 / Kubernetes 1.31.x + containerd）

## 目录结构
- `Script/00-Cluster-host.sh`：交互式生成 `Script/environment.sh`（所有配置统一从这里来）
- `Script/01-Download.sh`：按清单下载（可选 MD5 校验）
- `Script/02-Verify-artifacts.sh`：检查制品是否齐全（缺失直接退出，清单见 `manifests/artifacts.yaml`）
- `Script/10-Env.sh`：宿主机预置（可强改防火墙；默认只清 KUBE/CALI iptables 链）
- `Script/11-Install-containerd.sh`：安装containerd
- `Script/12-Load-images.sh`：load本地镜像
- `Script/13-Install-k8s-packages.sh`：安装所需要点安装包
- `Script/14-Kubeadm-init.sh`：初始化集群
- `Script/15-Deploy-cni.sh`
- `Script/16-Deploy-ingress.sh`
- `Script/09-Install-tools.sh`：安装 helm/helmfile
- `Script/17-Deploy-local-path.sh`
- `Script/18-Deploy-nfs-provisioner.sh`
- `Script/19-Deploy-tidb.sh`：部署tidb operator
- `Script/20-Deploy-nvidia.sh`：部署nvidia plugin
- `Script/90-Shovel-k8s.sh`：清理集群（kubeadm reset + 只清 KUBE/CALI 相关链）
- `Script/91-Cleanup-host.sh`：回滚“脚本改动过的地方”，恢复宿主机干净环境（尽可能）

## 使用顺序（建议）
先生成配置：

```bash
cd k8s-deploy/Script
bash 00-Cluster-host.sh
```

按清单下载缺失制品（离线环境可跳过下载，仅作为"补齐工具"）：

```bash
bash 01-Download.sh
```

下载完成后校验制品（建议 `MAAS_MD5_CHECK=1`，能发现坏包/截断包）：

```bash
bash 02-Verify-artifacts.sh
```

部署（逐步执行，任一步失败即退出）：

```bash
sudo bash 10-Env.sh
sudo bash 11-Install-containerd.sh
sudo bash 12-Load-images.sh
sudo bash 13-Install-k8s-packages.sh
sudo bash 09-Install-tools.sh
sudo bash 14-Kubeadm-init.sh
sudo bash 15-Deploy-cni.sh
sudo bash 16-Deploy-ingress.sh
sudo bash 17-Deploy-local-path.sh
sudo bash 18-Deploy-nfs-provisioner.sh   # 可选：仅当你在 00-Cluster-host.sh 里选择 DEPLOY_NFS=yes
sudo bash 19-Deploy-tidb.sh              # 可选
sudo bash 20-Deploy-nvidia.sh            # 可选：仅 NVIDIA
```

## 添加工作节点到集群

### 前置条件
- 主节点（control-plane）已完成初始化（已执行 `14-Kubeadm-init.sh`）
- 新节点与主节点网络互通
- 新节点已准备好相同的制品目录（可通过 NFS 共享或手动复制）

### 步骤 1：在新节点上准备环境

在新节点上执行以下脚本（与主节点相同的步骤）：

```bash
cd k8s-deploy/Script
# 确保 environment.sh 已存在（可从主节点复制，或重新运行 00-Cluster-host.sh）
# 注意：脚本会自动 source environment.sh，此步骤可选（仅用于在命令行中使用环境变量）
source environment.sh  # 可选

# 环境准备
sudo bash 10-Env.sh
sudo bash 11-Install-containerd.sh
sudo bash 12-Load-images.sh
sudo bash 13-Install-k8s-packages.sh
```

### 步骤 2：获取 kubeadm join 命令

在主节点上执行以下命令获取 join 命令：

```bash
# 直接创建新 token 并打印 join 命令（推荐）
kubeadm token create --print-join-command
```

**说明**：
- `kubeadm token create --print-join-command` 会同时创建新 token 并打印完整的 join 命令
- Token 默认有效期为 24 小时，过期后需要重新创建
- 如果需要查看 CA 证书 hash，也可以使用：`openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'`

输出示例：
```
kubeadm join 10.120.155.138:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:0123456789abcdef...
```

### 步骤 3：在新节点上执行 join

在新节点上执行步骤 2 获取的 `kubeadm join` 命令：

```bash
sudo kubeadm join <API_SERVER>:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

### 步骤 4：GPU 节点额外配置（仅 GPU 节点需要）

如果新节点是 **GPU 节点**，还需要执行：

```bash
sudo bash 20-Deploy-nvidia.sh
```

**注意**：
- `20-Deploy-nvidia.sh` 会安装 NVIDIA container toolkit 并配置 containerd runtime
- Device plugin 的 DaemonSet 已在主节点部署，会自动在所有有 `nvidia.com/gpu.present=true` label 的节点上运行
- 脚本会自动检测 GPU 并给节点打 label，无需手动操作

### 验证节点加入

在主节点上验证：

```bash
kubectl get nodes -o wide
kubectl get nodes <节点名> -o yaml | grep -A5 "labels:"
```

### CPU 节点 vs GPU 节点

| 节点类型 | 需要执行的脚本 |
|---------|--------------|
| **CPU 节点** | `10-Env.sh` → `11-Install-containerd.sh` → `12-Load-images.sh` → `13-Install-k8s-packages.sh` → `kubeadm join` |
| **GPU 节点** | `10-Env.sh` → `11-Install-containerd.sh` → `12-Load-images.sh` → `13-Install-k8s-packages.sh` → `kubeadm join` → `20-Deploy-nvidia.sh` |

**说明**：
- CPU 节点和 GPU 节点的基础步骤相同
- GPU 节点额外需要 `20-Deploy-nvidia.sh` 来安装 NVIDIA 工具包和配置 containerd runtime
- Device plugin DaemonSet 只需在主节点部署一次，会自动在所有 GPU 节点上运行

## 下载/校验开关
- `MAAS_MD5_CHECK=1`：对清单中所有条目执行 md5 校验；不正确会 `mv` 掉再下载（`dir` 类型条目不校验）。**建议默认开启**，能及时发现“截断包/坏包”
- `MAAS_MD5_CHECK=0`：如果文件已存在则直接跳过下载

## 日志颜色
- 默认：终端输出有颜色、日志文件无颜色
- 可选开关：`LOG_COLOR=auto|always|never`（默认 `auto`）

## 说明
- 所有“可能覆盖的文件/目录”会先 `mv` 成 `原名.k8s-deploy.<时间戳>`，并记录在 `/var/lib/k8s-deploy/backups.tsv`，供清理脚本回滚使用。
- 离线模式下，OS 依赖包与 `kubelet/kubeadm/kubectl` 需要你提前放到清单指定目录。
- `Script/environment.sh` 是唯一配置入口（由 `00-Cluster-host.sh` 生成）。你如果**手动移动了下载目录**，请同步修改 `DOWNLOAD_DIR`，脚本不会自动帮你创建软链或改回路径。

## 系统准备（Kubernetes 1.31 + containerd）
Kubeadm 默认 **要求关闭 swap**（否则 preflight 通常会失败）。本仓库的 `Script/10-Env.sh` 会执行：
- `swapoff -a`（只关闭当前运行时 swap，**默认不修改** `/etc/fstab`，避免误伤宿主机挂载配置）
- 关闭并禁用防火墙（`ufw` / `firewalld`）
- 写入并加载内核模块：`overlay`、`br_netfilter`、`nf_conntrack`
- 写入并应用 sysctl：`bridge-nf-call-iptables/ip6tables`、`ip_forward`、inotify 等
- iptables 默认只清理 `KUBE-*` / `CALI-*` 链（不做全量 flush）

你还需要确保：
- 宿主机时间正确（建议 NTP/chrony）
- 端口未被占用（如 6443/10250 等）
- containerd/kubelet 使用一致的 cgroup 驱动（本仓库按 containerd 默认/systemd 场景配置）


