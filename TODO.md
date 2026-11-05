# TODO — pre-rice setup

Goal: clone this repo, run `./setup.sh`, end with a working dwl rice + dev
environment. This repo holds **only patches, configs, scripts and wallpapers** —
never a copy of any codebase.

**Ground rules**
- A patch that fails to apply (or compile) gets *fixed*; the fixed patch is what we
  store. `setup.sh` refuses to continue on a stale patch — `.rej` never happens.
- Machine-specific quirks (cava's audio sink) stay local — never the tracked default.
- `fastcompmgr`/`slstatus` are X11-only → dropped (compositing is in wlroots; status
  is `scripts/status.sh`).

**Platform support**

| Platform | Shell + tooling | dwl/dwlb/st-wl | Ly session |
|----------|-----------------|----------------|--------------|
| Debian/Ubuntu (apt) | ✅ | ✅ | ✅ |
| Fedora (dnf) | ✅ | ✅ (needs wlroots 0.20) | ✅ |
| Arch (pacman) | ✅ | ✅ (needs wlroots 0.20) | ✅ |
| other Linux | best effort (`pkg_install_lenient`) | if deps resolve | if ly installs/builds |
| macOS (brew) | ✅ (installs Homebrew if absent) | — (Wayland-only) | — |

Build tooling (`gcc`/`make`/`pkg-config`) is installed in the **first** stage, because
dwl, dwlb, st-wl *and* LazyVim's treesitter parsers all compile later in the run.

---

## Phase 0 — repo layout ✅

```
setup.sh              entrypoint: detect → sudo → stages
lib/common.sh         logging, platform/PM detection, sudo keepalive, pkg wrappers
lib/packages.sh       per-PM package sets, fonts, VSCodium, Wayland/build deps
lib/suckless.sh       pinned clones, patch engine, config.h sync, build+install
lib/session.sh        Ly install/enable, dwl session entry, status feeder install
lib/dotfiles.sh       configs (never clobber), omz, nvim, wallpapers, login shell
lib/github.sh         gh auth login, setup-git, git identity
scripts/status.sh     slstatus replacement (1 line/s)
scripts/dwl-session   SDDM Exec target
scripts/dwl-autostart dwl -s payload: swaybg + dwlb + status feeder
configs/              starship.toml, cava/, btop/, zshrc, nvim/ (LazyVim)
patches/dwl/          3 patches (config, gaps, xwayland) + README
patches/st/           1 patch (full st-wl port) + README
patches/ly/           1 patch (configator key lookup) + README
wallpapers/           3 files, 16 MB
```

## Phase 1 — `setup.sh` bootstrap ✅

- [x] `set -euo pipefail`, repo-root-relative, per-stage functions, idempotent re-runs.
- [x] **Sudo once up front** (`sudo -v` + 50 s keepalive) with a warning banner.
- [x] **Distro + arch detection** → apt/dnf/pacman/zypper/apk/brew.
- [x] **Browser check before gh**: any browser → done, else chromium (firefox as second
      resort). macOS: Safari counts.
- [x] **Dev tools** (first stage): git, gh, **build-essential/gcc/make/pkg-config**,
      unzip, fontconfig, zsh, rust+cargo, **ripgrep**.
- [x] **neovim from upstream only** — never a package manager, on any platform.
      Upstream publishes release archives rather than a shell installer (there is no
      `install.sh` in the repo or its releases), so those archives are used:
      `/opt/nvim`, linked as `/usr/local/bin/nvim`. A package-managed neovim is
      **removed, not purged** (apt/dnf/zypper/pacman/apk/brew), so its config stays
      and nothing stale answers `nvim`. Re-runs compare `nvim --version` with the
      latest release tag and do nothing when equal.
- [x] **VSCodium**: deb822 repo (apt), yum repo (dnf), AUR via yay/paru (pacman), cask.
- [x] **Rice tools**: bat, eza, starship (official installer fallback), zoxide, btop,
      cava, cmatrix, fastfetch + FiraCode Nerd Font.
- [x] **Build deps**: `libwlroots-0.20-dev`, wayland, wayland-protocols, xkbcommon,
      libinput, pixman, fontconfig, freetype, imlib2, fcft, zlib, xcb + xcb-icccm
      (for XWayland), swaybg/wmenu/wlr-randr/xwayland, plus pam/xcb headers for
      Ly when it has to be built from source.
- [x] **Suckless**: clone pinned → apply patches → refresh `config.h` → build+install;
      `st` symlink only when no real X11 `st` exists.
- [x] **macOS**: Homebrew installed when absent (non-interactive, Xcode CLT gate) and
      added to the tracked zshrc.
- [x] **gh**: `auth login --web` → `setup-git` → identity from the API if unset.

## Phase 2 — Ly ✅

- [x] **Ly, not SDDM.** SDDM's experimental Wayland greeter crashes the whole machine
      on the first pointer movement, so the box boots into Ly on tty2 instead.
      `install_wayland_session()` deletes `/etc/sddm.conf.d/10-wayland.conf`, disables
      `sddm` (package kept) and enables `ly.service`.
- [x] **Ly is always built from source** at the pinned `v0.6.0` tag (git +
      submodules, `make installnoconf`, `make installsystemd`), never from a distro
      package: Ly 1.x needs Zig and a packaged 0.6.x would be unpatched. An existing
      `/etc/ly/config.ini` is kept, never overwritten.
- [x] **`patches/ly/01-configator-search.patch` — the greeter had no sessions.**
      configator's `search()` stored `strcmp()` in an `int8_t`; on aarch64 glibc that
      truncates `strcmp("Name", "Exec")` to `-113`, inverting the comparison, so
      `Name` was found and `Exec` never was. Ly dropped every `.desktop` entry and
      listed only its built-in `xinitrc` and `shell` — no Wayland, no dwm, nothing.
      With `int disc` the same machine lists dwl, Plasma (Wayland/X11), Hyprland,
      Weston and dwm. The patch is applied to the submodule before the build and
      reverse-applied before a re-run's `submodule update` (a dirty submodule would
      block the pinned checkout).
