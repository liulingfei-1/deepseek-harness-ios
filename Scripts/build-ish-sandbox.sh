#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
lock_file="$repository_root/Dependencies/upstreams.lock.json"
component_dir="$repository_root/Vendor/OpenMinisISH"
artifact_dir="$component_dir/Artifacts"
download_dir="$component_dir/downloads"

action="${1:-all}"
network_policy="${ISH_GUEST_NETWORK_DEFAULT:-enabled}"
meson_version="${ISH_MESON_VERSION:-1.9.2}"
meson_release_url="${ISH_MESON_RELEASE_URL:-https://github.com/mesonbuild/meson/releases/download/$meson_version/meson-$meson_version.tar.gz}"
meson_release_sha256="${ISH_MESON_RELEASE_SHA256:-}"
archive_timestamp="${ISH_ARCHIVE_TIMESTAMP:-202001010000.00}"
source_date_epoch="${SOURCE_DATE_EPOCH:-1577836800}"

if [ -z "$meson_release_sha256" ] && [ "$meson_version" = "1.9.2" ]; then
  meson_release_sha256="3499b59bb23982496e01e57b4103ac2f826f9c3a3f59e507a0a832487fe55e3d"
fi

log() {
  printf '[iSH] %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool is missing: $1"
}

lock_value() {
  /usr/bin/jq -er "$1" "$lock_file" 2>/dev/null \
    || fail "missing or invalid lock value: $1"
}

usage() {
  cat >&2 <<'EOF'
usage: Scripts/build-ish-sandbox.sh [all|libraries|rootfs|clean]

Environment:
  DEVELOPER_DIR                    Xcode developer directory
  ISH_GUEST_NETWORK_DEFAULT        enabled (default) or disabled
  ISH_KEEP_BUILD_DIR               1 to preserve the temporary build tree
  ISH_MESON                        path to a Meson executable
  ISH_MESON_VERSION                Meson version (default: 1.9.2)
  ISH_MESON_RELEASE_URL            official release archive override
  ISH_MESON_RELEASE_SHA256         required when overriding the Meson version
  ISH_NINJA                        path to a Ninja executable
  ISH_LIBARCHIVE_PREFIX            Homebrew libarchive prefix
EOF
  exit 2
}

case "$action" in
  all|libraries|rootfs|clean) ;;
  -h|--help) usage ;;
  *) usage ;;
esac

case "$network_policy" in
  enabled) network_default=1 ;;
  disabled) network_default=0 ;;
  *) fail "ISH_GUEST_NETWORK_DEFAULT must be enabled or disabled" ;;
esac

if [ "$action" = "clean" ]; then
  [ "$artifact_dir" != "$repository_root" ] || fail "refusing to remove repository root"
  rm -rf "$artifact_dir"
  log "removed $artifact_dir"
  exit 0
fi

require_tool git
require_tool /usr/bin/jq
require_tool /usr/bin/shasum
require_tool /usr/bin/tar
require_tool /usr/bin/patch
require_tool /usr/bin/zip
require_tool /usr/bin/unzip
require_tool /usr/bin/curl
require_tool /usr/bin/python3
require_tool /usr/bin/sed
require_tool /usr/bin/find
require_tool /usr/bin/xcodebuild
require_tool /usr/bin/plutil

[ -f "$lock_file" ] || fail "upstream lock is missing: $lock_file"
/usr/bin/jq -e . "$lock_file" >/dev/null

ish_commit="$(lock_value '.ishArm64.commit')"
ish_repository="$(lock_value '.ishArm64.repository')"
openminis_commit="$(lock_value '.openminis.commit')"
openminis_repository="$(lock_value '.openminis.repository')"
alpine_version="$(lock_value '.alpineRootfs.version')"
alpine_url="$(lock_value '.alpineRootfs.url')"
alpine_sha256="$(lock_value '.alpineRootfs.sha256')"
alpine_local_path="$(lock_value '.alpineRootfs.localPath')"
deployment_target="$(lock_value '.toolchain.minimumIOS')"

