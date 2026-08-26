#!/bin/sh

set -eu

source_root_value="$(pwd)"
if [ -n "${SRCROOT:-}" ]; then
  source_root_value="$SRCROOT"
fi

audit_input_list="${SCRIPT_INPUT_FILE_LIST_0:-$source_root_value/Scripts/device-audit-inputs.xcfilelist}"
if [ ! -r "$audit_input_list" ]; then
  printf '%s\n' 'error: device-only audit input list is missing or unreadable'
  exit 1
fi

forbidden_pattern='RemoteExecutor|Remote Executor|shell\.execute|node-pty|child_process|worker_threads|\bNSTask\b|\bProcess[[:space:]]*\(|\bposix_spawn\b|\bfork[[:space:]]*\(|\bexec(v|ve|vp|vpe|l|le|lp|lpe)?[[:space:]]*\(|\bsystem[[:space:]]*\(|\bdlopen[[:space:]]*\(|\bdlsym[[:space:]]*\(|\bJavaScriptCore\b|\bJSContext\b|\bevaluateJavaScript[[:space:]]*\(|\bWKWebView\b|\bWebKit\b|\bSafariServices\b|\bSFSafariViewController\b|\bUIApplication\.shared\.open\b'
network_pattern='\bURLSession\b|\bURLRequest\b|\bNSURLConnection\b|\bNW(Connection|Listener|Browser|PathMonitor)\b|\bCFHTTP|\bCFNetwork\b|\bwebSocketTask\b|\bMCP\b|\bsocket[[:space:]]*\(|\bconnect[[:space:]]*\(|\bgetaddrinfo[[:space:]]*\(|\bgethostbyname[[:space:]]*\('

audit_hits_file="$(mktemp -t harness-mobile-audit-hits.XXXXXX)"
audit_paths_file="$(mktemp -t harness-mobile-audit-paths.XXXXXX)"
listed_names_file="$(mktemp -t harness-mobile-listed-sources.XXXXXX)"
project_names_file="$(mktemp -t harness-mobile-project-sources.XXXXXX)"
trap 'rm -f "$audit_hits_file" "$audit_paths_file" "$listed_names_file" "$project_names_file"' EXIT

while IFS= read -r listed_path; do
  resolved_path="$(printf '%s' "$listed_path" | sed "s#\$(SRCROOT)#$source_root_value#g")"
  if [ ! -r "$resolved_path" ]; then
    printf 'error: audit input is missing or unreadable: %s\n' "$resolved_path"
    exit 1
  fi
  case "$resolved_path" in
    "$source_root_value/Package.swift") ;;
    *.swift) printf '%s\n' "$resolved_path" >> "$audit_paths_file" ;;
  esac
done < "$audit_input_list"

while IFS= read -r swift_path; do
  basename "$swift_path"
done < "$audit_paths_file" | sort -u > "$listed_names_file"

project_file="$source_root_value/HarnessMobile.xcodeproj/project.pbxproj"
rg -o 'path = "?[^;]+\.swift"?;' "$project_file" \
  | sed -E 's/.*path = "?([^";]+)"?;.*/\1/' \
  | sort -u > "$project_names_file"
if ! diff -u "$project_names_file" "$listed_names_file"; then
  printf '%s\n' 'error: every Swift file in the Xcode project must be listed for boundary audit'
  exit 1
fi

