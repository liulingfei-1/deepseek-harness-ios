#!/usr/bin/env bash
set -euo pipefail

# Produce a deterministic inventory for the pinned DeepSeek Harness source.
# This is intentionally read-only: it gives an upgrade review a stable list
# of upstream packages and the mobile tool/command surface to compare.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
upstream="$repo_root/Vendor/UpstreamSources/deepseekHarness"
lockfile="$repo_root/Dependencies/upstreams.lock.json"

if [[ ! -d "$upstream" ]]; then
  printf 'upstream checkout missing: %s\n' "$upstream" >&2
  exit 2
fi

locked_commit="$(awk -F'"' '/"deepseekHarness"/{in_section=1} in_section && /"commit"/{print $4; exit}' "$lockfile")"
actual_commit="$(git -C "$upstream" rev-parse HEAD)"
if [[ -z "$locked_commit" || "$locked_commit" != "$actual_commit" ]]; then
  printf 'UPSTREAM_COMMIT_MISMATCH locked=%s actual=%s\n' "${locked_commit:-<missing>}" "$actual_commit" >&2
  exit 1
fi

printf '# DeepSeek Harness parity inventory\n'
printf 'locked_commit: %s\n' "$actual_commit"
printf 'generated_at: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

printf '## Upstream packages\n'
find "$upstream/packages" -mindepth 3 -maxdepth 3 -name package.json -print \
  | sed "s#^$upstream/packages/##; s#/package.json\$##" \
  | LC_ALL=C sort

printf '\n## Mobile tools\n'
rg -o 'name: "[a-zA-Z0-9_:-]+"' "$repo_root/HarnessMobile/Core/Tools" \
  | sed -E 's/^.*name: "([^"]+)"$/\1/' \
  | LC_ALL=C sort -u

printf '\n## Slash commands\n'
rg -o 'name: "[a-zA-Z0-9_-]+"' "$repo_root/HarnessMobile/Core/Commands/SlashCommandCore.swift" \
  | sed -E 's/^.*name: "([^"]+)"$/\1/' \
  | LC_ALL=C sort -u

printf '\n## Review hints\n'
printf '%s\n' '- Compare this inventory after every upstream lock update.'
printf '%s\n' '- A new upstream package is not silently considered implemented; add a parity row and an explicit iOS replacement or TODO.'
printf '%s\n' '- This command never downloads code and never executes upstream plugin code.'