ish_checkout="$repository_root/Vendor/UpstreamSources/ishArm64"
openminis_checkout="$repository_root/Vendor/UpstreamSources/openminis"
network_patch="$component_dir/patches/0001-guest-network-policy.patch"
bridge_patch="$component_dir/patches/0002-minimal-openminis-ish-bridge.patch"
abi_offsets_patch="$component_dir/patches/0003-ish-bridge-abi-offsets.patch"
bridge_abi_guard_patch="$component_dir/patches/0004-openminis-ish-abi-guard.patch"
task_start_patch="$component_dir/patches/0005-checked-task-start.patch"
runtime_robustness_patch="$component_dir/patches/0006-ish-runtime-robustness.patch"
persistent_process_patch="$component_dir/patches/0007-persistent-process-stdin.patch"

verify_checkout() {
  local checkout="$1"
  local repository="$2"
  local commit="$3"
  local label="$4"

  [ -d "$checkout/.git" ] || fail "$label checkout is missing: $checkout"
  [ "$(git -C "$checkout" remote get-url origin)" = "$repository" ] \
    || fail "$label origin does not match the lock"
  [ "$(git -C "$checkout" rev-parse HEAD^{commit})" = "$commit" ] \
    || fail "$label checkout does not match the locked commit"
  [ -z "$(git -C "$checkout" status --porcelain --untracked-files=all)" ] \
    || fail "$label checkout contains local changes"
}

verify_gitlink() {
  local checkout="$1"
  local commit="$2"
  local path="$3"
  local expected="$4"
  local actual
  actual="$(git -C "$checkout" ls-tree "$commit" -- "$path" | awk '{print $3}')"
  [ "$actual" = "$expected" ] || fail "locked gitlink mismatch: $path"
}

verify_checkout "$ish_checkout" "$ish_repository" "$ish_commit" "ishArm64"
verify_checkout "$openminis_checkout" "$openminis_repository" "$openminis_commit" "OpenMinis"

verify_gitlink "$ish_checkout" "$ish_commit" \
  "$(lock_value '.ishArm64.submodules.libapps.path')" \
  "$(lock_value '.ishArm64.submodules.libapps.commit')"
verify_gitlink "$ish_checkout" "$ish_commit" \
  "$(lock_value '.ishArm64.submodules.libarchive.path')" \
  "$(lock_value '.ishArm64.submodules.libarchive.commit')"
verify_gitlink "$ish_checkout" "$ish_commit" \
  "$(lock_value '.ishArm64.submodules.linux.path')" \
  "$(lock_value '.ishArm64.submodules.linux.commit')"
verify_gitlink "$openminis_checkout" "$openminis_commit" \
  "$(lock_value '.openminis.gitlinks.ish.path')" \
  "$(lock_value '.openminis.gitlinks.ish.commit')"

[ -f "$network_patch" ] || fail "network policy patch is missing: $network_patch"
[ -f "$bridge_patch" ] || fail "OpenMinis bridge patch is missing: $bridge_patch"
[ -f "$abi_offsets_patch" ] || fail "iSH ABI offsets patch is missing: $abi_offsets_patch"
[ -f "$bridge_abi_guard_patch" ] || fail "OpenMinis ABI guard patch is missing: $bridge_abi_guard_patch"
[ -f "$task_start_patch" ] || fail "checked task-start patch is missing: $task_start_patch"
[ -f "$runtime_robustness_patch" ] || fail "iSH runtime robustness patch is missing: $runtime_robustness_patch"
[ -f "$persistent_process_patch" ] || fail "persistent process patch is missing: $persistent_process_patch"

developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
[ -d "$developer_dir" ] || fail "invalid DEVELOPER_DIR: $developer_dir"
export DEVELOPER_DIR="$developer_dir"
export SOURCE_DATE_EPOCH="$source_date_epoch"

xcrun_tool() {
  /usr/bin/xcrun --find "$1" 2>/dev/null || fail "Xcode tool is missing: $1"
}

clang="$(xcrun_tool clang)"
swiftc="$(xcrun_tool swiftc)"
ar="$(xcrun_tool ar)"
strip="$(xcrun_tool strip)"
libtool="$(xcrun_tool libtool)"
lipo="$(xcrun_tool lipo)"
nm="$(xcrun_tool nm)"

