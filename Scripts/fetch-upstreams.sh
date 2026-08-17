#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir_value/lib/upstream-lock.sh"

fetch_git_upstream() {
  component_value="$1"
  validate_component_name "$component_value"

  repo_value="$(lock_raw_value "$component_value.repository")"
  commit_value="$(lock_raw_value "$component_value.commit")"
  checkout_value="$(component_checkout_path "$component_value")"
  validate_https_url "$repo_value"
  validate_git_commit "$commit_value"

  mkdir -p "$upstream_source_root_value"
  if [ ! -d "$checkout_value/.git" ]; then
    [ ! -e "$checkout_value" ] || fail_upstream_lock "refusing to replace non-Git path: $checkout_value"
    mkdir "$checkout_value"
    git -C "$checkout_value" init -q
    git -C "$checkout_value" remote add origin "$repo_value"
    git -C "$checkout_value" fetch --filter=blob:none --depth 1 origin "$commit_value"
    fetched_commit_value="$(git -C "$checkout_value" rev-parse FETCH_HEAD^{commit})"
    [ "$fetched_commit_value" = "$commit_value" ] \
      || fail_upstream_lock "server returned a different commit for $component_value"
    git -C "$checkout_value" checkout --detach "$commit_value"
  fi

  configured_repo_value="$(git -C "$checkout_value" remote get-url origin)"
  [ "$configured_repo_value" = "$repo_value" ] \
    || fail_upstream_lock "origin mismatch for $component_value: $configured_repo_value"

  [ -z "$(git -C "$checkout_value" status --porcelain)" ] \
    || fail_upstream_lock "upstream checkout is dirty: $checkout_value"

  if [ "$(git -C "$checkout_value" rev-parse HEAD^{commit})" != "$commit_value" ]; then
    git -C "$checkout_value" fetch --depth 1 origin "$commit_value"
    fetched_commit_value="$(git -C "$checkout_value" rev-parse FETCH_HEAD^{commit})"
    [ "$fetched_commit_value" = "$commit_value" ] \
      || fail_upstream_lock "server returned a different commit for $component_value"
    git -C "$checkout_value" checkout --detach "$commit_value"
  fi
  printf 'Fetched %s at %s\n' "$component_value" "$commit_value"
}

require_upstream_tool git
require_upstream_tool /usr/bin/jq
/usr/bin/jq -e . "$upstream_lock_file_value" >/dev/null

if [ "$#" -eq 0 ]; then
  set -- deepseekHarness swiftAgentCore openminis ishArm64
fi

for component_value in "$@"; do
  fetch_git_upstream "$component_value"
done
