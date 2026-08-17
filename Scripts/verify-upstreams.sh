#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root_value="$(CDPATH= cd -- "$script_dir_value/.." && pwd)"
. "$script_dir_value/lib/upstream-lock.sh"

verify_git_upstream() {
  component_value="$1"
  validate_component_name "$component_value"
  repo_value="$(lock_raw_value "$component_value.repository")"
  commit_value="$(lock_raw_value "$component_value.commit")"
  checkout_value="$(component_checkout_path "$component_value")"
  validate_https_url "$repo_value"
  validate_git_commit "$commit_value"

  if [ ! -d "$checkout_value/.git" ]; then
    printf 'Not fetched (metadata verified): %s\n' "$component_value"
    return
  fi

  [ "$(git -C "$checkout_value" remote get-url origin)" = "$repo_value" ] \
    || fail_upstream_lock "origin mismatch for $component_value"
  [ "$(git -C "$checkout_value" rev-parse HEAD^{commit})" = "$commit_value" ] \
    || fail_upstream_lock "checkout revision mismatch for $component_value"
  [ -z "$(git -C "$checkout_value" status --porcelain)" ] \
    || fail_upstream_lock "upstream checkout contains local edits: $checkout_value"
  printf 'Verified checkout: %s\n' "$component_value"
}

verify_gitlink() {
  component_value="$1"
  path_key_value="$2"
  checkout_value="$(component_checkout_path "$component_value")"
  [ -d "$checkout_value/.git" ] || return 0

  path_value="$(lock_raw_value "$component_value.$path_key_value.path")"
  commit_value="$(lock_raw_value "$component_value.$path_key_value.commit")"
  validate_git_commit "$commit_value"
  tree_line_value="$(git -C "$checkout_value" ls-tree HEAD -- "$path_value")"
  actual_value="$(printf '%s\n' "$tree_line_value" | awk '{print $3}')"
  [ "$actual_value" = "$commit_value" ] \
    || fail_upstream_lock "Git link mismatch: $component_value/$path_value"
}

verify_optional_file_hash() {
  relative_path_value="$1"
  expected_hash_value="$2"
  absolute_path_value="$repository_root_value/$relative_path_value"
  [ -f "$absolute_path_value" ] || return 0

  actual_hash_value="$(/usr/bin/shasum -a 256 "$absolute_path_value" | awk '{print $1}')"
  [ "$actual_hash_value" = "$expected_hash_value" ] \
    || fail_upstream_lock "SHA-256 mismatch: $relative_path_value"
  printf 'Verified SHA-256: %s\n' "$relative_path_value"
}

verify_generated_artifacts() {
  artifact_count_value="$(/usr/bin/jq -er '.artifacts | length' "$repository_root_value/Dependencies/artifacts.lock.json")"
  artifact_index_value=0
  while [ "$artifact_index_value" -lt "$artifact_count_value" ]; do
    artifact_path_value="$(/usr/bin/jq -er --argjson index "$artifact_index_value" '.artifacts[$index].path' "$repository_root_value/Dependencies/artifacts.lock.json")"
    artifact_hash_value="$(/usr/bin/jq -er --argjson index "$artifact_index_value" '.artifacts[$index].sha256' "$repository_root_value/Dependencies/artifacts.lock.json")"
    artifact_required_value="$(/usr/bin/jq -er --argjson index "$artifact_index_value" '.artifacts[$index].required | tostring' "$repository_root_value/Dependencies/artifacts.lock.json")"
    case "$artifact_hash_value" in
      *[!0-9a-f]*|'') fail_upstream_lock "invalid artifact SHA-256: $artifact_path_value" ;;
    esac
    [ "${#artifact_hash_value}" -eq 64 ] \
      || fail_upstream_lock "artifact SHA-256 must contain 64 lowercase hex characters: $artifact_path_value"

    if [ "$artifact_required_value" = "true" ]; then
      [ -f "$repository_root_value/$artifact_path_value" ] \
        || fail_upstream_lock "required generated artifact is missing: $artifact_path_value"
    fi
    verify_optional_file_hash "$artifact_path_value" "$artifact_hash_value"
    artifact_index_value=$((artifact_index_value + 1))
  done
}

