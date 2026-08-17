# Dependency locks

`upstreams.lock.json` is the single machine-readable source of truth for
upstream repositories, exact Git commits, nested Git pins, and the Alpine
rootfs checksum.

`artifacts.lock.json` records SHA-256 hashes for locally rebuilt XCFrameworks
and other generated binary inputs. Generated binaries are not trusted merely
because they exist on disk: the build and verification scripts must compare
them with this file before they are linked or installed.

Use `Scripts/record-artifact.sh` from deterministic build scripts to refresh a
single generated artifact entry; do not hand-copy checksums from terminal
output.

`patches.lock.json` binds every local patch to both its SHA-256 and the exact
upstream base commit. Refresh an intentionally changed patch with
`Scripts/record-patch.sh`; a normal upstream update must fail until its patch
series has been reviewed and rebound.

Rules:

- Do not edit vendored upstream source in place.
- Keep project changes in `Vendor/**/patches` or in Swift adapter targets.
- Update one upstream at a time.
- Verify the lock, rebuild artifacts, replay patches, and run compatibility
  tests before accepting a new revision.
- Keep API keys and other credentials out of both lock files.

See `Docs/UPGRADING.md` for the full workflow.

The scripts use the system `/usr/bin/jq` for structured JSON access. They do
not parse lock files with regular expressions or depend on `plutil` accepting
JSON input.
