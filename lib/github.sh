# shellcheck shell=bash
# GitHub CLI: log in, wire git to gh, set an identity if none exists.

github_setup() {
	if ! have gh; then
		warn "gh not installed, skipping GitHub login"
		return 0
	fi

	if gh auth status >/dev/null 2>&1; then
		note "gh: already authenticated"
	else
		info "GitHub login (browser/device-code flow)"
		if ! gh auth login --hostname github.com --git-protocol https --web; then
			warn "gh auth login failed, run it later with: gh auth login"
			return 0
		fi
	fi

	gh auth setup-git || warn "'gh auth setup-git' failed; git may still prompt for credentials"

	if [ -z "$(git config --global user.name || true)" ]; then
		local login name email
		login=$(gh api user --jq .login 2>/dev/null || true)
		name=$(gh api user --jq '.name // empty' 2>/dev/null || true)
		email=$(gh api user --jq '.email // empty' 2>/dev/null || true)
		[ -n "$name" ] || name=${login:-$(id -un)}
		[ -n "$email" ] || email="${login:-$(id -un)}@users.noreply.github.com"
		git config --global user.name "$name"
		git config --global user.email "$email"
		note "git identity: $name <$email>"
	else
		note "git identity: $(git config --global user.name) <$(git config --global user.email)>"
	fi
}