iphoneos_sdk="$(/usr/bin/xcrun --sdk iphoneos --show-sdk-path)"
iphonesimulator_sdk="$(/usr/bin/xcrun --sdk iphonesimulator --show-sdk-path)"

resolve_meson() {
  if [ -n "${ISH_MESON:-}" ]; then
    [ -x "$ISH_MESON" ] || fail "ISH_MESON is not executable: $ISH_MESON"
    printf '%s\n' "$ISH_MESON"
    return
  fi
  if command -v meson >/dev/null 2>&1; then
    command -v meson
    return
  fi

  local release_dir="$repository_root/.tools/meson-$meson_version-source"
  local archive="$repository_root/.tools/downloads/meson-$meson_version.tar.gz"
  local actual=""
  local staging=""

  if [ -x "$release_dir/meson.py" ]; then
    printf '%s\n' "$release_dir/meson.py"
    return
  fi

  [ -n "$meson_release_sha256" ] \
    || fail "ISH_MESON_RELEASE_SHA256 is required for Meson $meson_version"
  mkdir -p "$repository_root/.tools/downloads"

  if [ -f "$archive" ]; then
    actual="$(/usr/bin/shasum -a 256 "$archive" | awk '{print $1}')"
    if [ "$actual" != "$meson_release_sha256" ]; then
      log "discarding Meson archive with an invalid checksum"
      rm -f "$archive"
    fi
  fi

  if [ ! -f "$archive" ]; then
    log "downloading official Meson $meson_version release"
    /usr/bin/curl --fail --location --retry 5 --retry-all-errors \
      --output "$archive.part" "$meson_release_url"
    actual="$(/usr/bin/shasum -a 256 "$archive.part" | awk '{print $1}')"
    if [ "$actual" != "$meson_release_sha256" ]; then
      rm -f "$archive.part"
      fail "Meson SHA-256 mismatch"
    fi
    mv "$archive.part" "$archive"
  fi

  staging="$(mktemp -d "$repository_root/.tools/.meson-$meson_version.XXXXXX")"
  /usr/bin/tar -xzf "$archive" --strip-components=1 -C "$staging"
  [ -f "$staging/meson.py" ] || fail "Meson release does not contain meson.py"
  chmod +x "$staging/meson.py"
  mv "$staging" "$release_dir"
  printf '%s\n' "$release_dir/meson.py"
}

meson="$(resolve_meson)"
if [ -n "${ISH_NINJA:-}" ]; then
  ninja="$ISH_NINJA"
else
  ninja="$(command -v ninja || true)"
fi
[ -n "$ninja" ] && [ -x "$ninja" ] || fail "Ninja is required"

llvm_clang=""
for candidate in \
  /opt/homebrew/opt/llvm/bin/clang \
  /usr/local/opt/llvm/bin/clang \
  /opt/local/bin/clang; do
  if [ -x "$candidate" ]; then
    llvm_clang="$candidate"
    break
  fi
done
[ -n "$llvm_clang" ] || fail "Homebrew/MacPorts LLVM clang is required for the ARM64 Linux VDSO"

lld="$(command -v ld.lld || true)"
[ -n "$lld" ] && [ -x "$lld" ] || fail "ld.lld is required for the ARM64 Linux VDSO"

libarchive_prefix="${ISH_LIBARCHIVE_PREFIX:-}"
if [ -z "$libarchive_prefix" ]; then
  for candidate in /opt/homebrew/opt/libarchive /usr/local/opt/libarchive; do
    if [ -f "$candidate/lib/libarchive.dylib" ] || [ -f "$candidate/lib/libarchive.a" ]; then
      libarchive_prefix="$candidate"
      break
    fi
  done
fi
[ -n "$libarchive_prefix" ] || fail "libarchive is required to create the fakefs rootfs"

path_parts="$(dirname "$meson"):$(dirname "$ninja"):$(dirname "$lld"):$(dirname "$llvm_clang")"
export PATH="$path_parts:$PATH"
export CPPFLAGS="-I$libarchive_prefix/include${CPPFLAGS:+ $CPPFLAGS}"
export CFLAGS="-I$libarchive_prefix/include${CFLAGS:+ $CFLAGS}"
export LDFLAGS="-L$libarchive_prefix/lib${LDFLAGS:+ $LDFLAGS}"
export PKG_CONFIG_PATH="$libarchive_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-ish-build.XXXXXX")"
cleanup() {
  if [ "${ISH_KEEP_BUILD_DIR:-0}" = "1" ]; then
    log "preserved build directory: $work_root"
  else
    rm -rf "$work_root"
  fi
}
trap cleanup EXIT HUP INT TERM

