# 高可用（HA）部署指南：Kubernetes 集群 + 关键组件（k8s-deploy）

本文覆盖两部分高可用：
- **Kubernetes 集群高可用**（控制面、etcd、入口）
- **关键组件高可用**（以 SeaweedFS + CSI 为例，可复用思路到其它组件）

适用本仓库：
- 脚本目录：`Script/`
- 制品清单：`manifests/artifacts.yaml`
- 配置目录：`config/`

> 目标：单机/单 Pod 故障不影响业务；并提供“改哪里 / 怎么改 / 怎么验”的可执行清单。

---

## 一、Kubernetes 集群高可用（必须先做）

### 1) 控制面（Control Plane）多副本

**最低推荐**：3 台控制面节点（奇数，便于仲裁）。

- **关键点**
  - 至少 3 个 control-plane：`kube-apiserver / kube-controller-manager / kube-scheduler` 多副本
  - `kube-apiserver` 前面需要一个 **高可用入口**（VIP / LB），客户端与工作节点都指向该入口

- **你需要准备**
  - 3 台控制面机器（资源与网络互通）
  - 一个对外入口：
    - **VIP**（如 keepalived + haproxy），或
    - **外部 LB**（云 LB / 硬件 LB）

> 本仓库当前脚本偏单控制面一键化；若你要控制面 HA，需要引入 VIP/LB 与多 control-plane 的 kubeadm 流程（建议单独规划/实施）。

### 2) etcd 高可用（强烈建议独立或至少 3 成员）

- **最低推荐**：3 成员 etcd（与控制面同机或独立均可）
- **关键点**
  - etcd 必须奇数成员（3/5）
  - 磁盘与网络质量直接影响集群稳定性

### 3) 集群入口与 DNS

你需要保证以下“入口”不单点：
- API Server 入口（VIP/LB）
- CoreDNS（默认 deployment，多副本即可）
- Ingress Controller（建议至少 2 副本，并跨节点）

### 4) 节点与故障域（拓扑）

要真正 HA，需要把副本分散到不同故障域：
- **节点级**：不同物理机
- **机架级**：不同 rack（可用 node label 表示）
- **机房级**：不同 DC（跨 IDC）

---

## 二、存储/组件高可用（以 SeaweedFS 为例）

### 0) 先确认“你要的 HA 等级”

常见三档：
- **抗单 Pod 故障**：组件副本数 >1 + readiness/liveness 正确
- **抗单节点故障**：副本分散到不同节点 + 数据冗余（replication）
- **跨机架/机房容灾**：拓扑标签 + 跨域副本策略（成本更高）

---

## 三、SeaweedFS 高可用：改哪些配置、在哪里改

本仓库 SeaweedFS 部署脚本：
- `Script/25-Deploy-seaweedfs.sh`

SeaweedFS Helm values：
- `config/seaweedfs-values.yaml`
  - 部署时脚本会覆盖拷贝到：`${DOWNLOAD_DIR}/seaweedfs/seaweedfs-values.yaml`

### 1) Master（控制面）HA

- **建议配置**
  - `master.replicas: 3`
  - 保持/启用 `master.affinity` 的 `podAntiAffinity`（跨节点）
  - 生产建议为 Master 使用 **可靠持久化**（避免单机 hostPath 风险）

- **改哪里**
  - `config/seaweedfs-values.yaml` → `master.replicas`

### 2) Filer（目录/元数据）HA

- **建议配置**
  - `filer.replicas: 2` 起步
  - 生产建议接入外部 DB（MySQL/PostgreSQL）做元数据后端（否则一致性/恢复风险更大）

- **改哪里**
  - `config/seaweedfs-values.yaml` → `filer.replicas` 与 DB 相关配置（建议以 Secret 方式注入）

### 3) Volume（数据面）HA

- **建议配置**
  - `volume.replicas: >=2`（结合节点数）
  - 保持/启用 `volume.affinity` 的 `podAntiAffinity`
  - 避免生产使用单机 `hostPath` 作为唯一持久化介质（节点/磁盘故障会导致数据不可用）

