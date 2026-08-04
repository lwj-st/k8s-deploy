#!/usr/bin/env bash
################################################################################
## Filename:    07-Check-host-info.sh
## Description: 统计宿主机硬件、系统、网络和加速卡信息并做终端友好展示
## Usage:
##   bash 07-Check-host-info.sh
## Env:
##   - NO_COLOR: 设置为任意值时禁用彩色输出
## Notes:
##   - 仅做本机查询，不安装软件、不修改配置、不写文件
##   - 兼容仓库目标系统：Ubuntu/CentOS/Rocky/openEuler/Kylin amd64
##   - 查询命令缺失或权限不足时不会中断；对应字段显示为未知或未检测到
################################################################################
set -uo pipefail

COLOR_RESET=""
COLOR_BOLD=""
COLOR_BLUE=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_DIM=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_RESET="$(printf '\033[0m')"
  COLOR_BOLD="$(printf '\033[1m')"
  COLOR_BLUE="$(printf '\033[34m')"
  COLOR_GREEN="$(printf '\033[32m')"
  COLOR_YELLOW="$(printf '\033[33m')"
  COLOR_DIM="$(printf '\033[2m')"
fi

have() {
  command -v "$1" >/dev/null 2>&1
}

run_out() {
  "$@" 2>/dev/null || true
}

read_first_line() {
  local file="$1"
  if [ -r "${file}" ]; then
    sed -n '1p' "${file}" 2>/dev/null || true
  fi
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//' 2>/dev/null || true
}

value_or_unknown() {
  local value
  value="$(printf '%s' "$1" | trim)"
  if [ -n "${value}" ]; then
    printf '%s\n' "${value}"
  else
    printf '未知\n'
  fi
}

print_title() {
  printf '%s%s%s\n' "${COLOR_BOLD}${COLOR_BLUE}" "宿主机信息统计" "${COLOR_RESET}"
  printf '%s\n' "生成时间: $(date '+%F %T %Z' 2>/dev/null || true)"
}

print_section() {
  printf '\n%s%s%s\n' "${COLOR_BOLD}${COLOR_GREEN}" "$1" "${COLOR_RESET}"
  printf '%s\n' "────────────────────────────────────────────────────────────"
}

print_kv() {
  local key="$1"
  local value="$2"
  printf '  %-18s %s\n' "${key}:" "$(value_or_unknown "${value}")"
}

print_block() {
  local title="$1"
  local content="$2"
  if [ -n "${content}" ]; then
    printf '  %s:\n' "${title}"
    printf '%s\n' "${content}" | sed 's/^/    /'
  else
    printf '  %-18s %s\n' "${title}:" "未检测到"
  fi
}

