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
#
# "The right unit" is init-specific: systemd on Arch/Debian/Fedora, and on Artix
# OpenRC, runit, s6 or dinit (see detect_init in lib/common.sh).

# Last release that still builds with make/cc; Ly 1.x requires Zig.
LY_REPO=https://github.com/fairyglade/ly.git
LY_REF=v0.6.0

# Artix's inits all keep gettys on tty1-6 (dinit lists them in console.conf,
# OpenRC, runit and s6 ship tty1-6 units), so the VT Ly may own there is tty7.
# It is written into Ly's config because v0.6.0 activates that VT itself;
# systemd keeps tty2 and disables getty@tty2 instead.
LY_INIT_TTY=7

install_session_scripts() {
	[ "$PLATFORM" = linux ] || return 0
	info "installing session scripts into ~/.local/bin"
	install_script "$REPO_ROOT/scripts/status.sh" "$HOME/.local/bin/status.sh"
	install_script "$REPO_ROOT/scripts/dwl-session" "$HOME/.local/bin/dwl-session"
	install_script "$REPO_ROOT/scripts/dwl-autostart" "$HOME/.local/bin/dwl-autostart"
	install_menu_command
}

# dwl's menu bind (Mod+Space / Mod+d) runs `wmenu-run`. Arch packages wmenu;
# Artix does not, and the AUR has no copy either, so bemenu - which speaks the
# same dmenu protocol and ships bemenu-run - answers to that name through a shim
# in ~/.local/bin, a directory dwl-session puts on PATH. The dwl config stays
# untouched either way.
install_menu_command() {
	have wmenu && return 0
	if [ "$DISTRO" != artix ] || ! have bemenu-run; then
		have bemenu-run || warn "no wmenu/bemenu: the Mod+Space menu will not open"
		return 0
	fi
	local tmp
	tmp=$(mktemp) || return 0
	printf '%s\n' \
		'#!/bin/sh' \
		'# wmenu is not packaged for Artix; bemenu speaks the same dmenu protocol.' \
		'exec bemenu-run "$@"' >"$tmp"
	install_script "$tmp" "$HOME/.local/bin/wmenu-run"
	rm -f "$tmp"
	note "menu: wmenu-run -> bemenu-run"
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
	install_ly_service "$dir"
	# Ly activates the VT named in its own config. systemd disables tty2's getty
	# instead; Artix's inits cannot spare a getty per VT, so Ly moves to tty7.
	if [ "$DISTRO" = artix ]; then
		set_ly_tty "$LY_INIT_TTY"
	fi
	have ly
}

# ---------------------------------------------------------------------------
# Ly's service definition, per init
# ---------------------------------------------------------------------------

# The unit comes from the tree we built for systemd/OpenRC/runit (upstream ships
# those three); dinit and s6 get a definition from this repo, since upstream has
# none and Artix's own packages are tied to the packaged binary.
install_ly_service() { # <ly checkout>
	local dir=$1
	case $INIT in
	systemd)
		root make -C "$dir" installsystemd || warn "ly.service install failed"
		;;
	openrc)
		root make -C "$dir" installopenrc || warn "ly's OpenRC service install failed"
		;;
	runit)
		install_ly_runit "$dir" || true
		;;
	dinit)
		install_ly_dinit || true
		;;
	s6)
		install_ly_s6 || true
		;;
	*)
		warn "no ly service file for init '$INIT'"
		;;
	esac
	return 0
}

# Upstream's `make installrunit` writes /etc/sv/ly, but Artix supervises from
# /etc/runit/sv, so its three files are installed there directly.
install_ly_runit() { # <ly checkout>
	local src=$1/res/ly-runit-service dst=/etc/runit/sv/ly
	if [ ! -d /etc/runit/sv ]; then
		warn "runit: /etc/runit/sv is missing, no ly service installed"
		return 1
	fi
	if [ ! -f "$src/run" ]; then
		warn "ly: $src/run is missing, no runit service installed"
		return 1
	fi
	root install -d -m 755 "$dst" \
		&& root_install_script "$src/run" "$dst/run" 755 \
		&& root_install_script "$src/finish" "$dst/finish" 755 \
		&& root_install_script "$src/conf" "$dst/conf" 644 \
		|| { warn "runit: could not install $dst"; return 1; }
	note "ly: runit service $dst"
}