source_dir="$work_root/source"
openminis_source_dir="$work_root/openminis-source"
mkdir -p "$source_dir"
mkdir -p "$openminis_source_dir"
git -C "$ish_checkout" archive "$ish_commit" | /usr/bin/tar -xf - -C "$source_dir"
git -C "$openminis_checkout" archive "$openminis_commit" \
  | /usr/bin/tar -xf - -C "$openminis_source_dir"

/usr/bin/patch -d "$source_dir" -p1 -C -s -i "$network_patch"
/usr/bin/patch -d "$source_dir" -p1 -f -s -i "$network_patch"
log "applied guest network policy to temporary source"
/usr/bin/patch -d "$source_dir" -p1 -C -s -i "$abi_offsets_patch"
/usr/bin/patch -d "$source_dir" -p1 -f -s -i "$abi_offsets_patch"
log "added generated iSH bridge ABI offsets"
/usr/bin/patch -d "$source_dir" -p1 -C -s -i "$task_start_patch"
/usr/bin/patch -d "$source_dir" -p1 -f -s -i "$task_start_patch"
log "added checked iSH task startup"
/usr/bin/patch -d "$openminis_source_dir" -p1 -C -s -i "$bridge_patch"
/usr/bin/patch -d "$openminis_source_dir" -p1 -f -s -i "$bridge_patch"
log "prepared minimal OpenMinis iSH compatibility bridge"
/usr/bin/patch -d "$openminis_source_dir" -p1 -C -s -i "$bridge_abi_guard_patch"
/usr/bin/patch -d "$openminis_source_dir" -p1 -f -s -i "$bridge_abi_guard_patch"
log "added OpenMinis/iSH compile-time ABI guards"
/usr/bin/patch -d "$openminis_source_dir" -p1 -C -s -i "$runtime_robustness_patch"
/usr/bin/patch -d "$openminis_source_dir" -p1 -f -s -i "$runtime_robustness_patch"
log "added embedded iSH runtime robustness fixes"
/usr/bin/patch -d "$openminis_source_dir" -p1 -C -s -i "$persistent_process_patch"
/usr/bin/patch -d "$openminis_source_dir" -p1 -f -s -i "$persistent_process_patch"
log "added independently piped persistent guest processes"

render_cross_file() {
  local template="$1"
  local output="$2"
  local sdkroot="$3"
  /usr/bin/sed \
    -e "s|@CLANG@|$clang|g" \
    -e "s|@AR@|$ar|g" \
    -e "s|@STRIP@|$strip|g" \
    -e "s|@SDKROOT@|$sdkroot|g" \
    -e "s|@DEPLOYMENT_TARGET@|$deployment_target|g" \
    -e "s|@NETWORK_DEFAULT@|$network_default|g" \
    "$template" > "$output"
}

build_slice() {
  local platform="$1"
  local sdkroot="$2"
  local template="$3"
  local cross_file="$work_root/$platform-arm64.ini"
  local build_dir="$work_root/build-$platform"

  render_cross_file "$template" "$cross_file" "$sdkroot"
  log "configuring $platform arm64"
  "$meson" setup "$build_dir" "$source_dir" \
    --cross-file "$cross_file" \
    --buildtype release \
    -Db_ndebug=true \
    -Dlog= \
    -Dlog_handler=nslog \
    -Dkernel=ish \
    -Dengine=asbestos \
    -Dguest_arch=arm64

  log "building $platform arm64"
  "$ninja" -C "$build_dir" \
    libish.a libish_emu.a libfakefs.a vdso/arm64/libvdso.so.elf

  for library in libish.a libish_emu.a libfakefs.a; do
    [ -s "$build_dir/$library" ] || fail "$platform did not produce $library"
  done
  [ -s "$build_dir/vdso/arm64/libvdso.so.elf" ] \
    || fail "$platform did not produce the ARM64 Linux VDSO"
}

