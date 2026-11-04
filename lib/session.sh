# shellcheck shell=bash
# Session layer: SDDM with the experimental Wayland greeter, dwl session entry,
# and the status feeder for the bar.

install_wayland_session() {
	[ "$PLATFORM" = linux ] || return 0

	info "installing session scripts into ~/.local/bin"
	install_script "$REPO_ROOT/scripts/status.sh" "$HOME/.local/bin/status.sh"
	install_script "$REPO_ROOT/scripts/dwl-session" "$HOME/.local/bin/dwl-session"
	install_script "$REPO_ROOT/scripts/dwl-autostart" "$HOME/.local/bin/dwl-autostart"

	if have sddm || [ -d /etc/sddm.conf.d ]; then
		info "SDDM: enabling the experimental Wayland greeter"
		local tmp
		tmp=$(mktemp)
		printf '[General]\nDisplayServer=wayland\n' >"$tmp"
		root mkdir -p /etc/sddm.conf.d
		root install -m 644 "$tmp" /etc/sddm.conf.d/10-wayland.conf
		rm -f "$tmp"
	else
		note "sddm not installed, skipping greeter config"
	fi

	# dwl's own session file starts plain `dwl`; point it at our wrapper so the
	# bar, wallpaper and status feed come up with the session.
	local desk=/usr/local/share/wayland-sessions/dwl.desktop
	if [ -f "$desk" ]; then
		root sed -i "s|^Exec=.*|Exec=$HOME/.local/bin/dwl-session|" "$desk"
		note "session exec -> $HOME/.local/bin/dwl-session"
	else
		warn "$desk missing (dwl not installed?)"
	fi

	if have systemctl; then
		# sddm must become the display manager; say so when another one was active
		local current_dm
		current_dm=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
		if [ -n "$current_dm" ] && [ "${current_dm##*/}" != sddm.service ]; then
			note "replacing active display manager ${current_dm##*/} with sddm"
		fi
		root systemctl set-default graphical.target >/dev/null 2>&1 \
			|| note "could not set graphical.target as default"
		root systemctl enable sddm >/dev/null 2>&1 || warn "could not enable sddm"
	fi
}
