# patches/st

One git-format patch for [st-wl](https://github.com/marchaesen/st-wl) — the
Wayland-native st fork — pinned to `8650534` (see `lib/suckless.sh`).

`01-config.patch` contains the whole port:

**Toggles** (`patches.def.h`)
- `SCROLLBACK_PATCH 1` with `HISTSIZE` 2000 → 5000, `COPYURL_PATCH 1`
- `BOXDRAW_PATCH 1` — **new**: the fork only ships the X11/Xft `drawboxes()`, so this
  patch adds `patch/boxdraw_wl.c`, a wld-renderer implementation (rectangles via
  `wld_fill_rectangle`, shapes/tables taken from Avi Halachmi's patch), includes it
  instead of `boxdraw.c`, and draws box glyphs in `wldrawCharacter()` before the font
  path. Crisp lines/blocks/shades, no dithered font glyphs.
- `NO_WINDOW_DECORATIONS_PATCH 1` — **new**: under dwl there is no xdg-decoration
  manager, so st-wl used to switch to client-side decorations on its own (a second
  frame plus a titlebar offset). That is what made `ANYSIZE` look broken/offset;
  with the toggle the compositor's border is the only frame and the cell grid sits
  flush in the tile.
- `ALPHA`, `ANYSIZE`, `CLIPBOARD`, `SYNC`, `SIXEL`, `KITTY_GRAPHICS`,
  `BLINKING_CURSOR`, `SELECTION_COLORS`, `FULLSCREEN`, `NEWTERM` stay on as upstream.

**Font** — three fork bugs, all fixed in this patch:
- `usedfont = opt_font;` became `usedfont = opt_font ? opt_font : font;`. Without
  `-f`, `usedfont` stayed `NULL`, `wlloadfonts()` never built a pattern and the
  terminal silently rendered with the embedded fallback font: wrong glyphs, wrong
  icons, and font reporting tools naming some unrelated system font.
- The size came from nowhere: `wlloadfonts()` is called with `DEFAULTFONTSIZE` and
  deletes `FC_SIZE`/`FC_PIXEL_SIZE` from the pattern, so `:size=11` was ignored and
  st-wl always rendered at 13 px. Size is now `DEFAULTFONTSIZE 15`
  (15 px ~= 11 pt at 96 dpi).
- **No fontconfig family matching.** `FONT_FACE` (`config.def.h`) is opened as a
  _file_: `FiraCodeNerdFontMono-<style>.ttf` is looked up in `~/.local/share/fonts`,
  `~/.fonts`, `~/Library/Fonts`, `/usr/share/fonts`, `/usr/local/share/fonts`,
  `…/truetype`, `…/TTF` and `…/opentype`, then handed to `wld_font_open_pattern()`
  as an `FC_FILE` + `FC_PIXEL_SIZE` pattern — nothing else is read, so no family
  match can resolve to an unrelated default font. Nerd Font releases ship no italic
  cuts, so italic falls back to regular and bold-italic to bold. fontconfig is only
  used for glyphs the face lacks, and `-f` still takes the fontconfig path.
  Verified by running with `FONTCONFIG_FILE=/dev/null` (fontconfig cannot load any
  config): the face still loads, and st-wl prints the file it opened on stderr.
- `DEFAULT_ALPHA 0.8`, `minlatency 1` / `maxlatency 12`,
  tokyonight palette at st-wl's indices (256 cursor, 257 reverse cursor,
  258 background `#24283b`, 259 foreground `#c0caf5`), `boxdraw = 1`,
  `boxdraw_bold = 0`, `boxdraw_braille = 0`.

Regenerate with `git diff > patches/st/01-config.patch` from the pinned commit (use
`git add -N` first if a file is new, or the new file is left out of the diff).
Note `patches.h` is generated from `patches.def.h`; `setup.sh` refreshes it, because a
stale copy silently keeps old toggles.
