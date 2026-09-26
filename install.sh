#!/usr/bin/env bash
# px0-click installer.
#
# Installs the px0 click-to-open toolchain into a home directory:
#   bin/px0-open, bin/hyperlink-paths  -> $PREFIX/bin (default ~/.local/bin)
#   shell/px0-click.zsh                -> $PREFIX/share/px0-click/ + sourced from ~/.zshrc
#   macOS px0:// URL handler app       -> ~/Applications (macOS only, --url-handler)
#   Herdr plugin                       -> linked via `herdr plugin link` (--herdr)
#
# Usage:
#   ./install.sh [--prefix ~/.local] [--url-handler] [--herdr] [--shell] [--all]
#   ./install.sh --uninstall [--prefix ~/.local]
#
# Nothing here touches px0 itself; it must already be installed.
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${HOME}/.local"
DO_SHELL=0
DO_URL_HANDLER=0
DO_HERDR=0
UNINSTALL=0

usage() {
    sed -n '2,/^#$/p' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --all) DO_SHELL=1; DO_URL_HANDLER=1; DO_HERDR=1; shift ;;
        --shell) DO_SHELL=1; shift ;;
        --url-handler) DO_URL_HANDLER=1; shift ;;
        --herdr) DO_HERDR=1; shift ;;
        --bin-only) DO_SHELL=0; DO_URL_HANDLER=0; DO_HERDR=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$PREFIX" != /* ]]; then
    PREFIX="$PWD/$PREFIX"
fi

BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/px0-click"
ZSHRC="$HOME/.zshrc"
printf -v SHELL_SCRIPT_QUOTED '%q' "$SHARE_DIR/px0-click.zsh"
SOURCE_LINE="[[ -f $SHELL_SCRIPT_QUOTED ]] && source $SHELL_SCRIPT_QUOTED"
# shellcheck disable=SC2016 # This legacy line is matched literally in .zshrc.
LEGACY_SOURCE_LINE='[[ -f "$HOME/.local/share/px0-click/px0-click.zsh" ]] && source "$HOME/.local/share/px0-click/px0-click.zsh"'
SOURCE_MARKER='# Click-to-open in px0 (px0-click).'
APP_NAME="px0 URL Handler.app"
APP_DIR="$HOME/Applications/$APP_NAME"
HERDR_PLUGIN_ID="joeharris76.px0-opener"

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

is_owned_helper() {
    local name="$1" path="$2" signature
    [[ -f "$path" && ! -L "$path" ]] || return 1
    case "$name" in
        px0-open)
            signature='# px0-open: open a file path or px0:///file URL in the px0 file browser.'
            ;;
        hyperlink-paths)
            signature='"""hyperlink-paths: wrap filesystem paths in stdin with OSC 8 px0:// hyperlinks.'
            ;;
        *)
            return 1
            ;;
    esac
    grep -Fqx "$signature" "$path" 2>/dev/null
}

is_owned_shell() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    grep -Fqx '# px0 click-to-open: make file paths printed in the terminal open in px0.' "$1" 2>/dev/null
}

is_owned_app() {
    local plist="$1/Contents/Info.plist"
    [[ -d "$1" && ! -L "$1" && -f "$plist" ]] || return 1
    awk '
        /<key>CFBundleIdentifier<\/key>/ {
            found = 1
            if ($0 ~ /<string>dev\.px0\.url-handler<\/string>/) exit 0
            next
        }
        found && /<string>dev\.px0\.url-handler<\/string>/ { exit 0 }
        found { exit 1 }
        END { if (!found) exit 1 }
    ' "$plist" 2>/dev/null
}

ensure_helper_replaceable() {
    local name="$1" path="$2"
    if path_exists "$path" && ! is_owned_helper "$name" "$path"; then
        echo "px0-click: refusing to overwrite unrelated helper at $path" >&2
        return 1
    fi
}

INSTALL_TXN_DIR=""
INSTALL_TXN_HERDR_PATH=""
INSTALL_TXN_ACTIVE=0
HERDR_LINK_WAS_PRESENT=0
HERDR_LINK_WAS_ENABLED=1
HERDR_LINK_ATTEMPTED=0

