# shellcheck shell=bash
# Session layer: Ly (TUI display manager), the dwl session entry, and the status
# feeder for the bar.
#
# SDDM is not used: its experimental Wayland greeter (weston's kiosk shell driven
# by Qt) hard-crashes the machine as soon as the pointer moves. Ly runs on a plain
# VT and starts the very same dwl session, so this layer only has to keep the
# session entry pointing at our wrapper and enable the right unit.
#
# Ly is always built from source here, never taken from a package: its configator
# submodule needs patches/ly, without which the greeter lists no sessions at all
# (see patches/ly/README.md).

# Last release that still builds with make/cc; Ly 1.x requires Zig.
LY_REPO=https://github.com/fairyglade/ly.git
LY_REF=v0.6.0

install_session_scripts() {
	[ "$PLATFORM" = linux ] || return 0
	info "installing session scripts into ~/.local/bin"
	install_script "$REPO_ROOT/scripts/status.sh" "$HOME/.local/bin/status.sh"
	install_script "$REPO_ROOT/scripts/dwl-session" "$HOME/.local/bin/dwl-session"
	install_script "$REPO_ROOT/scripts/dwl-autostart" "$HOME/.local/bin/dwl-autostart"
}

# dwl's `make install` writes the session file with `Exec=dwl`. Point it at our
# wrapper so bar, wallpaper and status feed come up with the session:
#
#   sudo sed -i "s|^Exec=.*|Exec=$HOME/.local/bin/dwl-session|" \
#       /usr/local/share/wayland-sessions/dwl.desktop
#
# Idempotent, verifies the result, and cheap enough to re-run right after every
# dwl install (see build_suckless()).
point_session_at_wrapper() {
	local exec_line="Exec=$HOME/.local/bin/dwl-session"
	local desk found=0

	for desk in /usr/local/share/wayland-sessions/dwl.desktop \
	            /usr/share/wayland-sessions/dwl.desktop; do
		[ -f "$desk" ] || continue
		found=1
		grep -qxF "$exec_line" "$desk" && continue

		root sed -i "s|^Exec=.*|$exec_line|" "$desk" \
			|| { warn "could not rewrite $desk"; continue; }
		if grep -qxF "$exec_line" "$desk"; then
			note "$desk exec -> $HOME/.local/bin/dwl-session"
		else
			warn "$desk still does not point at $HOME/.local/bin/dwl-session"
		fi
	done

	[ "$found" = 1 ] || warn "no dwl.desktop session file found (dwl not installed?)"
	link_session_into_standard_dir
}

# dwl installs into /usr/local/share/wayland-sessions, while greeters (Ly
# included) read /usr/share/wayland-sessions by default. A symlink makes both
# paths the same already-rewritten entry, so no greeter ever sees `Exec=dwl`.
link_session_into_standard_dir() {
	local src=/usr/local/share/wayland-sessions/dwl.desktop
	local dst=/usr/share/wayland-sessions/dwl.desktop

	[ -f "$src" ] || return 0
	if [ -e "$dst" ] || [ -L "$dst" ]; then
		return 0
	fi
	root mkdir -p /usr/share/wayland-sessions || return 0
	if root ln -s "$src" "$dst"; then
		note "$dst -> $src (session dir greeters read by default)"
	fi
}

# Always the pinned release from source: a distro package (or a stale copy from
# an earlier run) would be built against an unpatched configator and list no
# sessions. Ly 1.x needs Zig, so the pin stays on 0.6.0.
ensure_ly() {
	if build_ly; then
		note "ly: $LY_REF built from source (patched session lookup)"
		return 0
	fi
	if have ly; then
		warn "ly: source build failed, keeping the installed $(ly --version 2>/dev/null | head -1)"
		return 0
	fi
	return 1
}