# Artix's ly-dinit runs ly directly with the console shared with the gettys and
# starts after login.target; the binary here is our source build.
install_ly_dinit() {
	if [ ! -d /etc/dinit.d ]; then
		warn "dinit: /etc/dinit.d is missing, no ly service installed"
		return 1
	fi
	local tmp
	tmp=$(mktemp) || return 1
	cat >"$tmp" <<'EOF'
# Ly, as built from source by this repo (see lib/session.sh).
type            = process
command         = /usr/bin/ly
smooth-recovery = true
depends-on      = login.target
logfile         = /var/log/dinit/ly.log
# the getty services hold the console, ly switches the VT itself
options         = shares-console
EOF
	root_install_script "$tmp" /etc/dinit.d/ly 644 \
		|| { rm -f "$tmp"; warn "dinit: could not install /etc/dinit.d/ly"; return 1; }
	rm -f "$tmp"
	note "ly: dinit service /etc/dinit.d/ly"
}

# s6 gets a longrun that hands the console to ly through agetty - the same
# arrangement as Artix's packaged ly-s6 service, on the tty the gettys leave
# free. GETTY/TTY/BAUD/TERM come from /etc/s6/config/ly.conf, the file Artix's
# own service reads, so a hand-edited copy keeps working here.
install_ly_s6() {
	if [ ! -d /etc/s6/sv ]; then
		warn "s6: /etc/s6/sv is missing, no ly service installed"
		return 1
	fi
	local tmp
	tmp=$(mktemp -d) || return 1
	printf 'longrun\n' >"$tmp/type"
	cat >"$tmp/run" <<'EOF'
#!/bin/sh
[ -r /etc/s6/config/ly.conf ] && . /etc/s6/config/ly.conf
exec "${GETTY:-agetty}" -nl /usr/bin/ly "${TTY:-tty7}" "${BAUD:-115200}" "${TERM:-linux}"
EOF
	cat >"$tmp/ly.conf" <<'EOF'
# ly parameters (read by /etc/s6/sv/ly/run)
GETTY=agetty
TTY=tty7
BAUD=115200
TERM=linux
EOF
	root_install_script "$tmp/run" /etc/s6/sv/ly/run 755 \
		&& root_install_script "$tmp/type" /etc/s6/sv/ly/type 644 \
		&& root_install_script "$tmp/ly.conf" /etc/s6/config/ly.conf 644 \
		|| { rm -rf "$tmp"; warn "s6: could not install the ly service"; return 1; }
	rm -rf "$tmp"
	note "ly: s6 service /etc/s6/sv/ly"
}

# The VT Ly activates (v0.6.0 reads it from its own config).
ly_tty() {
	local n=2
	if [ -r /etc/ly/config.ini ]; then
		n=$(sed -n 's/^[[:space:]]*tty[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
			/etc/ly/config.ini | tail -1)
	fi
	printf '%s' "${n:-2}"
}

set_ly_tty() { # <tty>
	local f=/etc/ly/config.ini n=$1
	[ -f "$f" ] || return 0
	[ "$(ly_tty)" = "$n" ] && return 0

	root cp "$f" "$f.bak" || { warn "ly: could not back up $f"; return 0; }
	if grep -q '^[[:space:]]*tty[[:space:]]*=' "$f"; then
		root sed -i "s|^\([[:space:]]*tty[[:space:]]*=[[:space:]]*\)[0-9][0-9]*.*|\1$n|" "$f" \
			|| { warn "ly: could not set tty in $f"; return 0; }
	else
		# Ly's own default (tty = 2) is commented out: write the value
		printf '\ntty = %s\n' "$n" | root tee -a "$f" >/dev/null \
			|| { warn "ly: could not append tty to $f"; return 0; }
	fi
	if [ "$(ly_tty)" = "$n" ]; then
		note "ly: tty -> $n (previous config kept as $f.bak)"
	else
		warn "ly: $f still does not say tty = $n"
	fi
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

	if [ "$INIT" = systemd ]; then
		enable_ly_systemd
	else
		enable_ly_init
	fi
}

# systemd: retire SDDM, default to graphical.target, hand tty2 to Ly.
enable_ly_systemd() {
	# Retire SDDM: the Wayland greeter is what crashes on pointer input.
	if have sddm || [ -d /etc/sddm.conf.d ]; then
		info "removing the SDDM Wayland greeter config"
		root rm -f /etc/sddm.conf.d/10-wayland.conf
		if have systemctl; then
			root systemctl disable sddm >/dev/null 2>&1 || true
			note "sddm disabled (package kept; it stops at the next reboot/logout)"
		fi
	fi

	if ! have systemctl; then
		warn "systemd is PID 1 but systemctl is missing: enable ly by hand"
		return 0
	fi

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
}

# Artix (or any other systemd-less machine): the same two steps - retire a
# graphical login manager by its service name, then enable Ly - said in the
# running init's terms.
enable_ly_init() {
	if [ "$INIT" = unknown ]; then
		warn "no init system detected: enable ly by hand, or log in on a VT and run $HOME/.local/bin/dwl-session"
		return 0
	fi

	if disable_init_service sddm; then
		note "sddm disabled for $INIT (package kept)"
	fi

	# dwl needs a seat before it can draw anything: elogind's loginctl or seatd.
	# Artix splits both per init (elogind-dinit, seatd-runit, ...), so only name them.
	if ! have loginctl && ! have seatd && ! have seatd-launch; then
		warn "no logind/seatd found: dwl cannot take a seat (install elogind-$INIT or seatd-$INIT)"
	fi

	if ! have ly; then
		warn "ly not installed: no display manager enabled"
		return 0
	fi
	enable_ly_service
}