snapshot_install_path() {
    local key="$1" path="$2" slot
    slot="$INSTALL_TXN_DIR/$key"
    mkdir -p "$slot" || return 1
    if path_exists "$path"; then
        printf 'present\n' >"$slot/state" || return 1
        cp -pR "$path" "$slot/value" || return 1
    else
        printf 'absent\n' >"$slot/state" || return 1
    fi
}

restore_install_path() {
    local key="$1" path="$2" slot
    slot="$INSTALL_TXN_DIR/$key"
    [[ -f "$slot/state" ]] || return 0
    rm -rf "$path" || return 1
    if [[ "$(cat "$slot/state")" == "present" ]]; then
        mkdir -p "$(dirname "$path")" || return 1
        cp -pR "$slot/value" "$path" || return 1
    fi
}

begin_install_transaction() {
    INSTALL_TXN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/px0-click-install.XXXXXX")" || return 1
    snapshot_install_path bin-px0-open "$BIN_DIR/px0-open" || return 1
    snapshot_install_path bin-hyperlink-paths "$BIN_DIR/hyperlink-paths" || return 1
    if [[ "$DO_SHELL" -eq 1 ]]; then
        snapshot_install_path shell-script "$SHARE_DIR/px0-click.zsh" || return 1
        snapshot_install_path zshrc "$ZSHRC" || return 1
    fi
    if [[ "$DO_URL_HANDLER" -eq 1 ]]; then
        snapshot_install_path url-handler "$APP_DIR" || return 1
    fi
    INSTALL_TXN_ACTIVE=1
}

snapshot_herdr_config() {
    INSTALL_TXN_HERDR_PATH="$1"
    snapshot_install_path herdr-config "$INSTALL_TXN_HERDR_PATH"
}

rollback_install_transaction() {
    local failed=0
    if [[ "$HERDR_LINK_ATTEMPTED" -eq 1 ]]; then
        restore_herdr_link_state || failed=1
        HERDR_LINK_ATTEMPTED=0
    fi
    if [[ -n "$INSTALL_TXN_HERDR_PATH" ]]; then
        restore_install_path herdr-config "$INSTALL_TXN_HERDR_PATH" || failed=1
    fi
    if [[ "$DO_URL_HANDLER" -eq 1 ]]; then
        restore_install_path url-handler "$APP_DIR" || failed=1
    fi
    if [[ "$DO_SHELL" -eq 1 ]]; then
        restore_install_path zshrc "$ZSHRC" || failed=1
        restore_install_path shell-script "$SHARE_DIR/px0-click.zsh" || failed=1
    fi
    restore_install_path bin-hyperlink-paths "$BIN_DIR/hyperlink-paths" || failed=1
    restore_install_path bin-px0-open "$BIN_DIR/px0-open" || failed=1
    if [[ "$failed" -eq 0 ]]; then
        rm -rf "$INSTALL_TXN_DIR"
        INSTALL_TXN_DIR=""
        INSTALL_TXN_ACTIVE=0
        return 0
    fi
    echo "px0-click: rollback was incomplete; recovery snapshot retained at $INSTALL_TXN_DIR" >&2
    return 1
}

commit_install_transaction() {
    # Installation is complete before deleting the recovery snapshot. A signal
    # during snapshot cleanup should leave the coherent new install in place.
    INSTALL_TXN_ACTIVE=0
    if ! rm -rf "$INSTALL_TXN_DIR"; then
        INSTALL_TXN_ACTIVE=1
        return 1
    fi
    INSTALL_TXN_DIR=""
}

restore_herdr_link_state() {
    if [[ "$HERDR_LINK_WAS_PRESENT" -eq 0 ]]; then
        herdr plugin unlink "$HERDR_PLUGIN_ID" >/dev/null 2>&1
    elif [[ "$HERDR_LINK_WAS_ENABLED" -eq 1 ]]; then
        herdr plugin enable "$HERDR_PLUGIN_ID" >/dev/null 2>&1
    else
        herdr plugin disable "$HERDR_PLUGIN_ID" >/dev/null 2>&1
    fi
}

rollback_on_exit() {
    local rc=$?
    trap - EXIT HUP INT TERM
    if [[ "$INSTALL_TXN_ACTIVE" -eq 1 ]]; then
        echo "px0-click: installation interrupted; restoring the previous installation" >&2
        rollback_install_transaction || true
    fi
    exit "$rc"
}