copy_public_headers() {
  local headers="$1"
  local path
  mkdir -p "$headers/ish"

  for path in asbestos emu fs kernel platform util; do
    while IFS= read -r header; do
      local relative="${header#$source_dir/}"
      mkdir -p "$headers/ish/$(dirname "$relative")"
      cp "$header" "$headers/ish/$relative"
    done < <(/usr/bin/find "$source_dir/$path" -type f -name '*.h' | LC_ALL=C sort)
  done

  for path in debug.h misc.h xX_main_Xx.h deps/config.h; do
    mkdir -p "$headers/ish/$(dirname "$path")"
    cp "$source_dir/$path" "$headers/ish/$path"
  done
  cp "$work_root/build-iphoneos/cpu-offsets.h" "$headers/ish/cpu-offsets.h"
  cp "$component_dir/include/ish/ish.h" "$headers/ish/ish.h"
  mkdir -p "$headers/ish/bridge"
  for path in ISHKernel.h ISHShellExecutor.h CurrentRoot.h; do
    cp "$openminis_source_dir/src/ios/iSH/$path" "$headers/ish/bridge/$path"
  done
  cp "$component_dir/include/module.modulemap" "$headers/module.modulemap"
}

build_bridge_slice() {
  local platform="$1"
  local sdkroot="$2"
  local headers="$3"
  local target
  local build_dir="$work_root/bridge-$platform"
  local bridge_source="$openminis_source_dir/src/ios/iSH"
  local objects=()
  local sources=(
    "$bridge_source/CurrentRoot.m"
    "$bridge_source/ISHKernel.m"
    "$bridge_source/ISHShellExecutor.m"
  )
  local source
  local object

  case "$platform" in
    iphoneos) target="arm64-apple-ios$deployment_target" ;;
    iphonesimulator) target="arm64-apple-ios$deployment_target-simulator" ;;
    *) fail "unknown bridge platform: $platform" ;;
  esac

  mkdir -p "$build_dir"
  for source in "${sources[@]}"; do
    object="$build_dir/$(basename "${source%.m}").o"
    "$clang" \
      -arch arm64 \
      -target "$target" \
      -isysroot "$sdkroot" \
      -fobjc-arc \
      -fblocks \
      -fmodules \
      -fmodules-cache-path="$build_dir/ModuleCache" \
      -O2 \
      -DNDEBUG \
      -DISH_INTERNAL=1 \
      -DGUEST_ARM64=1 \
      -I"$headers" \
      -I"$headers/ish" \
      -I"$bridge_source" \
      -Wno-nullability-completeness \
      -c "$source" \
      -o "$object"
    objects+=("$object")
  done

  "$ar" crs "$build_dir/libHarnessISHBridge.a" "${objects[@]}"
  [ -s "$build_dir/libHarnessISHBridge.a" ] \
    || fail "$platform did not produce the OpenMinis bridge archive"
}

