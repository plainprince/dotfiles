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

install_dev_tools() {
	if [ "$PLATFORM" = macos ] && ! xcode-select -p >/dev/null 2>&1; then
		die "Xcode command line tools missing: run 'xcode-select --install' first"
	fi

	# The compiler/make/pkg-config part is not optional: dwl, dwlb, st-wl and
	# LazyVim's treesitter parsers all build from source later in this run.
	info "installing developer tools"
	# no neovim here: the distro packages are stale, see install_neovim()
	case $PM in
	apt) pkg_install git curl wget ca-certificates gnupg build-essential pkg-config file zsh unzip fontconfig gh ripgrep ;;
	dnf) pkg_install git curl wget ca-certificates gnupg2 gcc gcc-c++ make pkgconf-pkg-config file zsh unzip fontconfig gh ripgrep ;;
	pacman) pkg_install git curl wget ca-certificates gnupg base-devel pkgconf file zsh unzip fontconfig github-cli ripgrep ;;
	zypper) pkg_install_lenient git curl wget ca-certificates gpg2 gcc gcc-c++ make pkg-config file zsh unzip fontconfig gh ripgrep ;;
	apk) pkg_install_lenient git curl wget ca-certificates gpg build-base pkgconf file zsh unzip fontconfig github-cli ripgrep ;;
	brew) pkg_install git gh ripgrep ;;
	esac

	install_rust
	install_neovim
}

# Neovim from the official release tarball, not the distro package: Debian 13
# ships 0.10.4, Fedora/Arch lag the same way, and LazyVim tracks the 0.11+/0.12
# releases. Linux installs to /opt/nvim (override with NVIM_DEST) and links
# /usr/local/bin/nvim at it, so a distro neovim that is already installed keeps
# working but never wins on PATH. macOS uses Homebrew, which is the install path
# upstream documents for macOS.
install_neovim() {
	if [ "$PLATFORM" = macos ]; then
		info "installing neovim (Homebrew)"
		pkg_install neovim || warn "brew install neovim failed"
		return 0
	fi

	local arch
	case $ARCH in
	aarch64|arm64) arch=arm64 ;;
	x86_64|amd64) arch=x86_64 ;;
	*)
		warn "no official neovim build for $ARCH, keeping the distro package"
		return 0
		;;
	esac

	local dest=${NVIM_DEST:-/opt/nvim} tag have_ver tmp

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

	info "installing neovim ${tag:-latest} (official linux-$arch tarball)"
	tmp=$(mktemp -d)
	if ! curl -fL -o "$tmp/nvim.tar.gz" \
		"https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$arch.tar.gz"; then
		rm -rf "$tmp"
		warn "neovim download failed; leaving the existing install alone"
		return 0
	fi

	# unpack first, so a bad tarball cannot leave the machine without neovim
	if ! tar -C "$tmp" -xzf "$tmp/nvim.tar.gz"; then
		rm -rf "$tmp"
		warn "neovim tarball did not extract; leaving the existing install alone"
		return 0
	fi
	root rm -rf "$dest"
	root mkdir -p "$(dirname "$dest")"
	root mv "$tmp/nvim-linux-$arch" "$dest" \
		|| { rm -rf "$tmp"; warn "could not move neovim into $dest"; return 0; }
	rm -rf "$tmp"
	link_neovim "$dest"
}

# nvim sits in /opt, so link it where PATH already looks (/usr/local/bin comes
# before /usr/bin, which is why an existing distro neovim is shadowed rather
# than removed). A hand-built nvim in that spot is kept as nvim.bak.
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
	dnf) pkg_install rust cargo ;;
	pacman) pkg_install rust ;;
	zypper) pkg_install rust cargo ;;
	apk) pkg_install rust cargo ;;
	brew) pkg_install rust ;;
	none) : ;;
	esac
	have cargo || warn "cargo still missing; consider https://rustup.rs"
}

