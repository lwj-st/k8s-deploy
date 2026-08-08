#!/usr/bin/env bash
################################################################################
## Filename:    apply.sh
## Description: 将 ModelEngine（GPUStack）Grafana 数据源与看板导入 kube-prom-stack Grafana
## Usage:
##   bash apply.sh apply|regenerate|restart|all|check
## Artifacts:
##   - （无）本脚本只 apply 同目录 YAML / 从集群源 ConfigMap 再生清单
## Images:
##   - （无）不部署镜像，仅创建/更新 ConfigMap
## Env:
##   - NS_MONITORING: 目标命名空间，默认 monitoring（Grafana / kube-prom 所在 ns）
##   - NS_SOURCE: ModelEngine 源命名空间，默认 modelstudio（regenerate / 数据源 URL 用）
##   - PROM_SVC: ModelEngine Prometheus 服务名，默认 modelengine-prometheus
##   - PROM_URL: 可选；若设置则覆盖自动拼接的数据源 URL
##   - GRAFANA_DEPLOY: Grafana Deployment 名，默认 kube-prom-stack-grafana
##   - SKIP_SOFT_CHECKS: 设为 1 时跳过软依赖探测（仍检查硬依赖）
## Notes:
##   - 幂等：可重复 apply；会覆盖同名 ConfigMap
##   - restart 会滚动重启 Grafana；若存储为 emptyDir，UI 改过的 admin 密码会回到 Secret 默认值
##   - 不修改 kube-prom / modelengine 的 scrape 配置，只挂远程数据源看已有 gpustack:* 指标
##
## 前序依赖（硬依赖：不满足则脚本失败退出）:
##   1. kubectl、python3 可用，且当前上下文能访问目标集群
##   2. 命名空间 ${NS_MONITORING} 已存在
##   3. apply：同目录已有
##        modelengine-grafana-datasource.yaml
##        modelengine-grafana-dashboard-runtime.yaml
##        modelengine-grafana-dashboard-worker.yaml
##   4. regenerate：源 ConfigMap ${NS_SOURCE}/modelengine-grafana-dashboards 存在，
##      且含键 gpustack-runtime-dashboard.json、gpustack-worker.json
##   5. restart：Deployment ${GRAFANA_DEPLOY} 存在于 ${NS_MONITORING}
##
## 前序依赖（软依赖：缺了 apply 仍成功，但看板无数据 / UI 不出现）:
##   1. ${NS_MONITORING} 中 Grafana 带 sidecar，认标签
##        grafana_dashboard=1 / grafana_datasource=1
##   2. Service ${PROM_SVC}.${NS_SOURCE}.svc:9090 可从 Grafana Pod 访问
##   3. 该 Prometheus 已采集 GPUStack Worker，存在 gpustack:cluster_info 等指标
##   4. Grafana 与 ${NS_SOURCE} 跨命名空间网络互通
################################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS_MONITORING="${NS_MONITORING:-monitoring}"
NS_SOURCE="${NS_SOURCE:-modelstudio}"
PROM_SVC="${PROM_SVC:-modelengine-prometheus}"
PROM_URL="${PROM_URL:-http://${PROM_SVC}.${NS_SOURCE}.svc:9090}"
GRAFANA_DEPLOY="${GRAFANA_DEPLOY:-kube-prom-stack-grafana}"
SKIP_SOFT_CHECKS="${SKIP_SOFT_CHECKS:-0}"

DATASOURCE_YAML="${SCRIPT_DIR}/modelengine-grafana-datasource.yaml"
RUNTIME_YAML="${SCRIPT_DIR}/modelengine-grafana-dashboard-runtime.yaml"
WORKER_YAML="${SCRIPT_DIR}/modelengine-grafana-dashboard-worker.yaml"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: bash $(basename "$0") apply|regenerate|restart|all|check

  check       检查硬/软前序依赖（默认不改集群）
  apply       kubectl apply 同目录 YAML（默认动作）
  regenerate  从 ${NS_SOURCE}/modelengine-grafana-dashboards 重新生成 YAML
  restart     滚动重启 ${GRAFANA_DEPLOY}（首次挂数据源建议执行）
  all         regenerate + apply + restart

