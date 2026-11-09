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

# Some steps must not run as root (makepkg refuses to build one): drop to the
# user who called setup.sh through sudo, stay put otherwise.
as_builder() {
	if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
		sudo -u "$SUDO_USER" "$@"
	else
		"$@"
	fi
}

# Every source tree this repo builds from (dwl, dwlb, st-wl, Ly) is a derived
# artefact - a re-run re-creates it from the pin plus the patches - so none of
# them belongs in $HOME's face. They live in one cache dir, outside the repo, so
# a checkout never shows up in `git status` there.
CACHE_DIR=$HOME/.cache/dotfiles

# Those trees used to be cloned straight into $HOME. The old copy is dead weight
# and, worse, easy to hand-edit by mistake, so point it out once per tree.
stale_tree_note() { # <old dir> <new dir>
	[ -d "$1" ] && [ ! -e "$2" ] || return 0
	note "$1 is no longer used: the build tree moved to $2 (delete it if it holds no edits)"
}

# ---------------------------------------------------------------------------
# platform detection
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# package manager (Linux)
#
# The distro list is not enumerated here: a dozen managers cover all of it,
# and what matters is which one owns this system. The order settles the cases
# where several are installed - an immutable Fedora has rpm-ostree *and* dnf,
# a phone has apt but no root, Termux's apt lives in a prefix.
#
# Prints "<manager> <family>"; the family picks the package names (they differ
# even between pacman and pacman: Artix drops systemd-only packages, ALARM is a
# separate repository, and a PKGBUILD for x86_64 does not build on aarch64).
pick_pm() {
	# Android/Termux: apt in a prefix, no root, nothing installable in /usr
	if [ -n "${TERMUX_VERSION:-}" ] || [ "${PREFIX:-}" = /data/data/com.termux/files/usr ]; then
		printf 'apt termux'; return 0
	fi
	# immutable images (Silverblue, Kinoite, Bazzite, CoreOS): layering, not dnf
	if [ -f /run/ostree-booted ] && have rpm-ostree; then
		printf 'rpm-ostree fedora'; return 0
	fi
	if have pacman; then printf 'pacman arch'; return 0; fi
	if have apt-get; then printf 'apt debian'; return 0; fi
	if have dnf; then printf 'dnf fedora'; return 0; fi
	if have yum; then printf 'yum fedora'; return 0; fi
	if have zypper; then printf 'zypper suse'; return 0; fi
	if have apk; then printf 'apk alpine'; return 0; fi
	if have xbps-install; then printf 'xbps void'; return 0; fi
	if have emerge; then printf 'emerge gentoo'; return 0; fi
	if have nix; then printf 'nix nixos'; return 0; fi
	if have guix; then printf 'guix guix'; return 0; fi
	if have eopkg; then printf 'eopkg solus'; return 0; fi
	if have swupd; then printf 'swupd clear'; return 0; fi
	if have slackpkg; then printf 'slackpkg slackware'; return 0; fi
	if have tce-load; then printf 'tce tinycore'; return 0; fi
	# PackageKit last: desktops ship pkcon next to their real manager, but on
	# Endless and Sailfish it is the only sane way to install anything.
	if have pkcon; then printf 'pkcon packagekit'; return 0; fi
	if have brew; then printf 'brew macos'; return 0; fi
	printf 'none none'
}

# Families where the rice cannot be installed system-wide: no writable
# /usr/local, no /etc/ly, no init service to hook. The shell/dev/zsh steps still
# run, the Wayland stack is skipped with an explanation instead of half-landing.
rice_unsupported() {
	case $1 in
	nixos | guix | termux) return 0 ;;
	esac
	return 1
}

