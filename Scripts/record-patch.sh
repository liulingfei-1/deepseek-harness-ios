#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root_value="$(CDPATH= cd -- "$script_dir_value/.." && pwd)"
. "$script_dir_value/lib/upstream-lock.sh"

usage() {
  printf 'usage: %s <repository-relative-patch-path> <upstream-component>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
relative_path_value="$1"
component_value="$2"
validate_component_name "$component_value"
case "$relative_path_value" in
  /*|../*|*/../*|*/..|..) fail_upstream_lock "patch path must remain inside the repository" ;;
esac

absolute_path_value="$repository_root_value/$relative_path_value"
[ -f "$absolute_path_value" ] || fail_upstream_lock "patch is missing: $relative_path_value"
hash_value="$(/usr/bin/shasum -a 256 "$absolute_path_value" | awk '{print $1}')"
base_commit_value="$(lock_raw_value "$component_value.commit")"
patch_lock_value="$repository_root_value/Dependencies/patches.lock.json"
temporary_lock_value="$(mktemp -t harness-patch-lock.XXXXXX)"
trap 'rm -f "$temporary_lock_value"' EXIT HUP INT TERM

/usr/bin/jq \
  --arg path "$relative_path_value" \
  --arg sha256 "$hash_value" \
  --arg upstream "$component_value" \
  --arg baseCommit "$base_commit_value" \
  '.patches = (
    [.patches[] | select(.path != $path)]
    + [{path: $path, sha256: $sha256, upstream: $upstream, baseCommit: $baseCommit}]
    | sort_by(.path)
  )' \
  "$patch_lock_value" > "$temporary_lock_value"
/usr/bin/jq -e . "$temporary_lock_value" >/dev/null
mv "$temporary_lock_value" "$patch_lock_value"

printf 'Recorded patch %s  %s\n' "$hash_value" "$relative_path_value"