- [x] **Ly starts on dwl, not X11**: `/etc/ly/save` holds `username` + a positional
      session index; the stale `1` is `xinitrc`. `preselect_dwl_session()` walks the
      session dir in readdir order (as Ly does, after its two built-in entries) and
      rewrites that index so a plain login opens dwl. Re-run the script whenever the
      session list changes.
- [x] `dwl.desktop` exec → `~/.local/bin/dwl-session`. dwl's own `make install`
      rewrites that file to a plain `Exec=dwl`, so the re-point (the `sed` documented
      in `lib/session.sh`) runs right after the dwl install in `build_suckless()` and
      verifies its result. The session scripts are installed *before* dwl is built, so
      a later failure can no longer leave a session without bar, wallpaper and status.
- [x] **Session dir bridge**: dwl installs into `/usr/local/share/wayland-sessions`,
      greeters read `/usr/share/wayland-sessions`, so the latter is a symlink to the
      former (never clobbering an existing file). `set-default graphical.target`;
      `getty@tty2` disabled because Ly owns tty2.

## Phase 3 — DWL with dwm's config/binds ✅

- [x] `patches/dwl/01-config.patch`: `MODKEY = WLR_MODIFIER_LOGO`, borderpx 2,
      `gappx 8`, `TAGCOUNT 10`, greyscale palette
      (`root #000000 / border #222222 / focus #aaaaaa / urgent #ffffff`), rules
      (`gimp` float, `firefox` → tag 9), `termcmd = st`, `browsercmd = chromium`,
      `wmenu-run` menu, mfact 0.55 / nmaster 1 (dwl defaults already matched).
