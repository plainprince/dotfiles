# shellcheck shell=bash
# Package sets per platform / package manager.

# macOS: Homebrew is the package manager, so make sure it exists before anything
# else runs. Never reinstalls or upgrades an existing brew.
ensure_homebrew() {
	[ "$PLATFORM" = macos ] || return 0

	if have brew; then
		note "homebrew: already installed ($(brew --prefix 2>/dev/null || echo unknown))"
		return 0
	fi

	if ! xcode-select -p >/dev/null 2>&1; then
		have xcode-select && xcode-select --install 2>/dev/null
		die "Homebrew needs the Xcode command line tools: run 'xcode-select --install', wait for it to finish, then re-run setup.sh"
	fi

	info "installing Homebrew (non-interactive)"
	NONINTERACTIVE=1 /bin/bash -c \
		"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
		|| die "Homebrew installation failed"

	# put brew on PATH for the rest of this run
	if [ -x /opt/homebrew/bin/brew ]; then
		eval "$(/opt/homebrew/bin/brew shellenv)"
	elif [ -x /usr/local/bin/brew ]; then
		eval "$(/usr/local/bin/brew shellenv)"
	fi
	have brew || die "brew installed but not on PATH"
	note "homebrew: $(brew --version | head -1)"
}

# Arch only: make sure an AUR helper exists. When neither paru nor yay is
# installed, build paru from the AUR the manual way:
#   git clone https://aur.archlinux.org/paru.git, cd paru, makepkg -si
ensure_aur_helper() {
	[ "$PM" = pacman ] || return 0
	if have paru || have yay; then return 0; fi

	info "installing paru (AUR helper)"
	# makepkg refuses to run as root, so a root-only shell cannot build.
	if [ "$(id -u)" -eq 0 ] && [ -z "$(builder_user)" ]; then
		warn "running as root: makepkg refuses root builds; install paru manually"
		return 1
	fi

	# paru builds with cargo and needs the base toolchain + git
	pkg_install git base-devel rust || warn "paru build deps failed to install"
	if ! have makepkg || ! have fakeroot; then
		warn "makepkg/fakeroot missing (base-devel): cannot build paru"
		return 1
	fi

	local tmp
	tmp=$(as_builder mktemp -d) || return 1
	if ! as_builder git clone --quiet https://aur.archlinux.org/paru.git "$tmp/paru"; then
		warn "paru clone failed"
		rm -rf "$tmp"
		return 1
	fi
	if ! as_builder bash -c 'cd "$1" && makepkg -si --noconfirm' _ "$tmp/paru"; then
		rm -rf "$tmp"
		warn "paru build failed"
		return 1
	fi
	rm -rf "$tmp"

	if have paru || have yay; then
		note "AUR helper: $(have paru && echo paru || echo yay)"
		return 0
	fi
	warn "no AUR helper after paru build"
	return 1
}