smoke_test_xcframework_slice() {
  local platform="$1"
  local sdkroot="$2"
  local headers="$3"
  local library="$4"
  local target
  local smoke_dir="$work_root/smoke-$platform"
  local objc_source="$smoke_dir/main.m"
  local objc_executable="$smoke_dir/HarnessISHObjCSmoke"
  local swift_source="$smoke_dir/main.swift"
  local swift_executable="$smoke_dir/HarnessISHSwiftSmoke"

  case "$platform" in
    iphoneos) target="arm64-apple-ios$deployment_target" ;;
    iphonesimulator) target="arm64-apple-ios$deployment_target-simulator" ;;
    *) fail "unknown smoke-test platform: $platform" ;;
  esac

  mkdir -p "$smoke_dir"
  /usr/bin/printf '%s\n' \
    '@import Foundation;' \
    '@import HarnessISH;' \
    'int main(void) {' \
    '    @autoreleasepool {' \
    '        ISHKernel *kernel = ISHKernel.shared;' \
    '        kernel.guestNetworkEnabled = NO;' \
    '        (void)[ISHShellExecutor executeCommand:@"true" lineCallback:nil completion:nil];' \
    '        ISHShellProcess *process = [ISHShellExecutor startPersistentExecutable:@"/bin/cat" arguments:nil environment:nil fsContext:0 outputCallback:nil completion:nil];' \
    '        if (process != nil) {' \
    '            (void)process.pid;' \
    '            (void)process.isRunning;' \
    '            (void)[process writeStdin:NSData.data];' \
    '            [process closeStdin];' \
    '            [process terminate];' \
    '        }' \
    '        return 0;' \
    '    }' \
    '}' > "$objc_source"

  log "smoke testing $platform Objective-C module import and final link"
  "$clang" \
    -arch arm64 \
    -target "$target" \
    -isysroot "$sdkroot" \
    -fobjc-arc \
    -fblocks \
    -fmodules \
    -fmodules-cache-path="$smoke_dir/ModuleCache" \
    -Werror \
    -I"$headers" \
    "$objc_source" \
    "$library" \
    -framework Foundation \
    -framework SystemConfiguration \
    -framework UIKit \
    -framework Vision \
    -framework CoreLocation \
    -framework MapKit \
    -framework NaturalLanguage \
    -framework AVFoundation \
    -framework UserNotifications \
    -framework CoreBluetooth \
    -framework EventKit \
    -framework MediaPlayer \
    -framework Photos \
    -framework PhotosUI \
    -framework Speech \
    -framework HealthKit \
    -framework HomeKit \
    -framework CoreNFC \
    -lsqlite3 \
    -lresolv \
    -o "$objc_executable"
  "$lipo" -verify_arch arm64 "$objc_executable"

  /usr/bin/printf '%s\n' \
    'import Foundation' \
    'import HarnessISH' \
    '@main' \
    'struct HarnessISHSmoke {' \
    '    static func main() {' \
    '        let kernel = ISHKernel.shared' \
    '        kernel.guestNetworkEnabled = false' \
    '        _ = ISHShellExecutor.executeCommand("true", lineCallback: nil, completion: nil)' \
    '        let process = ISHShellExecutor.startPersistentExecutable("/bin/cat", arguments: nil, environment: nil, fsContext: 0, outputCallback: nil, completion: nil)' \
    '        if let process {' \
    '            _ = process.pid' \
    '            _ = process.isRunning' \
    '            _ = process.writeStdin(Data())' \
    '            process.closeStdin()' \
    '            process.terminate()' \
    '        }' \
    '    }' \
    '}' > "$swift_source"

  log "smoke testing $platform Swift module import and final link"
  "$swiftc" \
    -parse-as-library \
    -target "$target" \
    -sdk "$sdkroot" \
    -I "$headers" \
    "$swift_source" \
    "$library" \
    -framework Foundation \
    -framework SystemConfiguration \
    -framework UIKit \
    -framework Vision \
    -framework CoreLocation \
    -framework MapKit \
    -framework NaturalLanguage \
    -framework AVFoundation \
    -framework UserNotifications \
    -framework CoreBluetooth \
    -framework EventKit \
    -framework MediaPlayer \
    -framework Photos \
    -framework PhotosUI \
    -framework Speech \
    -lsqlite3 \
    -lresolv \
    -o "$swift_executable"
  "$lipo" -verify_arch arm64 "$swift_executable"
}

deterministic_zip_directory() {
  local source="$1"
  local output="$2"
  local name
  local staging="$work_root/archive-$(basename "$output" .zip)"
  name="$(basename "$source")"

  rm -rf "$staging"
  mkdir -p "$staging"
  cp -R "$source" "$staging/$name"
  /usr/bin/find "$staging/$name" -exec /usr/bin/touch -h -t "$archive_timestamp" {} +
  rm -f "$output"
  (
    cd "$staging"
    LC_ALL=C /usr/bin/find "$name" -print \
      | LC_ALL=C sort \
      | /usr/bin/zip -X -y -q "$output" -@
  )
  /usr/bin/unzip -tq "$output" >/dev/null
}

canonicalize_xcframework_info() {
  local xcframework="$1"
  local json="$work_root/xcframework-info.json"
  local sorted="$work_root/xcframework-info-sorted.json"

  /usr/bin/plutil -convert json -o "$json" "$xcframework/Info.plist"
  /usr/bin/jq '.AvailableLibraries |= sort_by(.LibraryIdentifier)' \
    "$json" > "$sorted"
  /usr/bin/plutil -convert xml1 -o "$xcframework/Info.plist" "$sorted"
}

