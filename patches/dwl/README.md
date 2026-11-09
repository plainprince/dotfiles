# patches/dwl

git-format patches for [dwl](https://codeberg.org/dwl/dwl), pinned to `a6e2c15`
(see `lib/suckless.sh`), applied in filename order by `setup.sh`.

| patch | what |
|-------|------|
| `01-config.patch` | the dwm config port: `MODKEY = WLR_MODIFIER_LOGO`, borderpx 2, `gappx 8`, `TAGCOUNT 10`, greyscale palette, `gimp`/`firefox` rules, `termcmd = st-wl` (the Wayland build — plain `st` may be an X11 binary), `browsercmd = chromium` (a placeholder: `setup.sh` rewrites it to the browser it found or installed, see `set_dwl_browser`), `wmenu-run` with dwm's dmenu colours (`-N 000000 -n cccccc -S 222222 -s ffffff`, FiraCode Mono 10), the full dwm bind set (no Ctrl tag variants), multi-monitor + Ctrl-Alt-Backspace/VT binds kept |
| `02-gaps.patch` | gaps in `tile()`: the monitor area is inset by `gappx` on every side and every client loses `gappx` on its right/bottom edge (dwm's fullgaps behaviour, not vanitygaps) |
| `03-xwayland.patch` | `config.mk`: `XWAYLAND = -DXWAYLAND`, `XLIBS = xcb xcb-icccm` so X clients run under dwl |

Regenerating one (in the clone, never in this repo's tree):

```sh
cd ~/.cache/dotfiles/dwl
# ...edit...
git diff -- config.def.h > ~/dev/dotfiles/patches/dwl/01-config.patch
```

Rules that already bit us once:
- `dwl` builds from **`config.h`**, not `config.def.h`. A stale `config.h` silently
  shadows the patched config — `setup.sh` refreshes it (backing up any hand-written
  version as `config.h.bak`).
- A patch that stops applying gets fixed against the pinned commit; `setup.sh`
  refuses to continue otherwise.

Note: dropping dwl's `Ctrl` tag binds (dwm had none) leaves `toggleview()` and
`toggletag()` unused, so the build prints two harmless `-Wunused-function` warnings.