scan_files() {
  scan_pattern="$1"
  scan_mode="$2"
  : > "$audit_hits_file"
  while IFS= read -r swift_path; do
    case "$scan_mode:$swift_path" in
      # SQLite query projection uses a private helper named `exec` for SQL
      # statements; it never invokes a process or remote execution primitive.
      all:*/Core/Trace/SessionQueryReadModel.swift) continue ;;
      outside-network:*/Core/Network/OpenAICompatibleClient.swift) continue ;;
      outside-network:*/Core/Network/DeepSeekFilesClient.swift) continue ;;
      # Provider adapters own request URL/header/body construction, while the
      # client remains the only component that actually performs URLSession I/O.
      outside-network:*/Core/Network/ModelProviderAdapter.swift) continue ;;
      # This file is the audited connection-pool lifecycle seam. It observes
      # path interface changes and resets provider-owned URLSession objects; it
      # does not construct requests or perform model I/O itself.
      outside-network:*/Core/Network/HarnessLLMSessionRegistry.swift) continue ;;
      outside-network:*/Core/Tools/WebFetchTool.swift) continue ;;
      outside-network:*/Core/Tools/ISH/ISHGuestNetworkMonitor.swift) continue ;;
      # MCP is a byte-framed client over the already audited on-device iSH
      # stdio bridge. It contains protocol names such as MCP and connect(), but
      # owns no URLSession, socket, NWConnection, or host Process primitive.
      outside-network:*/Core/Tools/MCP/*.swift) continue ;;
      # AVAudioEngine.connect() builds the local audio graph; it is not a
      # network primitive despite sharing the method name.
      outside-network:*/Core/Background/BackgroundAudioKeepAlive.swift) continue ;;
      outside-network:*/Core/Agent/MobileHarnessPrompt.swift) continue ;;
      # URLProtocol is used here only to provide an in-process fixture for the
      # native web-fetch tests; it does not create a production network path.
      outside-network:*/HarnessMobileTests/WebFetchToolTests.swift) continue ;;
      # In-process URLProtocol fixture for provider discovery status/body/size
      # contracts. Production provider networking remains in Core/Network.
      outside-network:*/HarnessMobileTests/ProviderModelDiscoveryTests.swift) continue ;;
      outside-network:*/HarnessMobileTests/HarnessLLMSessionRegistryTests.swift) continue ;;
      outside-network:*/HarnessMobileTests/MCPClientTests.swift) continue ;;
      inside-provider:*/Core/Network/OpenAICompatibleClient.swift) ;;
      inside-provider:*/Core/Network/DeepSeekFilesClient.swift) ;;
      inside-provider:*/Core/Network/ModelProviderAdapter.swift) ;;
      inside-provider:*) continue ;;
      inside-web-fetch:*/Core/Tools/WebFetchTool.swift) ;;
      inside-web-fetch:*) continue ;;
    esac
    rg -nH "$scan_pattern" "$swift_path" >> "$audit_hits_file" 2>/dev/null || scan_exit=$?
    scan_exit="${scan_exit:-0}"
    if [ "$scan_exit" -gt 1 ]; then
      printf 'error: audit could not read %s\n' "$swift_path"
      exit 1
    fi
    unset scan_exit
  done < "$audit_paths_file"
}

scan_files "$forbidden_pattern" all
if [ -s "$audit_hits_file" ]; then
  sed -n '1,120p' "$audit_hits_file"
  printf '%s\n' 'error: remote, subprocess, browser, or dynamic-code primitive found'
  exit 1
fi

scan_files "$network_pattern" outside-network
if [ -s "$audit_hits_file" ]; then
  sed -n '1,120p' "$audit_hits_file"
  printf '%s\n' 'error: network primitive found outside the audited model-provider and web-fetch boundaries'
  exit 1
fi

scan_files "$network_pattern" inside-provider
provider_files_with_network="$(cut -d: -f1 "$audit_hits_file" | sort -u | wc -l | tr -d ' ')"
if [ "$provider_files_with_network" -ne 3 ]; then
  printf '%s\n' 'error: exactly three audited model-provider files must own request construction or network I/O (adapters + chat + DeepSeek Files)'
  exit 1
fi

scan_files "$network_pattern" inside-web-fetch
web_fetch_files_with_network="$(cut -d: -f1 "$audit_hits_file" | sort -u | wc -l | tr -d ' ')"
if [ "$web_fetch_files_with_network" -ne 1 ]; then
  printf '%s\n' 'error: exactly one audited native web-fetch file must own anonymous web I/O'
  exit 1
fi

package_file="$source_root_value/Package.swift"
if rg -n '\.package[[:space:]]*\(' "$package_file"; then
  printf '%s\n' 'error: runtime package dependencies require an explicit boundary review'
  exit 1
fi

if rg -n 'XCRemoteSwiftPackageReference' "$project_file"; then
  printf '%s\n' 'error: remote Xcode package dependencies require an explicit boundary review'
  exit 1
fi