Env: NS_MONITORING NS_SOURCE PROM_SVC PROM_URL GRAFANA_DEPLOY SKIP_SOFT_CHECKS
EOF
}

require_commands() {
  have kubectl || die "缺少 kubectl，请先安装并配置集群访问"
  have python3 || die "缺少 python3（regenerate / 依赖检查需要）"
}

require_namespace() {
  local ns="$1"
  kubectl get namespace "${ns}" >/dev/null 2>&1 \
    || die "硬依赖缺失：命名空间 ${ns} 不存在（请先部署 kube-prom-stack / 目标 Grafana 所在 ns）"
}

require_apply_files() {
  local f
  for f in "${DATASOURCE_YAML}" "${RUNTIME_YAML}" "${WORKER_YAML}"; do
    [[ -f "${f}" ]] || die "硬依赖缺失：清单文件不存在 ${f}（先执行 regenerate，或从已有环境拷贝 yaml）"
  done
}

require_source_dashboard_cm() {
  kubectl get configmap modelengine-grafana-dashboards -n "${NS_SOURCE}" >/dev/null 2>&1 \
    || die "硬依赖缺失：ConfigMap ${NS_SOURCE}/modelengine-grafana-dashboards 不存在（regenerate 需要）"
}

require_grafana_deploy() {
  kubectl get deploy "${GRAFANA_DEPLOY}" -n "${NS_MONITORING}" >/dev/null 2>&1 \
    || die "硬依赖缺失：Deployment ${NS_MONITORING}/${GRAFANA_DEPLOY} 不存在（restart 需要）"
}