summary_item() {
  local key="$1"
  local value="$2"
  local padded_key="${key}"
  local width=0
  local i ch

  # 目标宽度按 4 个中文字符计算，即 8 个终端显示列。
  for ((i = 0; i < ${#key}; i++)); do
    ch="${key:i:1}"
    if printf '%s' "${ch}" | LC_ALL=C grep -q '^[ -~]$' 2>/dev/null; then
      width=$((width + 1))
    else
      width=$((width + 2))
    fi
  done
  while [ "${width}" -lt 8 ]; do
    padded_key="${padded_key} "
    width=$((width + 1))
  done

  printf '  %s %s： %s\n' "${COLOR_YELLOW}•${COLOR_RESET}" "${padded_key}" "$(value_or_unknown "${value}")"
}

join_lines() {
  local content="$1"
  if [ -n "${content}" ]; then
    printf '%s\n' "${content}" | awk 'NF { if (out != "") out = out ", "; out = out $0 } END { print out }' 2>/dev/null || true
  else
    printf '未知\n'
  fi
}

os_id=""
os_version_id=""
os_pretty=""
if [ -r /etc/os-release ]; then
  os_id="$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print tolower($2); exit}' /etc/os-release 2>/dev/null || true)"
  os_version_id="$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
  os_pretty="$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
fi

case "${os_id}" in
  kylin*) os_id="kylin" ;;
esac

supported_os="否"
case "${os_id}" in
  ubuntu|centos|rocky|openeuler|kylin) supported_os="是" ;;
esac

arch="$(run_out uname -m | trim)"
supported_arch="否"
if [ "${arch}" = "x86_64" ] || [ "${arch}" = "amd64" ]; then
  supported_arch="是"
fi

host_name="$(run_out hostname -f | trim)"
[ -n "${host_name}" ] || host_name="$(run_out hostname | trim)"
kernel="$(run_out uname -r | trim)"
kernel_full="$(run_out uname -a | trim)"

machine_vendor="$(read_first_line /sys/class/dmi/id/sys_vendor | trim)"
machine_product="$(read_first_line /sys/class/dmi/id/product_name | trim)"
machine_version="$(read_first_line /sys/class/dmi/id/product_version | trim)"
machine_model="$(printf '%s %s %s' "${machine_vendor}" "${machine_product}" "${machine_version}" | trim)"
board_name="$(read_first_line /sys/class/dmi/id/board_name | trim)"
if [ -z "${machine_product}" ] && have dmidecode; then
  machine_product="$(run_out dmidecode -s system-product-name | sed -n '1p' | trim)"
  machine_model="$(printf '%s %s %s' "${machine_vendor}" "${machine_product}" "${machine_version}" | trim)"
fi

print_title

print_section "系统"
print_kv "机型" "${machine_model}"
print_kv "主板" "${board_name}"
print_kv "OS" "${os_pretty:-${os_id} ${os_version_id}}"
print_kv "仓库支持OS" "${supported_os} (${os_id:-unknown} ${os_version_id:-unknown})"
print_kv "架构" "${arch}"
print_kv "仓库支持架构" "${supported_arch}"
print_kv "内核" "${kernel}"
print_kv "主机名" "${host_name}"
print_kv "启动时间" "$(run_out uptime -s | trim)"
print_kv "运行时长" "$(run_out uptime -p | trim)"

print_section "网络"
default_route="$(run_out ip route show default | sed -n '1p' | trim)"
default_iface="$(printf '%s\n' "${default_route}" | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}' 2>/dev/null || true)"
print_kv "默认网卡" "${default_iface}"
print_kv "默认路由" "${default_route}"
if have ip; then
  ipv4_list="$(run_out ip -o -4 addr show scope global | awk '{print $2, $4}' | sort -u)"
  ipv6_list="$(run_out ip -o -6 addr show scope global | awk '{print $2, $4}' | sort -u)"
else
  ipv4_list="$(run_out hostname -I | tr ' ' '\n' | awk '/^[0-9]+\./{print}' | sort -u)"
  ipv6_list="$(run_out hostname -I | tr ' ' '\n' | awk '/:/{print}' | sort -u)"
fi
print_block "IPv4" "${ipv4_list}"
print_block "IPv6" "${ipv6_list}"

print_section "CPU"
if have lscpu; then
  cpu_model="$(run_out lscpu | awk -F: '/Model name/{print $2; exit}' | trim)"
  cpu_socket="$(run_out lscpu | awk -F: '/Socket\(s\)/{print $2; exit}' | trim)"
  cpu_core_per_socket="$(run_out lscpu | awk -F: '/Core\(s\) per socket/{print $2; exit}' | trim)"
  cpu_thread_per_core="$(run_out lscpu | awk -F: '/Thread\(s\) per core/{print $2; exit}' | trim)"
  cpu_total="$(run_out lscpu | awk -F: '/^CPU\(s\)/{print $2; exit}' | trim)"
  cpu_max_mhz="$(run_out lscpu | awk -F: '/CPU max MHz/{print $2; exit}' | trim)"
  cpu_min_mhz="$(run_out lscpu | awk -F: '/CPU min MHz/{print $2; exit}' | trim)"
else
  cpu_model="$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | trim)"
  cpu_total="$(awk -F: '/^processor/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null | trim)"
  cpu_socket="$(awk -F: '/physical id/{s[$2]=1} END{print length(s)}' /proc/cpuinfo 2>/dev/null | trim)"
  cpu_core_per_socket=""
  cpu_thread_per_core=""
  cpu_max_mhz=""
  cpu_min_mhz=""
fi

cpu_cur_mhz=""
cpu_freq_count=0
cpu_freq_sum=0
for freq_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
  [ -r "${freq_file}" ] || continue
  freq_value="$(read_first_line "${freq_file}" | awk '{printf "%.0f", $1/1000}' 2>/dev/null || true)"
  if [ -n "${freq_value}" ]; then
    cpu_freq_sum=$((cpu_freq_sum + freq_value))
    cpu_freq_count=$((cpu_freq_count + 1))
  fi
done
if [ "${cpu_freq_count}" -gt 0 ]; then
  cpu_cur_mhz="$((cpu_freq_sum / cpu_freq_count)) MHz (平均)"
fi

print_kv "型号" "${cpu_model}"
print_kv "总逻辑核数" "${cpu_total}"
print_kv "物理CPU数" "${cpu_socket}"
print_kv "每CPU核心数" "${cpu_core_per_socket}"
print_kv "每核心线程数" "${cpu_thread_per_core}"
print_kv "当前频率" "${cpu_cur_mhz}"
print_kv "最高频率" "${cpu_max_mhz:+${cpu_max_mhz} MHz}"
print_kv "最低频率" "${cpu_min_mhz:+${cpu_min_mhz} MHz}"

print_section "内存"
mem_total=""
mem_used=""
mem_available=""
mem_summary=""
if have free; then
  mem_free_table="$(run_out free -h)"
  print_block "容量" "${mem_free_table}"
  mem_total="$(printf '%s\n' "${mem_free_table}" | awk '/^Mem:/ {print $2; exit}' 2>/dev/null || true)"
  mem_used="$(printf '%s\n' "${mem_free_table}" | awk '/^Mem:/ {print $3; exit}' 2>/dev/null || true)"
  mem_available="$(printf '%s\n' "${mem_free_table}" | awk '/^Mem:/ {print $7; exit}' 2>/dev/null || true)"
else
  mem_total="$(awk '/MemTotal/{printf "%.2f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || true)"
  mem_available="$(awk '/MemAvailable/{printf "%.2f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || true)"
  print_kv "总内存" "${mem_total}"
  print_kv "可用内存" "${mem_available}"
