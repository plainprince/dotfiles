#!/usr/bin/env bash
# Dotfiles repo that pre-rices a fresh machine: clone, run ./setup.sh, done.
# Linux gets the full Wayland rice, macOS the shell environment.
# Safe to re-run: existing configs and checkouts are left alone.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export REPO_ROOT

# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/packages.sh
. "$REPO_ROOT/lib/packages.sh"
# shellcheck source=lib/suckless.sh
. "$REPO_ROOT/lib/suckless.sh"
# shellcheck source=lib/session.sh
. "$REPO_ROOT/lib/session.sh"
# shellcheck source=lib/dotfiles.sh
. "$REPO_ROOT/lib/dotfiles.sh"
# shellcheck source=lib/github.sh
. "$REPO_ROOT/lib/github.sh"

summary() {
	info "done"
}

main() {
	banner
	detect_platform
	require_sudo
	ensure_homebrew # macOS: brew is the package manager
	pkg_sync

	# dev tools first: a browser that has to come from the AUR is built with
	# git + makepkg (base-devel). Still long before `gh auth login --web` below,
	# which is what actually needs the browser.
	install_dev_tools
	ensure_browser
	install_rice_tools
	install_nerd_font
	install_vscodium

	if [ "$PLATFORM" = linux ] && [ "$RICE_SUPPORTED" = 1 ]; then
		install_wayland_pkgs
		# before dwl: its session file must never point at a wrapper that is not
		# on disk yet
		install_session_scripts
		build_suckless
		install_wayland_session
	elif [ "$PLATFORM" = linux ]; then
		warn "skipping the Wayland rice: $DISTRO ($PM_FAMILY) has no writable /usr/local and no init unit layout to hook Ly into"
	else
		info "macOS: skipping dwl/dwlb/st-wl and Ly (Wayland-only stack)"
	fi

	install_dotfiles
	github_setup
	summary
}

main "$@"
