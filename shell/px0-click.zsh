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
# The format keeps line/column metadata visible and px0-open translates the
# query parameters into px0's path:line:column form.
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
    local base rc filter_dir stdout_fifo stderr_fifo stdout_pid stderr_pid
    local -a stdout_stream stderr_stream
    stdout_stream=()
    stderr_stream=()
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
        # A single path-like argument opens in px0 when it (or its numeric
        # :line/:line:col-suffixed base) exists. An exact path wins first;
        # otherwise only the documented numeric suffix forms are recognized.
        base="$1"
        if [[ ! -e "$base" && "$base" =~ '^(.+):[0-9]+$' && -e "$match[1]" ]]; then
            base="$match[1]"
        elif [[ ! -e "$base" && "$base" =~ '^(.+):[0-9]+:[0-9]+$' ]]; then
            base="$match[1]"
        elif [[ ! -e "$base" && "$base" =~ '^(.+):[0-9]+$' ]]; then
            base="$match[1]"
        fi
        if [[ -e "$base" ]]; then
            px0-open "$1"
            return $?
        fi
    fi
    # Keep stdout and stderr on their original routes. Each stream gets its
    # own filter, so explicit redirects such as `>out 2>err` remain separate
    # while compiler diagnostics are still linkified. Use line buffering only
    # for a stream whose destination is a terminal.
    if [[ -t 1 ]]; then
        stdout_stream=(-u)
    fi
    if [[ -t 2 ]]; then
        stderr_stream=(-u)
    fi
    filter_dir=$(mktemp -d "${TMPDIR:-/tmp}/px0-click.XXXXXX") || return 1
    stdout_fifo="$filter_dir/stdout"
    stderr_fifo="$filter_dir/stderr"
    if ! mkfifo "$stdout_fifo" "$stderr_fifo"; then
        rm -rf "$filter_dir"
        return 1
    fi
    hyperlink-paths "${stdout_stream[@]}" --base "$PWD" <"$stdout_fifo" &
    stdout_pid=$!
    hyperlink-paths "${stderr_stream[@]}" --base "$PWD" <"$stderr_fifo" >&2 &
    stderr_pid=$!
    "$@" >"$stdout_fifo" 2>"$stderr_fifo"
    rc=$?
    wait "$stdout_pid" 2>/dev/null || true
    wait "$stderr_pid" 2>/dev/null || true
    rm -rf "$filter_dir"
    # Report the wrapped command's status, not the filter's, so
    # `px rg pattern` still signals "no match" correctly.
    return $rc
}
