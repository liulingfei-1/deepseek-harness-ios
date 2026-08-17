#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root_value="$(CDPATH= cd -- "$script_dir_value/.." && pwd)"
upstream_lock_file_value="${UPSTREAM_LOCK_FILE:-$repository_root_value/Dependencies/upstreams.lock.json}"
upstream_source_root_value="${UPSTREAM_SOURCE_ROOT:-$repository_root_value/Vendor/UpstreamSources}"

fail_upstream_lock() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_upstream_tool() {
  command -v "$1" >/dev/null 2>&1 || fail_upstream_lock "required tool is missing: $1"
}

lock_raw_value() {
  key_path_value="$1"
  /usr/bin/jq -er --arg path "$key_path_value" '
    getpath($path | split("."))
    | if type == "string" then . else tostring end
  ' "$upstream_lock_file_value" 2>/dev/null \
    || fail_upstream_lock "missing lock value: $key_path_value"
}

validate_component_name() {
  case "$1" in
    deepseekHarness|swiftAgentCore|openminis|ishArm64) ;;
    *) fail_upstream_lock "unknown Git upstream: $1" ;;
  esac
}

validate_git_commit() {
  commit_value="$1"
  case "$commit_value" in
    *[!0-9a-f]*|'') fail_upstream_lock "invalid Git commit: $commit_value" ;;
  esac
  [ "${#commit_value}" -eq 40 ] || fail_upstream_lock "Git commit must contain 40 lowercase hex characters"
}

validate_https_url() {
  case "$1" in
    https://*) ;;
    *) fail_upstream_lock "upstream URL must use HTTPS: $1" ;;
  esac
}

component_checkout_path() {
  printf '%s/%s\n' "$upstream_source_root_value" "$1"
}
