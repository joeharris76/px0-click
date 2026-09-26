#!/usr/bin/env bash
# px0-click smoke tests: deterministic, sandboxed regressions for packaged helpers.
#
# Usage: ./tests/smoke.sh
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_DIR/bin"
FAILURES=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n  %s\n' "$1" "$2"; FAILURES=$((FAILURES + 1)); }
contains() { [[ "$1" == *"$2"* ]]; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/px0-click-smoke.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/project/src" "$SANDBOX/state/px0-open"
touch "$SANDBOX/project/src/main.py" "$SANDBOX/project/notes.md"

cat >"$SANDBOX/bin/px0" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${PX0_CALL_LOG:?}"
EOF
chmod +x "$SANDBOX/bin/px0"
export PX0_CALL_LOG="$SANDBOX/calls.log"
export PX0_BIN="$SANDBOX/bin/px0"
export HOME="$SANDBOX"
export PX0_OPEN_LOG_DIR="$SANDBOX/state/px0-open"
: >"$PX0_CALL_LOG"

wait_for_call() {
    local expected="$1" i
    for ((i=0; i<50; i++)); do
        [[ "$(cat "$PX0_CALL_LOG" 2>/dev/null)" == "$expected" ]] && return 0
        sleep 0.1
    done
    return 1
}

uri_for() {
    python3 -c 'import sys, urllib.parse; print("px0://" + urllib.parse.quote(sys.argv[1], safe="/"))' "$1"
}

# Core link and open behavior.
out=$(printf 'src/main.py:10:2\n' | "$BIN/hyperlink-paths" --base "$SANDBOX/project")
case "$out" in
    *"$SANDBOX/project/src/main.py?line=10&col=2"*'src/main.py:10:2'*) pass "linkify relative path with line/col" ;;
    *) fail "linkify relative path with line/col" "$(printf '%s' "$out" | cat -v)" ;;
esac

out=$(printf 'no/such/file.py\n' | "$BIN/hyperlink-paths" --base "$SANDBOX/project")
if [[ "$out" == *$'\x1b]8;;'* ]]; then
    fail "missing path stays plain" "$(printf '%s' "$out" | cat -v)"
else
    pass "missing path stays plain"
fi

out=$(printf 'input/output\n' | "$BIN/hyperlink-paths" --base "$SANDBOX/project")
if [[ "$out" == *$'\x1b]8;;'* ]]; then
    fail "prose with slashes stays plain" "$(printf '%s' "$out" | cat -v)"
else
    pass "prose with slashes stays plain"
fi

line='see src/main.py:10 for details.'
linked=$(printf '%s\n' "$line" | "$BIN/hyperlink-paths" --base "$SANDBOX/project")
stripped=$(printf '%s' "$linked" | python3 -c 'import re,sys; sys.stdout.write(re.sub("\x1b]8;;.*?\x1b\\\\", "", sys.stdin.read()))')
if [[ "$stripped" == "$line" ]]; then
    pass "visible text remains byte-identical"
else
    fail "visible text remains byte-identical" "$stripped"
fi

: >"$PX0_CALL_LOG"
(cd "$SANDBOX/project" && "$BIN/px0-open" src/main.py:10:2 >/dev/null)
if wait_for_call "$SANDBOX/project/src/main.py:10:2"; then
    pass "px0-open preserves direct numeric line/column"
else
    fail "px0-open preserves direct numeric line/column" "$(cat "$PX0_CALL_LOG")"
fi

: >"$PX0_CALL_LOG"
"$BIN/px0-open" "px0://$SANDBOX/project/notes.md?line=3&col=4" >/dev/null
if wait_for_call "$SANDBOX/project/notes.md:3:4"; then
    pass "px0-open translates URL line/column for px0"
else
    fail "px0-open translates URL line/column for px0" "$(cat "$PX0_CALL_LOG")"
fi

: >"$PX0_CALL_LOG"
"$BIN/px0-open" "file://$SANDBOX/project/notes.md" >/dev/null
if wait_for_call "$SANDBOX/project/notes.md"; then
    pass "px0-open accepts a local file URL"
else
    fail "px0-open accepts a local file URL" "$(cat "$PX0_CALL_LOG")"
fi

touch "$HOME/item" "$HOME/item:123"
: >"$PX0_CALL_LOG"
# shellcheck disable=SC2088 # px0-open, not this shell, must expand the literal tilde.
"$BIN/px0-open" '~/item:123' >/dev/null
if wait_for_call "$HOME/item:123"; then
    pass "px0-open prefers exact tilde-relative numeric filenames"
else
    fail "px0-open prefers exact tilde-relative numeric filenames" "$(cat "$PX0_CALL_LOG")"
fi

: >"$PX0_CALL_LOG"
# shellcheck disable=SC2088 # px0-open, not this shell, must expand the literal tilde.
"$BIN/px0-open" '~/item:123:4' >/dev/null
if wait_for_call "$HOME/item:123:4"; then
    pass "px0-open preserves numeric-suffix filename plus location for px0"
else
    fail "px0-open preserves numeric-suffix filename plus location for px0" "$(cat "$PX0_CALL_LOG")"
fi

# URL authority and decoded-control safety.
: >"$PX0_CALL_LOG"
if authority_out=$("$BIN/px0-open" 'file://attacker.example/etc/passwd' 2>&1); then
    fail "reject non-local file URI authority" "exited 0"
elif [[ -s "$PX0_CALL_LOG" ]]; then
    fail "reject non-local file URI authority" "px0 was invoked: $(cat "$PX0_CALL_LOG")"
elif contains "$authority_out" "refusing non-local file URI authority"; then
    pass "reject non-local file URI authority"
else
    fail "reject non-local file URI authority" "$authority_out"
fi