# Install via whichever AUR helper exists (paru preferred, yay as fallback).
# Never wrapped in root/sudo: the helpers escalate themselves for -S.
aur_install() {
	[ $# -eq 0 ] && return 0
	if have paru; then paru -S --noconfirm --needed "$@"
	elif have yay; then yay -S --noconfirm --needed "$@"
	else
		note "no AUR helper (paru/yay) installed"
		return 1
	fi
}

# Last resort for a package the repos of an Arch-family system do not carry:
# the AUR is nothing but git repositories, so fetch the PKGBUILD by hand and
# build it.
#
#   git clone https://aur.archlinux.org/<pkg>.git && cd <pkg> && makepkg -si
#
# No helper is involved - that is the point. Artix does not mirror every Arch
# package, ALARM keeps its own set, and a small derivative may have neither paru
# nor yay. Every failure is a warning: the caller decides what to do without the
# package (and some names are in neither the repos nor the AUR - check the AUR
# RPC before adding one here).
aur_git_install() {
	[ $# -eq 0 ] && return 0
	if [ "$PM_FAMILY" != arch ]; then
		warn "AUR is Arch-only; this is $PM_FAMILY"
		return 1
	fi
	if [ "$(id -u)" -eq 0 ] && [ -z "$(builder_user)" ]; then
		warn "makepkg refuses to build as root: run setup.sh as your user (sudo or doas is used for installs)"
		return 1
	fi
	if ! have git || ! have makepkg || ! have fakeroot; then
		warn "AUR build needs git, makepkg and fakeroot (base-devel + git)"
		return 1
	fi

	local p tmp rc=1
	for p in "$@"; do
		tmp=$(as_builder mktemp -d) || continue
		if ! as_builder git clone --quiet --depth=1 "https://aur.archlinux.org/$p.git" "$tmp/$p" 2>/dev/null; then
			note "AUR: no package named $p"
			rm -rf "$tmp"
			continue
		fi
		# x86_64-only PKGBUILD on ARM (ALARM, Asahi) is a build that cannot
		# work: say why before it burns time.
		if [ -n "${ARCH:-}" ] && [ -f "$tmp/$p/PKGBUILD" ] \
			&& ! grep -qE "(^|[^a-z])($ARCH|any)([^a-z]|$)" "$tmp/$p/PKGBUILD"; then
			warn "AUR: $p does not build for $ARCH (arch=() in its PKGBUILD)"
			rm -rf "$tmp"
			continue
		fi
		info "building $p from the AUR (git + makepkg -si)"
		if as_builder bash -c 'cd "$1" && makepkg -si --noconfirm' _ "$tmp/$p"; then
			note "AUR: $p installed"
			rc=0
		else
			warn "AUR: $p failed to build (see the log above)"
		fi
		rm -rf "$tmp"
	done
	return $rc
}

# Arch: try pacman first, then the AUR helper, then the AUR by git. A package
# missing from one path is retried on the next instead of failing the run.
# Always returns 0; unresolvable packages are warnings, like
# pkg_install_lenient.
arch_install_lenient() {
	[ $# -eq 0 ] && return 0
	if pkg_install "$@"; then return 0; fi
	warn "pacman batch failed, retrying one at a time (pacman, AUR helper, AUR git)"
	ensure_aur_helper || true
	local p
	for p in "$@"; do
		pkg_install "$p" || aur_install "$p" || aur_git_install "$p" \
			|| warn "not available here, skipping: $p"
	done
	return 0
}

install_dev_tools() {
	if [ "$PLATFORM" = macos ] && ! xcode-select -p >/dev/null 2>&1; then
		die "Xcode command line tools missing: run 'xcode-select --install' first"
	fi

	# The compiler/make/pkg-config part is not optional: dwl, dwlb, st-wl and
	# LazyVim's treesitter parsers all build from source later in this run.
	info "installing developer tools"
	# no neovim here on purpose: install_neovim() uses the upstream release and
	# removes any package-managed copy, the package managers are never used for it
	case $PM in
	apt) pkg_install git curl wget ca-certificates gnupg build-essential pkg-config file zsh unzip fontconfig gh ripgrep ;;
	dnf | yum | rpm-ostree) pkg_install git curl wget ca-certificates gnupg2 gcc gcc-c++ make pkgconf-pkg-config file zsh unzip fontconfig gh ripgrep ;;
	pacman) pkg_install git curl wget ca-certificates gnupg base-devel pkgconf file zsh unzip fontconfig github-cli ripgrep ;;
	zypper) pkg_install_lenient git curl wget ca-certificates gpg2 gcc gcc-c++ make pkg-config file zsh unzip fontconfig gh ripgrep ;;
	apk) pkg_install_lenient git curl wget ca-certificates gpg build-base pkgconf file zsh unzip fontconfig github-cli ripgrep ;;
	# base-devel is Void's metapackage for the build chain too
	xbps) pkg_install_lenient git curl wget ca-certificates gnupg base-devel pkg-config file zsh unzip fontconfig github-cli ripgrep ;;
	# portage atoms: a bare name can be ambiguous, so the essentials are spelled
	# out. USE flags are the user's business and are not touched.
	emerge) pkg_install_lenient dev-vcs/git net-misc/curl net-misc/wget app-misc/ca-certificates app-crypt/gnupg sys-devel/gcc sys-devel/make dev-util/pkgconf sys-apps/file app-shells/zsh app-arch/unzip media-libs/fontconfig sys-apps/ripgrep ;;
	nix) pkg_install_lenient git curl wget cacert gnupg gcc gnumake pkg-config file zsh unzip fontconfig gh ripgrep ;;
	guix) pkg_install_lenient git curl wget nss-certs gnupg gcc-toolchain make pkg-config file zsh unzip fontconfig gh ripgrep ;;
	eopkg)
		# Solus ships the toolchain as one component bundle
		root eopkg install -y -c system.devel || warn "solus: the system.devel bundle failed"
		pkg_install_lenient git curl wget ca-certificates make pkg-config file zsh unzip fontconfig gh ripgrep ;;
	swupd | slackpkg | tce | pkcon | none)
		# Clause-by-clause lists for these do not exist: try the generic names
		# and let the lenient retry name what this system does not carry.
		note "$PM: no exact package names here, trying the generic ones"
		pkg_install_lenient git curl wget ca-certificates gcc make pkg-config file zsh unzip fontconfig ripgrep ;;
	brew) pkg_install git gh ripgrep ;;
	esac

	install_rust
	install_neovim
}

