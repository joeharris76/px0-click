#!/usr/bin/env bash
# Herdr action: open the Ctrl+clicked link in px0.
# Herdr injects the clicked URL via HERDR_PLUGIN_CLICKED_URL (and the full
# invocation context via HERDR_PLUGIN_CONTEXT_JSON). px0-open normalizes
# px0:// and file:// URLs to filesystem paths and launches px0 detached,
# so this action returns immediately.
set -u

resolve_opener() {
  local configured=""
  if [[ -n "${PX0_OPEN_BIN:-}" ]]; then
    printf '%s' "$PX0_OPEN_BIN"
    return 0
  fi
  if [[ -n "${PX0_CLICK_PREFIX:-}" ]]; then
    printf '%s/bin/px0-open' "$PX0_CLICK_PREFIX"
    return 0
  fi
  if [[ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" && -r "$HERDR_PLUGIN_CONFIG_DIR/px0-open-path" ]]; then
    IFS= read -r configured <"$HERDR_PLUGIN_CONFIG_DIR/px0-open-path" || [[ -n "$configured" ]]
    if [[ -n "$configured" ]]; then
      printf '%s' "$configured"
      return 0
    fi
  fi
  printf '%s/.local/bin/px0-open' "$HOME"
}

url="${HERDR_PLUGIN_CLICKED_URL:-}"

if [[ -z "$url" ]]; then
  echo "px0-opener: missing HERDR_PLUGIN_CLICKED_URL" >&2
  exit 1
fi

scheme="${url%%://*}"
scheme="$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')"

case "$scheme" in
  px0|file) ;;
  *)
    echo "px0-opener: unsupported URL scheme: $url" >&2
    exit 1
    ;;
esac

opener="$(resolve_opener)"
if [[ ! -x "$opener" ]]; then
  echo "px0-opener: helper not executable at $opener (set PX0_OPEN_BIN)" >&2
  exit 1
fi

exec "$opener" -- "$url"