cat >"$SANDBOX/bin/noisy-px0" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$1" >"${CONTROL_ARG_FILE:?}"
printf 'ARG=%s\n' "$1"
EOF
chmod +x "$SANDBOX/bin/noisy-px0"
control_log_dir="$SANDBOX/control-log"
control_arg="$SANDBOX/control-arg"
CONTROL_ARG_FILE="$control_arg" PX0_BIN="$SANDBOX/bin/noisy-px0" PX0_OPEN_LOG_DIR="$control_log_dir" \
    "$BIN/px0-open" 'file:///tmp/real%0AFORGED_EVENT=success' >/dev/null 2>&1
for ((i=0; i<50; i++)); do
    [[ -e "$control_arg" ]] && break
    sleep 0.02
done
if python3 - "$control_arg" <<'PY'
import pathlib
import sys
raise SystemExit(0 if pathlib.Path(sys.argv[1]).read_bytes() == b"/tmp/real\nFORGED_EVENT=success" else 1)
PY
then
    if grep -R -Fq 'FORGED_EVENT=success' "$control_log_dir" 2>/dev/null; then
        fail "decoded controls cannot inject log lines" "forged marker reached the log"
    else
        pass "decoded controls cannot inject log lines"
    fi
else
    fail "decoded controls cannot inject log lines" "target bytes were not preserved safely"
fi

direct_control_log_dir="$SANDBOX/direct-control-log"
: >"$control_arg"
CONTROL_ARG_FILE="$control_arg" PX0_BIN="$SANDBOX/bin/noisy-px0" \
    PX0_OPEN_LOG_DIR="$direct_control_log_dir" \
    "$BIN/px0-open" $'/tmp/real\nFORGED_DIRECT_EVENT=success' >/dev/null 2>&1
for ((i=0; i<50; i++)); do
    [[ -s "$control_arg" ]] && break
    sleep 0.02
done
if grep -R -Fq 'FORGED_DIRECT_EVENT=success' "$direct_control_log_dir" 2>/dev/null; then
    fail "direct path controls cannot inject log lines" "forged marker reached the log"
elif python3 - "$control_arg" <<'PY'
import pathlib
import sys
raise SystemExit(0 if pathlib.Path(sys.argv[1]).read_bytes() == b"/tmp/real\nFORGED_DIRECT_EVENT=success" else 1)
PY
then
    pass "direct path controls cannot inject log lines"
else
    fail "direct path controls cannot inject log lines" "target bytes were not preserved safely"
fi

# Deterministic startup failure and concurrent bounded-log safety.
cat >"$SANDBOX/bin/missing-interpreter" <<'EOF'
#!/definitely/not/a/real/interpreter
EOF
chmod +x "$SANDBOX/bin/missing-interpreter"
startup_false_successes=0
for ((i=1; i<=25; i++)); do
    if PX0_BIN="$SANDBOX/bin/missing-interpreter" PX0_OPEN_LOG_DIR="$SANDBOX/startup-log-$i" \
        "$BIN/px0-open" "$SANDBOX/project/notes.md" >/dev/null 2>&1; then
        startup_false_successes=$((startup_false_successes + 1))
    fi
done
if [[ "$startup_false_successes" -eq 0 ]]; then
    pass "report immediate px0 startup failure"
else
    fail "report immediate px0 startup failure" "$startup_false_successes false successes in 25 runs"
fi

rotation_dir="$SANDBOX/rotation-log"
rotation_log="$rotation_dir/px0-open.log"
mkdir -p "$rotation_dir"
cat >"$SANDBOX/bin/noisy-long-px0" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import sys; sys.stdout.buffer.write((b"noisy output line\n" * 10000)); sys.stdout.flush()'
sleep 0.6
printf 'LATE_APPEND_%s\n' "${LOG_TOKEN:?}"
sleep 0.6
EOF
chmod +x "$SANDBOX/bin/noisy-long-px0"
for i in 1 2 3; do
    LOG_TOKEN="$i" PX0_BIN="$SANDBOX/bin/noisy-long-px0" PX0_OPEN_LOG_DIR="$rotation_dir" \
        "$BIN/px0-open" "$SANDBOX/project/notes.md" >/dev/null
done
for ((i=0; i<200; i++)); do
    [[ -f "$rotation_log" ]] || { sleep 0.01; continue; }
    rotation_size=$(wc -c <"$rotation_log" | tr -d ' ')
    [[ "$rotation_size" -le 131072 ]] && grep -Fq 'LATE_APPEND_3' "$rotation_log" && break
    sleep 0.01
done
rotation_size=$(wc -c <"$rotation_log" | tr -d ' ')
if [[ "$rotation_size" -le 131072 ]] && grep -Fq 'LATE_APPEND_1' "$rotation_log" &&
    grep -Fq 'LATE_APPEND_2' "$rotation_log" && grep -Fq 'LATE_APPEND_3' "$rotation_log" &&
    ! compgen -G "$rotation_log.old.*" >/dev/null &&
    ! compgen -G "$rotation_log.compact.*" >/dev/null; then
    pass "log relay bounds long-lived writers without losing late output"
else
    fail "log relay bounds long-lived writers without losing late output" \
        "size=$rotation_size markers=$(grep -c 'LATE_APPEND_' "$rotation_log" 2>/dev/null || true)"
fi