- [x] Bind set (1:1 with `~/dwm/config.h`): `Mod+Space`/`Mod+d` menu,
      `Mod+Return` st-wl, `Mod+Shift+Return` chromium, `j/k` focusstack,
      `Mod+=/+-` incnmaster, `Mod+Shift+=/+-` setmfact, `Mod+z` zoom, `Mod+Tab` view,
      `Mod+w` killclient, `Mod+t` togglefloating, `Mod+l` layout cycle,
      `Mod+m` monocle, `Mod+Shift+e` quit, `TAGKEYS 1-9,0` (view + tag only),
      mouse move/float/resize (dwl's defaults already match dwm).
      Extra dwl keys kept: `Mod+e` fullscreen, `Mod+,/.` monitor focus/tag,
      `Ctrl+Alt+Backspace`, `Ctrl+Alt+F1..F12`.
- [x] `patches/dwl/02-gaps.patch`: gaps in `tile()` (monitor inset by `gappx`, every
      client loses `gappx` right/bottom) — dwm's fullgaps behaviour.
- [x] `patches/dwl/03-xwayland.patch`: `XWAYLAND`/`XLIBS` enabled for X clients.
- [x] Alpha: dwm's alpha patch was bar-only; bar transparency is dwlb's job, dwl has
      no client alpha. Documented decision, nothing to port.
- [x] Bar colours/transparency: dwlb gets dwm's SchemeNorm/SchemeSel values with
      dwm's `baralpha` (0xa0) as the `#RRGGBBAA` alpha channel — dwlb already parses
      8-digit colours and composites into an ARGB8888 buffer, so the bar is genuinely
      see-through instead of solid black.
- [x] Compiles and links against wlroots 0.20.2 (`dwl`, 380 KB binary).
- Note: dropping dwl's Ctrl tag binds leaves `toggleview()`/`toggletag()` unused →
      two harmless `-Wunused-function` warnings.

## Phase 4 — ST (terminal) ✅

- [x] Fork: `marchaesen/st-wl`, pinned. One patch: `patches/st/01-config.patch`.
- [x] Toggles: `SCROLLBACK_PATCH 1` (`HISTSIZE` 5000), `SCROLLBACK_MOUSE_PATCH 1`
      and `SCROLLBACK_MOUSE_ALTSCREEN_PATCH 1` (plain MouseWheel scrolls the history,
      no Shift needed and no `\e[5;2~` escape sent to the shell; on the alternate
      screen the wheel still goes to the application as ^Y/^E), `COPYURL_PATCH 1`;
- [x] **Wheel direction fixed.** The fork's `ashortcuts[]` bound `+1` to `kscrollup`,
      but `+1` is wheel *down* — its own `wlmousereportaxis()` encodes it as SGR button
      65 — so scrolling up was a no-op at the top of the buffer. The patch swaps
      `kscrollup`/`kscrolldown` (and the alt-screen ^Y/^E pair) to match the protocol.
      alpha/anysize/clipboard/sync/sixel/kitty/blinking cursor/selection colors were
      already on upstream.
- [x] **No focus fade.** st-wl's `ALPHA_FOCUS_HIGHLIGHT_PATCH` came with
      `ALPHA_FOCUS_FADE_MS 300`, a 300 ms animation of the background alpha when a
      window loses focus. Set to 0: unfocused terminals still get `alphaUnfocused`
      (0.75), but the value switches instantly. dwl itself has no fading code — the
      animation was entirely in the terminal.
- [x] Config: font from file (`FONT_FACE FiraCodeNerdFontMono`),
      `DEFAULTFONTSIZE 15`, `DEFAULT_ALPHA 0.8`, `minlatency 1`/`maxlatency 12`,
      tokyonight palette at st-wl's indices
      (258 = bg `#24283b`, 259 = fg `#c0caf5`).
- [x] **boxdraw works now (Wayland port).** The fork's toggle compiled the X11/Xft
      `drawboxes()` and could not build (`X11/X.h` redefines `Glyph`/`Cursor`/`Font_`).
      The patch now adds `patch/boxdraw_wl.c` — the same shape tables/geometry, drawn
      with `wld_fill_rectangle` — includes it instead of `boxdraw.c`, and draws box
      glyphs in `wldrawCharacter()` before the font path. `boxdraw = 1`, so lines,
      blocks, quadrants and shades are pixel-crisp instead of dithered font glyphs.
- [x] **CSD disabled** (`NO_WINDOW_DECORATIONS_PATCH 1` + the startup guard in
      `wl.c`): dwl exposes no xdg-decoration manager, so st-wl used to turn on
      client-side decorations — a second frame and a titlebar offset that made
      `ANYSIZE` look broken. The compositor's border is now the only frame and the
      grid sits flush in the tile.
- [x] **The config font was never used.** `wl.c` had `usedfont = opt_font;`, so
      without `-f` the pattern stayed `NULL`, no font file was loaded and the embedded
      fallback font rendered everything — wrong glyphs/icons, and font report tools
      naming an unrelated system font. Now `usedfont = opt_font ? opt_font : font;`
      (as in `st`), confirmed at runtime: a patch-only build of a pristine clone
      prints `Loading font file: .../FiraCodeNerdFontMono-Regular.ttf` (plus Bold) on
      plain startup. (`fastfetch` reports the GNOME font — `gsettings` says
      `Cantarell 11` — because it cannot see st-wl's config; not a rendering issue.)
- [x] **Font opened from a file, not matched by fontconfig.** `FONT_FACE` builds
      the path `<face>-<style>.ttf` in the usual font dirs and passes it to
      `wld_font_open_pattern()` as `FC_FILE` + `FC_PIXEL_SIZE`, so no family match
      can resolve to an unrelated default font. Runtime proof: the terminal loads
      FiraCode *even with fontconfig disabled* (`FONTCONFIG_FILE=/dev/null`).
      Italic cuts fall back to upright because Nerd Font releases have none.
- [x] **Font size actually applied.** st-wl calls
      `wlloadfonts(usedfont, DEFAULTFONTSIZE)`, which deletes `FC_SIZE`/`FC_PIXEL_SIZE`
      from the font pattern: the old `:size=11` was silently dropped and the terminal
      rendered at the fork's 13 px default. The size now lives in `DEFAULTFONTSIZE`
      (15 px, i.e. 11 pt at 96 dpi) and the font string carries none. Checked by
      resolving the exact pattern the code builds through libfontconfig:
      `FiraCode Nerd Font Mono` / `FiraCodeNerdFontMono-Regular.ttf` / 15 px
      (same pattern with the old config resolved to 13 px).
- [x] Compiles and links (`st-wl`, 13 MB debug binary).
- [x] `~/st`'s rejected hunks stay reference only; no upstream-st fallback needed.

## Phase 5 — status script ✅

- [x] `scripts/status.sh` → `~/.local/bin/`, 1 s loop, segments/icons/format strings
      verbatim from `~/slstatus/config.h` (including the missing space after disk),
      CPU delta math and RAM/disk formulas transcribed from the components.
- [x] IPv4 interface detected from the default route (never hardcoded `eth0`);
      keymap via `setxkbmap` → `localectl` fallback, refreshed every 10 s.
- [x] Fed into dwlb through its command socket (`dwlb -status-stdin all`).

## Phase 6 — CLI / ricing configs ✅

- [x] **starship**: original layout kept (segments, chevrons, symbols, substitutions,
      `os.symbols`), recoloured to **#000000/#ffffff**, `$character` collapsed onto the
      prompt line. Live config replaced; original at `starship.toml.pre-monochrome.bak`.
- [x] **neovim**: official release (Phase 1), tracked `configs/nvim/` = LazyVim
      starter layout + `lua/plugins/
      colorscheme.lua` with `tokyonight` `style = "night"`, `transparent = true`
      (sidebars/floats transparent too). Installed only when `~/.config/nvim` is absent.
- [x] **cava**: `method = pipewire`, the HDMI sink quirk commented out (auto-detect).
- [x] **btop**: tracked settings only; `greyscale.theme` copied next to the config.
- [x] **zsh**: portable zshrc (bat/batcat detection, omz-only syntax-highlighting,
      brew shellenv), omz cloned if absent, login shell switched when safe.

## Phase 7 — wallpapers ✅

- [x] `wallpapers/` (16 MB) tracked, copied to `~/Pictures/Wallpapers`; session uses
      `himalayan-mountains.png` (override with `WALLPAPER=`).

## Phase 8 — gh + git readiness ✅

- [x] `gh auth login --web` → `gh auth setup-git` → name/email from the API if unset.

## Phase 9 — verification

- [x] Shell syntax (`bash -n`, `sh -n`, `zsh -n`), Lua syntax (`nvim loadfile`),
      platform detection on Debian 13/aarch64.
- [x] Patch engine: applies, re-applies idempotently, hard-fails on a stale patch.
      A clone that still holds an **older revision** of a shipped patch (the normal
      rerun case after `patches/` changes) is merged three-way against the pinned
      commit instead of aborting the run; only a real conflict is fatal.
- [x] **Full build chain from pristine clones**: patches applied through the repo's own
      engine → `config.h`/`patches.h` refreshed → dwl, dwlb and st-wl all compile and
      link against wlroots 0.20.2 (aarch64), using a sysroot built from the distro's
      `.deb`s. Re-verified after the boxdraw port by applying only the shipped patch
      files to fresh clones and building those.
- [x] Boxdraw/CSD verified structurally: the preprocessed `wl.c` contains the
      `wldrawbox(...)` call and none of the `wl.csd_enabled = true` fallback.
- [x] `status.sh` live run (CPU/RAM/disk/IPv4/keymap/clock), dotfiles stage in a
      throwaway `$HOME`, starship render (single line, only black/white SGR codes).
- [x] `install_neovim`: real download + extract of v0.12.6 (arm64) into a temp
      prefix, `nvim --version` reports it, second run is a no-op, and a link that
      cannot be written degrades to a warning instead of aborting. A packaged nvim
      is detected per PM and removed (never purged); no PM path installs one.
- [x] Ly session listing: reproduced the empty greeter on this box (pristine
      `v0.6.0` + submodules, harness over Ly's own `desktop_load()`: 2 entries), then
      with `patches/ly` applied: 9 entries. `preselect_dwl_session()` exercised
      against a temp save file and session dir (rewrites the index, idempotent).
- [x] st-wl patch re-applied to a pristine clone of the pinned commit; font pattern
      resolution checked against libfontconfig (see Phase 4).
- [ ] Full `./setup.sh` on a fresh VM (sudo installs + gh login need a human).
- [ ] Recommended after first login: set the panel resolution/refresh with
      `wlr-randr` (`wlr-randr --output HDMI-A-1 --mode 1920x1080@60Hz`), then scale
      the font if it looks small. Machine-specific, so it is not in the config.
- [ ] Ly on tty2 → dwl session (wallpaper + bar + status) on real hardware.
- [ ] Walk the bind checklist and st-wl features (scrollback, copyurl, clipboard) live.

## Decisions taken

1. **Bar**: dwlb (dwl-native). No IPC patch → dwl's `-s` stdout feeds the tags, the
   status feeder talks to dwlb's socket.
2. **Rust**: distro package; rustup stays optional.
3. **Wallpapers**: tracked, all three (16 MB accepted).
4. **VSCodium**: official repo per PM, AUR/cask on Arch/macOS.
5. **XWayland**: enabled (config.mk patch) so X clients (and old habits) work.
6. **neovim/nvm/sdkman/bun**: neovim comes from upstream's release archive (distro
   packages are too old for LazyVim) and any packaged copy is removed, never
   installed or purged + tracked config; nvm/sdkman/bun stay manual, their zshrc
   blocks are guarded no-ops on a fresh box.
7. **Nothing existing is destroyed**: configs written only when absent, scripts backed
   up to `*.bak` when a local copy differs, dirty clones left alone, `st` never
   relinked over a real X11 st, installed packages/tools/shell/brew reused as-is,
   hand-written `config.h` preserved as `config.h.bak`.
8. **starship**: keep the original layout, only black/white + one line.
