# patches/ly

Patch for the `configator` submodule of [Ly](https://github.com/fairyglade/ly),
pinned to `v0.6.0` (see `lib/session.sh`). It is applied to
`~/.cache/dotfiles/ly/sub/configator` after the submodules are checked out, because a
submodule is its own git repository.

| patch | what |
|-------|------|
| `01-configator-search.patch` | `search()` stores `strcmp()` in an `int8_t`, which truncates the result. On aarch64 glibc `strcmp("Name", "Exec")` returns a positive value whose low byte is negative (`-113`), so the binary search takes the "key is smaller" branch and reports every later key as missing. `Name` was found, `Exec` was not, so Ly added **no** session: only the built-in `xinitrc` and `shell` entries appeared in the greeter, with no Wayland, dwm or desktop session at all. Widening it to `int` fixes the lookup every key uses (session files and `config.ini` alike). |

Regenerating (in the clone, never in this repo's tree):

```sh
cd ~/.cache/dotfiles/ly/sub/configator
# ...edit src/configator.c...
git diff > ~/dev/dotfiles/patches/ly/01-configator-search.patch
```

Ly is always compiled from source by `setup.sh`, never taken from a distro
package: a packaged Ly would be built against an unpatched `configator` and would
be just as blind. Building also needs the pam and xcb headers, which
`install_wayland_pkgs()` installs.