detect_platform() {
	OS=$(uname -s)
	ARCH=$(uname -m)

	case $OS in
	Linux)
		PLATFORM=linux
		DISTRO=$( (. /etc/os-release 2>/dev/null && printf '%s' "${ID:-linux}") || printf 'linux')
		detect_init
		local pm
		pm=$(pick_pm)
		PM=${pm%% *}
		PM_FAMILY=${pm#* }
		if rice_unsupported "$PM_FAMILY"; then RICE_SUPPORTED=0; else RICE_SUPPORTED=1; fi
		case $DISTRO in
		steamos)
			have steamos-readonly \
				&& note "SteamOS: the root filesystem is read-only ('sudo steamos-readonly disable' first) and an update wipes /usr/local"
			;;
		esac
		[ -d /bedrock ] && note "Bedrock Linux: using $PM - its strata decide which packages exist"
		;;
	Darwin)
		PLATFORM=macos
		DISTRO=macos
		PM_FAMILY=macos
		RICE_SUPPORTED=1
		if have brew; then PM=brew; else PM=none; fi
		;;
	*)
		die "unsupported OS: $OS (supported: Linux, macOS)"
		;;
	esac

	export OS PLATFORM DISTRO ARCH PM PM_FAMILY INIT RICE_SUPPORTED
	if [ "$PLATFORM" = linux ]; then
		info "platform: $OS/$ARCH  distro: $DISTRO  package manager: $PM ($PM_FAMILY)  init: $INIT"
	else
		info "platform: $OS/$ARCH  distro: $DISTRO  package manager: $PM"
	fi
	if [ "$RICE_SUPPORTED" = 0 ]; then
		warn "$DISTRO ($PM_FAMILY): the dwl/Ly rice needs a writable /usr/local, /etc/ly and an init unit - it is skipped, the shell/dev steps still run"
	fi

	if [ "$PLATFORM" = linux ] && [ "$INIT" = unknown ]; then
		warn "no known init system found on PID 1; the display-manager step will be skipped."
	fi

	if [ "$PM" = none ]; then
		warn "no supported package manager found."
		[ "$PLATFORM" = macos ] && warn "install Homebrew first: https://brew.sh"
		warn "package steps will be skipped; run setup.sh again afterwards."
	fi
	if [ "$PLATFORM" = macos ]; then
		note "macOS: shell environment only (dwl/dwlb/st-wl/Ly are Wayland/Linux-only)"
	fi
}

# ---------------------------------------------------------------------------
# init system (Linux)
#
# Arch/Artix share pacman but not PID 1: Artix installs OpenRC, runit, s6 or
# dinit instead of systemd, and each keeps its service files in a different
# place. The display-manager step has to speak the init that is actually
# running, so it is detected once here and everything else keys off $INIT.
# ---------------------------------------------------------------------------
detect_init() {
	INIT=unknown

	# systemd publishes this directory while it is PID 1
	if [ -d /run/systemd/system ]; then
		INIT=systemd
		return 0
	fi

	local comm
	comm=$(cat /proc/1/comm 2>/dev/null || ps -p 1 -o comm= 2>/dev/null || true)
	case $comm in
	systemd) INIT=systemd ;;
	dinit) INIT=dinit ;;
	runit) INIT=runit ;;
	openrc-init | openrc) INIT=openrc ;;
	s6-svscan | s6-init) INIT=s6 ;;
	66) INIT=66 ;;
	esac

	# PID 1 is unreadable in a chroot/container, and 66 supervises through s6:
	# fall back to what is installed. 66 keeps its trees in /etc/66.
	if [ "$INIT" = unknown ] || [ "$INIT" = s6 ]; then
		if have 66 && [ -d /etc/66/service ]; then
			INIT=66
		elif [ -d /etc/s6/sv ] || have s6-rc-db; then
			INIT=s6
		elif [ -d /etc/runit/sv ] || have runsv; then
			INIT=runit
		elif have dinitctl; then
			INIT=dinit
		elif have rc-status || [ -d /etc/runlevels ]; then
			INIT=openrc
		fi
	fi
}

