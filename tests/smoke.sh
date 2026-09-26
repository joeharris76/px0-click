#!/usr/bin/env bash
# px0-click smoke tests: verify the packaged helpers without px0, Herdr, or a GUI.
#
# Usage: ./tests/smoke.sh
# A fake px0 binary records its argv; assertions check hyperlink output,
# px0-open normalization, the zsh wrappers, and the Herdr action.
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_DIR/bin"
FAILURES=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n  %s\n' "$1" "$2"; FAILURES=$((FAILURES + 1)); }

# Sandbox: fake HOME with a stub px0 that logs argv, plus fixture files.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/px0-click-smoke.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/project/src"
touch "$SANDBOX/project/src/main.py" "$SANDBOX/project/notes.md"
cat >"$SANDBOX/bin/px0" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${PX0_CALL_LOG:?}"
EOF
chmod +x "$SANDBOX/bin/px0"
export PX0_CALL_LOG="$SANDBOX/calls.log"
export PX0_BIN="$SANDBOX/bin/px0"
: >"$PX0_CALL_LOG"

export HOME="$SANDBOX"
export PX0_OPEN_LOG_DIR="$SANDBOX/state/px0-open"

# px0-open launches px0 detached, so poll for the expected argv.
wait_for_call() {  # $1 = expected calls.log content
    local expected="$1" i
    for ((i=0; i<50; i++)); do
        [[ "$(cat "$PX0_CALL_LOG" 2>/dev/null)" == "$expected" ]] && return 0
        sleep 0.1
    done
    return 1
}

# 1. hyperlink-paths links an existing relative path with line/col.
# (OSC 8 puts the URI before the display text.)
out=$(printf 'src/main.py:10:2\n' | "$BIN/hyperlink-paths" --base "$SANDBOX/project")
case "$out" in
    *"$SANDBOX/project/src/main.py?line=10&col=2"*'src/main.py:10:2'*) pass "linkify relative path with line/col" ;;
    *) fail "linkify relative path with line/col" "$(printf '%s' "$out" | cat -v)" ;;
esac

# 2. Missing paths stay plain (no dead links).
out=$(printf 'no/such/file.py\n' | "$BIN/hyperlink-paths" --base "$SANDBOX/project")
case "$out" in
    *$'\x1b]8;;'*) fail "missing path stays plain" "$(printf '%s' "$out" | cat -v)" ;;
    *) pass "missing path stays plain" ;;
esac

# 3. Prose with slashes stays plain.
out=$(printf 'input/output\n' | "$BIN/hyperlink-paths" --base "$SANDBOX/project")
case "$out" in
    *$'\x1b]8;;'*) fail "prose stays plain" "$(printf '%s' "$out" | cat -v)" ;;
    *) pass "prose stays plain" ;;
esac

# 4. Visible text preserved byte-identical (strip OSC 8, compare).
line='see src/main.py:10 for details.'
linked=$(printf '%s\n' "$line" | "$BIN/hyperlink-paths" --base "$SANDBOX/project")
stripped=$(printf '%s' "$linked" | python3 -c 'import re,sys; sys.stdout.write(re.sub("\x1b]8;;.*?\x1b\\\\", "", sys.stdin.read()))')
if [[ "$stripped" == "$line" ]]; then pass "visible text byte-identical"; else fail "visible text byte-identical" "$stripped"; fi

# 5. px0-open strips :line:col and calls px0 with the clean path.
: >"$PX0_CALL_LOG"
out=$(cd "$SANDBOX/project" && "$BIN/px0-open" src/main.py:10:2)
if wait_for_call "$SANDBOX/project/src/main.py"; then pass "px0-open strips line/col"; else fail "px0-open strips line/col" "$(cat "$PX0_CALL_LOG")"; fi

# 6. px0-open handles a px0:// URL with query.
: >"$PX0_CALL_LOG"
"$BIN/px0-open" "px0://$SANDBOX/project/notes.md?line=3" >/dev/null
if wait_for_call "$SANDBOX/project/notes.md"; then pass "px0-open px0:// URL"; else fail "px0-open px0:// URL" "$(cat "$PX0_CALL_LOG")"; fi

# 7. px0-open handles file:// URLs.
: >"$PX0_CALL_LOG"
"$BIN/px0-open" "file://$SANDBOX/project/notes.md" >/dev/null
if wait_for_call "$SANDBOX/project/notes.md"; then pass "px0-open file:// URL"; else fail "px0-open file:// URL" "$(cat "$PX0_CALL_LOG")"; fi

# 8. Shell syntax of the zsh integration.
if zsh -n "$REPO_DIR/shell/px0-click.zsh"; then pass "zsh syntax"; else fail "zsh syntax" "zsh -n failed"; fi

# 9. px wrapper: pipes output through links, preserves exit status.
if command -v zsh >/dev/null 2>&1; then
    px_out=$(cd "$SANDBOX/project" && HOME="$SANDBOX" PATH="$BIN:$PATH" zsh -c 'source "$0"; px printf "src/main.py\n"; echo "rc=$?"' "$REPO_DIR/shell/px0-click.zsh")
    case "$px_out" in
        *'px0://'*'rc=0'*) pass "px wrapper links + rc=0" ;;
        *) fail "px wrapper links + rc=0" "$(printf '%s' "$px_out" | cat -v)" ;;
    esac
    px_rc=$(cd "$SANDBOX/project" && HOME="$SANDBOX" PATH="$BIN:$PATH" zsh -c 'source "$0"; px sh -c "exit 3" >/dev/null 2>&1; echo $?' "$REPO_DIR/shell/px0-click.zsh")
    if [[ "$px_rc" == "3" ]]; then pass "px preserves exit status"; else fail "px preserves exit status" "got $px_rc"; fi
else
    echo "skip  zsh not installed (px wrapper tests)"
fi

# 10. Herdr action forwards the clicked URL to px0-open.
: >"$PX0_CALL_LOG"
if HERDR_PLUGIN_CLICKED_URL="px0://$SANDBOX/project/notes.md?line=1" \
    PX0_OPEN_BIN="$BIN/px0-open" \
    bash "$REPO_DIR/herdr-plugin/open.sh" >/dev/null; then
    if wait_for_call "$SANDBOX/project/notes.md"; then
        pass "herdr action forwards URL"
    else
        fail "herdr action forwards URL" "$(cat "$PX0_CALL_LOG")"
    fi
else
    fail "herdr action forwards URL" "open.sh exited $?"
fi

# 11. Herdr action rejects unknown schemes.
if HERDR_PLUGIN_CLICKED_URL="https://example.com/x" PX0_OPEN_BIN="$BIN/px0-open" \
    bash "$REPO_DIR/herdr-plugin/open.sh" 2>/dev/null; then
    fail "herdr action rejects https" "exited 0"
else
    pass "herdr action rejects https"
fi

# 12. Swift handler still compiles.
if command -v swiftc >/dev/null 2>&1; then
    if swiftc -O -o "$SANDBOX/px0-url-handler-test" "$REPO_DIR/macos/px0-url-handler/main.swift" 2>"$SANDBOX/swiftc.log"; then
        pass "swift handler compiles"
    else
        fail "swift handler compiles" "$(head -n 5 "$SANDBOX/swiftc.log")"
    fi
else
    echo "skip  swiftc not installed (handler compile test)"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    printf '%d failure(s)\n' "$FAILURES"
    exit 1
fi
echo "all smoke tests passed"