# Neovim comes from upstream only. No package manager touches it: the distro
# packages and the Homebrew formula both lag (Debian 13 ships 0.10.4) while
# LazyVim tracks 0.11+/0.12. Upstream ships release archives rather than a shell
# installer, so those archives are what get installed: unpacked into /opt/nvim
# (override with NVIM_DEST) and linked at /usr/local/bin/nvim.
#
# A package-managed neovim is removed - not purged, so its config survives - both
# so it can never be the binary that answers `nvim` and so the next distro
# upgrade does not drop half a runtime next to the upstream one.
NEOVIM_DOWNLOAD=https://github.com/neovim/neovim/releases/latest/download

remove_packaged_neovim() {
	case $PM in
	apt)
		dpkg-query -W -f='${Status}' neovim 2>/dev/null \
			| grep -q 'install ok installed' || return 0
		info "removing the packaged neovim (upstream release is used instead)"
		DEBIAN_FRONTEND=noninteractive root apt-get remove -y neovim \
			|| warn "could not remove the packaged neovim"
		;;
	dnf)
		rpm -q neovim >/dev/null 2>&1 || return 0
		info "removing the packaged neovim (upstream release is used instead)"
		root dnf remove -y neovim || warn "could not remove the packaged neovim"
		;;
	zypper)
		rpm -q neovim >/dev/null 2>&1 || return 0
		info "removing the packaged neovim (upstream release is used instead)"
		root zypper --non-interactive remove neovim \
			|| warn "could not remove the packaged neovim"
		;;
	pacman)
		pacman -Q neovim >/dev/null 2>&1 || return 0
		info "removing the packaged neovim (upstream release is used instead)"
		root pacman -R --noconfirm neovim || warn "could not remove the packaged neovim"
		;;
	apk)
		apk info -e neovim >/dev/null 2>&1 || return 0
		info "removing the packaged neovim (upstream release is used instead)"
		root apk del neovim || warn "could not remove the packaged neovim"
		;;
	brew)
		brew list --formula neovim >/dev/null 2>&1 || return 0
		info "removing the Homebrew neovim (upstream release is used instead)"
		brew uninstall neovim || warn "could not remove the Homebrew neovim"
		;;
	xbps)
		xbps-query -l 2>/dev/null | grep -q '^ii neovim-' || return 0
		info "removing the packaged neovim (upstream release is used instead)"
		root xbps-remove -y neovim || warn "could not remove the packaged neovim"
		;;
	eopkg)
		eopkg list-installed 2>/dev/null | grep -q '^neovim' || return 0
		info "removing the packaged neovim (upstream release is used instead)"
		root eopkg remove -y neovim || warn "could not remove the packaged neovim"
		;;
	esac
	return 0
}

