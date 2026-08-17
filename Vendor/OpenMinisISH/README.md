# OpenMinis iSH component

This directory contains integration metadata and replayable local patches for
the iPhone Linux command sandbox. It intentionally does not vendor generated
libraries, an Alpine root filesystem, or an editable fork checkout.

The implementation is based on these exact upstream revisions:

- OpenMinis: `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd`
- OpenMinis/ish-arm64: `de124dd66124a15239cea1465164f74980ada245`
- Alpine minirootfs: `3.21.0`, `aarch64`

The canonical URLs, nested submodule pins, and rootfs checksum live in
`Dependencies/upstreams.lock.json`. `Scripts/build-ish-sandbox.sh` reads that
manifest and refuses a source or download that does not match it.

The replayable patch stack also emits core structure offsets and checks them
while compiling the Objective-C bridge. An upstream layout or architecture
macro mismatch therefore fails the XCFramework build instead of crashing later
inside `ISHShellExecutor` on a device.

## Generated output

Run:

```sh
DEVELOPER_DIR=/Users/liulingfei/Downloads/Xcode-beta.app/Contents/Developer \
  ./Scripts/build-ish-sandbox.sh all
```

The ignored `Artifacts/` directory then contains:

- `HarnessISH.xcframework`: combined `libish`, `libish_emu`, `libfakefs`, and
  the minimal OpenMinis `ISHKernel`/`ISHShellExecutor`/`CurrentRoot` bridge for
  iPhone arm64 and Apple Silicon iOS Simulator arm64.
- `HarnessISH.xcframework.zip`: deterministic distributable archive.
- `alpine-rootfs.zip`: a checksum-verified aarch64 fakefs root filesystem.
- `RootfsPatch.bundle`: OpenMinis' versioned guest compatibility overlays.
- `RootfsPatch.bundle.zip`: deterministic distributable overlay archive.
- `SHA256SUMS`: hashes for every distributable generated artifact.

Guest networking is enabled by default. Set
`ISH_GUEST_NETWORK_DEFAULT=disabled` at build time or set
`ISHKernel.shared.guestNetworkEnabled = NO` at runtime when the user chooses
offline Linux execution. The switch blocks new INET/INET6 sockets while
preserving AF_LOCAL; it does not revoke sockets that already exist. Native
model-provider requests are outside the guest and are unaffected.

The build requires LLVM Clang and `ld.lld` for the ARM64 Linux VDSO, plus
Meson, Ninja, and libarchive. If Meson is absent, the script downloads the
checksum-pinned official Meson GitHub release into the ignored `.tools/`
directory. Every XCFramework build then imports and finally links the module
from Objective-C and Swift for both the device and simulator slices.

See `Docs/ISH_SANDBOX_PORT.md` for the executor contract, app-layer bridge list,
performance limits, and the parts of OpenMinis that must remain behaviorally
compatible.

## License boundary

OpenMinis is GPL-3.0 and its iSH fork is GPL-covered with the upstream iOS
distribution exception. Linking the generated XCFramework into an app creates
GPL source-distribution obligations if that app is conveyed to anyone else.
Personal local sideloading does not erase the license, but it normally does not
constitute distribution. App Store-specific restrictions are not a target for
this project; iOS runtime suspension and entitlement limits still apply. Keep
the exact source revisions, patch files, build script, license text, and
installation instructions together with any build that is shared.

Upstream license sources:

- https://github.com/OpenMinis/OpenMinis/blob/9cf3a855fecd27bb5735b84cacbd56852a3ab8dd/LICENSE
- https://github.com/OpenMinis/ish-arm64/blob/de124dd66124a15239cea1465164f74980ada245/LICENSE.md
- https://github.com/OpenMinis/ish-arm64/blob/de124dd66124a15239cea1465164f74980ada245/LICENSE.IOS
