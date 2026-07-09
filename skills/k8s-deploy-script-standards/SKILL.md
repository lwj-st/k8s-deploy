---
name: k8s-deploy-script-standards
description: Use when creating or editing k8s-deploy shell scripts, especially scripts that read offline artifacts, image tar files, manifests/artifacts.yaml, /data/download paths, or deploy workloads from offline packages.
---

# k8s-deploy Script Standards

本仓库新建和修改脚本时遵循以下标准。

## 标准

1. 每个脚本都必须有标头，写清重要信息。
2. 非 `00` 开头脚本必须优先以 `manifests/artifacts.yaml` 为准。
3. 清单中已有制品时，通过 `framework.sh` 中的 helper 获取路径：
   - 优先用 `artifact_get_path_by_name "<artifact-name>"`。
   - OS 相关 Kubernetes 包目录用 `artifact_get_os_kubernetes_dir "<os_id>"`。
   - NVIDIA toolkit 基目录用 `artifact_get_nvidia_toolkit_base_dir`。
4. 只有制品清单中没有对应条目，或场景不能自然引用单个制品时，才允许用 `${DOWNLOAD_DIR}/...`。
   - 例如按目录遍历导入所有 `.tar`，或根据运行时变量拼接外部生成目录。
5. `00` 开头脚本是下载/生成制品脚本，不套用非 `00` 脚本的制品路径约束。
6. 不要在运行时代码中硬编码 `/data/download/...`。默认值可以只出现在配置入口或兼容清单旧前缀转换逻辑中。
7. 脚本只要会部署或应用依赖镜像的组件，就必须在脚本内先 import 需要的离线镜像 tar，不能只依赖 `12-Load-images.sh`。
   - `12-Load-images.sh` 是集中导入入口，但不是其他脚本的前置假设。
   - 每个部署脚本都要做兜底 import，确保单独执行该脚本时也能运行。
   - 镜像 tar 路径同样优先通过 `artifact_get_path_by_name` 从 `manifests/artifacts.yaml` 获取。
   - import 前至少检查文件存在；能做 tar 可读性检查时先检查再导入。
   - 优先使用 `framework.sh` 的 `import_image_artifact` / `import_image_artifacts` / `import_image_tar`。
   - 如脚本已有 `nerdctl/docker` 兼容逻辑，保持一致。
8. 自动检查必须随规范同步更新。
   - 标头字段与镜像兜底检查放在 `tests/check_script_standards.sh`。
   - `/data/download` 路径检查放在 `tests/check_download_dir_usage.sh`。
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
- 如果有，新增或修改脚本时引用该 `name`，不要手写 `${DOWNLOAD_DIR}/module/file`。
- 如果没有，判断是否应该先补充清单；确实不能入清单时再用 `${DOWNLOAD_DIR}`，并让用途保持局部、清楚。
- 如果脚本会 `kubectl apply` manifest 或 `helm install/upgrade` chart，检查对应工作负载需要哪些镜像；脚本内必须先导入这些镜像 tar。
- 即使已有 `Script/12-Load-images.sh`，也不要省略单脚本兜底 import。
- 新建脚本必须先写标头，再写代码。
- 修改后运行：

```bash
bash tests/check_script_standards.sh
bash tests/check_download_dir_usage.sh
bash -n Script/*.sh tests/*.sh
```
