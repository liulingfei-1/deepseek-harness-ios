# iSH sandbox port contract

This document defines the command-execution boundary for the iOS port. The
language model remains an API service reached by the native networking layer.
Every shell command, process, file operation, and package install runs inside
the app process on the phone through the pinned OpenMinis iSH ARM64 guest.
There is no remote command runner.

## Locked implementation

- OpenMinis: `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd`
- OpenMinis/ish-arm64: `de124dd66124a15239cea1465164f74980ada245`
- Alpine minirootfs: `3.21.0`, `aarch64`
- Guest architecture: ARM64 Linux on the Asbestos interpreter
- Host targets: iPhone arm64 and Apple Silicon iOS Simulator arm64

`Scripts/build-ish-sandbox.sh` exports those revisions into temporary source
trees, applies the recorded patches, and builds `HarnessISH.xcframework`.
The canonical upstream checkouts remain clean and are never compiled after a
local in-place edit.

The XCFramework contains the three iSH libraries plus a minimal runtime bridge
for embedding iSH in Harness Mobile:

- `libish`: kernel, processes, syscalls, sockets, PTY, mounts, and fakefs
- `libish_emu`: ARM64 Asbestos interpreter and ARM64 Linux VDSO
- `libfakefs`: SQLite-backed Linux filesystem metadata
- `ISHKernel`: boot, crash containment, fakefs, PTY, DNS, exit notifications,
  mounts, path routing hooks, and CPU throttle hooks, without generic iOS
  capability/offload handlers
- `ISHShellExecutor`: independent stdin/stdout/stderr pipes, PID reporting,
  timeout support, process-group termination, and streaming output
- `CurrentRoot`: versioned `RootfsPatch.bundle` overlay application

The bridge is extracted from the locked OpenMinis sources at build time. Local
patches expose guest network policy, change DNS storage paths, and bound
retained command output. The generic OpenMinis native offload set is excluded;
iOS integrations belong to typed Swift providers in the app target.

## Executor semantics

The Swift adapter must preserve these behaviors. They are compatibility
requirements, not optional UI details.

1. Keep stdout and stderr separate. Stream each chunk with a channel tag and
   return both final buffers independently. They may be merged only when a
   caller explicitly requests display-order text.
2. Return the guest PID as soon as `do_execve` succeeds. Store it before any
   asynchronous callback so Stop and timeout paths can always find the process.
3. Apply a finite timeout to every agent command. The recommended default is
   five minutes, with an explicit override for package installation or builds.
4. Stop the full command tree, not only the root PID. Send `SIGTERM` to tasks
   sharing the process group or descending from the root, wait about 200 ms,
   revalidate that the PID still names the same task, then send `SIGKILL` to
   survivors. Never allow this operation for PID 1.
5. Decode output incrementally. Preserve incomplete UTF-8 suffix bytes across
   4 KiB reads and flush them at EOF. A split multibyte scalar must not become
   replacement characters or corrupt the following chunk.
6. Stream without retaining unbounded output. The bridge keeps at most 1 MiB
   per stdout/stderr result buffer and appends an `[output truncated]` marker.
   UI history should use a smaller rolling window while durable command logs
   are written incrementally to disk.
7. Serialize mutable session setup in a Swift actor. On iPhone, default to one
   active command per session and at most two guest commands globally. A future
   parallel mode may use OpenMinis `fs_context` routing, but task creation,
   mount changes, and per-session cancellation bookkeeping must remain actor
   owned.
8. Throttle rather than spin. Preserve OpenMinis' adaptive scheduler hook,
   `GOMAXPROCS=2`, Node `--jitless`, and the process cleanup path. A sensible
   iPhone 16 Pro starting point is unrestricted foreground interaction, a
   50-65 percent duty target for sustained foreground builds, and 20-30
   percent while a valid background execution assertion remains active.

The executor must feed multiline commands through stdin to `/bin/sh`, add a
trailing newline for heredoc correctness, and redirect the command subshell's
spent stdin to `/dev/null`. This prevents stdio-based child tools from waiting
forever on an inherited pipe.

## Network boundary

Guest networking defaults to enabled. `ISHKernel.shared.guestNetworkEnabled`
or `ish_set_guest_network_enabled(false)` applies the user's explicit offline
choice. The switch blocks creation of new guest
`AF_INET` and `AF_INET6` sockets while preserving `AF_LOCAL`; it does not revoke
sockets that were already open.

