#!/usr/bin/env python3
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request


def run(cmd, input_data=None):
    result = subprocess.run(
        cmd,
        input=input_data,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\n{result.stderr.strip()}")
    return result.stdout


def load_yaml(path):
    try:
        import yaml
    except ImportError as exc:
        raise RuntimeError("python3 PyYAML is required for Grafana alerting config") from exc

    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def secret_value(namespace, secret_name, key):
    raw = run(
        [
            "kubectl",
            "-n",
            namespace,
            "get",
            "secret",
            secret_name,
            "-o",
            f"jsonpath={{.data.{key}}}",
        ]
    ).strip()
    if not raw:
        raise RuntimeError(f"secret {namespace}/{secret_name} missing key {key}")
    return base64.b64decode(raw).decode("utf-8")


class GrafanaClient:
    def __init__(self, url, username, password):
        self.url = url.rstrip("/")
        token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
        self.headers = {
            "Authorization": f"Basic {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def request(self, method, path, body=None, disable_provenance=False, allow_404=False):
        headers = dict(self.headers)
        if disable_provenance:
            headers["X-Disable-Provenance"] = "true"
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            f"{self.url}{path}",
            data=data,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                payload = resp.read().decode("utf-8")
                return None if not payload else json.loads(payload)
        except urllib.error.HTTPError as exc:
            if allow_404 and exc.code == 404:
                return None
            payload = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Grafana API {method} {path} failed: HTTP {exc.code} {payload}") from exc


def wait_for_grafana(client):
    last_error = None
    for _ in range(30):
        try:
            client.request("GET", "/api/health")
            return
        except Exception as exc:
            last_error = exc
            time.sleep(1)
    raise RuntimeError(f"Grafana API is not ready: {last_error}")


def start_port_forward(namespace, resource, local_port, remote_port):
    proc = subprocess.Popen(
        [
            "kubectl",
            "-n",
            namespace,
            "port-forward",
            resource,
            f"{local_port}:{remote_port}",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return proc


def ensure_folder(client, uid, title):
    existing = client.request("GET", f"/api/folders/{uid}", allow_404=True)
    if existing:
        if existing.get("title") != title:
            client.request(
                "PUT",
                f"/api/folders/{uid}",
                {"title": title, "version": existing.get("version", 1)},
            )
        return
    client.request("POST", "/api/folders", {"uid": uid, "title": title})


def prometheus_model(expr, datasource_uid):
    return {
        "datasource": {"type": "prometheus", "uid": datasource_uid},
        "editorMode": "code",
        "expr": expr,
        "instant": True,
        "intervalMs": 1000,
        "legendFormat": "__auto",
        "maxDataPoints": 43200,
        "range": False,
        "refId": "A",
    }


def reduce_model():
    return {
        "conditions": [
            {
                "evaluator": {"params": [], "type": "gt"},
                "operator": {"type": "and"},
                "query": {"params": ["B"]},
                "reducer": {"params": [], "type": "last"},
                "type": "query",
            }
        ],
        "datasource": {"type": "__expr__", "uid": "__expr__"},
        "expression": "A",
        "intervalMs": 1000,
        "maxDataPoints": 43200,
        "reducer": "last",
        "refId": "B",
        "type": "reduce",
    }


def threshold_model(threshold):
    return {
        "conditions": [
            {
                "evaluator": {"params": [threshold], "type": "gt"},
                "operator": {"type": "and"},
                "query": {"params": ["C"]},
                "reducer": {"params": [], "type": "last"},
                "type": "query",
            }
        ],
        "datasource": {"type": "__expr__", "uid": "__expr__"},
        "expression": "B",
        "intervalMs": 1000,
        "maxDataPoints": 43200,
        "refId": "C",
        "type": "threshold",
    }


def build_rule(config, rule):
    datasource_uid = rule.get("datasourceUid") or config.get("datasourceUid", "prometheus")
    threshold = float(rule.get("threshold", 0))
    return {
        "uid": rule["uid"],
        "orgID": int(config.get("orgId", 1)),
        "folderUID": config["folderUid"],
        "ruleGroup": config["ruleGroup"],
        "title": rule["title"],
        "condition": "C",
        "data": [
            {
                "refId": "A",
                "queryType": "",
                "relativeTimeRange": {"from": int(rule.get("relativeTimeRangeFrom", 600)), "to": 0},
                "datasourceUid": datasource_uid,
                "model": prometheus_model(rule["expr"], datasource_uid),
            },
            {
                "refId": "B",
                "queryType": "",
                "relativeTimeRange": {"from": 0, "to": 0},
                "datasourceUid": "__expr__",
                "model": reduce_model(),
            },
            {
                "refId": "C",
                "queryType": "",
                "relativeTimeRange": {"from": 0, "to": 0},
                "datasourceUid": "__expr__",
                "model": threshold_model(threshold),
            },
        ],
        "noDataState": rule.get("noDataState", "OK"),
        "execErrState": rule.get("execErrState", "Error"),
        "for": str(rule.get("for", "0s")),
        "annotations": {
            "summary": rule.get("summary", rule["title"]),
            "description": rule.get("description", ""),
        },
        "labels": {
            "severity": rule.get("severity", "warning"),
            "managed_by": "monitoring-managed-configs",
        },
        "isPaused": bool(rule.get("isPaused", False)),
    }


def upsert_rule(client, rule_body):
    uid = rule_body["uid"]
    exists = client.request("GET", f"/api/v1/provisioning/alert-rules/{uid}", allow_404=True)
    if exists:
        client.request(
            "PUT",
            f"/api/v1/provisioning/alert-rules/{uid}",
            rule_body,
            disable_provenance=True,
        )
        print(f"grafana alert rule/{uid} configured")
    else:
        client.request(
            "POST",
            "/api/v1/provisioning/alert-rules",
            rule_body,
            disable_provenance=True,
        )
        print(f"grafana alert rule/{uid} created")


def load_dashboard(path):
    source = Path(path)
    if not source.is_file():
        raise RuntimeError(f"Grafana dashboard file not found: {source}")

    if source.suffix == ".json":
        with source.open("r", encoding="utf-8") as fh:
            return json.load(fh)

    manifest = load_yaml(str(source))
    data = manifest.get("data") or {}
    json_values = [value for key, value in data.items() if key.endswith(".json")]
    if len(json_values) != 1:
        raise RuntimeError(f"Grafana dashboard ConfigMap must contain exactly one *.json data item: {source}")
    return json.loads(json_values[0])


def dashboard_payload(client, uid):
    return client.request("GET", f"/api/dashboards/uid/{uid}", allow_404=True)


def wait_until_dashboard_is_not_provisioned(client, uid):
    for _ in range(45):
        payload = dashboard_payload(client, uid)
        if not payload:
            return None
        if not (payload.get("meta") or {}).get("provisioned"):
            return payload
        time.sleep(1)
    return dashboard_payload(client, uid)


def upsert_dashboard(client, dashboard_config, config_dir):
    uid = dashboard_config["uid"]
    folder_uid = dashboard_config["folderUid"]
    folder_title = dashboard_config.get("folderTitle", folder_uid)
    dashboard_path = dashboard_config.get("path")
    if not dashboard_path:
        print(f"grafana dashboard/{uid} has no path, skip")
        return

    ensure_folder(client, folder_uid, folder_title)

    source = Path(dashboard_path)
    if not source.is_absolute():
        source = config_dir / source
    if not source.is_file():
        mounted_source = config_dir / Path(dashboard_path).name
        if mounted_source.is_file():
            source = mounted_source
    dashboard = load_dashboard(source)
    dashboard["uid"] = uid
    dashboard["id"] = None

    payload = wait_until_dashboard_is_not_provisioned(client, uid)
    meta = (payload or {}).get("meta") or {}
    if meta.get("provisioned"):
        raise RuntimeError(
            f"Grafana dashboard/{uid} is still sidecar-provisioned. "
            "Remove grafana_dashboard label from its ConfigMap and retry after Grafana reloads."
        )

    client.request(
        "POST",
        "/api/dashboards/db",
        {
            "dashboard": dashboard,
            "folderUid": folder_uid,
            "overwrite": True,
            "message": "apply managed alerting dashboard",
        },
    )
    print(f"grafana dashboard/{uid} configured in folder/{folder_uid}")


def apply_config(client, config, config_dir):
    ensure_folder(client, config["folderUid"], config.get("folderTitle", config["folderUid"]))
    for rule in config.get("rules") or []:
        upsert_rule(client, build_rule(config, rule))
    for dashboard in config.get("dashboards") or []:
        upsert_dashboard(client, dashboard, config_dir)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--grafana-url", default=os.getenv("GRAFANA_URL"))
    parser.add_argument("--namespace", default=os.getenv("MONITORING_NAMESPACE", "monitoring"))
    parser.add_argument("--grafana-secret", default=os.getenv("GRAFANA_SECRET", "kube-prom-stack-grafana"))
    parser.add_argument("--grafana-resource", default=os.getenv("GRAFANA_RESOURCE", "deploy/kube-prom-stack-grafana"))
    parser.add_argument("--local-port", type=int, default=int(os.getenv("GRAFANA_LOCAL_PORT", "13000")))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    config = load_yaml(args.config)
    config_dir = Path(args.config).resolve().parent
    rules = config.get("rules") or []
    if args.dry_run:
        print(json.dumps({
            "rules": [build_rule(config, rule) for rule in rules],
            "dashboards": config.get("dashboards") or [],
        }, ensure_ascii=False, indent=2))
        return

    username = os.getenv("GRAFANA_USER") or secret_value(args.namespace, args.grafana_secret, "admin-user")
    password = os.getenv("GRAFANA_PASSWORD") or secret_value(args.namespace, args.grafana_secret, "admin-password")

    if args.grafana_url:
        client = GrafanaClient(args.grafana_url, username, password)
        wait_for_grafana(client)
        apply_config(client, config, config_dir)
        return

    proc = start_port_forward(args.namespace, args.grafana_resource, args.local_port, 3000)
    try:
        client = GrafanaClient(f"http://127.0.0.1:{args.local_port}", username, password)
        wait_for_grafana(client)
        apply_config(client, config, config_dir)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)