build_libraries() {
  local device_symbols
  local symbol

  build_slice iphoneos "$iphoneos_sdk" \
    "$component_dir/meson/iphoneos-arm64.ini.in"
  build_slice iphonesimulator "$iphonesimulator_sdk" \
    "$component_dir/meson/iphonesimulator-arm64.ini.in"

  local package="$work_root/package"
  local headers="$package/Headers"
  local device_library="$package/iphoneos/libHarnessISH.a"
  local simulator_library="$package/iphonesimulator/libHarnessISH.a"
  mkdir -p "$(dirname "$device_library")" "$(dirname "$simulator_library")"
  copy_public_headers "$headers"
  build_bridge_slice iphoneos "$iphoneos_sdk" "$headers"
  build_bridge_slice iphonesimulator "$iphonesimulator_sdk" "$headers"

  "$libtool" -static -D -o "$device_library" \
    "$work_root/build-iphoneos/libish.a" \
    "$work_root/build-iphoneos/libish_emu.a" \
    "$work_root/build-iphoneos/libfakefs.a" \
    "$work_root/bridge-iphoneos/libHarnessISHBridge.a"
  "$libtool" -static -D -o "$simulator_library" \
    "$work_root/build-iphonesimulator/libish.a" \
    "$work_root/build-iphonesimulator/libish_emu.a" \
    "$work_root/build-iphonesimulator/libfakefs.a" \
    "$work_root/bridge-iphonesimulator/libHarnessISHBridge.a"

  "$lipo" -verify_arch arm64 "$device_library"
  "$lipo" -verify_arch arm64 "$simulator_library"
  device_symbols="$work_root/device-symbols.txt"
  "$nm" -gU "$device_library" > "$device_symbols"
  grep '_ish_set_guest_network_enabled' "$device_symbols" >/dev/null \
    || fail "network policy API is missing from the device library"
  grep -F '_OBJC_CLASS_$_ISHKernel' "$device_symbols" >/dev/null \
    || fail "OpenMinis ISHKernel bridge is missing from the device library"
  # Keep the interpreter's internal offload primitives available for its
  # optimized Linux execution path, but never link the product-specific
  # Build the minimal iSH runtime slice used by the remaining shell and host paths.
  for symbol in \
    _device_offload_register \
    _clipboard_offload_register \
    _open_offload_register \
    _vision_offload_register \
    _location_offload_register \
    _maps_offload_register \
    _nlp_offload_register \
    _speak_offload_register \
    _notification_offload_register \
    _bluetooth_offload_register \
    _calendar_offload_register \
    _media_offload_register \
    _photos_offload_register \
    _reminders_offload_register \
    _speech_offload_register \
    _healthkit_offload_register \
    _homekit_offload_register \
    _nfc_offload_register; do
    if grep -F "$symbol" "$device_symbols" >/dev/null; then
      fail "legacy OpenMinis capability handler leaked into the device library: $symbol"
    fi
  done

  rm -rf "$artifact_dir/HarnessISH.xcframework"
  /usr/bin/xcodebuild -create-xcframework \
    -library "$device_library" -headers "$headers" \
    -library "$simulator_library" -headers "$headers" \
    -output "$artifact_dir/HarnessISH.xcframework"
  canonicalize_xcframework_info "$artifact_dir/HarnessISH.xcframework"
  smoke_test_xcframework_slice \
    iphoneos \
    "$iphoneos_sdk" \
    "$artifact_dir/HarnessISH.xcframework/ios-arm64/Headers" \
    "$artifact_dir/HarnessISH.xcframework/ios-arm64/libHarnessISH.a"
  smoke_test_xcframework_slice \
    iphonesimulator \
    "$iphonesimulator_sdk" \
    "$artifact_dir/HarnessISH.xcframework/ios-arm64-simulator/Headers" \
    "$artifact_dir/HarnessISH.xcframework/ios-arm64-simulator/libHarnessISH.a"
  deterministic_zip_directory \
    "$artifact_dir/HarnessISH.xcframework" \
    "$artifact_dir/HarnessISH.xcframework.zip"
}

