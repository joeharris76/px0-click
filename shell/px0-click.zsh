# px0 click-to-open: make file paths printed in the terminal open in px0.
#
# What this sets up:
#   - `rg` emits native OSC 8 hyperlinks with px0:// targets when printing
#     to a terminal, so matches are Cmd/Ctrl+clickable with no piping.
#     Piped or redirected output is left untouched.
#   - `px <command...>` runs any command through hyperlink-paths, turning
#     printed paths (grep, compilers, test runners, git status, ls) into
#     clickable px0:// links. Plain `px <path>` opens a path in px0.
#   - `px0-open <path>` opens a path or px0:// URL in px0 directly.
#
# Clicks resolve through: Ghostty Cmd+click -> "px0 URL Handler" app ->
# px0-open -> px0; Herdr Ctrl+click -> px0-opener plugin -> px0-open -> px0.
# See px0-open(1) and hyperlink-paths in ../bin (px0-click repo).

# rg: clickable px0:// file hyperlinks on terminals, plain text otherwise.
# The format carries ?line=&col= so vimgrep matches open at the match;
# without line info rg substitutes 1/1, which just opens the file top.
# An explicit user --hyperlink-format still wins (last flag wins in rg).
if command -v rg >/dev/null 2>&1; then
    rg() {
        if [[ -t 1 ]]; then
            command rg --hyperlink-format 'px0://{path}?line={line}&col={column}' "$@"
        else
            command rg "$@"
        fi
    }
fi

# px: open a path in px0, or hyperlink all paths in a command's output.
# Note: the wrapped command must be a binary, builtin, or shell function;
# shell aliases do not resolve at runtime, so `px myalias` reports
# "command not found" while `px myfunction` works.
px() {
    local base stream rc
    stream=()
    if [[ $# -eq 0 ]]; then
        px0-open --help >&2
        return 2
    fi
    # A single existing path opens directly in px0. Only the bare form
    # counts: `px -- <cmd>` always runs the command, even when a file or
    # directory with the same name exists in $PWD (e.g. `px -- test`
    # runs `test`, it does not open ./test in px0).
    if [[ "${1:-}" == "--" ]]; then
        shift
        if [[ $# -eq 0 ]]; then
            px0-open --help >&2
            return 2
        fi
    elif [[ $# -eq 1 && "$1" != -* ]]; then
        # A single path-like argument opens in px0 when it (or its
        # :line/:line:col-suffixed base) exists. A :line or :line:col
        # suffix still opens when the base path exists
        # (px /tmp/demo.py:10); otherwise fall through and run it.
        base="$1"
        while [[ "$base" == *:[0-9]* && ! -e "$base" ]]; do
            base="${base%:*}"
        done
        if [[ -e "$base" ]]; then
            px0-open "$1"
            return $?
        fi
    fi
    # Both streams pass through hyperlink-paths (compilers print file
    # paths on stderr too), but stderr stays on the terminal when the
    # terminal is watching: `px cmd > file` keeps diagnostics visible
    # instead of baking them into the file. When stderr is piped (Herdr
    # panes, CI), both streams merge into the filter as before.
    # The filter runs line-buffered (-u) on terminals so long-running
    # commands stream live instead of appearing only at exit.
    if [[ -t 1 ]]; then
        stream=(-u)
    fi
    if [[ -t 2 ]]; then
        "$@" 2> >(hyperlink-paths $stream --base "$PWD" >&2) | hyperlink-paths $stream --base "$PWD"
        # Capture here: the if/else wrapper itself resets $pipestatus,
        # so reading it after fi would report the filter, not the command.
        rc=${pipestatus[1]}
    else
        "$@" 2>&1 | hyperlink-paths --base "$PWD"
        rc=${pipestatus[1]}
    fi
    # Report the wrapped command's status, not the filter's, so
    # `px rg pattern` still signals "no match" correctly.
    return $rc
}
