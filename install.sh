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
DO_BIN=1
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

BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/px0-click"
ZSHRC="$HOME/.zshrc"
SOURCE_LINE='[[ -f "$HOME/.local/share/px0-click/px0-click.zsh" ]] && source "$HOME/.local/share/px0-click/px0-click.zsh"'
APP_NAME="px0 URL Handler.app"
APP_DIR="$HOME/Applications/$APP_NAME"

uninstall() {
    rm -f "$BIN_DIR/px0-open" "$BIN_DIR/hyperlink-paths"
    rm -rf "$SHARE_DIR"
    if [[ -f "$ZSHRC" ]]; then
        grep -v 'share/px0-click/px0-click.zsh' "$ZSHRC" >"$ZSHRC.px0-click-tmp" || true
        mv "$ZSHRC.px0-click-tmp" "$ZSHRC"
    fi
    echo "px0-click: helpers removed. (The $APP_NAME bundle and Herdr plugin link are left in place; remove manually.)"
}

install_bin() {
    mkdir -p "$BIN_DIR" "$SHARE_DIR"
    cp "$REPO_DIR/bin/px0-open" "$BIN_DIR/px0-open"
    cp "$REPO_DIR/bin/hyperlink-paths" "$BIN_DIR/hyperlink-paths"
    chmod +x "$BIN_DIR/px0-open" "$BIN_DIR/hyperlink-paths"
    echo "px0-click: installed px0-open, hyperlink-paths -> $BIN_DIR"
}

install_shell() {
    mkdir -p "$SHARE_DIR"
    cp "$REPO_DIR/shell/px0-click.zsh" "$SHARE_DIR/px0-click.zsh"
    if [[ ! -f "$ZSHRC" ]]; then
        printf '%s\n' "$SOURCE_LINE" >"$ZSHRC"
    elif ! grep -qs 'share/px0-click/px0-click.zsh' "$ZSHRC"; then
        printf '\n# Click-to-open in px0 (px0-click).\n%s\n' "$SOURCE_LINE" >>"$ZSHRC"
    fi
    echo "px0-click: shell integration -> $SHARE_DIR/px0-click.zsh (sourced from ~/.zshrc)"
}

install_url_handler() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "px0-click: --url-handler is macOS only; skipped." >&2
        return 1
    fi
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "px0-click: swiftc not found; cannot build the URL handler." >&2
        return 1
    fi
    local build="$REPO_DIR/macos/px0-url-handler/build"
    rm -rf "$build" "$APP_DIR"
    mkdir -p "$build/$APP_NAME/Contents/MacOS"
    swiftc -O -o "$build/$APP_NAME/Contents/MacOS/px0-open" \
        "$REPO_DIR/macos/px0-url-handler/main.swift" || return 1
    cp "$REPO_DIR/macos/px0-url-handler/Info.plist" "$build/$APP_NAME/Contents/Info.plist"
    mkdir -p "$HOME/Applications"
    mv "$build/$APP_NAME" "$APP_DIR"
    rmdir "$build" 2>/dev/null || true
    # Register the bundle with LaunchServices and claim the px0:// scheme.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
    if command -v duti >/dev/null 2>&1; then
        duti -s dev.px0.url-handler px0 all || true
    else
        echo "px0-click: duti not found; set the px0:// handler manually:" >&2
        echo "  brew install duti && duti -s dev.px0.url-handler px0 all" >&2
        echo "  (or Get Info on any .px0 file -> Open with -> $APP_NAME)" >&2
    fi
    echo "px0-click: URL handler -> $APP_DIR"
}

install_herdr() {
    if ! command -v herdr >/dev/null 2>&1; then
        echo "px0-click: herdr not found; skipped." >&2
        return 1
    fi
    herdr plugin link "$REPO_DIR/herdr-plugin" || return 1
    echo "px0-click: Herdr plugin linked (restart the Herdr server to pick it up: herdr quit, then herdr)"
}

if [[ "$UNINSTALL" -eq 1 ]]; then
    uninstall
    exit 0
fi

install_bin
[[ "$DO_SHELL" -eq 1 ]] && install_shell
[[ "$DO_URL_HANDLER" -eq 1 ]] && install_url_handler
[[ "$DO_HERDR" -eq 1 ]] && install_herdr
echo "px0-click: done. Make sure $BIN_DIR is on PATH, then open a new shell."