rollback_on_signal() {
    local rc="$1"
    trap - EXIT HUP INT TERM
    if [[ "$INSTALL_TXN_ACTIVE" -eq 1 ]]; then
        echo "px0-click: installation interrupted; restoring the previous installation" >&2
        rollback_install_transaction || true
    fi
    exit "$rc"
}

arm_install_transaction_traps() {
    trap rollback_on_exit EXIT
    trap 'rollback_on_signal 129' HUP
    trap 'rollback_on_signal 130' INT
    trap 'rollback_on_signal 143' TERM
}

disarm_install_transaction_traps() {
    trap - EXIT HUP INT TERM
}

inspect_herdr_link_state() {
    local response state py
    py="$(command -v python3 2>/dev/null || true)"
    if [[ -z "$py" ]]; then
        echo "px0-click: python3 is required to inspect existing Herdr plugin ownership" >&2
        return 1
    fi
    response="$(herdr plugin list --plugin "$HERDR_PLUGIN_ID" --json)" || {
        echo "px0-click: cannot inspect existing Herdr plugin registration" >&2
        return 1
    }
    state="$(HERDR_PLUGIN_LIST_JSON="$response" "$py" - "$REPO_DIR/herdr-plugin" <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ["HERDR_PLUGIN_LIST_JSON"])
    plugins = data["result"]["plugins"]
except (KeyError, TypeError, ValueError):
    raise SystemExit("invalid plugin list response")
if len(plugins) == 0:
    print("absent")
elif len(plugins) == 1:
    plugin = plugins[0]
    same_root = os.path.realpath(plugin.get("plugin_root", "")) == os.path.realpath(sys.argv[1])
    if plugin.get("source", {}).get("kind", "local") == "local" and same_root:
        print("owned-enabled" if plugin.get("enabled", True) else "owned-disabled")
    else:
        print("other")
else:
    raise SystemExit("multiple plugins returned for one id")
PY
    )" || {
        echo "px0-click: cannot parse existing Herdr plugin registration" >&2
        return 1
    }
    case "$state" in
        absent)
            HERDR_LINK_WAS_PRESENT=0
            HERDR_LINK_WAS_ENABLED=1
            ;;
        owned-enabled)
            HERDR_LINK_WAS_PRESENT=1
            HERDR_LINK_WAS_ENABLED=1
            ;;
        owned-disabled)
            HERDR_LINK_WAS_PRESENT=1
            HERDR_LINK_WAS_ENABLED=0
            ;;
        other)
            echo "px0-click: refusing to replace unrelated Herdr plugin registration for $HERDR_PLUGIN_ID" >&2
            return 1
            ;;
        *)
            echo "px0-click: unexpected Herdr plugin registration state" >&2
            return 1
            ;;
    esac
}

preflight_install() {
    ensure_helper_replaceable px0-open "$BIN_DIR/px0-open" || return 1
    ensure_helper_replaceable hyperlink-paths "$BIN_DIR/hyperlink-paths" || return 1
    if [[ "$DO_SHELL" -eq 1 ]]; then
        if path_exists "$SHARE_DIR/px0-click.zsh" && ! is_owned_shell "$SHARE_DIR/px0-click.zsh"; then
            echo "px0-click: refusing to overwrite unrelated shell file at $SHARE_DIR/px0-click.zsh" >&2
            return 1
        fi
        if [[ -L "$ZSHRC" ]]; then
            echo "px0-click: refusing to replace symlinked $ZSHRC; edit its target manually" >&2
            return 1
        fi
    fi
    if [[ "$DO_URL_HANDLER" -eq 1 ]] && path_exists "$APP_DIR" && ! is_owned_app "$APP_DIR"; then
        echo "px0-click: refusing to overwrite unrelated app at $APP_DIR" >&2
        return 1
    fi
    if [[ "$DO_HERDR" -eq 1 ]] && ! command -v herdr >/dev/null 2>&1; then
        echo "px0-click: herdr not found; skipped." >&2
        return 1
    fi
    if [[ "$DO_HERDR" -eq 1 ]]; then
        inspect_herdr_link_state || return 1
    fi
}

