#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root_value="$(CDPATH= cd -- "$script_dir_value/.." && pwd)"
xcodegen_binary_value="$("$script_dir_value/bootstrap-xcodegen.sh")"

actual_version_value="$("$xcodegen_binary_value" --version | awk '{print $NF}')"
expected_version_value="$(/usr/bin/jq -er '.toolchain.xcodegen.version' "$repository_root_value/Dependencies/upstreams.lock.json")"
[ "$actual_version_value" = "$expected_version_value" ] || {
  printf 'error: XcodeGen version mismatch: expected %s, got %s\n' "$expected_version_value" "$actual_version_value" >&2
  exit 1
}

"$xcodegen_binary_value" generate \
  --spec "$repository_root_value/project.yml" \
  --project "$repository_root_value"
