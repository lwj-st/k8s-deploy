#!/usr/bin/env bash
# Source this file from a download container after defining log().

apply_package_repos() {
  local os_id="$1" os_version="$2"
  local repo_dir="/repo-config/${os_id}/${os_version}"

  [ -d "${repo_dir}" ] || return 0
  PACKAGE_REPOS_APPLIED=1

  if [ -d "${repo_dir}/apt" ]; then
    log "应用版本化 APT 源: ${os_id}-${os_version}"
    rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources
    mkdir -p /etc/apt/sources.list.d
    cp -a "${repo_dir}/apt/." /etc/apt/
  fi

  if [ -d "${repo_dir}/yum.repos.d" ]; then
    log "应用版本化 YUM/DNF 源: ${os_id}-${os_version}"
    rm -f /etc/yum.repos.d/*.repo
    mkdir -p /etc/yum.repos.d
    cp -a "${repo_dir}/yum.repos.d/." /etc/yum.repos.d/
  fi
}