download_alpine() {
  local destination="$repository_root/$alpine_local_path"
  local partial="$destination.part"
  local actual=""
  mkdir -p "$(dirname "$destination")" "$download_dir"

  if [ -f "$destination" ]; then
    actual="$(/usr/bin/shasum -a 256 "$destination" | awk '{print $1}')"
    if [ "$actual" = "$alpine_sha256" ]; then
      printf '%s\n' "$destination"
      return
    fi
    log "discarding Alpine download with an invalid checksum"
    rm -f "$destination"
  fi

  log "downloading Alpine $alpine_version aarch64"
  /usr/bin/curl --fail --location --retry 5 --retry-delay 2 \
    --continue-at - --output "$partial" "$alpine_url"
  actual="$(/usr/bin/shasum -a 256 "$partial" | awk '{print $1}')"
  if [ "$actual" != "$alpine_sha256" ]; then
    rm -f "$partial"
    fail "Alpine SHA-256 mismatch"
  fi
  mv "$partial" "$destination"
  printf '%s\n' "$destination"
}

build_rootfs() {
  local alpine_archive
  local rootfs_deps="$work_root/rootfs-deps"
  local rootfs_tool_dir="$rootfs_deps/tool-bin"
  local rootfs_source
  local alpine_series="${alpine_version%.*}"
  alpine_archive="$(download_alpine)"

  mkdir -p "$rootfs_deps/.cache" "$rootfs_tool_dir"
  cp "$openminis_checkout/deps/prepare_alpine_rootfs.sh" "$rootfs_deps/"
  ln -s "$source_dir" "$rootfs_deps/ish"
  # The pinned Meson release exposes meson.py rather than a `meson` basename,
  # while the upstream rootfs helper discovers it through PATH.
  ln -s "$meson" "$rootfs_tool_dir/meson"
  cp "$alpine_archive" "$rootfs_deps/.cache/$(basename "$alpine_archive")"

  log "creating Alpine fakefs with the pinned OpenMinis script"
  (
    cd "$rootfs_deps"
    PATH="$rootfs_tool_dir:$PATH" /bin/bash ./prepare_alpine_rootfs.sh "$alpine_series"
  )

  rootfs_source="$rootfs_deps/resources/alpine-rootfs"
  [ -d "$rootfs_source/data" ] || fail "fakefs data directory is missing"
  [ -f "$rootfs_source/meta.db" ] || fail "fakefs metadata database is missing"
  rm -f "$rootfs_source/meta.db-shm" "$rootfs_source/meta.db-wal"
  deterministic_zip_directory "$rootfs_source" "$artifact_dir/alpine-rootfs.zip"
}

package_rootfs_patch() {
  local source="$source_dir/app/RootfsPatch.bundle"
  [ -d "$source" ] || fail "RootfsPatch.bundle is missing from ishArm64"
  rm -rf "$artifact_dir/RootfsPatch.bundle"
  cp -R "$source" "$artifact_dir/RootfsPatch.bundle"
  deterministic_zip_directory \
    "$artifact_dir/RootfsPatch.bundle" \
    "$artifact_dir/RootfsPatch.bundle.zip"
}

write_checksums() {
  local checksum_file="$artifact_dir/SHA256SUMS"
  local filename
  : > "$checksum_file"
  for filename in \
    HarnessISH.xcframework.zip \
    RootfsPatch.bundle.zip \
    alpine-rootfs.zip; do
    if [ -f "$artifact_dir/$filename" ]; then
      (
        cd "$artifact_dir"
        /usr/bin/shasum -a 256 "$filename"
      ) >> "$checksum_file"
    fi
  done
}

mkdir -p "$artifact_dir"

case "$action" in
  all)
    build_libraries
    build_rootfs
    package_rootfs_patch
    ;;
  libraries)
    build_libraries
    package_rootfs_patch
    ;;
  rootfs)
    build_rootfs
    package_rootfs_patch
    ;;
esac

write_checksums
log "artifacts ready in $artifact_dir"
cat "$artifact_dir/SHA256SUMS"