install_neovim() {
	# NixOS/Guix keep /usr read-only, so the upstream archive has nowhere to
	# live here: let the distro's own neovim be the answer.
	if rice_unsupported "$PM_FAMILY"; then
		note "$PM_FAMILY: install neovim through $PM (the upstream archive needs a writable /usr/local)"
		return 0
	fi

	remove_packaged_neovim

	local os arch dest tag have_ver tmp

	if [ "$PLATFORM" = macos ]; then os=macos; else os=linux; fi
	case $ARCH in
	aarch64|arm64) arch=arm64 ;;
	x86_64|amd64) arch=x86_64 ;;
	*)
		warn "no official neovim build for $ARCH; install it by hand"
		return 0
		;;
	esac

	dest=${NVIM_DEST:-/opt/nvim}

	# releases/latest redirects to /releases/tag/vX.Y.Z - cheaper than the API
	tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
		https://github.com/neovim/neovim/releases/latest 2>/dev/null) || tag=
	tag=${tag##*/}

	if [ -x "$dest/bin/nvim" ]; then
		have_ver=$("$dest/bin/nvim" --version 2>/dev/null | head -1)
		if [ -z "$tag" ] || [ "$have_ver" = "NVIM $tag" ]; then
			note "neovim: already ${have_ver:-installed} in $dest"
			link_neovim "$dest"
			return 0
		fi
		info "neovim: upgrading ${have_ver:-unknown} -> $tag"
	fi

	info "installing neovim ${tag:-latest} (official $os-$arch archive)"
	tmp=$(mktemp -d)
	if ! curl -fL -o "$tmp/nvim.tar.gz" "$NEOVIM_DOWNLOAD/nvim-$os-$arch.tar.gz"; then
		rm -rf "$tmp"
		warn "neovim download failed; leaving the existing install alone"
		return 0
	fi

	# unpack first, so a bad tarball cannot leave the machine without neovim
	if ! tar -C "$tmp" -xzf "$tmp/nvim.tar.gz"; then
		rm -rf "$tmp"
		warn "neovim archive did not extract; leaving the existing install alone"
		return 0
	fi
	root rm -rf "$dest"
	root mkdir -p "$(dirname "$dest")"
	root mv "$tmp/nvim-$os-$arch" "$dest" \
		|| { rm -rf "$tmp"; warn "could not move neovim into $dest"; return 0; }
	rm -rf "$tmp"
	link_neovim "$dest"
}

# nvim sits in /opt, so link it where PATH already looks. A hand-built nvim in
# that spot is kept as nvim.bak.
link_neovim() { # <prefix>
	local bin=/usr/local/bin/nvim
	if [ -L "$bin" ] && [ "$(readlink "$bin")" = "$1/bin/nvim" ]; then
		return 0
	fi
	if [ -e "$bin" ] && [ ! -L "$bin" ]; then
		root mv -f "$bin" "$bin.bak" && note "existing $bin saved as $bin.bak"
	fi
	if root ln -sfn "$1/bin/nvim" "$bin"; then
		note "linked $bin -> $1/bin/nvim"
	else
		warn "could not link $bin; add $1/bin to PATH"
	fi
}

install_rust() {
	if have cargo; then
		note "rust: already installed ($(cargo --version 2>/dev/null || echo unknown))"
		return 0
	fi
	info "installing rust toolchain"
	case $PM in
	apt) pkg_install rustc cargo ;;
	dnf | yum | rpm-ostree) pkg_install rust cargo ;;
	pacman) pkg_install rust ;;
	zypper) pkg_install rust cargo ;;
	apk) pkg_install rust cargo ;;
	xbps) pkg_install rust cargo ;;
	emerge) pkg_install dev-lang/rust ;;
	nix) pkg_install rustc cargo ;;
	guix) pkg_install rust ;;
	eopkg) pkg_install rust ;;
	pkcon | swupd | slackpkg | tce) pkg_install_first rust rustc || true ;;
	brew) pkg_install rust ;;
	none) : ;;
	esac
	have cargo || warn "cargo still missing; consider https://rustup.rs"
}