fi
mem_summary="$(printf '总量=%s, 已用=%s, 可用=%s' "$(value_or_unknown "${mem_total}")" "$(value_or_unknown "${mem_used}")" "$(value_or_unknown "${mem_available}")")"
if have dmidecode; then
  mem_slots="$(run_out dmidecode -t memory | awk -F: '
    /Number Of Devices/ {gsub(/^[ \t]+/,"",$2); devices=$2}
    /Size:/ && $2 !~ /No Module Installed/ {used++}
    END {
      if (devices != "") print "内存槽位: " used "/" devices;
      else if (used > 0) print "已安装条数: " used;
    }')"
  [ -n "${mem_slots}" ] && print_block "内存槽位" "${mem_slots}"
fi

print_section "磁盘"
disk_summary=""
if have lsblk; then
  disk_list="$(run_out lsblk -o NAME,TYPE,SIZE,MODEL,ROTA,MOUNTPOINTS | sed -n '1,80p')"
  if [ -z "${disk_list}" ]; then
    disk_list="$(run_out lsblk -o NAME,TYPE,SIZE,MODEL,ROTA,MOUNTPOINT | sed -n '1,80p')"
  fi
  print_block "块设备" "${disk_list}"
  disk_summary="$(run_out lsblk -b -dn -o TYPE,SIZE | awk '
    $1=="disk" {count++; total+=$2}
    END {
      if (count > 0) printf "物理盘=%d, 总容量=%.2f TiB", count, total/1024/1024/1024/1024
    }')"
else
  print_block "块设备" ""
fi
df_list="$(run_out df -hT -x tmpfs -x devtmpfs | sed -n '1,80p')"
print_block "文件系统" "${df_list}"
fs_summary="$(printf '%s\n' "${df_list}" | awk 'NR>1 {count++; size=$3; used=$4; avail=$5; usep=$6} END {if (count > 0) printf "文件系统=%d, 最后一项: size=%s used=%s avail=%s use=%s", count, size, used, avail, usep}' 2>/dev/null || true)"