# zsh parsing and stream routing.
if command -v zsh >/dev/null 2>&1; then
    if zsh -n "$REPO_DIR/shell/px0-click.zsh"; then
        pass "zsh integration syntax"
    else
        fail "zsh integration syntax" "zsh -n failed"
    fi

    : >"$PX0_CALL_LOG"
    invalid_rc=$(cd "$SANDBOX/project" && HOME="$SANDBOX" PATH="$BIN:$PATH" \
        zsh -c 'source "$1"; touch demo; px demo:12oops >/dev/null 2>/dev/null; printf "%s" "$?"' \
        zsh "$REPO_DIR/shell/px0-click.zsh")
    if [[ "$invalid_rc" != "0" && ! -s "$PX0_CALL_LOG" ]]; then
        pass "zsh rejects nonnumeric location tails as paths"
    else
        fail "zsh rejects nonnumeric location tails as paths" "rc=$invalid_rc calls=$(cat "$PX0_CALL_LOG")"
    fi

    px_out=$(cd "$SANDBOX/project" && HOME="$SANDBOX" PATH="$BIN:$PATH" \
        zsh -c 'source "$1"; px printf "src/main.py\n"; printf "rc=%s\n" "$?"' \
        zsh "$REPO_DIR/shell/px0-click.zsh")
    px_rc=$(cd "$SANDBOX/project" && HOME="$SANDBOX" PATH="$BIN:$PATH" \
        zsh -c 'source "$1"; px sh -c "exit 3" >/dev/null 2>&1; printf "%s" "$?"' \
        zsh "$REPO_DIR/shell/px0-click.zsh")
    if contains "$px_out" 'px0://' && contains "$px_out" 'rc=0' && [[ "$px_rc" == "3" ]]; then
        pass "zsh links command output and preserves exit status"
    else
        fail "zsh links command output and preserves exit status" "output=$px_out rc=$px_rc"
    fi

    cat >"$SANDBOX/bin/emit-both" <<'EOF'
#!/usr/bin/env bash
printf 'OUT_ONLY\n'
printf 'ERR_ONLY\n' >&2
EOF
    chmod +x "$SANDBOX/bin/emit-both"
    stdout_file="$SANDBOX/zsh-stdout"
    stderr_file="$SANDBOX/zsh-stderr"
    (cd "$SANDBOX/project" && HOME="$SANDBOX" PATH="$SANDBOX/bin:$BIN:$PATH" \
        zsh -c 'source "$1"; px emit-both >"$2" 2>"$3"' \
        zsh "$REPO_DIR/shell/px0-click.zsh" "$stdout_file" "$stderr_file")
    if grep -Fqx 'OUT_ONLY' "$stdout_file" && ! grep -Fq 'ERR_ONLY' "$stdout_file" &&
        grep -Fqx 'ERR_ONLY' "$stderr_file" && ! grep -Fq 'OUT_ONLY' "$stderr_file"; then
        pass "zsh preserves explicit stdout/stderr redirection"
    else
        fail "zsh preserves explicit stdout/stderr redirection" "stdout=$(cat "$stdout_file") stderr=$(cat "$stderr_file")"
    fi

    race_bin="$SANDBOX/zsh-race-bin"
    mkdir -p "$race_bin"
    cat >"$race_bin/hyperlink-paths" <<'EOF'
#!/usr/bin/env bash
payload=$(cat)
if [[ "$payload" == *ERR_ONLY* ]]; then sleep 0.8; fi
printf '%s' "$payload"
EOF
    chmod +x "$race_bin/hyperlink-paths"
    : >"$stderr_file"
    immediate_bytes=$(cd "$SANDBOX/project" && HOME="$SANDBOX" PATH="$race_bin:$BIN:$PATH" \
        zsh -c 'source "$1"; px sh -c "printf ERR_ONLY >&2" >"$2" 2>"$3"; wc -c <"$3" | tr -d " "' \
        zsh "$REPO_DIR/shell/px0-click.zsh" "$stdout_file" "$stderr_file")
    if [[ "$immediate_bytes" == "8" && "$(cat "$stderr_file")" == "ERR_ONLY" ]]; then
        pass "zsh waits for stderr hyperlink filtering"
    else
        fail "zsh waits for stderr hyperlink filtering" \
            "immediate_bytes=$immediate_bytes later=$(cat "$stderr_file")"
    fi
else
    echo "skip  zsh not installed"
fi

# Herdr selected-path normalization and option boundary.
herdr_opener="$SANDBOX/bin/herdr-opener"
cat >"$herdr_opener" <<'EOF'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >"${HERDR_ARGS_LOG:?}"
EOF
chmod +x "$herdr_opener"
herdr_args="$SANDBOX/herdr-args"
context=$(python3 -c 'import json,sys; print(json.dumps({"selected_text":"src/main.py","focused_pane_cwd":sys.argv[1]}))' "$SANDBOX/project")
if HERDR_ARGS_LOG="$herdr_args" HERDR_PLUGIN_CONTEXT_JSON="$context" PX0_OPEN_BIN="$herdr_opener" \
    bash "$REPO_DIR/herdr-plugin/open-selected.sh" &&
    [[ "$(cat "$herdr_args")" == $'<-->\n<'"$SANDBOX/project/src/main.py"'>' ]]; then
    pass "Herdr resolves selected relative paths from pane cwd"
else
    fail "Herdr resolves selected relative paths from pane cwd" "$(cat "$herdr_args" 2>/dev/null)"
fi

context=$(python3 -c 'import json,sys; print(json.dumps({"selected_text":"\"space name\":10:2","focused_pane_cwd":sys.argv[1]}))' "$SANDBOX/project")
HERDR_ARGS_LOG="$herdr_args" HERDR_PLUGIN_CONTEXT_JSON="$context" PX0_OPEN_BIN="$herdr_opener" \
    bash "$REPO_DIR/herdr-plugin/open-selected.sh"
quoted_args=$(cat "$herdr_args")
context=$(python3 -c 'import json,sys; print(json.dumps({"selected_text":"-h","focused_pane_cwd":sys.argv[1]}))' "$SANDBOX/project")
HERDR_ARGS_LOG="$herdr_args" HERDR_PLUGIN_CONTEXT_JSON="$context" PX0_OPEN_BIN="$herdr_opener" \
    bash "$REPO_DIR/herdr-plugin/open-selected.sh"
option_args=$(cat "$herdr_args")
if [[ "$quoted_args" == $'<-->\n<'"$SANDBOX/project/space name:10:2"'>' &&
      "$option_args" == $'<-->\n<'"$SANDBOX/project/-h"'>' ]]; then
    pass "Herdr preserves quoted locations and option-like names"
else
    fail "Herdr preserves quoted locations and option-like names" "quoted=$quoted_args option=$option_args"
