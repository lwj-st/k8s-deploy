#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

stub_bin="${tmp_dir}/bin"
mkdir -p "${stub_bin}"
docker_log="${tmp_dir}/docker.log"
export DOWNLOAD_SCRIPT_TEST_LOG="${docker_log}"

cat > "${stub_bin}/docker" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  pull)
    printf 'docker pull' >> "${DOWNLOAD_SCRIPT_TEST_LOG}"
    shift
    for arg in "$@"; do printf ' %q' "${arg}" >> "${DOWNLOAD_SCRIPT_TEST_LOG}"; done
    printf '\n' >> "${DOWNLOAD_SCRIPT_TEST_LOG}"
    ;;
  ps)
    ;;
  run)
    printf 'docker run' >> "${DOWNLOAD_SCRIPT_TEST_LOG}"
    shift
    for arg in "$@"; do printf ' %q' "${arg}" >> "${DOWNLOAD_SCRIPT_TEST_LOG}"; done
    printf '\n' >> "${DOWNLOAD_SCRIPT_TEST_LOG}"
    ;;
  *)
    printf 'unexpected docker command: %s\n' "$*" >&2
    exit 1
    ;;
esac
STUB_EOF
chmod +x "${stub_bin}/docker"

PATH="${stub_bin}:${PATH}" \
  bash "${ROOT_DIR}/Script/00-Download-k8s-packages-docker.sh" \
    rocky 9.3 "${tmp_dir}/k8s-rpm" 1.31.11 arm64

PATH="${stub_bin}:${PATH}" \
  bash "${ROOT_DIR}/Script/00-Download-tools-packages-docker.sh" \
    rocky 9.3 "${tmp_dir}/tools-rpm" arm64

PATH="${stub_bin}:${PATH}" \
  bash "${ROOT_DIR}/Script/00-Download-nvidia-packages-docker.sh" \
    rocky 9.3 "${tmp_dir}/nvidia-rpm" arm64

platform_count="$(grep -c -- '--platform linux/arm64/v8' "${docker_log}")"
if [ "${platform_count}" -ne 3 ]; then
  echo "期望 3 个 Docker 下载脚本都使用 --platform linux/arm64/v8，实际 ${platform_count}" >&2
  cat "${docker_log}" >&2
  exit 1
fi

aarch64_count="$(grep -c -- ' aarch64' "${docker_log}")"
if [ "${aarch64_count}" -ne 3 ]; then
  echo "期望 3 个 Docker 下载脚本都把 aarch64 传入容器内下载脚本，实际 ${aarch64_count}" >&2
  cat "${docker_log}" >&2
  exit 1
fi

if grep -R -n -E -- '--platform linux/amd64|--arch=x86_64|--archlist=x86_64|repotrack -a x86_64' \
  "${ROOT_DIR}/Script/00-Download-k8s-packages.sh" \
  "${ROOT_DIR}/Script/00-Download-k8s-packages-docker.sh" \
  "${ROOT_DIR}/Script/00-Download-tools-packages.sh" \
  "${ROOT_DIR}/Script/00-Download-tools-packages-docker.sh" \
  "${ROOT_DIR}/Script/00-Download-nvidia-packages-docker.sh"; then
  echo "下载脚本仍存在 x86_64/linux-amd64 下载参数硬编码" >&2
  exit 1
fi

for script in \
  "${ROOT_DIR}/Script/00-Download-k8s-packages.sh" \
  "${ROOT_DIR}/Script/00-Download-k8s-packages-docker.sh" \
  "${ROOT_DIR}/Script/00-Download-tools-packages.sh" \
  "${ROOT_DIR}/Script/00-Download-tools-packages-docker.sh" \
  "${ROOT_DIR}/Script/00-Download-nvidia-packages-docker.sh"; do
  grep -q 'set_arch_vars "${REQUESTED_ARCH}"' "${script}" || {
    echo "${script}: 未通过 REQUESTED_ARCH 初始化架构变量" >&2
    exit 1
  }
done
