#!/bin/sh
set -eu

registry="https://registry.npmjs.org"
mirror=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --registry)
            [ "$#" -ge 2 ] || { echo "missing value for --registry" >&2; exit 64; }
            registry="$2"
            shift 2
            ;;
        --mirror)
            [ "$#" -ge 2 ] || { echo "missing value for --mirror" >&2; exit 64; }
            mirror="$2"
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 64
            ;;
    esac
done

case "$registry" in
    https://*) ;;
    *) echo "registry must use https" >&2; exit 64 ;;
esac
if [ -n "$mirror" ]; then
    case "$mirror" in
        https://*) ;;
        *) echo "mirror must use https" >&2; exit 64 ;;
    esac
fi

apk add --no-cache nodejs npm ca-certificates

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if [ "$node_major" -lt 20 ]; then
    echo "Node.js 20 or newer is required" >&2
    exit 69
fi

cache_dir="${TMPDIR:-/tmp}/harness-mobile-plugin-host-npm"
rm -rf "$cache_dir"
mkdir -p "$cache_dir"
trap 'rm -rf "$cache_dir"' EXIT HUP INT TERM

install_from() {
    selected_registry="$1"
    npm ci \
        --omit=dev \
        --ignore-scripts \
        --no-audit \
        --no-fund \
        --registry="$selected_registry" \
        --cache="$cache_dir"
}

if ! install_from "$registry"; then
    if [ -z "$mirror" ]; then
        exit 1
    fi
    echo "primary npm registry failed; retrying the configured mirror" >&2
    install_from "$mirror"
fi

node --check ./host.mjs
node --check ./marketplace.mjs
node --input-type=module -e "await import('@deepseek-ai/cordis'); await import('@deepseek-ai/cordis-plugin-loader'); await import('@deepseek-ai/dsh-app-boot'); await import('@deepseek-ai/dsh-atomic-write'); await import('@deepseek-ai/dsh-cordis-host-runner'); await import('@deepseek-ai/dsh-settings'); await import('@deepseek-ai/dsh-settings-file'); await import('@deepseek-ai/dsh-tool-cordis'); await import('yauzl')"