check_soft_deps() {
  local ok=1
  log "检查软依赖（不满足时 apply 仍可成功，但看板可能空白）..."

  if kubectl get deploy "${GRAFANA_DEPLOY}" -n "${NS_MONITORING}" >/dev/null 2>&1; then
    log "  [ok] Grafana Deployment ${GRAFANA_DEPLOY}"
  else
    warn "  [missing] Grafana Deployment ${NS_MONITORING}/${GRAFANA_DEPLOY}（sidecar 无法装载看板）"
    ok=0
  fi

  if kubectl get svc "${PROM_SVC}" -n "${NS_SOURCE}" >/dev/null 2>&1; then
    log "  [ok] Prometheus Service ${NS_SOURCE}/${PROM_SVC}"
  else
    warn "  [missing] Service ${NS_SOURCE}/${PROM_SVC}（数据源 URL=${PROM_URL} 将不可用）"
    ok=0
  fi

  # 尽力探测指标（主机侧用 ClusterIP，避免依赖集群 DNS）
  if have curl; then
    local ip port probe_url
    ip="$(kubectl get svc "${PROM_SVC}" -n "${NS_SOURCE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    port="$(kubectl get svc "${PROM_SVC}" -n "${NS_SOURCE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
    port="${port:-9090}"
    if [[ -n "${ip}" ]]; then
      probe_url="http://${ip}:${port}/api/v1/query?query=gpustack:cluster_info"
      if curl -fsS --connect-timeout 2 --max-time 5 "${probe_url}" 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("data",{}).get("result") else 1)' \
        2>/dev/null; then
        log "  [ok] 指标 gpustack:cluster_info 可查（via ${ip}:${port}；Grafana 内使用 ${PROM_URL}）"
      else
        warn "  [missing] ${ip}:${port} 未查到 gpustack:cluster_info（Worker 未刮取或 Prometheus 不可达）"
        ok=0
      fi
    fi
  else
    warn "  [skip] 未安装 curl，跳过指标探测"
  fi

  if [[ "${ok}" -eq 1 ]]; then
    log "软依赖检查通过"
  else
    warn "软依赖不完整：ConfigMap 仍可 apply，但 Grafana 可能无数据源/无曲线"
  fi
  return 0
}

check_deps() {
  local mode="$1"
  log "前序依赖检查（mode=${mode}）"
  log "  NS_MONITORING=${NS_MONITORING}"
  log "  NS_SOURCE=${NS_SOURCE}"
  log "  PROM_URL=${PROM_URL}"
  log "  GRAFANA_DEPLOY=${GRAFANA_DEPLOY}"

  require_commands
  require_namespace "${NS_MONITORING}"

  case "${mode}" in
    apply)
      require_apply_files
      ;;
    regenerate)
      require_namespace "${NS_SOURCE}"
      require_source_dashboard_cm
      ;;
    restart)
      require_grafana_deploy
      ;;
    all)
      require_namespace "${NS_SOURCE}"
      require_source_dashboard_cm
      require_grafana_deploy
      ;;
    check)
      # check 模式：硬依赖缺失只告警，便于一次看清环境缺口
      if kubectl get namespace "${NS_SOURCE}" >/dev/null 2>&1; then
        log "  [ok] 命名空间 ${NS_SOURCE}"
        if kubectl get configmap modelengine-grafana-dashboards -n "${NS_SOURCE}" >/dev/null 2>&1; then
          log "  [ok] 源看板 ConfigMap ${NS_SOURCE}/modelengine-grafana-dashboards"
        else
          warn "  [missing] 源看板 ConfigMap（仅 regenerate 需要；纯 apply 可用现成 yaml）"
        fi
      else
        warn "  [missing] 命名空间 ${NS_SOURCE}"
      fi
      if [[ -f "${DATASOURCE_YAML}" && -f "${RUNTIME_YAML}" && -f "${WORKER_YAML}" ]]; then
        log "  [ok] 同目录 apply 清单文件齐全"
      else
        warn "  [missing] 同目录 yaml 不齐（apply 会失败；可先 regenerate）"
      fi
      if kubectl get deploy "${GRAFANA_DEPLOY}" -n "${NS_MONITORING}" >/dev/null 2>&1; then
        log "  [ok] Grafana Deployment ${GRAFANA_DEPLOY}"
      else
        warn "  [missing] Grafana Deployment（restart / sidecar 装载需要）"
      fi
      ;;
    *)
      die "未知 mode: ${mode}"
      ;;
  esac

  if [[ "${SKIP_SOFT_CHECKS}" != "1" ]]; then
    check_soft_deps
  else
    warn "已设置 SKIP_SOFT_CHECKS=1，跳过软依赖探测"
  fi
}

