#!/usr/bin/env bash
# Herdr action: open the currently selected pane text as a path in px0.
# Herdr passes the selection inside HERDR_PLUGIN_CONTEXT_JSON as
# selected_text (there is no HERDR_PLUGIN_SELECTED_TEXT env var).
# The text is trimmed of surrounding whitespace/quotes, then handed to
# px0-open, which strips :line:col suffixes, resolves ~ and relative
# paths, and launches px0 detached.
set -u

trim_selection() {
    local py sel
    # python3 only: jq is not a dependency of this plugin.
    for py in "${PX0_PYTHON:-}" "$(command -v python3 2>/dev/null || true)" \
        /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        [[ -n "$py" && -x "$py" ]] || continue
        sel="$("$py" -c '
import json, os, sys
try:
    ctx = json.loads(os.environ.get("HERDR_PLUGIN_CONTEXT_JSON", "{}"))
except Exception:
    ctx = {}
sys.stdout.write(str(ctx.get("selected_text") or ""))
' 2>/dev/null)" && { printf '%s' "$sel"; return 0; }
    done
    return 1
}

sel="$(trim_selection || true)"
# Trim surrounding whitespace, quotes, and backticks: selections made by
# double-click or drag often include them.
sel="$(printf '%s' "$sel" | sed -e 's/^[[:space:]`"'\'']*//' -e 's/[[:space:]`"'\'']*$//')"

if [[ -z "$sel" ]]; then
    echo "px0-opener: no selected text (select a path, then invoke again)" >&2
    exit 1
fi

opener="${PX0_OPEN_BIN:-$HOME/.local/bin/px0-open}"
if [[ ! -x "$opener" ]]; then
    echo "px0-opener: helper not executable at $opener (set PX0_OPEN_BIN)" >&2
    exit 1
fi

exec "$opener" "$sel"