remove_owned_helper() {
    local name="$1" path="$2"
    path_exists "$path" || return 0
    if ! is_owned_helper "$name" "$path"; then
        echo "px0-click: preserving unrelated helper at $path" >&2
        return 0
    fi
    rm -f "$path"
}

has_owned_zshrc_line() {
    local rc
    grep -Fqx -- "$SOURCE_LINE" "$ZSHRC" 2>/dev/null && return 0
    rc=$?
    [[ "$rc" -gt 1 ]] && return "$rc"
    grep -Fqx -- "$LEGACY_SOURCE_LINE" "$ZSHRC" 2>/dev/null && return 0
    rc=$?
    [[ "$rc" -gt 1 ]] && return "$rc"
    # A marker causes the stricter state-machine filter below to inspect the
    # following source line. This recognizes installer stanzas from old custom
    # prefixes without treating arbitrary substring matches as owned.
    grep -Fqx -- "$SOURCE_MARKER" "$ZSHRC" 2>/dev/null
}

filter_owned_zshrc_lines() {
    PX0_CLICK_SOURCE_LINE="$SOURCE_LINE" \
    PX0_CLICK_LEGACY_SOURCE_LINE="$LEGACY_SOURCE_LINE" \
    PX0_CLICK_SOURCE_MARKER="$SOURCE_MARKER" \
        awk '
            function owned_source(line, prefix, separator, body, split_at, left, right) {
                prefix = "[[ -f "
                separator = " ]] && source "
                if (substr(line, 1, length(prefix)) != prefix) return 0
                body = substr(line, length(prefix) + 1)
                split_at = index(body, separator)
                if (split_at == 0) return 0
                left = substr(body, 1, split_at - 1)
                right = substr(body, split_at + length(separator))
                if (left != right) return 0
                if (substr(left, 1, 1) == "\"" && substr(left, length(left), 1) == "\"") {
                    left = substr(left, 2, length(left) - 2)
                }
                return left ~ /\/share\/px0-click\/px0-click\.zsh$/
            }
            BEGIN {
                owned = ENVIRON["PX0_CLICK_SOURCE_LINE"]
                legacy = ENVIRON["PX0_CLICK_LEGACY_SOURCE_LINE"]
                marker = ENVIRON["PX0_CLICK_SOURCE_MARKER"]
                pending_marker = ""
            }
            $0 == marker { pending_marker = $0; next }
            $0 == owned || $0 == legacy || (pending_marker != "" && owned_source($0)) {
                pending_marker = ""
                next
            }
            {
                if (pending_marker != "") {
                    print pending_marker
                    pending_marker = ""
                }
                print
            }
            END {
                if (pending_marker != "") print pending_marker
            }
        ' "$ZSHRC"
}

prepare_zshrc_without_integration() {
    local rc
    ZSHRC_TMP=""
    path_exists "$ZSHRC" || return 0
    if [[ -L "$ZSHRC" ]]; then
        echo "px0-click: refusing to replace symlinked $ZSHRC; edit its target manually" >&2
        return 1
    fi
    if [[ ! -f "$ZSHRC" ]]; then
        echo "px0-click: refusing to modify non-file $ZSHRC" >&2
        return 1
    fi
    if has_owned_zshrc_line; then
        :
    else
        rc=$?
        if [[ "$rc" -eq 1 ]]; then
            return 0
        fi
        echo "px0-click: cannot read $ZSHRC; leaving it unchanged" >&2
        return 1
    fi
    ZSHRC_TMP="$(mktemp "${ZSHRC}.px0-click.XXXXXX")" || return 1
    if ! cp -p "$ZSHRC" "$ZSHRC_TMP" ||
        ! filter_owned_zshrc_lines >"$ZSHRC_TMP"; then
        rm -f "$ZSHRC_TMP"
        ZSHRC_TMP=""
        echo "px0-click: cannot safely update $ZSHRC; leaving it unchanged" >&2
        return 1
    fi
}