print_section "GPU / 加速卡"
gpu_found=0
nvidia_summary=""
cuda_version=""
accelerator_summary=""
accelerator_driver_summary=""
accelerator_runtime_summary=""
if have nvidia-smi; then
  gpu_found=1
  nvidia_driver="$(run_out nvidia-smi --query-gpu=driver_version --format=csv,noheader | sed -n '1p' | trim)"
  cuda_version="$(run_out nvidia-smi | awk -F'CUDA Version: ' '/CUDA Version/{print $2}' | awk '{print $1}' | sed -n '1p' | trim)"
  print_kv "NVIDIA驱动" "${nvidia_driver}"
  print_kv "CUDA版本" "${cuda_version}"
  nvidia_gpus="$(run_out nvidia-smi --query-gpu=index,name,pci.bus_id,memory.total,clocks.current.graphics,clocks.current.memory,power.draw,temperature.gpu --format=csv,noheader,nounits)"
  print_block "NVIDIA GPU" "${nvidia_gpus}"
  nvidia_summary="$(printf '%s\n' "${nvidia_gpus}" | awk -F, '
    NF >= 4 {
      count++;
      name=$2; gsub(/^[ \t]+|[ \t]+$/, "", name);
      mem=$4; gsub(/^[ \t]+|[ \t]+$/, "", mem);
      names[name]=1;
      total_mem+=mem;
    }
    END {
      for (n in names) {
        if (name_list != "") name_list=name_list "/";
        name_list=name_list n;
      }
      if (count > 0) printf "%d 张, 型号=%s, 总显存=%d MiB", count, name_list, total_mem;
    }')"
  accelerator_summary="NVIDIA: $(value_or_unknown "${nvidia_summary}")"
  accelerator_driver_summary="NVIDIA=${nvidia_driver:-未知}"
  accelerator_runtime_summary="CUDA=${cuda_version:-未知}"
else
  nvidia_proc="$(read_first_line /proc/driver/nvidia/version | trim)"
  [ -n "${nvidia_proc}" ] && gpu_found=1
  if [ -n "${nvidia_proc}" ]; then
    print_kv "NVIDIA驱动" "${nvidia_proc}"
    accelerator_summary="NVIDIA驱动已加载: ${nvidia_proc}"
    accelerator_driver_summary="NVIDIA=${nvidia_proc}"
  fi
fi

if have npu-smi; then
  gpu_found=1
  ascend_info="$(run_out npu-smi info | sed -n '1,120p')"
  print_block "Ascend NPU" "${ascend_info}"
  accelerator_summary="${accelerator_summary:+${accelerator_summary}; }Ascend NPU: 已检测到"
  accelerator_driver_summary="${accelerator_driver_summary:+${accelerator_driver_summary}; }Ascend=npu-smi 可用，版本见明细"
  if [ -r /usr/local/Ascend/ascend-toolkit/latest/version.info ]; then
    # shellcheck disable=SC2016 # awk 程序需要原样传入，未使用 shell 变量展开。
    ascend_cann_version="$(run_out awk -F= '/Version=|version=/{print $2; exit}' /usr/local/Ascend/ascend-toolkit/latest/version.info | trim)"
    accelerator_runtime_summary="${accelerator_runtime_summary:+${accelerator_runtime_summary}; }CANN=${ascend_cann_version:-version.info 可读}"
  else
    accelerator_runtime_summary="${accelerator_runtime_summary:+${accelerator_runtime_summary}; }CANN=未检测到"
  fi
fi

if have rocm-smi; then
  gpu_found=1
  dcu_info="$(run_out rocm-smi --showproductname --showdriverversion --showmeminfo vram --showclocks | sed -n '1,120p')"
  print_block "Hygon DCU/ROCm" "${dcu_info}"
  accelerator_summary="${accelerator_summary:+${accelerator_summary}; }Hygon DCU/ROCm: 已检测到"
  accelerator_driver_summary="${accelerator_driver_summary:+${accelerator_driver_summary}; }Hygon DCU=rocm-smi 可用，版本见明细"
  accelerator_runtime_summary="${accelerator_runtime_summary:+${accelerator_runtime_summary}; }ROCm=rocm-smi 可用"
elif have hy-smi; then
  gpu_found=1
  dcu_info="$(run_out hy-smi | sed -n '1,120p')"
  print_block "Hygon DCU" "${dcu_info}"
  accelerator_summary="${accelerator_summary:+${accelerator_summary}; }Hygon DCU: 已检测到"
  accelerator_driver_summary="${accelerator_driver_summary:+${accelerator_driver_summary}; }Hygon DCU=hy-smi 可用，版本见明细"
