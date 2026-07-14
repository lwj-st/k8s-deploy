---
name: k8s-deploy-script-standards
description: Use when creating or editing k8s-deploy shell scripts, especially scripts that read offline artifacts, image tar files, manifests/artifacts.yaml paths, or deploy workloads from offline packages.
---

# k8s-deploy Script Standards

本仓库新建和修改脚本时遵循以下标准。

## 标准

1. 每个脚本都必须有标头，写清重要信息。
2. 非 `00` 开头脚本必须优先以 `manifests/artifacts.yaml` 为准。
3. 所有离线制品、离线包目录和镜像 tar 路径都必须在 `manifests/artifacts.yaml` 声明，并通过 `framework.sh` 中的 helper 获取：
   - 优先用 `artifact_get_path_by_name "<artifact-name>"`。
   - OS 相关 Kubernetes 包目录用 `artifact_get_os_kubernetes_dir "<os_id>"`。
   - OS 相关常用工具目录用 `artifact_get_os_tools_dir "<os_id>"`。
   - NVIDIA toolkit 目录用 `artifact_get_nvidia_toolkit_dir "<os_id>"`。
4. 清单的 `path` 使用绝对路径。路径迁移时只修改 `manifests/artifacts.yaml` 对应条目，脚本不得使用 `DOWNLOAD_DIR` 或硬编码 `/data/download/...`。
5. `00` 开头脚本保留用户传入的输出目录参数；未传入时也必须从清单中的目录制品取得默认值。
6. 脚本只要会部署或应用依赖镜像的组件，就必须在脚本内先 import 需要的离线镜像 tar，不能只依赖 `12-Load-images.sh`。
   - `12-Load-images.sh` 是集中导入入口，但不是其他脚本的前置假设。
   - 每个部署脚本都要做兜底 import，确保单独执行该脚本时也能运行。
   - 镜像 tar 路径同样优先通过 `artifact_get_path_by_name` 从 `manifests/artifacts.yaml` 获取。
   - import 前至少检查文件存在；能做 tar 可读性检查时先检查再导入。
   - 优先使用 `framework.sh` 的 `import_image_artifact` / `import_image_artifacts` / `import_image_tar`。
   - 如脚本已有 `nerdctl/docker` 兼容逻辑，保持一致。
7. 自动检查必须随规范同步更新。
   - 标头字段与镜像兜底检查放在 `tests/check_script_standards.sh`。
   - `DOWNLOAD_DIR` 和直接 `/data/download` 路径检查放在 `tests/check_download_dir_usage.sh`。
   - `00` 下载脚本、`12-Load-images.sh`、公共库脚本不按普通部署脚本检查镜像兜底。

## 脚本标头

新建脚本必须使用这个标头格式；修改旧脚本时，如果触碰脚本开头，顺手补齐缺失字段。

```bash
#!/usr/bin/env bash
################################################################################
## Filename:    28-Example.sh
## Description: 一句话说明脚本做什么
## Usage:
##   bash 28-Example.sh install|upgrade|uninstall
## Artifacts:
##   - manifests/artifacts.yaml: artifact.name.used.by.this.script
## Images:
##   - image.artifact.name.imported.before.deploy
## Env:
##   - REQUIRED_OR_OPTIONAL_ENV: 说明默认值或用途
## Notes:
##   - 重要前置条件、幂等行为、不会做什么
################################################################################
set -euo pipefail
```

字段规则：
- `Filename`、`Description` 必填。
- `Usage` 必填；没有参数也写出实际执行命令。
- `Artifacts` 有离线制品依赖时必填，写 `manifests/artifacts.yaml` 中的 `name`。
- `Images` 脚本会部署镜像时必填，写需要 import 的镜像制品 `name`。
- `Env` 使用环境变量时必填，写默认值、是否必需、影响范围。
- `Notes` 写关键前置条件、幂等性、危险操作、跳过条件。

## 脚本结构

- 标头后立即写 `set -euo pipefail`。
- 普通脚本使用：
  - `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
  - `source "${SCRIPT_DIR}/framework.sh"`
  - 需要完整环境时调用 `init_framework`。
- 会修改系统、安装包、写 Kubernetes 资源的脚本必须 `require_root`。
- 依赖命令用 `have <cmd> || die "缺少 <cmd>..."` 显式检查。
- 对外部命令优先用 `log_command`，保持日志一致。
- 函数放在 `main` 前；脚本末尾使用 `main "$@"`。
- 临时文件必须用 `mktemp`，并用 `trap` 清理。
- 新脚本默认可重复执行；不可重复执行的步骤必须在 `Notes` 和运行日志中说明。
- 部署脚本默认离线运行，不应临时联网下载；下载只能放在 `00` 或明确下载脚本中。
- 删除、覆盖、重启等有风险操作要先检查目标，日志写清楚；不要静默 destructive 操作。

## 修改脚本时

- 先查 `manifests/artifacts.yaml` 是否已有对应 `name`。
- 如果有，新增或修改脚本时引用该 `name`，不要手写制品路径。
- 如果没有，先补充清单；目录型、仅本地预置或无下载 URL 的制品也必须有条目。
- 如果脚本会 `kubectl apply` manifest 或 `helm install/upgrade` chart，检查对应工作负载需要哪些镜像；脚本内必须先导入这些镜像 tar。
- 即使已有 `Script/12-Load-images.sh`，也不要省略单脚本兜底 import。
- 新建脚本必须先写标头，再写代码。
- 修改后运行：

```bash
bash tests/check_script_standards.sh
bash tests/check_download_dir_usage.sh
bash -n Script/*.sh tests/*.sh
```