# ---------------------------------------------------------------------------
# sudo: ask once, then keep the timestamp alive for the whole run
# ---------------------------------------------------------------------------
require_sudo() {
	if [ "${PM_FAMILY:-}" = termux ]; then
		die "Termux/Android has no root and no writable /usr: run this inside a proot/chroot distribution (or a real Linux), not in Termux itself"
	fi
	if [ "$(id -u)" -eq 0 ]; then
		SUDO=none
		return 0
	fi
	have sudo || die "sudo is required (or run setup.sh as root)"
	printf '\n%sPrivileged steps:%s package installs, /usr/local binaries, /etc/ly, init services.\n' "$B" "$Z"
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
	yum) root yum -q makecache || true ;;
	# full upgrade on Arch avoids a partial-upgrade breakage later in the run
	pacman) root pacman -Syu --noconfirm --needed ;;
	zypper) root zypper --non-interactive refresh ;;
	apk) root apk update ;;
	xbps) root xbps-install -S ;;
	emerge) root emerge --sync --quiet \
		|| warn "emerge --sync failed (offline?); working from the current tree" ;;
	nix) root nix-channel --update >/dev/null 2>&1 || true ;;
	guix) note "guix: using the current channels (a 'guix pull' would take over the run)" ;;
	eopkg) root eopkg update-repo -y || true ;;
	swupd) root swupd update --no-boot-update || warn "swupd update failed" ;;
	slackpkg) root slackpkg -batch=on -default_answer=y update || warn "slackpkg update failed" ;;
	rpm-ostree) note "immutable image: layered packages only appear after a reboot" ;;
	pkcon) root pkcon refresh force -y >/dev/null 2>&1 || true ;;
	brew) brew update --quiet || true ;;
	esac
}

# nix has no "install these names" batch: every attribute is its own profile
# entry, so a batch is a loop and one miss does not stop the rest.
pkg_install_nix() {
	local p rc=0
	for p in "$@"; do
		if nix profile install "nixpkgs#$p" >/dev/null 2>&1 \
			|| nix-env -iA "nixpkgs.$p"; then
			continue
		fi
		warn "nix: no attribute $p"
		rc=1
	done
	return $rc
}

pkg_install() {
	[ $# -eq 0 ] && return 0
	if [ "$PM" = none ]; then
		warn "skipping packages (no package manager): $*"
		return 0
	fi
	case $PM in
	apt)
		if [ "$PM_FAMILY" = termux ]; then apt install -y "$@"
		else DEBIAN_FRONTEND=noninteractive root apt-get install -y "$@"
		fi
		;;
	dnf) root dnf install -y "$@" ;;
	yum) root yum install -y "$@" ;;
	pacman) root pacman -S --noconfirm --needed "$@" ;;
	zypper) root zypper --non-interactive install "$@" ;;
	apk) root apk add "$@" ;;
	xbps) root xbps-install -y "$@" ;;
	emerge) root emerge --ask=n --noreplace --quiet "$@" ;;
	nix) pkg_install_nix "$@" ;;
	guix) root guix install "$@" ;;
	eopkg) root eopkg install -y "$@" ;;
	swupd) root swupd bundle-add "$@" ;;
	slackpkg) root slackpkg -batch=on -default_answer=y install "$@" ;;
	tce) tce-load -wi "$@" ;;
	pkcon) root pkcon install -y "$@" ;;
	rpm-ostree) root rpm-ostree install --idempotent "$@" ;;
	brew) brew install "$@" ;;
	esac
}

# Several spellings, one intent: install the first candidate this distro carries
# (a browser, an arch-flavoured package name). Prints the winner.
pkg_install_first() {
	local p
	for p in "$@"; do
		if pkg_install "$p" >/dev/null 2>&1; then
			printf '%s' "$p"
			return 0
		fi
	done
	return 1
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

# Same contract for files under /etc (service definitions): a differing copy is
# kept as <dest>.bak, then replaced - a service file is repo design, so a fix
# has to reach a machine that already has the old one.
root_install_script() { # <src> <dest> [mode]
	if [ -e "$2" ] && ! cmp -s "$1" "$2"; then
		root cp "$2" "$2.bak"
		note "existing $2 saved as $2.bak"
	fi
	# -D: the parent (/etc/s6/sv/ly, ...) has to be created as root, not as the
	# user running setup.sh
	root install -D -m "${3:-755}" "$1" "$2"
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