fi

# Hyperlink parser edge cases.
touch "$SANDBOX/project/item" "$SANDBOX/project/item:123" \
    "$SANDBOX/project/only:" "$SANDBOX/project/[id]" "$SANDBOX/project/(auth)"
exact_ok=1
for exact_path in "$SANDBOX/project/item:123" "$SANDBOX/project/only:" \
    "$SANDBOX/project/[id]" "$SANDBOX/project/(auth)"; do
    out=$(printf '%s\n' "$exact_path" | "$BIN/hyperlink-paths")
    expected_uri=$(uri_for "$exact_path")
    if ! contains "$out" "$expected_uri" || contains "$out" '?line='; then exact_ok=0; fi
done
if [[ "$exact_ok" -eq 1 ]]; then
    pass "exact punctuation and numeric-suffix filenames win"
else
    fail "exact punctuation and numeric-suffix filenames win" "one or more exact names were reinterpreted"
fi

out=$(printf '%s\n' "$SANDBOX/project/item:123:4" | "$BIN/hyperlink-paths")
if contains "$out" "$(uri_for "$SANDBOX/project/item:123")?line=4"; then
    pass "numeric-suffix filename keeps a following location"
else
    fail "numeric-suffix filename keeps a following location" "$(printf '%s' "$out" | cat -v)"
fi

out=$(printf '%s\n' "$SANDBOX/project/item:123:4:5" | "$BIN/hyperlink-paths")
if contains "$out" "$(uri_for "$SANDBOX/project/item:123")?line=4&col=5"; then
    pass "numeric-suffix filename keeps following line and column"
else
    fail "numeric-suffix filename keeps following line and column" "$(printf '%s' "$out" | cat -v)"
fi

out=$(printf '%s\n' "$SANDBOX/project/item:123:4:5:match text" | "$BIN/hyperlink-paths")
if contains "$out" "$(uri_for "$SANDBOX/project/item:123")?line=4&col=5" &&
    [[ "$out" == *':match text' ]]; then
    pass "numeric-suffix filename keeps vimgrep location and match text"
else
    fail "numeric-suffix filename keeps vimgrep location and match text" "$(printf '%s' "$out" | cat -v)"
fi

spaced="$SANDBOX/project/not created/my dir"
out=$(printf '%s\n' "$spaced" | "$BIN/hyperlink-paths" --no-exists-check)
if contains "$out" "$(uri_for "$spaced")"; then
    pass "no-exists-check keeps a final spaced component"
else
    fail "no-exists-check keeps a final spaced component" "$(printf '%s' "$out" | cat -v)"
fi

mkdir -p "$SANDBOX/project/rel"
touch "$SANDBOX/project/rel/f"
out=$(printf '%s\n' "\$P/f" | P=rel "$BIN/hyperlink-paths" --base "$SANDBOX/project")
if contains "$out" "$(uri_for "$SANDBOX/project/rel/f")"; then
    pass "relative environment paths honor --base"
else
    fail "relative environment paths honor --base" "$(printf '%s' "$out" | cat -v)"
fi

sgr_input="$SANDBOX/sgr-input"
sgr_output="$SANDBOX/sgr-output"
printf '\033[38:2::255:0:0m%s\033[0m\n' "$SANDBOX/project/notes.md" >"$sgr_input"
"$BIN/hyperlink-paths" <"$sgr_input" >"$sgr_output"
if grep -a -Fq "$(uri_for "$SANDBOX/project/notes.md")" "$sgr_output" &&
    python3 - "$sgr_input" "$sgr_output" <<'PY'
import pathlib
import re
import sys
original = pathlib.Path(sys.argv[1]).read_bytes()
linked = pathlib.Path(sys.argv[2]).read_bytes()
visible = re.sub(rb"\x1b]8;;.*?\x1b\\", b"", linked)
raise SystemExit(0 if visible == original else 1)
PY
then
    pass "colon-parameter ANSI SGR preserves and links paths"
else
    fail "colon-parameter ANSI SGR preserves and links paths" "output mismatch"
fi

pua_input="$SANDBOX/pua-input"
pua_output="$SANDBOX/pua-output"
python3 - "$pua_input" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes("\x1b[31mA\ue000B\x1b[0m\n".encode())
PY
"$BIN/hyperlink-paths" <"$pua_input" >"$pua_output"
if cmp -s "$pua_input" "$pua_output"; then
    pass "literal private-use text survives ANSI folding"
else
    fail "literal private-use text survives ANSI folding" "bytes changed"
fi

if python3 - "$BIN/hyperlink-paths" <<'PY'
import subprocess
import sys
payload = b"a" * 30000 + b"\n"
try:
    result = subprocess.run([sys.argv[1]], input=payload, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=2.0, check=True)
except (subprocess.SubprocessError, OSError):
    raise SystemExit(1)
raise SystemExit(0 if result.stdout == payload else 1)
PY
then
    pass "long slash-free word completes within practical guard"
else
    fail "long slash-free word completes within practical guard" "30k input exceeded 2 seconds or changed"
fi

# Copy the installer into the sandbox. Disable only the fixed absolute
# LaunchServices registration command so successful URL-handler tests do not
# mutate the user's desktop registration database.
INSTALL_REPO="$SANDBOX/install-repo"
mkdir -p "$INSTALL_REPO/bin" "$INSTALL_REPO/shell" "$INSTALL_REPO/herdr-plugin" "$INSTALL_REPO/macos/px0-url-handler"
cp "$REPO_DIR/install.sh" "$INSTALL_REPO/install.sh"
cp "$REPO_DIR/bin/px0-open" "$REPO_DIR/bin/hyperlink-paths" "$INSTALL_REPO/bin/"
cp "$REPO_DIR/shell/px0-click.zsh" "$INSTALL_REPO/shell/"
cp "$REPO_DIR/herdr-plugin/"* "$INSTALL_REPO/herdr-plugin/"
cp "$REPO_DIR/macos/px0-url-handler/main.swift" "$REPO_DIR/macos/px0-url-handler/Info.plist" \
    "$INSTALL_REPO/macos/px0-url-handler/"