install_rice_tools() {
	info "installing shell/rice tools"
	if [ "$PM" = pacman ]; then
		arch_install_lenient bat eza starship zoxide btop cava cmatrix fastfetch
	else
		pkg_install_lenient bat eza starship zoxide btop cava cmatrix fastfetch
	fi

	# starship is not packaged on every distro (e.g. Fedora) -> official installer
	if ! have starship; then
		note "starship not packaged here, using the official installer"
		curl -fsSL https://starship.rs/install.sh | sh -s -- -y || warn "starship install failed"
	fi
}

# fontconfig is the authority the bar (dwlb) resolves the family against.
# A single fc-list call can miss a just-installed family (stale cache), so
# check the exact family name first and fall back to a broader match.
font_present() {
	have fc-list || return 1
	local families
	families=$(fc-list 2>/dev/null) || return 1
	printf '%s\n' "$families" | grep -qi 'FiraCode Nerd Font' && return 0
	printf '%s\n' "$families" | grep -qi 'FiraCode'
}

install_nerd_font() {
	local dir
	if [ "$PLATFORM" = macos ]; then dir="$HOME/Library/Fonts"; else dir="$HOME/.local/share/fonts"; fi

	# stale or partial .ttf files on disk must not count as installed.
	if font_present; then
		note "font: FiraCode Nerd Font already present"
		return 0
	fi
	if ! have fc-list && ls "$dir"/FiraCodeNerdFont*.ttf >/dev/null 2>&1; then
		note "font: FiraCode Nerd Font files already present (no fc-list to verify)"
		return 0
	fi

	info "installing FiraCode Nerd Font"
	mkdir -p "$dir"
	local tmp
	tmp=$(mktemp -d)
	if ! curl -fsSL --retry 3 -o "$tmp/FiraCode.zip" \
		https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip; then
		rm -rf "$tmp"
		font_missing "font download failed"
		return 0
	fi
	if ! unzip -qo "$tmp/FiraCode.zip" -d "$dir"; then
		rm -rf "$tmp"
		font_missing "font unzip failed"
		return 0
	fi
	rm -rf "$tmp"
	# the archive must actually have yielded font files, not just exited 0
	if ! ls "$dir"/FiraCode*.ttf >/dev/null 2>&1 && ! ls "$dir"/FiraCode*.otf >/dev/null 2>&1; then
		font_missing "font archive contained no FiraCode files"
		return 0
	fi
	# the download/unzip is this function's job: a fresh install needs a cache
	# reload before fontconfig lists the family, so rebuild and re-verify
	# (targeted first, full on retry) instead of failing on the first listing.
	if have fc-cache; then fc-cache -f "$dir" >/dev/null 2>&1 || true; fi
	if font_present || ! have fc-list; then
		note "font: FiraCode Nerd Font installed"
		return 0
	fi
	if have fc-cache; then fc-cache -f >/dev/null 2>&1 || true; fi
	if font_present; then
		note "font: FiraCode Nerd Font installed"
		return 0
	fi
	# files are on disk but fontconfig still does not list the family: the
	# download did its job, so do not block setup - a later cache reload
	# (or login) picks them up. Still loud, just not fatal.
	warn "FiraCode Nerd Font files are in $dir but fontconfig does not list the family yet; continuing - run 'fc-cache -f' and re-run setup.sh if the bar shows tofu"
}

# The dwl bar matches "FiraCode Nerd Font" through fontconfig: without it the
# status icons render as tofu. Loud on Linux (the bar is core to the rice),
# a warning on macOS (only the terminal/prompt wants it, and that font is
# picked in the terminal's own settings).
font_missing() { # <reason>
	if [ "$PLATFORM" = linux ]; then
		die "FiraCode Nerd Font unavailable ($1); the bar would show tofu. Fix the download/unzip and re-run."
	else
		warn "FiraCode Nerd Font unavailable ($1); continuing without it"
	fi
}

# First browser already on PATH. Split off from ensure_browser() so the dwl
# config can point its Mod+Shift+Return bind at the same answer without
# installing anything (see set_dwl_browser in lib/suckless.sh).
detect_browser() {
	local b
	for b in firefox firefox-esr chromium chromium-browser google-chrome \
	         google-chrome-stable librewolf brave-browser vivaldi; do
		if have "$b"; then
			printf '%s' "$b"
			return 0
		fi
	done
	return 1
}