local_package_reference_count="$(rg -c 'isa = XCLocalSwiftPackageReference;' "$project_file" || true)"
if [ "$local_package_reference_count" -gt 0 ]; then
  local_package_paths="$(awk '
    /\/\* Begin XCLocalSwiftPackageReference section \*\// { in_section = 1; next }
    /\/\* End XCLocalSwiftPackageReference section \*\// { in_section = 0 }
    in_section && /relativePath = / {
      path = $0
      sub(/^[[:space:]]*relativePath = /, "", path)
      sub(/;[[:space:]]*$/, "", path)
      gsub(/"/, "", path)
      print path
    }
  ' "$project_file")"
  local_package_path_count="$(printf '%s\n' "$local_package_paths" | awk 'NF { count += 1 } END { print count + 0 }')"
  unreviewed_local_package_paths="$(printf '%s\n' "$local_package_paths" | rg -v '^\.$' || true)"
  if [ "$local_package_reference_count" -ne "$local_package_path_count" ] \
    || [ -n "$unreviewed_local_package_paths" ]; then
    rg -n 'XCLocalSwiftPackageReference|relativePath = ' "$project_file" || true
    printf '%s\n' 'error: only the audited repository-root Swift package may be referenced locally'
    exit 1
  fi
fi

framework_hits_file="$(mktemp -t harness-mobile-framework-hits.XXXXXX)"
trap 'rm -f "$audit_hits_file" "$audit_paths_file" "$listed_names_file" "$project_names_file" "$framework_hits_file"' EXIT
rg -n '\.(xcframework|framework)(/|"|[[:space:]])|lib(sqlite3|resolv)\.tbd' "$project_file" \
  > "$framework_hits_file" 2>/dev/null || framework_scan_exit=$?
framework_scan_exit="${framework_scan_exit:-0}"
if [ "$framework_scan_exit" -gt 1 ]; then
  printf '%s\n' 'error: bundled framework audit failed'
  exit 1
fi
unset framework_scan_exit

# HealthKit is a signed Apple system framework used only by the audited
# on-device permission/status surface and the statically linked OpenMinis
# `apple-healthkit` handler. It introduces no dynamic code or remote execution
# boundary, so keep it in the explicit framework allowlist rather than
# weakening this fail-closed audit.
if rg -v 'HarnessISH\.xcframework|HealthKit\.framework|SystemConfiguration\.framework|libsqlite3\.tbd|libresolv\.tbd' \
  "$framework_hits_file" > "$audit_hits_file"; then
  sed -n '1,120p' "$audit_hits_file"
  printf '%s\n' 'error: an unreviewed framework or native library was added'
  exit 1
fi

harness_framework_count="$(rg -c 'HarnessISH\.xcframework' "$framework_hits_file" || true)"
if [ "$harness_framework_count" -lt 1 ]; then
  printf '%s\n' 'error: the fixed on-device HarnessISH boundary is missing'
  exit 1
fi

verify_locked_artifact() {
  artifact_relative_path="$1"
  artifact_absolute_path="$source_root_value/$artifact_relative_path"
  expected_hash="$(/usr/bin/jq -er --arg path "$artifact_relative_path" \
    '.artifacts[] | select(.path == $path) | .sha256' \
    "$source_root_value/Dependencies/artifacts.lock.json")"
  if [ ! -r "$artifact_absolute_path" ]; then
    printf 'error: locked iSH artifact is missing: %s\n' "$artifact_relative_path"
    exit 1
  fi
  actual_hash="$(/usr/bin/shasum -a 256 "$artifact_absolute_path" | awk '{print $1}')"
  if [ "$actual_hash" != "$expected_hash" ]; then
    printf 'error: locked iSH artifact hash mismatch: %s\n' "$artifact_relative_path"
    exit 1
  fi
}

verify_locked_artifact 'Vendor/OpenMinisISH/Artifacts/HarnessISH.xcframework.zip'
verify_locked_artifact 'Vendor/OpenMinisISH/Artifacts/RootfsPatch.bundle.zip'
verify_locked_artifact 'Vendor/OpenMinisISH/Artifacts/alpine-rootfs.zip'

printf '%s\n' 'Device-only tool audit passed: model networking, anonymous native web fetch, and fixed local iSH execution are isolated.'
