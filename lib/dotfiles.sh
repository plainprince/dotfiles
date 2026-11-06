# shellcheck shell=bash
# Dotfiles: starship, cava, btop, zsh + oh-my-zsh, neovim, wallpapers.
# Existing files are never overwritten - a re-run must not destroy local tweaks
# (a machine-specific cava sink, a hand-edited zshrc, ...).

install_config() { # <src> <dest>
	if [ -e "$2" ]; then
		note "keeping existing $2"
		return 0
	fi
	mkdir -p "$(dirname "$2")"
	cp "$1" "$2"
	info "installed $2"
}

install_btop_theme() {
	local src= d
	for d in /usr/share/btop/themes /usr/local/share/btop/themes \
		"$(brew --prefix 2>/dev/null || true)/share/btop/themes"; do
		if [ -n "$d" ] && [ -f "$d/greyscale.theme" ]; then
			src=$d/greyscale.theme
			break
		fi
	done
	if [ -n "$src" ]; then
		mkdir -p "$HOME/.config/btop/themes"
		cp "$src" "$HOME/.config/btop/themes/greyscale.theme"
		note "btop theme: greyscale.theme"
	else
		warn "greyscale.theme not found, btop falls back to its default theme"
	fi
}

install_omz() {
	if [ -d "$HOME/.oh-my-zsh" ]; then
		note "oh-my-zsh: already installed"
	else
		info "installing oh-my-zsh"
		git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh" \
			|| warn "oh-my-zsh clone failed"
	fi
	# omz ships git, zsh-autosuggestions, zsh-syntax-highlighting, zoxide and
	# starship plugins - nothing extra to fetch for our plugin list.

	if have zsh && [ -e "$HOME/.zshrc" ]; then
		local zshbin current
		zshbin=$(command -v zsh)
		current=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
		if [ "${current:-}" != "$zshbin" ]; then
			if root chsh -s "$zshbin" "$(id -un)" >/dev/null 2>&1; then
				note "login shell -> $zshbin (takes effect on next login)"
			else
				warn "could not change login shell; run: chsh -s $zshbin"
			fi
		fi
	fi
}

# Neovim: LazyVim starter layout with the transparent tokyonight theme.
# Plugins are fetched by LazyVim on first launch (needs git; treesitter needs cc).
install_nvim_config() {
	if [ -d "$HOME/.config/nvim" ]; then
		note "keeping existing ~/.config/nvim"
		return 0
	fi
	if ! have nvim; then
		note "neovim not installed, skipping ~/.config/nvim"
		return 0
	fi
	cp -R "$REPO_ROOT/configs/nvim" "$HOME/.config/nvim"
	info "installed ~/.config/nvim (LazyVim + transparent tokyonight)"
}

install_wallpapers() {
	local dest="$HOME/Pictures/Wallpapers" f
	mkdir -p "$dest"
	shopt -s nullglob
	for f in "$REPO_ROOT"/wallpapers/*; do
		[ -e "$dest/$(basename "$f")" ] || cp "$f" "$dest/"
	done
	shopt -u nullglob
	note "wallpapers -> $dest"
}

# starship throws away the *whole* config when a single value is invalid (an
# unknown os.symbols variant, a typo'd key, ...) and then warns on every prompt,
# so what we ship is checked and an installed copy that no longer loads is
# repaired (kept as .bak) instead of silently left broken.
starship_accepts() { # <config file>
	have starship || return 0
	# config errors are only logged to stderr, the exit status stays 0
	! STARSHIP_CONFIG="$1" starship prompt 2>&1 1>/dev/null | grep -q 'Failed to load config'
}

# The prompt is repo design (unlike zshrc/nvim, nothing here is machine specific),
# so a differing local copy is kept as .bak and replaced: otherwise a fixed
# starship.toml never reaches a machine that already has the broken one.
install_starship_config() {
	local src="$REPO_ROOT/configs/starship.toml"
	local dest="$HOME/.config/starship.toml"
	if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
		cp "$dest" "$dest.bak"
		note "existing $dest saved as $dest.bak"
		cp "$src" "$dest"
		info "updated $dest"
	elif [ ! -e "$dest" ]; then
		mkdir -p "$(dirname "$dest")"
		cp "$src" "$dest"
		info "installed $dest"
	else
		note "keeping existing $dest"
	fi
	starship_accepts "$dest" \
		|| warn "starship cannot load $dest - the prompt falls back to its defaults"
}

install_dotfiles() {
	info "installing configs"
	install_starship_config
	install_config "$REPO_ROOT/configs/cava/config" "$HOME/.config/cava/config"
	install_config "$REPO_ROOT/configs/btop/btop.conf" "$HOME/.config/btop/btop.conf"
	install_btop_theme
	install_config "$REPO_ROOT/configs/zshrc" "$HOME/.zshrc"
	install_nvim_config
	install_omz
	install_wallpapers
}