- **改哪里**
  - `config/seaweedfs-values.yaml` → `volume.replicas` / `volume.dataDirs` / `volume.affinity`

---

## 四、StorageClass（seaweedfs-storage）：replication、默认类、回收策略

脚本创建/重建 StorageClass 的位置：
- `Script/25-Deploy-seaweedfs.sh` → `apply_storage_class()`

### 1) replication 怎么填更合适

replication 格式 `XYZ`：
- **X**：跨 DataCenter 的副本数
- **Y**：同 DC 跨 Rack 的副本数
- **Z**：同 Rack 跨 Server 的副本数

推荐：
- 单节点/测试：`000`
- 同机房多节点抗单机：**`001`（推荐起步）**
- 跨机架：`010`
- 跨机房：`100`

> 注意：replication 只有在“副本真的落在不同故障域”时才有意义；需要配合调度分散与拓扑标签。

### 2) Retain vs Delete

- **生产建议**：`Retain`
- **测试/临时**：`Delete`

### 3) 设为默认 StorageClass

脚本支持把 `seaweedfs-storage` 设为默认，并自动取消其它默认类（避免多个默认导致歧义）。

- **环境变量（脚本）**
  - `SEAWEEDFS_STORAGE_IS_DEFAULT=true|false`（默认 `true`）

- **手动命令（立刻生效）**

```bash
kubectl annotate storageclass seaweedfs-storage storageclass.kubernetes.io/is-default-class="true" --overwrite
```

---

## 五、CSI Driver（seaweedfs-csi-driver）高可用注意点

### 1) 离线镜像必须齐全

CSI controller/node/mount 及 sidecar 镜像都必须本地可用，否则离线环境会 `ImagePullBackOff`。

本仓库已将 CSI 镜像作为制品条目管理，并在 `25-Deploy-seaweedfs.sh` 里导入。

### 2) 组件形态

通常会包含：
- `Deployment`：controller（默认 1 个对象，可调 `controller.replicas`）
- `DaemonSet`：node
- `DaemonSet`：mount（若启用）

---

## 六、执行与校验（通用命令）

### 1) 部署/升级

```bash
cd /data/k8s-deploy/Script
sudo bash 25-Deploy-seaweedfs.sh upgrade
```

### 2) 组件状态

```bash
kubectl -n seaweedfs get pods -o wide
kubectl -n seaweedfs-csi-driver get pods -o wide
kubectl get storageclass
```

### 3) 核对副本数（按实际资源名为准）

```bash
kubectl -n seaweedfs get sts,deploy
kubectl -n seaweedfs-csi-driver get deploy,ds
```

### 4) 动态卷最小闭环验证（PVC + Pod 读写）

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sw-test-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: seaweedfs-storage
  resources:
    requests:
      storage: 1Gi
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: sw-test-pod
spec:
  containers:
  - name: busybox
    image: busybox:1.33.1
    command: ["sh","-c","echo ok > /data/ok.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: sw-test-pvc
EOF

kubectl get pvc sw-test-pvc
kubectl exec -it sw-test-pod -- cat /data/ok.txt
```

清理：

```bash
kubectl delete pod sw-test-pod
kubectl delete pvc sw-test-pvc
```

---

## 七、最容易踩坑的点（务必看）

- **集群不 HA，组件再 HA 也不稳**：API/etcd 单点时，任何控制面抖动都会影响所有组件。
- **只改 replication 不等于 HA**：Master/Filer 单点仍会让系统不可用或难恢复。
- **副本没分散=没容灾**：必须配合反亲和、拓扑标签与多节点。
- **hostPath 的生产风险**：节点/磁盘故障直接导致数据不可用。
- **StorageClass 不可变字段**：`parameters/reclaimPolicy/volumeBindingMode` 改动需要删除重建（脚本已处理，建议低峰执行）。

