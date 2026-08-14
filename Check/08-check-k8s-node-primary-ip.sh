#!/usr/bin/env bash
################################################################################
## Filename:    08-check-k8s-node-primary-ip.sh
## Description: 部署 K8s 之前检查本机主 IP 是否唯一、一致（只读，不依赖 kubelet/kubectl）
## Usage:
##   bash Check/08-check-k8s-node-primary-ip.sh
## Env:
##   - REACH_IP: 可选，路由探测目的地址；默认取默认路由网关，没有则 1.1.1.1
##   - CLUSTER_IFACE: 可选，若传入则额外要求默认出口必须是这张网卡
##   - NO_COLOR: 设置为任意值时禁用彩色输出（FAIL 默认红色，仅终端启用）
## Notes:
##   - 在未装 K8s 的节点上执行；每台机器各自跑，不写死 IP、不强制网卡名
##   - 候选主 IP = 内核访问探测地址时选用的 src（默认路由）
##   - 再和 hostname -I 第一项、其它网卡地址做源时的出口交叉验证
##   - 不访问集群 API，不修改系统
################################################################################
set -euo pipefail

CLUSTER_IFACE="${CLUSTER_IFACE:-}"
REACH_IP="${REACH_IP:-}"

fail=0

COLOR_RESET=""
COLOR_RED=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_RESET="$(printf '\033[0m')"
  COLOR_RED="$(printf '\033[31m')"
fi

get_route_field() {
  local target="$1"
  local field="$2"
  local from_ip="${3:-}"
  if [ -n "${from_ip}" ]; then
    ip route get "${target}" from "${from_ip}" 2>/dev/null \
      | awk -v key="${field}" '{for(i=1;i<=NF;i++) if($i==key){print $(i+1); exit}}'
  else
    ip route get "${target}" 2>/dev/null \
      | awk -v key="${field}" '{for(i=1;i<=NF;i++) if($i==key){print $(i+1); exit}}'
  fi
}

fail_msg() {
  printf '%sFAIL: %s%s\n' "${COLOR_RED}" "$*" "${COLOR_RESET}"
  fail=1
}

warn_msg() {
  echo "WARN: $*"
}

skip_iface() {
  case "$1" in
    lo|docker0|podman0|cni0|flannel.1|virbr*|br-*|tunl*|cali*|kube-*|veth*)
      return 0
      ;;
  esac
  return 1
}

print_fail_hints() {
  cat <<EOF

部署前未通过时，应改本机网络后再装 K8s，部署脚本不会自动兜底：
  - 默认路由的 src、hostname -I 第一项必须是同一个地址
  - 用其它网卡 IP 当源访问外网/业务网时，不能被策略路由拐到存储网卡
  - 不要用 from <存储网段> lookup <独立表> 且该表只有存储默认路由
EOF
}

if ! command -v ip >/dev/null 2>&1; then
  fail_msg "缺少 ip 命令"
  exit 1
fi

if [ -n "${CLUSTER_IFACE}" ] && ! ip link show dev "${CLUSTER_IFACE}" >/dev/null 2>&1; then
  fail_msg "网卡不存在: ${CLUSTER_IFACE}"
  echo "当前网卡: $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | paste -sd ',')"
  exit 1
fi

if [ -z "${REACH_IP}" ]; then
  REACH_IP="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
  REACH_IP="${REACH_IP:-1.1.1.1}"
fi

default_count="$(ip -4 route show default 2>/dev/null | wc -l | awk '{print $1}')"
if [ "${default_count}" -gt 1 ]; then
  warn_msg "存在多条 IPv4 默认路由，按当前内核选路检查："
  ip -4 route show default
fi

EXPECT_DEV="$(get_route_field "${REACH_IP}" dev || true)"
EXPECT_IP="$(get_route_field "${REACH_IP}" src || true)"
first="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

if [ -z "${EXPECT_IP}" ] || [ -z "${EXPECT_DEV}" ]; then
  fail_msg "无法从路由得到访问 ${REACH_IP} 的 src/dev"
  ip route get "${REACH_IP}" || true
  exit 1
fi

echo "候选主网卡=${EXPECT_DEV} 候选主IP=${EXPECT_IP}（内核访问 ${REACH_IP} 时选用）"
echo "hostname -I 第一项=${first:-未知}"
echo "本机全局 IPv4："
ip -4 -o addr show scope global | awk '{gsub(/:$/,"",$2); printf "  %s %s\n", $2, $4}'

if [ -n "${CLUSTER_IFACE}" ] && [ "${EXPECT_DEV}" != "${CLUSTER_IFACE}" ]; then
  fail_msg "默认出口是 ${EXPECT_DEV}，与指定的 CLUSTER_IFACE=${CLUSTER_IFACE} 不一致"
fi

if [ -z "${first}" ]; then
  warn_msg "无法获取 hostname -I"
elif [ "${first}" != "${EXPECT_IP}" ]; then
  fail_msg "hostname -I 第一项是 ${first}，内核默认源地址是 ${EXPECT_IP}。两者必须一致，否则 Node IP / 探活源地址常会变成 ${first}"
fi

if ip rule | grep -Eq 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
  echo "INFO: 本机策略路由："
  ip rule
fi

echo "INFO: 用其它网卡地址作为源，看访问 ${REACH_IP} 会不会被拐走"
while read -r ifname cidr; do
  [ -n "${ifname}" ] || continue
  skip_iface "${ifname}" && continue
  other_ip="${cidr%%/*}"
  [ "${other_ip}" = "${EXPECT_IP}" ] && continue

  odev="$(get_route_field "${REACH_IP}" dev "${other_ip}" || true)"
  osrc="$(get_route_field "${REACH_IP}" src "${other_ip}" || true)"
  otable="$(get_route_field "${REACH_IP}" table "${other_ip}" || true)"
  echo "  from ${other_ip} (${ifname}) -> dev=${odev:-未知} src=${osrc:-未知} table=${otable:-main}"

  if [ -n "${odev}" ] && [ "${odev}" != "${EXPECT_DEV}" ]; then
    fail_msg "从 ${other_ip}(${ifname}) 访问 ${REACH_IP} 走 ${odev}（table=${otable:-main}），不是默认出口 ${EXPECT_DEV}。部署后若 kubelet 用该地址做源，将无法按集群网访问本机 Pod"
  fi
done < <(ip -4 -o addr show scope global | awk '{gsub(/:$/,"",$2); print $2,$4}')

echo

if [ "${fail}" -eq 0 ]; then
  echo "========================================"
  echo "PASS: 部署前主 IP 检查通过"
  echo "主网卡: ${EXPECT_DEV}"
  echo "主 IP : ${EXPECT_IP}"
  echo "========================================"
  exit 0
fi

echo "========================================"
printf '%sFAIL: 部署前主 IP 检查未通过，不建议在此节点安装 K8s%s\n' "${COLOR_RED}" "${COLOR_RESET}"
echo "内核默认源: ${EXPECT_IP} (${EXPECT_DEV})"
echo "hostname -I 第一项: ${first:-未知}"
print_fail_hints
echo "========================================"
exit 1