fi

if have ixsmi; then
  gpu_found=1
  ix_info="$(run_out ixsmi | sed -n '1,120p')"
  print_block "Iluvatar" "${ix_info}"
  accelerator_summary="${accelerator_summary:+${accelerator_summary}; }Iluvatar: 已检测到"
  accelerator_driver_summary="${accelerator_driver_summary:+${accelerator_driver_summary}; }Iluvatar=ixsmi 可用，版本见明细"
fi

if have lspci; then
  pci_accel="$(run_out lspci | grep -Ei 'vga|3d|display|nvidia|huawei|ascend|hygon|iluvatar|amd/ati' | sed -n '1,120p')"
  [ -n "${pci_accel}" ] && gpu_found=1
  print_block "PCI设备" "${pci_accel}"
fi

if [ "${gpu_found}" -eq 0 ]; then
  printf '  %s\n' "未检测到 GPU/NPU/DCU 或相关查询工具不可用"
  accelerator_summary="未检测到 GPU/NPU/DCU 或相关查询工具不可用"
  accelerator_driver_summary="未知"
  accelerator_runtime_summary="未知"
fi

print_section "驱动 / 内核模块"
module_list=""
if have lsmod; then
  module_list="$(run_out lsmod | awk '/nvidia|nouveau|amdgpu|kfd|hisi|drv_pcie_host|iluvatar|ix/ {print}' | sed -n '1,80p')"
fi
print_block "相关模块" "${module_list}"

print_section "容器 / Kubernetes"
runtime_summary=""
for cmd in containerd ctr crictl docker podman kubelet kubeadm kubectl helm helmfile; do
  if have "${cmd}"; then
    version_line="$(run_out "${cmd}" --version | sed -n '1p' | trim)"
    [ -n "${version_line}" ] || version_line="已安装"
    printf '  %-18s %s\n' "${cmd}:" "${version_line}"
    runtime_summary="${runtime_summary:+${runtime_summary}; }${cmd}=已安装"
  else
    printf '  %-18s %s%s%s\n' "${cmd}:" "${COLOR_DIM}" "未安装/未在PATH" "${COLOR_RESET}"
  fi
done

print_section "汇总"
summary_item "机型" "${machine_model}"
summary_item "OS" "${os_pretty:-${os_id} ${os_version_id}}"
summary_item "支持" "OS=${supported_os}, 架构=${supported_arch}"
summary_item "架构" "${arch}"
summary_item "主机" "${host_name}"
summary_item "内核" "${kernel}"
summary_item "全内核" "${kernel_full}"
summary_item "网卡" "${default_iface}"
summary_item "路由" "${default_route}"
summary_item "IPv4" "$(join_lines "${ipv4_list}")"
summary_item "IPv6" "$(join_lines "${ipv6_list}")"
summary_item "CPU" "${cpu_model}"
summary_item "核数" "逻辑核=${cpu_total:-未知}, 物理CPU=${cpu_socket:-未知}, 每CPU核心=${cpu_core_per_socket:-未知}, 每核心线程=${cpu_thread_per_core:-未知}"
summary_item "频率" "当前=$(value_or_unknown "${cpu_cur_mhz}"), 最高=$(value_or_unknown "${cpu_max_mhz:+${cpu_max_mhz} MHz}"), 最低=$(value_or_unknown "${cpu_min_mhz:+${cpu_min_mhz} MHz}")"
summary_item "内存" "${mem_summary}"
summary_item "磁盘" "${disk_summary:-${fs_summary}}"
summary_item "加速卡" "${accelerator_summary}"
summary_item "驱动" "${accelerator_driver_summary}"
summary_item "运行时" "${accelerator_runtime_summary}"
summary_item "模块" "$(printf '%s\n' "${module_list}" | awk '{print $1}' | sort -u | awk 'NF' ORS=', ' | sed 's/, $//' 2>/dev/null || true)"
summary_item "容器" "$(printf '%s\n' "${runtime_summary}" | sed 's/; /, /g' 2>/dev/null || true)"
printf '\n'
