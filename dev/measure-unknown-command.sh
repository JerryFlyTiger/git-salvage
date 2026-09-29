#!/usr/bin/env bash
# Measures git's answer to an unknown command, the format `git salvage`
# copies for an unknown subcommand: one candidate, several, and none.
# Re-run after a git upgrade; the answers are git's, not ours.
set -u
HOME=$(mktemp -d)
trap 'rm -rf "$HOME"' EXIT
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1 HOME XDG_CONFIG_HOME="$HOME/.config"
# Bypass an installed shim: this measures git itself.
export GIT_SALVAGE_ACTIVE=1
cd "$HOME" || exit 1
for c in resotre com xyzzy; do
	echo "== git $c"
	git "$c" 2>&1 | sed -n l
	echo "rc=${PIPESTATUS[0]}"
done