uninstall() {
    ZSHRC_TMP=""
    prepare_zshrc_without_integration || return 1

    if [[ -n "$ZSHRC_TMP" ]]; then
        if ! mv -f "$ZSHRC_TMP" "$ZSHRC"; then
            rm -f "$ZSHRC_TMP"
            echo "px0-click: failed to update $ZSHRC" >&2
            return 1
        fi
        ZSHRC_TMP=""
    fi

    remove_owned_helper px0-open "$BIN_DIR/px0-open" || return 1
    remove_owned_helper hyperlink-paths "$BIN_DIR/hyperlink-paths" || return 1
    if path_exists "$SHARE_DIR/px0-click.zsh"; then
        if is_owned_shell "$SHARE_DIR/px0-click.zsh"; then
            rm -f "$SHARE_DIR/px0-click.zsh" || return 1
        else
            echo "px0-click: preserving unrelated shell file at $SHARE_DIR/px0-click.zsh" >&2
        fi
    fi
    rmdir "$SHARE_DIR" 2>/dev/null || true
    echo "px0-click: helpers removed. (The $APP_NAME bundle and Herdr plugin link are left in place; remove manually.)"
}

install_bin() {
    local stage had_px0=0
    ensure_helper_replaceable px0-open "$BIN_DIR/px0-open" || return 1
    ensure_helper_replaceable hyperlink-paths "$BIN_DIR/hyperlink-paths" || return 1
    mkdir -p "$BIN_DIR" "$SHARE_DIR" || return 1
    stage="$(mktemp -d "$BIN_DIR/.px0-click-install.XXXXXX")" || return 1

    if ! cp "$REPO_DIR/bin/px0-open" "$stage/px0-open" ||
        ! cp "$REPO_DIR/bin/hyperlink-paths" "$stage/hyperlink-paths" ||
        ! chmod +x "$stage/px0-open" "$stage/hyperlink-paths"; then
        rm -rf "$stage"
        return 1
    fi

    if path_exists "$BIN_DIR/px0-open"; then
        had_px0=1
        cp -p "$BIN_DIR/px0-open" "$stage/px0-open.backup" || { rm -rf "$stage"; return 1; }
    fi
    if path_exists "$BIN_DIR/hyperlink-paths"; then
        cp -p "$BIN_DIR/hyperlink-paths" "$stage/hyperlink-paths.backup" || { rm -rf "$stage"; return 1; }
    fi

    if ! mv -f "$stage/px0-open" "$BIN_DIR/px0-open"; then
        rm -rf "$stage"
        return 1
    fi
    if ! mv -f "$stage/hyperlink-paths" "$BIN_DIR/hyperlink-paths"; then
        if [[ "$had_px0" -eq 1 ]]; then
            if ! mv -f "$stage/px0-open.backup" "$BIN_DIR/px0-open"; then
                echo "px0-click: failed to restore prior px0-open; backup retained at $stage/px0-open.backup" >&2
                return 1
            fi
        elif ! rm -f "$BIN_DIR/px0-open"; then
            echo "px0-click: failed to roll back $BIN_DIR/px0-open" >&2
            return 1
        fi
        rm -rf "$stage"
        return 1
    fi

    rm -rf "$stage"
    echo "px0-click: installed px0-open, hyperlink-paths -> $BIN_DIR"
}

prepare_zshrc_with_integration() {
    if [[ -L "$ZSHRC" ]]; then
        echo "px0-click: refusing to replace symlinked $ZSHRC; edit its target manually" >&2
        return 1
    fi
    ZSHRC_TMP="$(mktemp "${ZSHRC}.px0-click.XXXXXX")" || return 1
    if path_exists "$ZSHRC"; then
        if [[ ! -f "$ZSHRC" ]] || ! cp -p "$ZSHRC" "$ZSHRC_TMP"; then
            rm -f "$ZSHRC_TMP"
            ZSHRC_TMP=""
            echo "px0-click: cannot read $ZSHRC; leaving it unchanged" >&2
            return 1
        fi
        if ! filter_owned_zshrc_lines >"$ZSHRC_TMP"; then
            rm -f "$ZSHRC_TMP"
            ZSHRC_TMP=""
            echo "px0-click: cannot safely update $ZSHRC; leaving it unchanged" >&2
            return 1
        fi
    else
        : >"$ZSHRC_TMP" || { rm -f "$ZSHRC_TMP"; ZSHRC_TMP=""; return 1; }
    fi
    printf '\n# Click-to-open in px0 (px0-click).\n%s\n' "$SOURCE_LINE" >>"$ZSHRC_TMP" || {
        rm -f "$ZSHRC_TMP"
        ZSHRC_TMP=""
        return 1
    }
}