ensure_browser() {
	info "checking for an installed browser"
	local b
	if b=$(detect_browser); then
		note "browser: $b"
		return 0
	fi
	if [ "$PLATFORM" = macos ]; then
		note "browser: Safari (built in)"
		return 0
	fi

	warn "no browser found, installing the fallback"
	case $PM_FAMILY in
	arch)
		# Artix mirrors neither every Arch repo package nor AUR chromium for
		# ALARM: try the repos, then the AUR by git, then another browser.
		pkg_install_first chromium chromium-browser firefox \
			|| aur_git_install chromium || true ;;
	debian | suse | fedora | alpine | void | gentoo | solus | packagekit)
		pkg_install_first chromium chromium-browser firefox-esr firefox || true ;;
	*) pkg_install_first chromium firefox || true ;;
	esac
	if b=$(detect_browser); then
		note "browser: $b"
		return 0
	fi
	warn "still no browser: 'gh auth login --web' will only print a device code"
}

install_vscodium() {
	if have codium; then
		note "vscodium: already installed"
		return 0
	fi
	info "installing VSCodium"
	local tmp
	case $PM in
	apt)
		local key=/usr/share/keyrings/vscodium-archive-keyring.asc
		curl -fsSL https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
			| root tee "$key" >/dev/null || { warn "vscodium key fetch failed"; return 0; }
		tmp=$(mktemp)
		printf 'Types: deb\nURIs: https://download.vscodium.com/debs\nSuites: vscodium\nComponents: main\nArchitectures: %s\nSigned-By: %s\n' \
			"$(dpkg --print-architecture)" "$key" >"$tmp"
		root install -m 644 "$tmp" /etc/apt/sources.list.d/vscodium.sources
		rm -f "$tmp"
		root apt-get update -qq || warn "apt update after adding the vscodium repo failed"
		pkg_install codium || warn "codium install failed, the repo layout may have changed"
		;;
	dnf)
		tmp=$(mktemp)
		cat >"$tmp" <<'REPO'
[vscodium]
name=VSCodium
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpm/releases/$releasever/$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
REPO
		root install -m 644 "$tmp" /etc/yum.repos.d/vscodium.repo
		rm -f "$tmp"
		pkg_install codium || warn "codium install failed"
		;;
	pacman)
		# VSCodium is AUR-only on Arch: helper first, then the manual git way.
		ensure_aur_helper || true
		aur_install vscodium-bin || aur_git_install vscodium-bin \
			|| warn "VSCodium is AUR-only here: 'paru -S vscodium-bin' (or yay)"
		;;
	xbps | apk | eopkg | emerge | nix | guix)
		pkg_install_first codium vscodium \
			|| warn "no VSCodium package for $PM; install it by hand"
		;;
	brew) brew install --cask vscodium || warn "vscodium cask failed" ;;
	*)
		[ "$PM" = none ] || warn "no VSCodium path for $PM"
		;;
	esac
}

