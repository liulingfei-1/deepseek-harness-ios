#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root_value="$(CDPATH= cd -- "$script_dir_value/.." && pwd)"
artifact_lock_value="$repository_root_value/Dependencies/artifacts.lock.json"

usage() {
  printf 'usage: %s <repository-relative-path> <source-component> [required:true|false]\n' "$0" >&2
  exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
relative_path_value="$1"
source_component_value="$2"
required_value="${3:-true}"

case "$relative_path_value" in
  /*|../*|*/../*|*/..|..) printf 'error: artifact path must remain inside the repository\n' >&2; exit 1 ;;
esac
case "$required_value" in
  true|false) ;;
  *) usage ;;
esac

absolute_path_value="$repository_root_value/$relative_path_value"
[ -f "$absolute_path_value" ] || {
  printf 'error: artifact is missing: %s\n' "$relative_path_value" >&2
  exit 1
}

hash_value="$(/usr/bin/shasum -a 256 "$absolute_path_value" | awk '{print $1}')"
temporary_lock_value="$(mktemp -t harness-artifact-lock.XXXXXX)"
trap 'rm -f "$temporary_lock_value"' EXIT HUP INT TERM

/usr/bin/jq \
  --arg path "$relative_path_value" \
  --arg sha256 "$hash_value" \
  --arg source "$source_component_value" \
  --argjson required "$required_value" \
  '.artifacts = (
    [.artifacts[] | select(.path != $path)]
    + [{path: $path, sha256: $sha256, source: $source, required: $required}]
    | sort_by(.path)
  )' \
  "$artifact_lock_value" > "$temporary_lock_value"
/usr/bin/jq -e . "$temporary_lock_value" >/dev/null
mv "$temporary_lock_value" "$artifact_lock_value"

printf 'Recorded %s  %s\n' "$hash_value" "$relative_path_value"
