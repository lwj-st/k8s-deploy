#!/usr/bin/env bash
################################################################################
## Filename:    12-Load-images.sh
## Description: 将离线镜像 tar 导入到 containerd（ctr -n k8s.io images import）
## Notes:
##   - 只导入，不下载、不修复坏包（坏包请走 01-Verify/02-Download）
################################################################################
set -euo pipefail

# ---------------------------------------------------------------------------- #
# Global variables / init
# ---------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

################################################################################
# Function: is_tar_readable
# Description: tar 包可读性校验（避免 ctr import 遇到 unexpected EOF）
################################################################################
is_tar_readable() { tar -tf "$1" >/dev/null 2>&1; }

################################################################################
# Function: import_tar
# Description: 导入单个镜像 tar（来自 manifests/artifacts.yaml）
################################################################################
import_tar() {
  local name="$1" file="$2"
  [ -f "${file}" ] || die "缺少镜像 tar: name=${name} path=${file}"
  is_tar_readable "${file}" || die "镜像 tar 不可读/疑似损坏: name=${name} path=${file}（请用 MAAS_MD5_CHECK=1 执行 01-Verify/02-Download 修复）"
  log_command "ctr -n k8s.io images import \"${file}\""
}

################################################################################
# Function: import_from_manifest
# Description: 从 manifests/artifacts.yaml 中导入所有 type=tar 的镜像
################################################################################
import_from_manifest() {
  local manifest="${K8S_DEPLOY_ROOT}/manifests/artifacts.yaml"
  [ -f "${manifest}" ] || die "未找到制品清单: ${manifest}"

  local count=0
  while IFS=$'\x1f' read -r module type name path url md5 desc os_id; do
    [ -n "${module}" ] || continue
    [ "${module}" = "os" ] && continue
    [ "${type}" = "tar" ] || continue
    [[ "${path}" == *.tar ]] || continue
    import_tar "${name}" "${path}"
    count=$((count+1))
  done < <(parse_artifacts_yaml "${manifest}")

  [ "${count}" -gt 0 ] || die "制品清单中未找到任何 type=tar 的镜像条目"
}

################################################################################
# Function: main
# Description: 主逻辑
################################################################################
main() {
  init_framework
  require_root

  have ctr || die "缺少 ctr（containerd 未安装？请先执行 11-Install-containerd.sh）"
  import_from_manifest

  log_info "镜像导入完成"
}

main "$@"