# Remove a service from the boot set of the running init. Every init's packaged
# sddm uses the plain name 'sddm', so this needs no distro table.
# Returns 0 when something was actually disabled.
disable_init_service() { # <service name>
	local name=$1 d removed=0
	case $INIT in
	openrc)
		if [ -e "/etc/runlevels/default/$name" ]; then
			root rc-update del "$name" default >/dev/null 2>&1 && removed=1
		fi
		;;
	runit)
		for d in /run/runit/service /etc/runit/runsvdir/default; do
			[ -e "$d/$name" ] || [ -L "$d/$name" ] || continue
			root rm -f "$d/$name" && removed=1
		done
		;;
	dinit)
		if [ -e "/etc/dinit.d/boot.d/$name" ] || [ -L "/etc/dinit.d/boot.d/$name" ]; then
			root rm -f "/etc/dinit.d/boot.d/$name" && removed=1
		fi
		;;
	s6)
		if [ -e "/etc/s6/adminsv/default/contents.d/$name" ]; then
			root rm -f "/etc/s6/adminsv/default/contents.d/$name" && removed=1
			have s6-db-reload && root s6-db-reload >/dev/null 2>&1 || true
		fi
		;;
	esac
	[ "$removed" = 1 ]
}

# Add Ly to the boot set of the running init. systemd, OpenRC and dinit only
# record it for the next boot; runit's runsvdir and s6-rc notice the change and
# start the greeter immediately.
enable_ly_service() {
	case $INIT in
	openrc)
		if ! have rc-update; then
			warn "openrc: rc-update is missing, enable ly by hand"
			return 0
		fi
		root rc-update add ly default >/dev/null 2>&1 \
			|| { warn "openrc: 'rc-update add ly default' failed"; return 0; }
		note "ly enabled in the openrc default runlevel (next boot)"
		;;
	runit)
		if [ ! -d /etc/runit/sv/ly ]; then
			warn "runit: /etc/runit/sv/ly is missing, enable ly by hand"
			return 0
		fi
		# /run/runit/service is Artix's live directory, normally a symlink to
		# /etc/runit/runsvdir/<runlevel>, so this link also survives a reboot.
		local svdir=/run/runit/service
		[ -d "$svdir" ] || svdir=/etc/runit/runsvdir/default
		root mkdir -p "$svdir" \
			|| { warn "runit: could not create $svdir"; return 0; }
		root ln -sfn /etc/runit/sv/ly "$svdir/ly" \
			|| { warn "runit: could not link $svdir/ly"; return 0; }
		note "ly enabled in $svdir (runit starts it now)"
		;;
	dinit)
		if [ ! -f /etc/dinit.d/ly ]; then
			warn "dinit: /etc/dinit.d/ly is missing, enable ly by hand"
			return 0
		fi
		# dinitctl enable would also start the greeter mid-setup; boot.d is
		# what pid 1 waits for (Artix documents the link as an absolute path),
		# and it is honoured on the next boot.
		root mkdir -p /etc/dinit.d/boot.d \
			|| { warn "dinit: could not create /etc/dinit.d/boot.d"; return 0; }
		root ln -sfn /etc/dinit.d/ly /etc/dinit.d/boot.d/ly \
			|| { warn "dinit: could not link /etc/dinit.d/boot.d/ly"; return 0; }
		note "ly enabled in /etc/dinit.d/boot.d (next boot)"
		;;
	s6)
		if [ ! -d /etc/s6/sv/ly ]; then
			warn "s6: /etc/s6/sv/ly is missing, enable ly by hand"
			return 0
		fi
		root mkdir -p /etc/s6/adminsv/default/contents.d \
			|| { warn "s6: could not create the default bundle"; return 0; }
		root touch /etc/s6/adminsv/default/contents.d/ly \
			|| { warn "s6: could not add ly to the default bundle"; return 0; }
		if have s6-db-reload; then
			if root s6-db-reload >/dev/null 2>&1; then
				note "ly added to the s6 default bundle (s6-rc starts it now)"
			else
				warn "s6: 's6-db-reload' failed, run it by hand"
			fi
		else
			warn "s6: run 's6-db-reload' to activate the ly service"
		fi
		;;
	*)
		warn "init '$INIT' is not supported for the display manager; log in on a VT and run $HOME/.local/bin/dwl-session"
		;;
	esac
	return 0
}