This switch does not affect model inference. Provider requests are made by the
native URLSession client and can remain available while the Linux guest is
offline when the user disables it. Guest networking is required for commands such as `apk`,
`git`, `curl`, `pip`, and `npm` that need direct network access.

API keys stay in Keychain and the native provider layer. Do not write a model
key into the Alpine image, shell profile, workspace, build log, or generated
artifact. Inject a secret into an individual guest process only when a tool
explicitly requires it.

## Root filesystem lifecycle

Bundle `alpine-rootfs.zip` and `RootfsPatch.bundle` as app resources. On first
launch, extract the rootfs to a staging directory, verify `data/` and
`meta.db`, then atomically move it into the app's Application Support area.
Mark the installed tree as excluded from backup. Do not unpack on the main
thread.

Boot order must remain:

1. Install the iSH crash handler and embedded `die` handler.
2. Mount fakefs and register its canonical host path.
3. Create PID 1 and required device nodes.
4. Apply the versioned rootfs overlay.
5. Mount procfs and devpts.
6. Create and bind-mount the host-managed `resolv.conf`.
7. Install the process-exit hook and TTY drivers.
8. Create init stdio, then mark the kernel booted.

Rootfs reset must stop all commands first. Deleting a mounted fakefs tree while
the kernel still references it leaves stale descriptors and requires an app
restart.

## App-layer extraction list

The following OpenMinis files are the minimum reference set for completing the
native app integration. Keep their public semantics while removing dependencies
on unrelated Minis features:

- `src/ios/iSH/ISHKernel.{h,m}`
- `src/ios/iSH/ISHShellExecutor.{h,m}`
- `src/ios/iSH/CurrentRoot.{h,m}`
- `src/ios/iSH/RootfsManager.swift`
- `src/ios/Agent/ISH/ISHExecutionCoordinator.swift`
- `src/ios/Agent/ISH/MinisFsRouter.swift`
- `src/ios/Agent/ISH/ShellCommandRingBuffer.swift`
- `src/ios/iSH/Terminal/ANSIParser.swift`
- `src/ios/iSH/Terminal/TerminalBuffer.swift`
- `src/ios/iSH/Terminal/TerminalCanvasView.swift`
- `src/ios/iSH/Terminal/TerminalEmulator.swift`
- `src/ios/iSH/Terminal/TerminalInputView.swift`
- `src/ios/iSH/Terminal/TerminalKeyboardAccessory.swift`
- `src/ios/iSH/Terminal/TerminalTypes.swift`

`ISHKernel`, `ISHShellExecutor`, and `CurrentRoot` are already compiled into
the XCFramework. The Swift lifecycle, actor/session router, command history,
and terminal UI remain app-target work and should call this bridge instead of
reimplementing the kernel.

Consumers must link `SystemConfiguration.framework`, `libsqlite3.tbd`, and
`libresolv.tbd`. The XCFramework module is `HarnessISH`.

## Background execution reality

Personal Xcode sideloading removes App Store review concerns, but it does not
remove iOS process suspension, jetsam, entitlement, or background-time limits.
A fake-location session is not a reliable or appropriate general-purpose
compute assertion. A Live Activity displays status and controls; it does not
keep the iSH interpreter scheduled.

Use documented background task APIs for bounded continuation, checkpoint the
active command and workspace, and treat suspension or termination as normal.
For long builds, the UI must state that the command can pause when iOS removes
execution time and can resume only when the app receives execution again.

## Verification matrix

Before connecting command execution to the agent loop, test all of the
following on the iPhone 16 Pro:

- `uname -m` returns `aarch64` and a simple command returns exit code 0.
- stdout and stderr remain distinguishable under interleaved output.
- a PID is reported before the first output callback.
- timeout and Stop terminate a shell plus nested `sleep` children.
- a UTF-8 scalar split across read boundaries is emitted intact.
- output above 1 MiB streams but the final retained buffer is truncated.
- guest `curl` fails while network access is disabled and succeeds after the
  runtime switch is enabled.
- rootfs overlay versioning is idempotent across launches.
- terminal resize, interactive input, and ANSI rendering work after rotation.
- memory pressure and background suspension do not leave orphan guest threads.

Generated binaries are GPL-covered. Personal local use is not distribution,
but any build shared with another person must include the corresponding source,
local patches, build instructions, GPL text, and iSH additional iOS terms.
