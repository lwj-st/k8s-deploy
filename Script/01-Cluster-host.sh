#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

get_cur_path
init_logging

log_info "交互式生成 environment.sh（所有部署脚本统一读取这个文件）"

default_ip() {
  if have ip; then
    ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1
  fi
}

read -r -p "下载目录 DOWNLOAD_DIR (默认: /data/download): " DOWNLOAD_DIR
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/data/download}"

read -r -p "K8S_VERSION (默认: 1.31.11): " K8S_VERSION
K8S_VERSION="${K8S_VERSION:-1.31.11}"

read -r -p "Pod CIDR (默认: 10.112.0.0/16): " POD_CIDR
POD_CIDR="${POD_CIDR:-10.112.0.0/16}"

read -r -p "Service CIDR (默认: 10.96.0.0/12): " SERVICE_CIDR
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"

# Calico IP 自动探测方式（可选）
# 示例：
#   interface=enp65s0f1
#   can-reach=10.0.0.1
# 默认: interface=bond1（如不符合你环境，请在此处修改）
read -r -p "Calico IP 网卡名 (默认: interface=bond1): " CALICO_IP_AUTODETECTION_METHOD
CALICO_IP_AUTODETECTION_METHOD="${CALICO_IP_AUTODETECTION_METHOD:-interface=bond1}"

ip_guess="$(default_ip || true)"
read -r -p "API advertise 地址 (默认: ${ip_guess:-空，需要你填}): " API_ADVERTISE_ADDRESS
API_ADVERTISE_ADDRESS="${API_ADVERTISE_ADDRESS:-$ip_guess}"
if [ -z "${API_ADVERTISE_ADDRESS}" ]; then
  die "必须提供 API_ADVERTISE_ADDRESS"
fi

read -r -p "镜像仓库 IMAGE_REPOSITORY (默认: registry.cn-hangzhou.aliyuncs.com/google_containers): " IMAGE_REPOSITORY
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-registry.cn-hangzhou.aliyuncs.com/google_containers}"

read -r -p "是否允许在线安装 OS 依赖/ kube 包？ALLOW_ONLINE (yes/no, 默认: no): " ALLOW_ONLINE
ALLOW_ONLINE="${ALLOW_ONLINE:-no}"

read -r -p "Ingress 节点名（kubectl node 名，默认: $(hostname | tr 'A-Z' 'a-z')）: " INGRESS_NODE_NAME
INGRESS_NODE_NAME="${INGRESS_NODE_NAME:-$(hostname | tr 'A-Z' 'a-z')}"

# MD5 校验开关（默认开启，便于发现坏包/截断包）
read -r -p "下载/校验开关 MAAS_MD5_CHECK (1=开启校验,0=关闭, 默认: 1): " MAAS_MD5_CHECK
MAAS_MD5_CHECK="${MAAS_MD5_CHECK:-1}"
case "${MAAS_MD5_CHECK}" in
  0|1) : ;;
  *) die "MAAS_MD5_CHECK 只能是 0 或 1" ;;
esac

# NFS（可选，仅当你要执行 18-Deploy-nfs-provisioner.sh 才需要）
# - NFS_SERVER: NFS 服务端 IP/域名（必须是已完成 export 的 NFS 服务端）
# - NFS_PATH: 服务端导出的目录路径
read -r -p "是否部署 NFS 动态供给器？DEPLOY_NFS (yes/no, 默认: no): " DEPLOY_NFS
DEPLOY_NFS="${DEPLOY_NFS:-no}"
case "${DEPLOY_NFS}" in
  yes|no) : ;;
  *) die "DEPLOY_NFS 只能是 yes 或 no" ;;
esac

NFS_SERVER=""
NFS_PATH=""
if [ "${DEPLOY_NFS}" = "yes" ]; then
  nfs_path_guess="/data/nfs"
  if [ -d /data/nfs ]; then
    nfs_path_guess="/data/nfs"
  fi
  # 默认：如果你要部署 NFS，则默认使用当前控制节点 IP + /data/nfs
  read -r -p "NFS Server（用于 nfs-provisioner，默认: ${API_ADVERTISE_ADDRESS}）: " NFS_SERVER
  NFS_SERVER="${NFS_SERVER:-${API_ADVERTISE_ADDRESS}}"
  read -r -p "NFS Export Path（用于 nfs-provisioner，默认: ${nfs_path_guess}）: " NFS_PATH
  NFS_PATH="${NFS_PATH:-$nfs_path_guess}"

  if [ -z "${NFS_SERVER}" ] || [ -z "${NFS_PATH}" ]; then
    die "你选择了 DEPLOY_NFS=yes，但 NFS_SERVER/NFS_PATH 不能为空"
  fi
fi

# containerd 数据目录（镜像与元数据存储，默认 /var/lib/containerd）
read -r -p "是否修改 containerd 数据目录？(直接回车=不修改使用默认 /var/lib/containerd；输入路径如 /data/containerd 则生效): " CONTAINERD_ROOT
CONTAINERD_ROOT="${CONTAINERD_ROOT:-}"

cat > "${SCRIPT_DIR}/environment.sh" <<EOF
#!/usr/bin/env bash
export DOWNLOAD_DIR="${DOWNLOAD_DIR}"
export K8S_VERSION="${K8S_VERSION}"
export POD_CIDR="${POD_CIDR}"
export SERVICE_CIDR="${SERVICE_CIDR}"
export API_ADVERTISE_ADDRESS="${API_ADVERTISE_ADDRESS}"
export IMAGE_REPOSITORY="${IMAGE_REPOSITORY}"
export CALICO_IP_AUTODETECTION_METHOD="${CALICO_IP_AUTODETECTION_METHOD}"
export ALLOW_ONLINE="${ALLOW_ONLINE}"
export INGRESS_NODE_NAME="${INGRESS_NODE_NAME}"
export MAAS_MD5_CHECK="${MAAS_MD5_CHECK}"
export NFS_SERVER="${NFS_SERVER}"
export NFS_PATH="${NFS_PATH}"
export CONTAINERD_ROOT="${CONTAINERD_ROOT:-}"

# 说明：MAAS_MD5_CHECK=1 时 verify/download 会强校验 md5；=0 时存在即跳过（更快但不防坏包）
# CONTAINERD_ROOT 非空时，11-Install-containerd.sh 将把 containerd 数据目录设为该路径（默认 /var/lib/containerd）
EOF

chmod 600 "${SCRIPT_DIR}/environment.sh"
log_info "已生成: ${SCRIPT_DIR}/environment.sh"
log_info "下一步建议：bash 02-Download.sh"


