#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root_value="$(CDPATH= cd -- "$script_dir_value/.." && pwd)"
. "$script_dir_value/lib/upstream-lock.sh"

require_upstream_tool /usr/bin/curl
require_upstream_tool /usr/bin/jq
require_upstream_tool /usr/bin/shasum
require_upstream_tool /usr/bin/unzip

version_value="$(lock_raw_value toolchain.xcodegen.version)"
url_value="$(lock_raw_value toolchain.xcodegen.url)"
hash_value="$(lock_raw_value toolchain.xcodegen.sha256)"
archive_relative_value="$(lock_raw_value toolchain.xcodegen.localArchivePath)"
archive_value="$repository_root_value/$archive_relative_value"
install_value="$repository_root_value/.tools/xcodegen/$version_value"
binary_value="$install_value/bin/xcodegen"

validate_https_url "$url_value"

if [ -x "$binary_value" ]; then
  printf '%s\n' "$binary_value"
  exit 0
fi

mkdir -p "$(dirname -- "$archive_value")" "$(dirname -- "$install_value")"
if [ ! -f "$archive_value" ]; then
  temporary_archive_value="$(mktemp -t xcodegen-download.XXXXXX)"
  trap 'rm -f "$temporary_archive_value"' EXIT HUP INT TERM
  /usr/bin/curl --fail --location --output "$temporary_archive_value" "$url_value"
  actual_hash_value="$(/usr/bin/shasum -a 256 "$temporary_archive_value" | awk '{print $1}')"
  [ "$actual_hash_value" = "$hash_value" ] \
    || fail_upstream_lock "downloaded XcodeGen archive failed SHA-256 verification"
  mv "$temporary_archive_value" "$archive_value"
fi

actual_hash_value="$(/usr/bin/shasum -a 256 "$archive_value" | awk '{print $1}')"
[ "$actual_hash_value" = "$hash_value" ] \
  || fail_upstream_lock "cached XcodeGen archive failed SHA-256 verification"

temporary_directory_value="$(mktemp -d -t xcodegen-install.XXXXXX)"
trap 'rm -rf "$temporary_directory_value"' EXIT HUP INT TERM
/usr/bin/unzip -q "$archive_value" -d "$temporary_directory_value"
[ -x "$temporary_directory_value/xcodegen/bin/xcodegen" ] \
  || fail_upstream_lock "XcodeGen archive layout is not recognized"
[ ! -e "$install_value" ] || fail_upstream_lock "refusing to replace existing XcodeGen path: $install_value"
mv "$temporary_directory_value/xcodegen" "$install_value"

printf '%s\n' "$binary_value"
