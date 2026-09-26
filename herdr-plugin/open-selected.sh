#!/usr/bin/env bash
# Herdr action: open the currently selected pane text as a path in px0.
# Herdr passes the selection and focused pane cwd inside
# HERDR_PLUGIN_CONTEXT_JSON. The selection is normalized and relative paths
# are resolved before px0-open runs from the plugin directory.
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

selection_target() {
    local py target
    # python3 only: jq is not a dependency of this plugin.
    for py in "${PX0_PYTHON:-}" "$(command -v python3 2>/dev/null || true)" \
        /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        [[ -n "$py" && -x "$py" ]] || continue
        target="$("$py" -c '
import json
import os
import re
import sys

try:
    ctx = json.loads(os.environ.get("HERDR_PLUGIN_CONTEXT_JSON", "{}"))
except Exception:
    ctx = {}

selection = str(ctx.get("selected_text") or "").strip()
match = re.fullmatch(r"([\"\x27`])(.*)\1((?::[0-9]+){0,2})", selection, re.DOTALL)
if match:
    selection = match.group(2) + match.group(3)

if selection and not (
    os.path.isabs(selection)
    or selection == "~"
    or selection.startswith("~/")
    or "://" in selection
):
    cwd = str(ctx.get("focused_pane_cwd") or ctx.get("workspace_cwd") or "")
    if not cwd:
        sys.exit(3)
    selection = os.path.join(cwd, selection)

sys.stdout.write(selection)
' 2>/dev/null)" && { printf '%s' "$target"; return 0; }
    done
    return 1
}

if ! sel="$(selection_target)"; then
    echo "px0-opener: cannot resolve selection (python3 and focused pane cwd are required)" >&2
    exit 1
fi

if [[ -z "$sel" ]]; then
    echo "px0-opener: no selected text (select a path, then invoke again)" >&2
    exit 1
fi

opener="$(resolve_opener)"
if [[ ! -x "$opener" ]]; then
    echo "px0-opener: helper not executable at $opener (set PX0_OPEN_BIN)" >&2
    exit 1
fi

exec "$opener" -- "$sel"
