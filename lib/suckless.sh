# shellcheck shell=bash
# Suckless stack: dwl (compositor), dwlb (bar), st-wl (Wayland st fork).
# Only patches from this repo are applied - no vendored source trees.

DWL_REPO=https://codeberg.org/dwl/dwl.git
DWL_REF=a6e2c155de5daf01f47a726029dc929c4fb8e489
DWLB_REPO=https://github.com/kolunmi/dwlb.git
DWLB_REF=48dbe00bdb98a1ae6a0e60558ce14503616aa759
STWL_REPO=https://github.com/marchaesen/st-wl.git
STWL_REF=86505348b5ebf1532229e201e5d782b8ea92266c

clone_pinned() { # <repo> <ref> <dir>
	local url=$1 ref=$2 dir=$3
	if [ -d "$dir/.git" ]; then
		note "reusing $dir"
		git -C "$dir" fetch --quiet origin 2>/dev/null || warn "fetch failed in $dir"
		if [ -z "$(git -C "$dir" status --porcelain)" ]; then
			git -C "$dir" checkout --quiet --detach "$ref" 2>/dev/null \
				|| warn "could not check out $ref in $dir"
		else
			note "$dir has local changes (patches applied?), leaving checkout alone"
		fi
		return 0
	fi
	info "cloning $url"
	git clone --quiet "$url" "$dir" || die "clone failed: $url"
	git -C "$dir" checkout --quiet --detach "$ref" \
		|| warn "could not check out $ref in $dir, staying on default branch"
}

# Applies every patch in <patchdir> idempotently. A patch that does not apply is
# a hard failure: fix the patch, never skip it.
#
# A clone reused from an earlier run still carries the *old* revision of a patch,
# so neither the reverse check (new hunks are not in the tree yet) nor the plain
# forward check (old hunks are already applied) passes. Those cases are merged
# three-way against the pinned commit instead of aborting the whole run.
apply_patches() { # <dir> <patchdir>
	local dir=$1 pdir=$2 p files
	[ -d "$pdir" ] || return 0
	shopt -s nullglob
	for p in "$pdir"/*.patch; do
		if git -C "$dir" apply --reverse --check "$p" >/dev/null 2>&1; then
			note "already applied: $(basename "$p")"
		elif git -C "$dir" apply --check "$p" >/dev/null 2>&1; then
			git -C "$dir" apply "$p" || die "could not apply $p"
			info "applied: $(basename "$p")"
		else
			files=$(git -C "$dir" apply --numstat "$p" | cut -f3-)
			# git apply --3way needs the index to match these files, so stage them
			# (path list from the patch: never the build artefacts).
			# shellcheck disable=SC2086
			git -C "$dir" add -- $files >/dev/null 2>&1 || true
			if git -C "$dir" apply --3way "$p" >/dev/null 2>&1; then
				info "merged: $(basename "$p") (clone held an older revision)"
			else
				# leave the tree as it was, not with conflict markers in it
				# shellcheck disable=SC2086
				git -C "$dir" checkout -- $files >/dev/null 2>&1 || true
				shopt -u nullglob
				die "patch does not apply: $p
     Rebase/fix the patch onto $(git -C "$dir" rev-parse --short HEAD) and commit the fixed patch.
     If $dir holds local edits, move them aside and re-run."
			fi
		fi
	done
	shopt -u nullglob
}

# Refresh the generated config.h / patches.h from their .def.h templates, so a
# patched config or toggle is actually used. A hand-written copy is kept as .bak.
sync_generated() { # <dir>
	local dir=$1 pair src dst
	for pair in config patches; do
		src="$dir/$pair.def.h"
		dst="$dir/$pair.h"
		[ -f "$src" ] || continue
		if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
			cp "$dst" "$dst.bak"
			note "stale $pair.h in $dir saved as $pair.h.bak"
		fi
		cp "$src" "$dst"
	done
}

build_suckless() {
	[ "$PLATFORM" = linux ] || return 0

	have make || die "make is missing"
	have pkg-config || die "pkg-config is missing"
	have cc || have gcc || die "no C compiler found"
	have tic || warn "tic is missing; st-wl's terminfo entry will not be installed (package: ncurses-bin)"

	info "dwl"
	clone_pinned "$DWL_REPO" "$DWL_REF" "$HOME/dwl"
	apply_patches "$HOME/dwl" "$REPO_ROOT/patches/dwl"
	sync_generated "$HOME/dwl"
	pkg-config --exists wlroots-0.20 || die "wlroots-0.20 not found via pkg-config.
     dwl's pinned commit needs wlroots 0.20:
       debian: libwlroots-0.20-dev   fedora: wlroots-devel   arch: wlroots0.20"
	make -C "$HOME/dwl" || die "dwl build failed"
	root make -C "$HOME/dwl" install
	# dwl's install rewrites its session file to a plain `Exec=dwl`; point it back
	# at our wrapper here, not only in install_wayland_session(), or a failure in
	# any later build step leaves the session without bar, wallpaper and status.
	point_session_at_wrapper

	info "dwlb"
	clone_pinned "$DWLB_REPO" "$DWLB_REF" "$HOME/dwlb"
	apply_patches "$HOME/dwlb" "$REPO_ROOT/patches/dwlb"
	make -C "$HOME/dwlb" || die "dwlb build failed"
	root make -C "$HOME/dwlb" install

	info "st-wl"
	clone_pinned "$STWL_REPO" "$STWL_REF" "$HOME/st-wl"
	apply_patches "$HOME/st-wl" "$REPO_ROOT/patches/st"
	sync_generated "$HOME/st-wl"
	make -C "$HOME/st-wl" || die "st-wl build failed"
	root make -C "$HOME/st-wl" install

	# many tools call `st`; link it unless an st is already installed.
	if ! have st; then
		root ln -sfn /usr/local/bin/st-wl /usr/local/bin/st
		note "linked /usr/local/bin/st -> st-wl"
	fi
}