# Wayland stack + everything dwl/dwlb/st-wl link against. Linux only.
install_wayland_pkgs() {
	info "installing Wayland/compositor packages"
	# xcb + xcb-icccm are for the XWayland patch in patches/dwl/03-xwayland.patch
	case $PM in
	apt) pkg_install_lenient \
		libwlroots-0.20-dev libwayland-dev wayland-protocols libxkbcommon-dev libinput-dev \
		libpixman-1-dev libfontconfig-dev libfreetype-dev libimlib2-dev libfcft-dev libtllist-dev zlib1g-dev \
		libxcb1-dev libxcb-icccm4-dev \
		libpam0g-dev \
		swaybg wmenu wlr-randr xwayland ;;
	dnf | yum | rpm-ostree) pkg_install_lenient \
		wlroots-devel wayland-devel wayland-protocols-devel libxkbcommon-devel libinput-devel \
		pixman-devel fontconfig-devel freetype-devel imlib2-devel fcft-devel tllist-devel zlib-devel \
		libxcb-devel xcb-util-wm-devel pam-devel \
		swaybg wmenu wlr-randr xorg-x11-server-Xwayland ;;
	# ly is built from source (patched): see lib/session.sh
	# NOTE: the 0.20 library is the versioned 'wlroots0.20' package, not
	# 'wlroots' (which tracks the latest major and, via paru, matches several
	# versioned AUR results). The versioned name is unambiguous on both managers.
	pacman)
		# Arch, Artix, Manjaro, ALARM, Asahi, SteamOS, KaOS and the rest of the
		# family share these names but not their repositories: a name this
		# particular set does not carry goes through the AUR by git.
		# pam is in Arch's base but is named explicitly for ly's build.
		# wmenu is left to install_wmenu: a name Artix does not carry would
		# otherwise be retried against an AUR that has no wmenu at all.
		arch_install_lenient \
			wlroots0.20 wayland wayland-protocols libxkbcommon libinput pixman fontconfig freetype2 \
			imlib2 fcft tllist zlib libxcb xcb-util-wm pam \
			swaybg wlr-randr xorg-xwayland
		;;
	zypper) pkg_install_lenient wlroots-devel wayland-devel libxkbcommon-devel fcft-devel \
		imlib2-devel pixman-devel fontconfig-devel freetype2-devel tllist-devel libxcb-devel xcb-util-wm-devel \
		pam-devel \
		swaybg wmenu wlr-randr ;;
	apk) pkg_install_lenient wlroots-dev wayland-dev wayland-protocols libxkbcommon-dev fcft-dev \
		imlib2-dev pixman-dev fontconfig-dev freetype-dev tllist-dev \
		linux-pam-dev libxcb-dev \
		swaybg wmenu wlr-randr ;;
	xbps)
		# Void versions wlroots like Arch does. 0.20 is what the pinned dwl
		# needs; an older one at least lets the build reach the pkg-config check.
		pkg_install wlroots0.20 || pkg_install wlroots0.19 \
			|| warn "void: no wlroots 0.19/0.20 package (dwl needs 0.20)"
		pkg_install_lenient wayland wayland-protocols libxkbcommon libinput pixman \
			fontconfig freetype imlib2 fcft tllist zlib libxcb xcb-util-wm linux-pam \
			swaybg wmenu wlr-randr xorg-server-xwayland ;;
	emerge)
		# portage atoms; USE flags and the wlroots version are the user's call,
		# so this is best effort and the build step names what is missing.
		pkg_install_lenient gui-libs/wlroots dev-libs/wayland dev-libs/wayland-protocols \
			x11-libs/libxkbcommon dev-libs/libinput x11-libs/pixman media-libs/fontconfig \
			media-libs/freetype media-libs/imlib2 gui-libs/fcft dev-libs/tllist sys-libs/zlib \
			x11-libs/libxcb x11-libs/xcb-util-wm sys-libs/pam \
			gui-apps/swaybg gui-apps/wmenu x11-misc/wlr-randr x11-base/xwayland ;;
	*)
		warn "no Wayland package list for $PM ($PM_FAMILY): install wlroots 0.20, wayland, wayland-protocols, libxkbcommon, libinput, pixman, fontconfig, freetype, imlib2, fcft, tllist, zlib, libxcb + xcb-util-wm, pam and swaybg/wmenu, then re-run"
		;;
	esac
	install_wmenu
}

# dwl's menu bind (Mod+Space / Mod+d) runs wmenu-run. wmenu is in Arch's extra
# repository; Artix has no repository for it, and the AUR carries no wmenu under
# any name (wmenu, wmenu-git and wmenu-wayland all answer "not found"), so a
# git build cannot help there. bemenu speaks the same dmenu protocol, and
# lib/session.sh's wmenu-run shim puts it behind that name; the bind and dwl's
# config stay untouched either way.
install_wmenu() {
	have wmenu && return 0
	if [ "$PM_FAMILY" = arch ]; then
		pkg_install wmenu || note "wmenu: not in this system's repositories"
		have wmenu && return 0
	fi
	have bemenu-run || pkg_install_lenient bemenu
	have bemenu-run \
		|| warn "menu: neither wmenu nor bemenu is available here; Mod+Space will not open"
}
