# px0-click

Make file paths printed in the terminal **Cmd/Ctrl-clickable to open in
[px0](https://github.com/openai/px0)**, the terminal file browser. Works in
[Ghostty](https://ghostty.org/) (Cmd+click) and
[Herdr](https://herdr.dev/) (Ctrl+click), with line/column info carried
through so `rg --vimgrep` matches open at the match.

## How it works

```
terminal output  ->  hyperlink-paths  ->  OSC 8 px0:// links  ->  click
px0:// click     ->  px0-open         ->  px0 <path> (detached)
Ghostty Cmd+click -> "px0 URL Handler" app -> px0-open -> px0
Herdr Ctrl+click  -> px0-opener plugin     -> px0-open -> px0
```

Three small pieces:

| Piece | What it does |
|---|---|
| `bin/hyperlink-paths` | Stdin filter: wraps existing file paths in OSC 8 `px0://` hyperlinks. Visible text is byte-identical; only real files link (existence-checked by default). Handles `:line[:col]`, `~/`, relative paths, spaces, brackets, ANSI colors, unicode. |
| `bin/px0-open` | Opens a path or `px0://`/`file://` URL in px0 (detached), normalizing `:line:col` suffixes, `~`, relative paths, and percent-encoding. |
| `shell/px0-click.zsh` | zsh integration: `rg` emits native `px0://` hyperlinks on terminals; `px <path>` opens a path in px0, `px <cmd...>` runs any command through `hyperlink-paths` (exit status preserved). |

Plus two optional integrations: a macOS `px0://` URL handler app
(`macos/px0-url-handler`, for Ghostty) and a Herdr link-handler plugin
(`herdr-plugin`, for Herdr).

## Install

Requires: `px0` on `PATH` (or set `PX0_BIN`), `python3`, `zsh`. macOS URL
handler needs `swiftc` (Xcode CLT); `duti` recommended for scheme
registration. Herdr plugin needs `herdr >= 0.7.0`.

```sh
git clone https://github.com/joeharris76/px0-click.git
cd px0-click
./install.sh --all        # helpers + shell + URL handler + Herdr plugin
```

Pick pieces instead:

```sh
./install.sh --shell --herdr   # helpers always install; add shell + Herdr
./install.sh --url-handler     # just the macOS px0:// handler app
./install.sh --prefix ~/.local # custom install prefix (default ~/.local)
./install.sh --uninstall       # remove helpers + shell sourcing
```

Then open a new shell (or `source ~/.zshrc`). Restart the Herdr server once
(`herdr quit`, then `herdr`) to pick up the plugin.

### Manual install

- **Helpers only:** copy `bin/px0-open` and `bin/hyperlink-paths` anywhere on
  `PATH` and `chmod +x` them.
- **Shell only:** `source shell/px0-click.zsh` from `~/.zshrc`.
- **Herdr only:** `herdr plugin link /path/to/px0-click/herdr-plugin`, or
  `herdr plugin install joeharris76/px0-click/herdr-plugin`.
- **URL handler only:** build `macos/px0-url-handler/main.swift` into
  `~/Applications/px0 URL Handler.app` (see `install.sh`
  `install_url_handler`), register with LaunchServices, and claim the scheme:
  `duti -s dev.px0.url-handler px0 all`.

## Usage

```sh
px0-open src/main.py:10:2        # open a path (line/col stripped for px0)
px0-open 'px0:///abs/path?line=5' # open a px0:// URL (from clicks)

rg --vimgrep TODO               # matches are clickable on terminals already
px rg --vimgrep TODO            # same, explicit

px pytest                       # any command: paths in output become links
px git status --short
px -- test                      # -- forces "run", never "open"
git status --short | hyperlink-paths   # pipe anything manually
```

Environment overrides: `PX0_BIN` (px0 binary), `PX0_PYTHON` (urldecode
interpreter), `PX0_OPEN_LOG_DIR` (click log dir), `PX0_OPEN_BIN` (helper path
for the Herdr plugin).

## Layout

```
px0-click/
  bin/hyperlink-paths     stdin -> OSC 8 px0:// links (python3, no deps)
  bin/px0-open            path/URL -> px0 (bash + python3 for urldecode)
  shell/px0-click.zsh     rg wrapper + px wrapper (source from ~/.zshrc)
  herdr-plugin/           Herdr link handlers for px0:// and file://
  macos/px0-url-handler/  Swift source + Info.plist for the px0:// app
  tests/smoke.sh          end-to-end checks (no px0, Herdr, or GUI needed)
  install.sh              installer (--all, --shell, --herdr, --url-handler)
```

## License

MIT. See [LICENSE](LICENSE).