build_ly() {
	local dir=$HOME/ly cp=$REPO_ROOT/patches/ly/01-configator-search.patch

	if ! have git || ! { have cc || have gcc; }; then
		warn "ly: git and a C compiler are needed to build it from source"
		return 1
	fi

	info "building ly $LY_REF from source"
	if [ -d "$dir/.git" ]; then
		note "reusing $dir"
		git -C "$dir" fetch --quiet --tags origin 2>/dev/null || warn "fetch failed in $dir"
		# the configator patch lives in a submodule: do not mistake it for an edit
		# to the superproject (it would block a pin bump on a later run)
		if [ -z "$(git -C "$dir" status --porcelain --ignore-submodules=dirty)" ]; then
			git -C "$dir" checkout --quiet --detach "$LY_REF" 2>/dev/null \
				|| warn "could not check out $LY_REF in $dir"
		else
			note "$dir has local changes, leaving checkout alone"
		fi
	else
		git clone --quiet "$LY_REPO" "$dir" || { warn "clone failed: $LY_REPO"; return 1; }
		git -C "$dir" checkout --quiet --detach "$LY_REF" 2>/dev/null \
			|| warn "could not check out $LY_REF in $dir"
	fi

	# Ly vendors argoat/configator/dragonfail/termbox as git submodules. Our
	# configator patch leaves that submodule dirty, and a dirty submodule makes
	# the next run's `submodule update` refuse the pinned commit - drop the patch
	# first (it is re-applied below), never anyone else's edits.
	git -C "$dir/sub/configator" apply --reverse "$cp" >/dev/null 2>&1 || true
	git -C "$dir" submodule update --init --recursive --quiet \
		|| { warn "ly submodules failed to check out"; return 1; }

	# Without this, configator's search() truncates strcmp() into an int8_t and
	# finds no key at all on aarch64: Ly lists only the built-in xinitrc and shell.
	if git -C "$dir/sub/configator" apply --reverse --check "$cp" >/dev/null 2>&1; then
		note "ly: configator lookup already patched"
	elif git -C "$dir/sub/configator" apply "$cp" >/dev/null 2>&1; then
		note "ly: configator lookup patched"
	else
		warn "ly: configator patch does not apply to $(git -C "$dir/sub/configator" rev-parse --short HEAD 2>/dev/null)"
		return 1
	fi

	make -C "$dir" || { warn "ly build failed"; return 1; }
	# installnoconf keeps an existing /etc/ly/config.ini (and its hand edits)
	root make -C "$dir" installnoconf || { warn "ly install failed"; return 1; }
	[ -f /etc/ly/config.ini ] \
		|| root install -m 644 "$dir/res/config.ini" /etc/ly/config.ini
	if have systemctl; then
		root make -C "$dir" installsystemd || warn "ly.service install failed"
	fi
	have ly
}

# Ly opens the session index it saved last time. That list is: shell, xinitrc,
# then the Wayland sessions in readdir order, so index 1 - what the broken lookup
# left in /etc/ly/save - opens X11. Recompute dwl's position and point the save
# file at it, so a plain login lands in dwl. The index is positional, so it is
# recomputed on every run (a new .desktop file shifts everything after it).
preselect_dwl_session() { # [save-file] [wayland-session-dir]
	local save=${1:-/etc/ly/save} sdir=${2:-/usr/share/wayland-sessions}
	local idx=2 f found=0

	[ -f "$save" ] && [ -d "$sdir" ] || return 0
	[ -n "$(sed -n '1p' "$save")" ] || return 0

	while IFS= read -r f; do
		case $f in .*) continue ;; esac
		if [ "$f" = dwl.desktop ]; then found=1; break; fi
		idx=$((idx + 1))
	done < <(find "$sdir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)

	[ "$found" = 1 ] || return 0
	[ "$(sed -n '2p' "$save")" = "$idx" ] && return 0
	root sed -i "2s/.*/$idx/" "$save" \
		|| { warn "could not point $save at dwl"; return 0; }
	note "ly: preselected dwl (session $idx) in $save"
}

install_wayland_session() {
	[ "$PLATFORM" = linux ] || return 0

	install_session_scripts
	point_session_at_wrapper

	if ! ensure_ly; then
		warn "ly is missing: no display manager will start $HOME/.local/bin/dwl-session"
	fi

	preselect_dwl_session

	# Retire SDDM: the Wayland greeter is what crashes on pointer input.
	if have sddm || [ -d /etc/sddm.conf.d ]; then
		info "removing the SDDM Wayland greeter config"
		root rm -f /etc/sddm.conf.d/10-wayland.conf
		if have systemctl; then
			root systemctl disable sddm >/dev/null 2>&1 || true
			note "sddm disabled (package kept; it stops at the next reboot/logout)"
		fi
	fi

	if have systemctl; then
		root systemctl set-default graphical.target >/dev/null 2>&1 \
			|| note "could not set graphical.target as default"
		if have ly; then
			# ly owns tty2; a getty on that VT would fight it for the console
			root systemctl disable getty@tty2.service >/dev/null 2>&1 || true
			if root systemctl enable ly.service >/dev/null 2>&1 \
				|| root systemctl enable ly@tty2.service >/dev/null 2>&1; then
				note "ly enabled on tty2 (display-manager.service)"
			else
				warn "could not enable ly: run 'systemctl enable ly.service'"
			fi
		else
			warn "ly not installed: no display manager enabled"
		fi
	fi
}
