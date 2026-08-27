#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root_value="$(CDPATH= cd -- "$script_dir_value/.." && pwd)"
swift_scratch_path_value="${HARNESS_SWIFT_SCRATCH_PATH:-${TMPDIR:-/tmp}/harnessmobile-swift-build}"

"$script_dir_value/verify-upstreams.sh"
"$script_dir_value/audit-no-remote-execution.sh"
"$script_dir_value/verify-capability-manifest.sh"
swift test \
  --package-path "$repository_root_value" \
  --scratch-path "$swift_scratch_path_value"

printf '%s\n' 'Upgrade compatibility checks passed.'