install_rice_tools() {
	info "installing shell/rice tools"
	pkg_install_lenient bat eza starship zoxide btop cava cmatrix fastfetch

	# starship is not packaged on every distro (e.g. Fedora) -> official installer
	if ! have starship; then
		note "starship not packaged here, using the official installer"
		curl -fsSL https://starship.rs/install.sh | sh -s -- -y || warn "starship install failed"
	fi
}

install_nerd_font() {
	local dir
	if [ "$PLATFORM" = macos ]; then dir="$HOME/Library/Fonts"; else dir="$HOME/.local/share/fonts"; fi

	if ls "$dir"/FiraCodeNerdFont*.ttf >/dev/null 2>&1 \
		|| fc-list 2>/dev/null | grep -qi 'FiraCode Nerd Font'; then
		note "font: FiraCode Nerd Font already present"
		return 0
	fi

	info "installing FiraCode Nerd Font"
	mkdir -p "$dir"
	local tmp
	tmp=$(mktemp -d)
	if ! curl -fsSL -o "$tmp/FiraCode.zip" \
		https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip; then
		warn "font download failed; the bar and terminal will use a fallback font"
		rm -rf "$tmp"
		return 0
	fi
	unzip -qo "$tmp/FiraCode.zip" -d "$dir" || warn "font unzip failed"
	rm -rf "$tmp"
	if [ "$PLATFORM" = linux ] && have fc-cache; then fc-cache -f >/dev/null 2>&1 || true; fi
}

ensure_browser() {
	info "checking for an installed browser"
	local b
	for b in firefox firefox-esr chromium chromium-browser google-chrome google-chrome-stable librewolf brave-browser vivaldi; do
		if have "$b"; then
			note "browser: $b"
			return 0
		fi
	done
	if [ "$PLATFORM" = macos ]; then
		note "browser: Safari (built in)"
		return 0
	fi

	warn "no browser found, installing chromium as the fallback"
	case $PM in
	apt) pkg_install chromium || pkg_install firefox-esr ;;
	dnf) pkg_install chromium || pkg_install firefox ;;
	pacman) pkg_install chromium || pkg_install firefox ;;
	*) pkg_install chromium || pkg_install firefox ;;
	esac
	for b in firefox firefox-esr chromium chromium-browser google-chrome librewolf; do
		if have "$b"; then return 0; fi
	done
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
		if have yay; then yay -S --noconfirm vscodium-bin
		elif have paru; then paru -S --noconfirm vscodium-bin
		else warn "VSCodium is AUR-only here: 'yay -S vscodium-bin'"
		fi
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
		libpixman-1-dev libfontconfig-dev libfreetype-dev libimlib2-dev libfcft-dev zlib1g-dev \
		libxcb1-dev libxcb-icccm4-dev \
		swaybg wmenu wlr-randr sddm qt6-wayland weston xwayland ;;
	dnf) pkg_install_lenient \
		wlroots-devel wayland-devel wayland-protocols-devel libxkbcommon-devel libinput-devel \
		pixman-devel fontconfig-devel freetype-devel imlib2-devel fcft-devel zlib-devel \
		libxcb-devel xcb-util-wm-devel \
		swaybg wmenu wlr-randr sddm qt6-qtwayland weston xorg-x11-server-Xwayland ;;
	pacman) pkg_install_lenient \
		wlroots wayland wayland-protocols libxkbcommon libinput pixman fontconfig freetype2 \
		imlib2 fcft zlib libxcb xcb-util-wm \
		swaybg wmenu wlr-randr sddm qt6-wayland weston xorg-xwayland ;;
	zypper) pkg_install_lenient wlroots-devel wayland-devel libxkbcommon-devel fcft-devel \
		imlib2-devel pixman-devel fontconfig-devel freetype2-devel libxcb-devel xcb-util-wm-devel \
		swaybg wmenu wlr-randr sddm weston ;;
	apk) pkg_install_lenient wlroots-dev wayland-dev wayland-protocols libxkbcommon-dev fcft-dev \
		imlib2-dev pixman-dev fontconfig-dev freetype-dev \
		swaybg wmenu wlr-randr ;;
	esac
}
