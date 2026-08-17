#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir_value/lib/upstream-lock.sh"

usage() {
  printf 'usage: %s <deepseekHarness|swiftAgentCore|openminis|ishArm64> <git-ref>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
require_upstream_tool git
require_upstream_tool /usr/bin/jq
component_value="$1"
requested_ref_value="$2"
validate_component_name "$component_value"
repo_value="$(lock_raw_value "$component_value.repository")"
validate_https_url "$repo_value"

temporary_directory_value="$(mktemp -d -t harness-upstream-update.XXXXXX)"
trap 'rm -rf "$temporary_directory_value"' EXIT HUP INT TERM

git -C "$temporary_directory_value" init -q
git -C "$temporary_directory_value" remote add origin "$repo_value"
git -C "$temporary_directory_value" fetch --depth 1 origin "$requested_ref_value"
resolved_commit_value="$(git -C "$temporary_directory_value" rev-parse FETCH_HEAD^{commit})"
validate_git_commit "$resolved_commit_value"

temporary_lock_value="$(mktemp -t harness-upstreams-lock.XXXXXX)"
trap 'rm -rf "$temporary_directory_value"; rm -f "$temporary_lock_value"' EXIT HUP INT TERM
/usr/bin/jq \
  --arg component "$component_value" \
  --arg commit "$resolved_commit_value" \
  '.[$component].commit = $commit' \
  "$upstream_lock_file_value" > "$temporary_lock_value"
/usr/bin/jq -e . "$temporary_lock_value" >/dev/null
mv "$temporary_lock_value" "$upstream_lock_file_value"

printf 'Updated %s lock to %s.\n' "$component_value" "$resolved_commit_value"
printf '%s\n' 'Next: fetch the revision, replay patches, rebuild artifacts, and run Scripts/upgrade-check.sh.'