verify_patch_series() {
  patch_lock_value="$repository_root_value/Dependencies/patches.lock.json"
  patch_count_value="$(/usr/bin/jq -er '.patches | length' "$patch_lock_value")"
  patch_index_value=0
  while [ "$patch_index_value" -lt "$patch_count_value" ]; do
    patch_path_value="$(/usr/bin/jq -er --argjson index "$patch_index_value" '.patches[$index].path' "$patch_lock_value")"
    patch_hash_value="$(/usr/bin/jq -er --argjson index "$patch_index_value" '.patches[$index].sha256' "$patch_lock_value")"
    patch_upstream_value="$(/usr/bin/jq -er --argjson index "$patch_index_value" '.patches[$index].upstream' "$patch_lock_value")"
    patch_base_commit_value="$(/usr/bin/jq -er --argjson index "$patch_index_value" '.patches[$index].baseCommit' "$patch_lock_value")"
    validate_component_name "$patch_upstream_value"
    [ "$patch_base_commit_value" = "$(lock_raw_value "$patch_upstream_value.commit")" ] \
      || fail_upstream_lock "patch base commit is stale: $patch_path_value"
    [ -f "$repository_root_value/$patch_path_value" ] \
      || fail_upstream_lock "recorded patch is missing: $patch_path_value"
    verify_optional_file_hash "$patch_path_value" "$patch_hash_value"
    patch_index_value=$((patch_index_value + 1))
  done
}

require_upstream_tool git
require_upstream_tool /usr/bin/jq
require_upstream_tool /usr/bin/shasum
/usr/bin/jq -e . "$upstream_lock_file_value" >/dev/null
/usr/bin/jq -e . "$repository_root_value/Dependencies/artifacts.lock.json" >/dev/null
/usr/bin/jq -e . "$repository_root_value/Dependencies/patches.lock.json" >/dev/null

schema_value="$(lock_raw_value schemaVersion)"
[ "$schema_value" = "1" ] || fail_upstream_lock "unsupported upstream lock schema: $schema_value"

for component_value in deepseekHarness swiftAgentCore openminis ishArm64; do
  verify_git_upstream "$component_value"
done

verify_gitlink openminis gitlinks.ish
verify_gitlink openminis gitlinks.proot
verify_gitlink ishArm64 submodules.libapps
verify_gitlink ishArm64 submodules.libarchive
verify_gitlink ishArm64 submodules.linux

rootfs_url_value="$(lock_raw_value alpineRootfs.url)"
rootfs_hash_value="$(lock_raw_value alpineRootfs.sha256)"
rootfs_path_value="$(lock_raw_value alpineRootfs.localPath)"
validate_https_url "$rootfs_url_value"
case "$rootfs_hash_value" in
  *[!0-9a-f]*|'') fail_upstream_lock "invalid Alpine SHA-256" ;;
esac
[ "${#rootfs_hash_value}" -eq 64 ] || fail_upstream_lock "Alpine SHA-256 must contain 64 lowercase hex characters"
verify_optional_file_hash "$rootfs_path_value" "$rootfs_hash_value"

xcodegen_url_value="$(lock_raw_value toolchain.xcodegen.url)"
xcodegen_hash_value="$(lock_raw_value toolchain.xcodegen.sha256)"
xcodegen_archive_value="$(lock_raw_value toolchain.xcodegen.localArchivePath)"
validate_https_url "$xcodegen_url_value"
case "$xcodegen_hash_value" in
  *[!0-9a-f]*|'') fail_upstream_lock "invalid XcodeGen SHA-256" ;;
esac
[ "${#xcodegen_hash_value}" -eq 64 ] || fail_upstream_lock "XcodeGen SHA-256 must contain 64 lowercase hex characters"
verify_optional_file_hash "$xcodegen_archive_value" "$xcodegen_hash_value"

fixture_commit_value="$(/usr/bin/jq -er '.source.commit' "$repository_root_value/CompatibilityFixtures/deepseek/harness-wire-v1.json")"
[ "$fixture_commit_value" = "$(lock_raw_value deepseekHarness.commit)" ] \
  || fail_upstream_lock "DeepSeek compatibility fixture does not match the locked Harness commit"
verify_generated_artifacts
verify_patch_series

printf '%s\n' 'Upstream lock verification passed.'
