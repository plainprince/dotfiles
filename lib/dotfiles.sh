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

install_dotfiles() {
	info "installing configs"
	install_config "$REPO_ROOT/configs/starship.toml" "$HOME/.config/starship.toml"
	install_config "$REPO_ROOT/configs/cava/config" "$HOME/.config/cava/config"
	install_config "$REPO_ROOT/configs/btop/btop.conf" "$HOME/.config/btop/btop.conf"
	install_btop_theme
	install_config "$REPO_ROOT/configs/zshrc" "$HOME/.zshrc"
	install_nvim_config
	install_omz
	install_wallpapers
}
