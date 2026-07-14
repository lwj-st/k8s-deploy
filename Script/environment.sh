#!/usr/bin/env bash
################################################################################
## Filename:    environment.sh
## Description: k8s-deploy 集群部署配置
## Usage:
##   source Script/environment.sh
## Notes:
##   - 通常由 01-Cluster-host.sh 生成
################################################################################
export K8S_VERSION="1.31.11"
export TARGET_OS_VERSION=""
export POD_CIDR="10.112.0.0/16"
export SERVICE_CIDR="10.96.0.0/12"
export API_ADVERTISE_ADDRESS="10.119.54.138"
export IMAGE_REPOSITORY="registry.cn-hangzhou.aliyuncs.com/google_containers"
export CALICO_IP_AUTODETECTION_METHOD="bond0"
export ALLOW_ONLINE="no"
export INGRESS_NODE_NAME="10-118-244-13"
export GRAFANA_INGRESS_HOST="grafana.sensecore.com"
export MAAS_MD5_CHECK="1"
export NFS_SERVER=""
export NFS_PATH=""
export CONTAINERD_ROOT="/data/containerd"

# 说明：MAAS_MD5_CHECK=1 时 verify/download 会强校验 md5；=0 时存在即跳过（更快但不防坏包）
# TARGET_OS_VERSION 由 01-Cluster-host.sh 根据支持列表选择；为空时请重新执行该脚本。
# CONTAINERD_ROOT 非空时，11-Install-containerd.sh 将把 containerd 数据目录设为该路径（默认 /var/lib/containerd）