python3 - "$INSTALL_REPO/install.sh" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f \"$APP_DIR\" 2>/dev/null || true\n"
if text.count(needle) != 1:
    raise SystemExit("unexpected lsregister command")
path.write_text(text.replace(needle, "    : # LaunchServices registration suppressed by sandboxed smoke test\n"))
PY
chmod +x "$INSTALL_REPO/install.sh"
INSTALLER="$INSTALL_REPO/install.sh"

# Installer destructive boundaries.
case_dir="$SANDBOX/install-symlink-zshrc"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
mkdir -p "$case_home" "$case_dir/dotfiles"
printf 'export KEEP_SYMLINK=1\n' >"$case_dir/dotfiles/zshrc"
cp "$case_dir/dotfiles/zshrc" "$case_dir/zshrc.before"
ln -s "$case_dir/dotfiles/zshrc" "$case_home/.zshrc"
if HOME="$case_home" "$INSTALLER" --prefix "$case_prefix" --shell >/dev/null 2>&1; then
    symlink_rc=0
else
    symlink_rc=$?
fi
if [[ "$symlink_rc" -ne 0 && -L "$case_home/.zshrc" ]] &&
    cmp -s "$case_dir/dotfiles/zshrc" "$case_dir/zshrc.before"; then
    pass "installer refuses symlinked zshrc without replacing it"
else
    fail "installer refuses symlinked zshrc without replacing it" "rc=$symlink_rc"
fi

case_dir="$SANDBOX/install-prefix-migration"
case_home="$case_dir/home"
old_prefix="$case_dir/old prefix"
new_prefix="$case_dir/new prefix"
mkdir -p "$case_home"
HOME="$case_home" "$INSTALLER" --prefix "$old_prefix" --shell >/dev/null
HOME="$case_home" "$INSTALLER" --prefix "$new_prefix" --shell >/dev/null
printf -v old_shell_quoted '%q' "$old_prefix/share/px0-click/px0-click.zsh"
printf -v new_shell_quoted '%q' "$new_prefix/share/px0-click/px0-click.zsh"
marker_count=$(grep -Fxc '# Click-to-open in px0 (px0-click).' "$case_home/.zshrc" || true)
if [[ "$marker_count" -eq 1 ]] && ! grep -Fq "$old_shell_quoted" "$case_home/.zshrc" &&
    grep -Fq "$new_shell_quoted" "$case_home/.zshrc"; then
    prefix_migration_ok=1
else
    prefix_migration_ok=0
fi
HOME="$case_home" "$INSTALLER" --uninstall --prefix "$new_prefix" >/dev/null
if [[ "$prefix_migration_ok" -eq 1 ]] && ! grep -Fq 'share/px0-click/px0-click.zsh' "$case_home/.zshrc"; then
    pass "shell integration migrates and uninstalls across custom prefixes"
else
    fail "shell integration migrates and uninstalls across custom prefixes" "$(cat "$case_home/.zshrc")"
fi

case_dir="$SANDBOX/install-unreadable"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
mkdir -p "$case_home" "$case_dir/fake-bin"
HOME="$case_home" "$INSTALLER" --prefix "$case_prefix" >/dev/null
printf 'keep this\n[[ -f /old/share/px0-click/px0-click.zsh ]] && source /old/share/px0-click/px0-click.zsh\n' >"$case_home/.zshrc"
cp "$case_home/.zshrc" "$case_dir/zshrc.before"
real_grep=$(command -v grep)
cat >"$case_dir/fake-bin/grep" <<'EOF'
#!/usr/bin/env bash
if [[ "${!#}" == "${FAIL_GREP_PATH:?}" ]]; then exit 2; fi
exec "${REAL_GREP:?}" "$@"
EOF
chmod +x "$case_dir/fake-bin/grep"
if HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" REAL_GREP="$real_grep" FAIL_GREP_PATH="$case_home/.zshrc" \
    "$INSTALLER" --uninstall --prefix "$case_prefix" >/dev/null 2>&1; then
    unreadable_rc=0
else
    unreadable_rc=$?
fi
if [[ "$unreadable_rc" -ne 0 ]] && cmp -s "$case_home/.zshrc" "$case_dir/zshrc.before" &&
    [[ -x "$case_prefix/bin/px0-open" && -x "$case_prefix/bin/hyperlink-paths" ]]; then
    pass "uninstall read error leaves zshrc and helpers unchanged"
else
    fail "uninstall read error leaves zshrc and helpers unchanged" "rc=$unreadable_rc"
fi

case_dir="$SANDBOX/install-unrelated"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
mkdir -p "$case_home" "$case_prefix/bin"
printf 'unrelated px0-open\n' >"$case_prefix/bin/px0-open"
printf 'unrelated hyperlink-paths\n' >"$case_prefix/bin/hyperlink-paths"
printf '%s\n' 'before' 'documentation: share/px0-click/px0-click.zsh.backup' 'after' >"$case_home/.zshrc"
cp "$case_prefix/bin/px0-open" "$case_dir/px0.before"
cp "$case_prefix/bin/hyperlink-paths" "$case_dir/hyperlink.before"
cp "$case_home/.zshrc" "$case_dir/zshrc.before"
if HOME="$case_home" "$INSTALLER" --prefix "$case_prefix" >/dev/null 2>&1; then install_unrelated_rc=0; else install_unrelated_rc=$?; fi
if HOME="$case_home" "$INSTALLER" --uninstall --prefix "$case_prefix" >/dev/null 2>&1; then uninstall_unrelated_rc=0; else uninstall_unrelated_rc=$?; fi
if [[ "$install_unrelated_rc" -ne 0 && "$uninstall_unrelated_rc" -eq 0 ]] &&
    cmp -s "$case_prefix/bin/px0-open" "$case_dir/px0.before" &&
    cmp -s "$case_prefix/bin/hyperlink-paths" "$case_dir/hyperlink.before" &&
    cmp -s "$case_home/.zshrc" "$case_dir/zshrc.before"; then
    pass "installer preserves unrelated helpers and zshrc references"