install_shell() {
    local stage backup="" had_shell=0
    if path_exists "$SHARE_DIR/px0-click.zsh" && ! is_owned_shell "$SHARE_DIR/px0-click.zsh"; then
        echo "px0-click: refusing to overwrite unrelated shell file at $SHARE_DIR/px0-click.zsh" >&2
        return 1
    fi
    prepare_zshrc_with_integration || return 1
    mkdir -p "$SHARE_DIR" || { rm -f "$ZSHRC_TMP"; ZSHRC_TMP=""; return 1; }
    stage="$(mktemp "$SHARE_DIR/.px0-click.zsh.XXXXXX")" || {
        rm -f "$ZSHRC_TMP"
        ZSHRC_TMP=""
        return 1
    }
    if ! cp "$REPO_DIR/shell/px0-click.zsh" "$stage"; then
        rm -f "$stage" "$ZSHRC_TMP"
        ZSHRC_TMP=""
        return 1
    fi
    if path_exists "$SHARE_DIR/px0-click.zsh"; then
        had_shell=1
        backup="$(mktemp "$SHARE_DIR/.px0-click.zsh.backup.XXXXXX")" || {
            rm -f "$stage" "$ZSHRC_TMP"
            ZSHRC_TMP=""
            return 1
        }
        cp -p "$SHARE_DIR/px0-click.zsh" "$backup" || {
            rm -f "$stage" "$backup" "$ZSHRC_TMP"
            ZSHRC_TMP=""
            return 1
        }
    fi
    if ! mv -f "$stage" "$SHARE_DIR/px0-click.zsh"; then
        rm -f "$stage" "$backup" "$ZSHRC_TMP"
        ZSHRC_TMP=""
        return 1
    fi
    if ! mv -f "$ZSHRC_TMP" "$ZSHRC"; then
        rm -f "$ZSHRC_TMP"
        ZSHRC_TMP=""
        if [[ "$had_shell" -eq 1 ]]; then
            if ! mv -f "$backup" "$SHARE_DIR/px0-click.zsh"; then
                echo "px0-click: failed to restore prior shell file; backup retained at $backup" >&2
                return 1
            fi
        elif ! rm -f "$SHARE_DIR/px0-click.zsh"; then
            echo "px0-click: failed to roll back $SHARE_DIR/px0-click.zsh" >&2
            return 1
        fi
        echo "px0-click: failed to update $ZSHRC" >&2
        return 1
    fi
    ZSHRC_TMP=""
    rm -f "$backup"
    echo "px0-click: shell integration -> $SHARE_DIR/px0-click.zsh (sourced from ~/.zshrc)"
}

install_url_handler() {
    local app_parent="$HOME/Applications" build staged_app backup=""
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "px0-click: --url-handler is macOS only; skipped." >&2
        return 1
    fi
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "px0-click: swiftc not found; cannot build the URL handler." >&2
        return 1
    fi
    if path_exists "$APP_DIR" && ! is_owned_app "$APP_DIR"; then
        echo "px0-click: refusing to overwrite unrelated app at $APP_DIR" >&2
        return 1
    fi

    mkdir -p "$app_parent" || return 1
    build="$(mktemp -d "$app_parent/.px0-url-handler-build.XXXXXX")" || return 1
    staged_app="$build/$APP_NAME"
    if ! mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" ||
        ! swiftc -O -o "$staged_app/Contents/MacOS/px0-open" \
            "$REPO_DIR/macos/px0-url-handler/main.swift" ||
        ! cp "$REPO_DIR/macos/px0-url-handler/Info.plist" "$staged_app/Contents/Info.plist" ||
        ! printf '%s\n' "$BIN_DIR/px0-open" >"$staged_app/Contents/Resources/px0-open-path"; then
        rm -rf "$build"
        return 1
    fi

    if path_exists "$APP_DIR"; then
        backup="$(mktemp -d "$app_parent/.px0-url-handler-backup.XXXXXX")" || {
            rm -rf "$build"
            return 1
        }
        rmdir "$backup" || { rm -rf "$backup" "$build"; return 1; }
        if ! mv "$APP_DIR" "$backup"; then
            rm -rf "$build"
            return 1
        fi
    fi

    if ! mv "$staged_app" "$APP_DIR"; then
        if [[ -n "$backup" ]]; then
            mv "$backup" "$APP_DIR" || echo "px0-click: failed to restore prior app from $backup" >&2
        fi
        rm -rf "$build"
        return 1
    fi
    rmdir "$build" 2>/dev/null || true
    if [[ -n "$backup" ]]; then
        rm -rf "$backup"
    fi

    echo "px0-click: URL handler -> $APP_DIR"
}