regenerate() {
  log "从 ${NS_SOURCE}/modelengine-grafana-dashboards 重新生成清单 -> ${SCRIPT_DIR}"
  python3 - "${SCRIPT_DIR}" "${NS_SOURCE}" "${NS_MONITORING}" "${PROM_URL}" <<'PY'
import json, pathlib, subprocess, sys

outdir = pathlib.Path(sys.argv[1])
ns_source = sys.argv[2]
ns_monitoring = sys.argv[3]
prom_url = sys.argv[4]

cm = json.loads(subprocess.check_output(
    ["kubectl", "get", "cm", "modelengine-grafana-dashboards", "-n", ns_source, "-o", "json"],
    text=True,
))
DS_UID = "gpustack-prometheus"
DS = {"type": "prometheus", "uid": DS_UID}

def rewrite_ds(obj):
    if isinstance(obj, dict):
        ds = obj.get("datasource")
        if isinstance(ds, dict) and ds.get("type") == "prometheus":
            obj["datasource"] = dict(DS)
        for k, v in list(obj.items()):
            if k in ("title", "description") and isinstance(v, str):
                obj[k] = v.replace("GPUStack", "ModelEngine").replace("gpustack", "modelengine")
            else:
                rewrite_ds(v)
    elif isinstance(obj, list):
        for v in obj:
            rewrite_ds(v)

def fix_vars(dash):
    rewrite_ds(dash)
    for t in (dash.get("templating") or {}).get("list") or []:
        if t.get("type") == "query":
            t["datasource"] = dict(DS)
    return dash

ds_body = f"""apiVersion: 1
datasources:
  - name: ModelEngine-Prometheus
    type: prometheus
    uid: {DS_UID}
    url: {prom_url}
    access: proxy
    isDefault: false
    editable: true
    jsonData:
      httpMethod: POST
      timeInterval: 15s
"""

docs = [{
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {
        "name": "modelengine-grafana-datasource",
        "namespace": ns_monitoring,
        "labels": {"app": "modelengine-monitoring", "grafana_datasource": "1"},
    },
    "data": {"modelengine-datasource.yaml": ds_body},
}]

key_map = {
    "gpustack-runtime-dashboard.json": (
        "modelengine-grafana-dashboard-runtime",
        "modelengine-runtime-dashboard.json",
    ),
    "gpustack-worker.json": (
        "modelengine-grafana-dashboard-worker",
        "modelengine-worker-dashboard.json",
    ),
}

for src_key, (cm_name, out_key) in key_map.items():
    if src_key not in cm["data"]:
        raise SystemExit(f"源 ConfigMap 缺少键: {src_key}")
    dash = fix_vars(json.loads(cm["data"][src_key]))
    docs.append({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": cm_name,
            "namespace": ns_monitoring,
            "labels": {"app": "modelengine-monitoring", "grafana_dashboard": "1"},
            "annotations": {"grafana_folder": "ModelEngine"},
        },
        "data": {out_key: json.dumps(dash, ensure_ascii=False, separators=(",", ":"))},
    })

for d in docs:
    name = d["metadata"]["name"]
    tmp = outdir / f"{name}.json"
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
    yml = subprocess.check_output(
        ["kubectl", "apply", "--dry-run=client", "-f", str(tmp), "-o", "yaml"],
        text=True,
    )
    (outdir / f"{name}.yaml").write_text(yml)
    tmp.unlink()
    print(f"generated {name}.yaml")
PY
  log "regenerate 完成"
}

apply_all() {
  log "kubectl apply ConfigMaps -> namespace/${NS_MONITORING}"
  kubectl apply -f "${DATASOURCE_YAML}"
  kubectl apply -f "${RUNTIME_YAML}"
  kubectl apply -f "${WORKER_YAML}"
  log "apply 完成；Grafana sidecar 会自动装载带 grafana_dashboard/grafana_datasource 标签的 ConfigMap"
  log "若 UI 仍无 ModelEngine-Prometheus 数据源，请执行: bash $0 restart"
}

restart_grafana() {
  warn "即将滚动重启 Deployment/${GRAFANA_DEPLOY}（emptyDir 场景会重置 Grafana admin 密码到 Secret 默认值）"
  kubectl rollout restart "deploy/${GRAFANA_DEPLOY}" -n "${NS_MONITORING}"
  kubectl rollout status "deploy/${GRAFANA_DEPLOY}" -n "${NS_MONITORING}" --timeout=180s
  log "Grafana 重启完成"
}

main() {
  local mode="${1:-apply}"

  case "${mode}" in
    -h|--help|help)
      usage
      return 0
      ;;
    check|apply|regenerate|restart|all)
      ;;
    *)
      usage >&2
      die "未知参数: ${mode}"
      ;;
  esac

  check_deps "${mode}"

  case "${mode}" in
    check)
      log "依赖检查结束（未修改集群）"
      ;;
    apply)
      apply_all
      ;;
    regenerate)
      regenerate
      ;;
    restart)
      restart_grafana
      ;;
    all)
      regenerate
      require_apply_files
      apply_all
      restart_grafana
      ;;
  esac
}

main "$@"