else
    fail "installer preserves unrelated helpers and zshrc references" \
        "install=$install_unrelated_rc uninstall=$uninstall_unrelated_rc"
fi

case_dir="$SANDBOX/install-required-failure"
mkdir -p "$case_dir/home"
printf 'not a directory\n' >"$case_dir/block"
if HOME="$case_dir/home" "$INSTALLER" --prefix "$case_dir/block/child" >"$case_dir/out" 2>&1; then
    fail "required installer stage failure is fatal" "exited 0"
else
    pass "required installer stage failure is fatal"
fi

case_dir="$SANDBOX/install-url-upgrade"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
mkdir -p "$case_home/Applications/px0 URL Handler.app/Contents" "$case_dir/fake-bin"
printf 'old app sentinel\n' >"$case_home/Applications/px0 URL Handler.app/sentinel"
cat >"$case_home/Applications/px0 URL Handler.app/Contents/Info.plist" <<'EOF'
<plist><dict><key>CFBundleIdentifier</key><string>dev.px0.url-handler</string></dict></plist>
EOF
cat >"$case_dir/fake-bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
cat >"$case_dir/fake-bin/swiftc" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$case_dir/fake-bin/uname" "$case_dir/fake-bin/swiftc"
if HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" "$INSTALLER" --prefix "$case_prefix" --url-handler >/dev/null 2>&1; then
    failed_upgrade_rc=0
else
    failed_upgrade_rc=$?
fi
if [[ "$failed_upgrade_rc" -ne 0 && -f "$case_home/Applications/px0 URL Handler.app/sentinel" &&
      ! -e "$case_prefix/bin/px0-open" && ! -e "$case_prefix/bin/hyperlink-paths" ]]; then
    pass "failed URL-handler build rolls back all installation stages"
else
    fail "failed URL-handler build rolls back all installation stages" "rc=$failed_upgrade_rc partial state remains"
fi

case_dir="$SANDBOX/install-signal-rollback"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
mkdir -p "$case_home" "$case_dir/fake-bin"
cat >"$case_dir/fake-bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
cat >"$case_dir/fake-bin/swiftc" <<'EOF'
#!/usr/bin/env bash
sleep 2
exit 42
EOF
chmod +x "$case_dir/fake-bin/uname" "$case_dir/fake-bin/swiftc"
HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" "$INSTALLER" --prefix "$case_prefix" --url-handler \
    >"$case_dir/out" 2>&1 &
signal_install_pid=$!
for ((i=0; i<200; i++)); do
    [[ -e "$case_prefix/bin/px0-open" ]] && break
    sleep 0.01
done
kill -TERM "$signal_install_pid" 2>/dev/null || true
if wait "$signal_install_pid"; then signal_install_rc=0; else signal_install_rc=$?; fi
if [[ "$signal_install_rc" -eq 143 && ! -e "$case_prefix/bin/px0-open" &&
      ! -e "$case_prefix/bin/hyperlink-paths" &&
      ! -e "$case_home/Applications/px0 URL Handler.app" ]]; then
    pass "installer signal rolls back completed stages"
else
    fail "installer signal rolls back completed stages" "rc=$signal_install_rc $(cat "$case_dir/out")"
fi

case_dir="$SANDBOX/install-unrelated-app"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
mkdir -p "$case_home/Applications/px0 URL Handler.app" "$case_dir/fake-bin"
printf 'unrelated app sentinel\n' >"$case_home/Applications/px0 URL Handler.app/UNRELATED_APP_SENTINEL"
cat >"$case_dir/fake-bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
cat >"$case_dir/fake-bin/swiftc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$case_dir/fake-bin/uname" "$case_dir/fake-bin/swiftc"
if HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" "$INSTALLER" --prefix "$case_prefix" --url-handler \
    >/dev/null 2>&1; then
    unrelated_app_rc=0
else
    unrelated_app_rc=$?
fi
if [[ "$unrelated_app_rc" -ne 0 &&
      -f "$case_home/Applications/px0 URL Handler.app/UNRELATED_APP_SENTINEL" &&
      ! -e "$case_prefix/bin/px0-open" && ! -e "$case_prefix/bin/hyperlink-paths" ]]; then
    pass "installer preserves unrelated same-name URL-handler app"
else
    fail "installer preserves unrelated same-name URL-handler app" "rc=$unrelated_app_rc"
fi

case_dir="$SANDBOX/install-herdr-rollback"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
case_config="$case_dir/herdr-config"
mkdir -p "$case_home" "$case_dir/fake-bin" "$case_config"
printf 'old-link:elsewhere\n' >"$case_dir/link-state"
printf 'old helper path\n' >"$case_config/px0-open-path"
cat >"$case_dir/fake-bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == 'plugin list' ]]; then printf '%s\n' '{"result":{"plugins":[]}}'; exit 0; fi
if [[ "$1 ${2:-}" == 'plugin config-dir' ]]; then printf '%s\n' "${HERDR_TEST_CONFIG:?}"; exit 0; fi
if [[ "$1 ${2:-}" == 'plugin link' ]]; then printf 'new-link:%s\n' "$3" >"${HERDR_LINK_STATE:?}"; exit 0; fi
exit 2
EOF
real_mktemp=$(command -v mktemp)
cat >"$case_dir/fake-bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "${FAIL_MKTEMP_PREFIX:?}"* ]]; then exit 1; fi
exec "${REAL_MKTEMP:?}" "$@"
EOF
chmod +x "$case_dir/fake-bin/herdr" "$case_dir/fake-bin/mktemp"
if HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" HERDR_TEST_CONFIG="$case_config" \
    HERDR_LINK_STATE="$case_dir/link-state" FAIL_MKTEMP_PREFIX="$case_config/.px0-open-path." \
    REAL_MKTEMP="$real_mktemp" "$INSTALLER" --prefix "$case_prefix" --herdr >/dev/null 2>&1; then
    herdr_rollback_rc=0
