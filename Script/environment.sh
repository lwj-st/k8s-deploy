#!/usr/bin/env bash
export DOWNLOAD_DIR="/data/download"
export K8S_VERSION="1.31.11"
export POD_CIDR="10.112.0.0/16"
export SERVICE_CIDR="10.96.0.0/12"
export API_ADVERTISE_ADDRESS="10.119.96.10"
export IMAGE_REPOSITORY="registry.cn-hangzhou.aliyuncs.com/google_containers"
export CALICO_IP_AUTODETECTION_METHOD="eth0"
export ALLOW_ONLINE="no"
export INGRESS_NODE_NAME="wx-ecs-01"
export GRAFANA_INGRESS_HOST="grafana.sensecore.com"
export MAAS_MD5_CHECK="1"
export NFS_SERVER="10.119.96.10"
export NFS_PATH="/data/nfs"
export CONTAINERD_ROOT=""

# 说明：MAAS_MD5_CHECK=1 时 verify/download 会强校验 md5；=0 时存在即跳过（更快但不防坏包）
# CONTAINERD_ROOT 非空时，11-Install-containerd.sh 将把 containerd 数据目录设为该路径（默认 /var/lib/containerd）
