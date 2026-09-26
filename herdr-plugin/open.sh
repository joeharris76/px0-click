#!/usr/bin/env bash
# Herdr action: open the Ctrl+clicked link in px0.
# Herdr injects the clicked URL via HERDR_PLUGIN_CLICKED_URL (and the full
# invocation context via HERDR_PLUGIN_CONTEXT_JSON). px0-open normalizes
# px0:// and file:// URLs to filesystem paths and launches px0 detached,
# so this action returns immediately.
set -u

url="${HERDR_PLUGIN_CLICKED_URL:-}"

if [[ -z "$url" ]]; then
  echo "px0-opener: missing HERDR_PLUGIN_CLICKED_URL" >&2
  exit 1
fi

scheme="${url%%://*}"
scheme="$(printf '%s' "$scheme" | tr 'A-Z' 'a-z')"

case "$scheme" in
  px0|file) ;;
  *)
    echo "px0-opener: unsupported URL scheme: $url" >&2
    exit 1
    ;;
esac

opener="${PX0_OPEN_BIN:-$HOME/.local/bin/px0-open}"
if [[ ! -x "$opener" ]]; then
  echo "px0-opener: helper not executable at $opener (set PX0_OPEN_BIN)" >&2
  exit 1
fi

exec "$opener" "$url"