else
    herdr_rollback_rc=$?
fi
if [[ "$herdr_rollback_rc" -ne 0 && "$(cat "$case_dir/link-state")" == 'old-link:elsewhere' &&
      "$(cat "$case_config/px0-open-path")" == 'old helper path' &&
      ! -e "$case_prefix/bin/px0-open" && ! -e "$case_prefix/bin/hyperlink-paths" ]]; then
    pass "failed Herdr config stage preserves prior link and rolls back helpers"
else
    fail "failed Herdr config stage preserves prior link and rolls back helpers" "rc=$herdr_rollback_rc"
fi

case_dir="$SANDBOX/install-registration-rollback"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
mkdir -p "$case_home" "$case_dir/fake-bin"
printf 'old-association\n' >"$case_dir/association"
cat >"$case_dir/fake-bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
cat >"$case_dir/fake-bin/swiftc" <<'EOF'
#!/usr/bin/env bash
out=''
while [[ $# -gt 0 ]]; do
    if [[ "$1" == '-o' ]]; then out="$2"; shift 2; else shift; fi
done
mkdir -p "$(dirname "$out")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$out"
chmod +x "$out"
EOF
cat >"$case_dir/fake-bin/duti" <<'EOF'
#!/usr/bin/env bash
printf 'new-association:%s\n' "$*" >"${DUTI_STATE:?}"
EOF
cat >"$case_dir/fake-bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == 'plugin list' ]]; then printf '%s\n' '{"result":{"plugins":[]}}'; exit 0; fi
if [[ "$1 ${2:-}" == 'plugin config-dir' ]]; then exit 42; fi
exit 0
EOF
chmod +x "$case_dir/fake-bin/"*
if HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" DUTI_STATE="$case_dir/association" \
    "$INSTALLER" --prefix "$case_prefix" --url-handler --herdr >/dev/null 2>&1; then
    registration_rollback_rc=0
else
    registration_rollback_rc=$?
fi
if [[ "$registration_rollback_rc" -ne 0 && "$(cat "$case_dir/association")" == 'old-association' &&
      ! -e "$case_home/Applications/px0 URL Handler.app" &&
      ! -e "$case_prefix/bin/px0-open" && ! -e "$case_prefix/bin/hyperlink-paths" ]]; then
    pass "failed later stage does not change URL registration"
else
    fail "failed later stage does not change URL registration" "rc=$registration_rollback_rc"
fi

case_dir="$SANDBOX/install-herdr-partial-link"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
case_config="$case_dir/herdr-config"
mkdir -p "$case_home" "$case_dir/fake-bin" "$case_config"
printf 'absent\n' >"$case_dir/link-state"
cat >"$case_dir/fake-bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == 'plugin list' ]]; then printf '%s\n' '{"result":{"plugins":[]}}'; exit 0; fi
if [[ "$1 ${2:-}" == 'plugin config-dir' ]]; then printf '%s\n' "${HERDR_TEST_CONFIG:?}"; exit 0; fi
if [[ "$1 ${2:-}" == 'plugin link' ]]; then printf 'new-link:%s\n' "$3" >"${HERDR_LINK_STATE:?}"; exit 42; fi
if [[ "$1 ${2:-}" == 'plugin unlink' ]]; then printf 'absent\n' >"${HERDR_LINK_STATE:?}"; exit 0; fi
exit 2
EOF
chmod +x "$case_dir/fake-bin/herdr"
if HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" HERDR_TEST_CONFIG="$case_config" \
    HERDR_LINK_STATE="$case_dir/link-state" "$INSTALLER" --prefix "$case_prefix" --herdr >/dev/null 2>&1; then
    herdr_partial_rc=0
else
    herdr_partial_rc=$?
fi
if [[ "$herdr_partial_rc" -ne 0 && "$(cat "$case_dir/link-state")" == 'absent' &&
      ! -e "$case_config/px0-open-path" &&
      ! -e "$case_prefix/bin/px0-open" && ! -e "$case_prefix/bin/hyperlink-paths" ]]; then
    pass "partial Herdr link failure restores absent registry state"
else
    fail "partial Herdr link failure restores absent registry state" "rc=$herdr_partial_rc"
fi

case_dir="$SANDBOX/install-herdr-unrelated"
case_home="$case_dir/home"
case_prefix="$case_dir/prefix"
mkdir -p "$case_home" "$case_dir/fake-bin"
printf 'old-link:elsewhere\n' >"$case_dir/link-state"
cat >"$case_dir/fake-bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == 'plugin list' ]]; then
    printf '%s\n' '{"result":{"plugins":[{"plugin_id":"joeharris76.px0-opener","plugin_root":"/elsewhere/plugin","enabled":true,"source":{"kind":"local"}}]}}'
    exit 0
fi
if [[ "$1 ${2:-}" == 'plugin link' ]]; then printf 'new-link\n' >"${HERDR_LINK_STATE:?}"; exit 0; fi
exit 2
EOF
chmod +x "$case_dir/fake-bin/herdr"
if HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" HERDR_LINK_STATE="$case_dir/link-state" \
    "$INSTALLER" --prefix "$case_prefix" --herdr >/dev/null 2>&1; then
    herdr_unrelated_rc=0
else
    herdr_unrelated_rc=$?
fi
if [[ "$herdr_unrelated_rc" -ne 0 && "$(cat "$case_dir/link-state")" == 'old-link:elsewhere' &&
      ! -e "$case_prefix/bin/px0-open" && ! -e "$case_prefix/bin/hyperlink-paths" ]]; then
    pass "installer preserves unrelated Herdr plugin registration"
else
    fail "installer preserves unrelated Herdr plugin registration" "rc=$herdr_unrelated_rc"
fi

# Custom prefix must reach the shell, Herdr, and URL-handler bundle.
case_dir="$SANDBOX/install-custom-prefix"
case_home="$case_dir/home"
case_prefix="$case_dir/custom prefix"
case_config="$case_dir/herdr-config"
mkdir -p "$case_home" "$case_dir/fake-bin" "$case_config"
cat >"$case_dir/fake-bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
cat >"$case_dir/fake-bin/swiftc" <<'EOF'
#!/usr/bin/env bash
out=''
while [[ $# -gt 0 ]]; do
    if [[ "$1" == '-o' ]]; then out="$2"; shift 2; else shift; fi
done
[[ -n "$out" ]] || exit 2
mkdir -p "$(dirname "$out")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$out"
chmod +x "$out"
EOF
cat >"$case_dir/fake-bin/duti" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$case_dir/fake-bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == 'plugin list' ]]; then printf '%s\n' '{"result":{"plugins":[]}}'; exit 0; fi
if [[ "$1 ${2:-}" == 'plugin link' ]]; then exit 0; fi
if [[ "$1 ${2:-}" == 'plugin config-dir' ]]; then printf '%s\n' "${HERDR_TEST_CONFIG:?}"; exit 0; fi
exit 2
EOF
chmod +x "$case_dir/fake-bin/"*
if HOME="$case_home" PATH="$case_dir/fake-bin:$PATH" HERDR_TEST_CONFIG="$case_config" \
    "$INSTALLER" --prefix "$case_prefix" --shell --url-handler --herdr >"$case_dir/out" 2>&1; then
    custom_rc=0
else
    custom_rc=$?
fi
app_config="$case_home/Applications/px0 URL Handler.app/Contents/Resources/px0-open-path"
if [[ "$custom_rc" -eq 0 && "$(cat "$case_config/px0-open-path" 2>/dev/null)" == "$case_prefix/bin/px0-open" &&
      "$(cat "$app_config" 2>/dev/null)" == "$case_prefix/bin/px0-open" ]] &&
    HOME="$case_home" zsh -c 'source "$HOME/.zshrc"; whence px >/dev/null'; then
    pass "custom prefix propagates to shell, Herdr, and URL handler"
else
    fail "custom prefix propagates to shell, Herdr, and URL handler" "rc=$custom_rc $(cat "$case_dir/out")"
fi

# Both Herdr actions must consume the installer-recorded helper path, not fall
# back to ~/.local when PX0_OPEN_BIN is unset.
: >"$PX0_CALL_LOG"
if HOME="$case_home" HERDR_PLUGIN_CONFIG_DIR="$case_config" PX0_BIN="$SANDBOX/bin/px0" \
    PX0_OPEN_LOG_DIR="$case_dir/click-log" \
    HERDR_PLUGIN_CLICKED_URL="px0://$SANDBOX/project/notes.md" \
    bash "$INSTALL_REPO/herdr-plugin/open.sh" >/dev/null &&
    wait_for_call "$SANDBOX/project/notes.md"; then
    custom_clicked_ok=1
else
    custom_clicked_ok=0
fi
: >"$PX0_CALL_LOG"
context=$(python3 -c 'import json,sys; print(json.dumps({"selected_text":sys.argv[1]}))' "$SANDBOX/project/notes.md")
if HOME="$case_home" HERDR_PLUGIN_CONFIG_DIR="$case_config" PX0_BIN="$SANDBOX/bin/px0" \
    PX0_OPEN_LOG_DIR="$case_dir/selected-log" HERDR_PLUGIN_CONTEXT_JSON="$context" \
    bash "$INSTALL_REPO/herdr-plugin/open-selected.sh" >/dev/null &&
    wait_for_call "$SANDBOX/project/notes.md"; then
    custom_selected_ok=1
else
    custom_selected_ok=0
fi
if [[ "$custom_clicked_ok" -eq 1 && "$custom_selected_ok" -eq 1 ]]; then
    pass "both Herdr actions consume custom-prefix configuration"
else
    fail "both Herdr actions consume custom-prefix configuration" \
        "clicked=$custom_clicked_ok selected=$custom_selected_ok calls=$(cat "$PX0_CALL_LOG")"
fi

# The regular Herdr clicked-URL action still forwards allowed schemes.
: >"$PX0_CALL_LOG"
if HERDR_PLUGIN_CLICKED_URL="px0://$SANDBOX/project/notes.md?line=1" PX0_OPEN_BIN="$BIN/px0-open" \
    bash "$REPO_DIR/herdr-plugin/open.sh" >/dev/null && wait_for_call "$SANDBOX/project/notes.md:1"; then
    pass "Herdr clicked-URL action forwards px0 URL"
else
    fail "Herdr clicked-URL action forwards px0 URL" "$(cat "$PX0_CALL_LOG")"
fi
if HERDR_PLUGIN_CLICKED_URL='https://example.com/x' PX0_OPEN_BIN="$BIN/px0-open" \
    bash "$REPO_DIR/herdr-plugin/open.sh" >/dev/null 2>&1; then
    fail "Herdr clicked-URL action rejects unknown schemes" "exited 0"
else
    pass "Herdr clicked-URL action rejects unknown schemes"
fi

# Swift handler compile check, when the macOS toolchain is available.
if command -v swiftc >/dev/null 2>&1; then
    if swiftc -O -o "$SANDBOX/px0-url-handler-test" "$REPO_DIR/macos/px0-url-handler/main.swift" 2>"$SANDBOX/swiftc.log"; then
        pass "Swift URL handler compiles"
    else
        fail "Swift URL handler compiles" "$(head -n 5 "$SANDBOX/swiftc.log")"
    fi
else
    echo "skip  swiftc not installed"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    printf '%d failure(s)\n' "$FAILURES"
    exit 1
fi
printf 'all smoke tests passed\n'
