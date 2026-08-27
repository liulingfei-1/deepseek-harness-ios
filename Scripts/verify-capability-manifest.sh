#!/bin/sh

set -eu

script_dir_value="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root_value="$(CDPATH= cd -- "$script_dir_value/.." && pwd)"
manifest_path_value="${1:-$repository_root_value/Docs/CAPABILITY_MANIFEST.json}"
project_file_value="$repository_root_value/HarnessMobile.xcodeproj/project.pbxproj"
audit_input_list_value="$repository_root_value/Scripts/device-audit-inputs.xcfilelist"

[ -r "$manifest_path_value" ] || {
  printf 'error: capability manifest is missing or unreadable: %s\n' "$manifest_path_value" >&2
  exit 1
}

/usr/bin/jq -e '
  .schemaVersion == 1
  and (.generatedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  and (.repository | type == "string" and length > 0)
  and (.capabilities | type == "array" and length > 0)
  and all(.capabilities[];
    (.id | type == "string" and test("^[a-z0-9-]+$"))
    and (.state | type == "string")
    and (.state as $state | (["VERIFY", "PARTIAL", "DONE", "IOS-REPLACEMENT", "OUT-OF-SCOPE"] | index($state) != null))
    and (.compiled | type == "boolean")
    and (.unit | type == "boolean")
    and (.simulator | type == "boolean")
    and (.device | type == "boolean")
    and (.entitlement | type == "object")
    and (.entitlement.required | type == "boolean")
    and (.entitlement.names | type == "array" and all(.[]; type == "string" and length > 0))
    and (.experimental | type == "boolean")
    and (.lastVerified | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.sourcePaths | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    and (.testPaths | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    and (.boundaryPaths | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    and (.surfaces | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  )
' "$manifest_path_value" >/dev/null

duplicate_ids_value="$(/usr/bin/jq -r '.capabilities[].id' "$manifest_path_value" | sort | uniq -d)"
[ -z "$duplicate_ids_value" ] || {
  printf 'error: duplicate capability IDs: %s\n' "$duplicate_ids_value" >&2
  exit 1
}

while IFS= read -r relative_path_value; do
  case "$relative_path_value" in
    /*|../*|*/../*|*/..|..) printf 'error: manifest path escapes repository: %s\n' "$relative_path_value" >&2; exit 1 ;;
  esac
  [ -f "$repository_root_value/$relative_path_value" ] || {
    printf 'error: manifest source/test path is missing: %s\n' "$relative_path_value" >&2
    exit 1
  }
done <<EOF
$(/usr/bin/jq -r '.capabilities[] | .sourcePaths[], .testPaths[], .boundaryPaths[]' "$manifest_path_value")
EOF

manifest_contains_path() {
  expected_path_value="$1"
  /usr/bin/jq -e --arg expected "$expected_path_value" \
    'any(.capabilities[]; ((.sourcePaths + .testPaths) | index($expected)) != null)' \
    "$manifest_path_value" >/dev/null
}

manifest_contains_path 'HarnessMobile/App/AppModel.swift' || {
  printf '%s\n' 'error: manifest must cover AppModel.swift' >&2
  exit 1
}
manifest_contains_path 'HarnessMobile/Core/Tools/ProductionToolCatalog.swift' || {
  printf '%s\n' 'error: manifest must cover ProductionToolCatalog.swift' >&2
  exit 1
}
manifest_contains_path 'HarnessMobileTests/ProductionToolCatalogTests.swift' || {
  printf '%s\n' 'error: manifest must cover ProductionToolCatalogTests.swift' >&2
  exit 1
}

for required_surface_value in production catalog ui boundary; do
  /usr/bin/jq -e --arg surface "$required_surface_value" \
    'any(.capabilities[]; (.surfaces | index($surface)) != null)' \
    "$manifest_path_value" >/dev/null || {
    printf 'error: manifest has no %s coverage surface\n' "$required_surface_value" >&2
    exit 1
  }
done

/usr/bin/grep -Fq 'Tools/ProductionToolCatalog.swift' "$repository_root_value/Package.swift" || {
  printf '%s\n' 'error: Package.swift no longer records the SwiftPM production catalog exclusion' >&2
  exit 1
}

for required_path_value in \
  '$(SRCROOT)/HarnessMobile/App/AppModel.swift' \
  '$(SRCROOT)/HarnessMobile/Core/Tools/ProductionToolCatalog.swift' \
  '$(SRCROOT)/HarnessMobileTests/ProductionToolCatalogTests.swift'; do
  /usr/bin/grep -Fqx "$required_path_value" "$audit_input_list_value" || {
    printf 'error: Xcode audit input list omits %s\n' "$required_path_value" >&2
    exit 1
  }
done

for required_source_value in AppModel.swift ProductionToolCatalog.swift ProductionToolCatalogTests.swift; do
  /usr/bin/grep -Fq "$required_source_value in Sources" "$project_file_value" || {
    printf 'error: Xcode project does not compile %s\n' "$required_source_value" >&2
    exit 1
  }
done

temporary_manifest_value="$(mktemp -t harness-capability-manifest.XXXXXX)"
trap 'rm -f "$temporary_manifest_value"' EXIT HUP INT TERM
/usr/bin/jq -S . "$manifest_path_value" > "$temporary_manifest_value"
/usr/bin/cmp -s "$manifest_path_value" "$temporary_manifest_value" || {
  printf '%s\n' 'error: capability manifest is not canonically sorted; run jq -S . on it' >&2
  exit 1
}

printf 'Capability manifest verified: %s\n' "$manifest_path_value"
