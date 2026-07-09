#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0

has_header_field() {
  local header="$1" field="$2"
  grep -q "^## ${field}:" <<<"${header}"
}

is_download_or_library_script() {
  local rel="$1"
  case "${rel}" in
    Script/00-*.sh|Script/12-Load-images.sh|Script/framework.sh|Script/log.sh|Script/environment.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

for script in "${ROOT_DIR}"/Script/*.sh; do
  rel="${script#"${ROOT_DIR}/"}"
  header="$(sed -n '1,40p' "${script}")"
  content="$(sed -n '1,$p' "${script}")"

  if ! grep -q '^#!/usr/bin/env bash$' <<<"${header}"; then
    echo "${rel}: 缺少 shebang: #!/usr/bin/env bash" >&2
    failed=1
  fi
  if ! grep -q '^## Filename:' <<<"${header}"; then
    echo "${rel}: 缺少标头字段 Filename" >&2
    failed=1
  fi
  if ! grep -q '^## Description:' <<<"${header}"; then
    echo "${rel}: 缺少标头字段 Description" >&2
    failed=1
  fi
  if ! grep -q '^## Usage:' <<<"${header}"; then
    echo "${rel}: 缺少标头字段 Usage" >&2
    failed=1
  fi

  if ! is_download_or_library_script "${rel}" && grep -q 'artifact_get_path_by_name' <<<"${content}" && ! has_header_field "${header}" "Artifacts"; then
    echo "${rel}: 使用 artifact_get_path_by_name 但标头缺少 Artifacts" >&2
    failed=1
  fi

  if ! is_download_or_library_script "${rel}" && grep -Eq 'import_image_tar|import_image_artifact|import_image_artifacts|images import|nerdctl .*load|docker load' <<<"${content}"; then
    if ! has_header_field "${header}" "Images"; then
      echo "${rel}: 导入镜像但标头缺少 Images" >&2
      failed=1
    fi
  fi

  if ! is_download_or_library_script "${rel}" && has_header_field "${header}" "Images"; then
    if ! grep -Eq 'import_image_tar|import_image_artifact|import_image_artifacts|images import|nerdctl .*load|docker load' <<<"${content}"; then
      echo "${rel}: 标头声明 Images 但脚本内没有镜像导入兜底" >&2
      failed=1
    fi
  fi
done

exit "${failed}"
