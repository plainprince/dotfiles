# shellcheck shell=bash
# Logging, platform detection, privilege and package-manager helpers.
# Sourced by setup.sh; every other lib depends on this one.

if [ -t 1 ]; then
	B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; Z=$'\033[0m'
else
	B=; D=; R=; Z=
fi

info() { printf '%s==>%s %s\n' "$B" "$Z" "$*"; }
note() { printf '%s   %s%s\n' "$D" "$*" "$Z"; }
warn() { printf '%s[!]%s %s\n' "$R" "$Z" "$*" >&2; }
die() { printf '%s[x]%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

banner() {
	cat <<'EOF'
  pre-rice setup
  Installs packages and writes files under /etc and /usr/local.
  sudo is asked for once and kept alive for the whole run.
EOF
}

root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# ---------------------------------------------------------------------------
# platform detection
# ---------------------------------------------------------------------------
detect_platform() {
	OS=$(uname -s)
	ARCH=$(uname -m)

	case $OS in
	Linux)
		PLATFORM=linux
		DISTRO=$( (. /etc/os-release 2>/dev/null && printf '%s' "${ID:-linux}") || printf 'linux')
		if have apt-get; then PM=apt
		elif have dnf; then PM=dnf
		elif have pacman; then PM=pacman
		elif have zypper; then PM=zypper
		elif have apk; then PM=apk
		else PM=none
		fi
		;;
	Darwin)
		PLATFORM=macos
		DISTRO=macos
		if have brew; then PM=brew; else PM=none; fi
		;;
	*)
		die "unsupported OS: $OS (supported: Linux, macOS)"
		;;
	esac

	export OS PLATFORM DISTRO ARCH PM
	info "platform: $OS/$ARCH  distro: $DISTRO  package manager: $PM"

	if [ "$PM" = none ]; then
		warn "no supported package manager found."
		[ "$PLATFORM" = macos ] && warn "install Homebrew first: https://brew.sh"
		warn "package steps will be skipped; run setup.sh again afterwards."
	fi
	if [ "$PLATFORM" = macos ]; then
		note "macOS: shell environment only (dwl/dwlb/st-wl/SDDM are Wayland-only)"
	fi
}

# ---------------------------------------------------------------------------
# sudo: ask once, then keep the timestamp alive for the whole run
# ---------------------------------------------------------------------------
require_sudo() {
	if [ "$(id -u)" -eq 0 ]; then
		SUDO=none
		return 0
	fi
	have sudo || die "sudo is required (or run setup.sh as root)"
	printf '\n%sPrivileged steps:%s package installs, /usr/local binaries, /etc/sddm.conf.d, systemctl.\n' "$B" "$Z"
	sudo -v || die "sudo authentication failed"
	SUDO=sudo
	# keepalive: refresh the sudo timestamp every 50s while this script lives
	( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || exit 0; sleep 50; done ) &
	SUDO_KEEPALIVE=$!
	trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT
}

# ---------------------------------------------------------------------------
# package manager wrappers
# ---------------------------------------------------------------------------
pkg_sync() {
	[ "$PM" = none ] && return 0
	info "refreshing package metadata"
	case $PM in
	apt) root apt-get update -qq ;;
	dnf) root dnf -q makecache || true ;;
	# full upgrade on Arch avoids a partial-upgrade breakage later in the run
	pacman) root pacman -Syu --noconfirm --needed ;;
	zypper) root zypper --non-interactive refresh ;;
	apk) root apk update ;;
	brew) brew update --quiet || true ;;
	esac
}

pkg_install() {
	[ $# -eq 0 ] && return 0
	if [ "$PM" = none ]; then
		warn "skipping packages (no package manager): $*"
		return 0
	fi
	case $PM in
	apt) DEBIAN_FRONTEND=noninteractive root apt-get install -y "$@" ;;
	dnf) root dnf install -y "$@" ;;
	pacman) root pacman -S --noconfirm --needed "$@" ;;
	zypper) root zypper --non-interactive install "$@" ;;
	apk) root apk add "$@" ;;
	brew) brew install "$@" ;;
	esac
}

# Install a script we own (status.sh, session wrappers). If a local copy differs,
# keep it as <dest>.bak instead of silently destroying hand edits.
install_script() { # <src> <dest>
	mkdir -p "$(dirname "$2")"
	if [ -e "$2" ] && ! cmp -s "$1" "$2"; then
		cp "$2" "$2.bak"
		note "existing $2 saved as $2.bak"
	fi
	install -m 755 "$1" "$2"
}

# One package name a distro spells differently must not kill the run: retry the
# batch one package at a time and report what this distro does not carry.
pkg_install_lenient() {
	[ $# -eq 0 ] && return 0
	if pkg_install "$@"; then return 0; fi
	warn "batch install failed, retrying one at a time"
	local p
	for p in "$@"; do
		pkg_install "$p" || warn "not available here, skipping: $p"
	done
	return 0
}