register_url_handler() {
    # Register only after every requested fallible stage has succeeded. These
    # best-effort commands are then the final external side effects.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
    if command -v duti >/dev/null 2>&1; then
        duti -s dev.px0.url-handler px0 all || true
    else
        echo "px0-click: duti not found; set the px0:// handler manually:" >&2
        echo "  brew install duti && duti -s dev.px0.url-handler px0 all" >&2
        echo "  (or Get Info on any .px0 file -> Open with -> $APP_NAME)" >&2
    fi
}

install_herdr() {
    local config_dir config_tmp link_rc
    if ! command -v herdr >/dev/null 2>&1; then
        echo "px0-click: herdr not found; skipped." >&2
        return 1
    fi
    config_dir="$(herdr plugin config-dir "$HERDR_PLUGIN_ID")" || return 1
    [[ -n "$config_dir" ]] || return 1
    mkdir -p "$config_dir" || return 1
    if [[ -n "$INSTALL_TXN_DIR" ]]; then
        snapshot_herdr_config "$config_dir/px0-open-path" || return 1
    fi
    config_tmp="$(mktemp "$config_dir/.px0-open-path.XXXXXX")" || return 1
    if ! printf '%s\n' "$BIN_DIR/px0-open" >"$config_tmp" ||
        ! mv -f "$config_tmp" "$config_dir/px0-open-path"; then
        rm -f "$config_tmp"
        return 1
    fi
    # Link last. The transaction rollback restores the preflight registry state
    # if Herdr reports failure after mutating it or the installer is interrupted.
    HERDR_LINK_ATTEMPTED=1
    if [[ "$HERDR_LINK_WAS_PRESENT" -eq 1 && "$HERDR_LINK_WAS_ENABLED" -eq 0 ]]; then
        herdr plugin link "$REPO_DIR/herdr-plugin" --disabled
    else
        herdr plugin link "$REPO_DIR/herdr-plugin"
    fi
    link_rc=$?
    if [[ "$link_rc" -ne 0 ]]; then
        return "$link_rc"
    fi
    echo "px0-click: Herdr plugin linked (restart the Herdr server to pick it up: herdr quit, then herdr)"
    return 0
}

if [[ "$UNINSTALL" -eq 1 ]]; then
    uninstall || exit 1
    exit 0
fi

preflight_install || exit 1
if ! begin_install_transaction; then
    [[ -n "$INSTALL_TXN_DIR" ]] && rm -rf "$INSTALL_TXN_DIR"
    exit 1
fi
arm_install_transaction_traps
install_rc=0
install_bin || install_rc=$?
if [[ "$DO_SHELL" -eq 1 ]]; then
    [[ "$install_rc" -ne 0 ]] || install_shell || install_rc=$?
fi
if [[ "$DO_URL_HANDLER" -eq 1 ]]; then
    [[ "$install_rc" -ne 0 ]] || install_url_handler || install_rc=$?
fi
if [[ "$DO_HERDR" -eq 1 ]]; then
    [[ "$install_rc" -ne 0 ]] || install_herdr || install_rc=$?
fi
if [[ "$install_rc" -ne 0 ]]; then
    echo "px0-click: installation failed; restoring the previous installation" >&2
    rollback_install_transaction || true
    exit "$install_rc"
fi
if ! commit_install_transaction; then
    echo "px0-click: failed to finalize installation; restoring the previous installation" >&2
    rollback_install_transaction || true
    exit 1
fi
disarm_install_transaction_traps
if [[ "$DO_URL_HANDLER" -eq 1 ]]; then
    register_url_handler
fi
echo "px0-click: done. Make sure $BIN_DIR is on PATH, then open a new shell."
