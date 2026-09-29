#!/usr/bin/env bash
# Measures whether the shim is reached from shells other than bash:
#   S1  PATH set before the shell starts (a new shell after editing the profile)
#   S2  PATH set inside the shell with the line `install` prints for it
#   S3  the shell ran the real git first (hashed it), then PATH changed
#   S4  the shell hashed the real git, then the shim appeared in a directory
#       that was already on PATH ahead of it (PATH itself unchanged)
#   S5  an alias (oh-my-zsh style `grhh`) and a `git` shell function
# "shim" = the git-salvage stderr line was printed and a refs/salvage ref made.
# Re-run after an OS or shell upgrade; the answers are the shells', not ours.
# shellcheck disable=SC2016 # single-quoted $ is expanded by the shell under test
set -u
HERE=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)
HOME=$(mktemp -d)
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1 HOME XDG_CONFIG_HOME="$HOME/.config"
# The real git: the first `git` on PATH that is not a git-salvage shim, so an
# installed shim cannot pass for the real git below.
# The marker is read from bin/git-salvage, which uses it to recognise a shim.
MARKER=$(sed -n 's/^SHIM_MARKER="\(.*\)"$/\1/p' "$HERE/bin/git-salvage")
[ -n "$MARKER" ] || { echo "no SHIM_MARKER in bin/git-salvage" >&2; exit 1; }
real_git() {
	local d IFS=:
	set -f
	for d in $PATH; do
		[ -n "$d" ] || d=.
		[ -f "$d/git" ] && [ -x "$d/git" ] || continue
		grep -qF -- "$MARKER" "$d/git" 2>/dev/null && continue
		set +f
		printf '%s\n' "$d/git"
		return 0
	done
	set +f
	return 1
}
REAL=$(real_git) || { echo "no real git on PATH" >&2; exit 1; }
REALDIR=${REAL%/*}
PATH=$REALDIR:$PATH
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main
SHIMDIR=$HOME/shimbin
PREDIR=$HOME/prebin          # on PATH ahead of the real git, empty at first
mkdir -p "$PREDIR"
"$HERE/bin/git-salvage" install --dir "$SHIMDIR" >/dev/null || exit 1
BASEPATH=$REALDIR:/usr/bin:/bin
echo "git $(git --version | cut -d' ' -f3), real git in $REALDIR"

fresh() { # fresh repo with uncommitted work in $R
	R=$(mktemp -d "$HOME/r.XXXXXX")
	git -C "$R" init -q && echo base > "$R/a" && git -C "$R" add a &&
		git -C "$R" commit -qm base && echo dirty >> "$R/a"
}
# verdict <stderr-file>: did the shim run, did the command itself run?
verdict() {
	local refs gone
	refs=$(git -C "$R" for-each-ref refs/salvage | wc -l | tr -d ' ')
	grep -q 'dirty' "$R/a" && gone=no || gone=yes
	if grep -q '^git-salvage:' "$1" && [ "$refs" -gt 0 ]; then
		printf 'shim     (refs=%s, work reset=%s)\n' "$refs" "$gone"
	else
		printf 'NO SHIM  (refs=%s, work reset=%s) %s\n' "$refs" "$gone" \
			"$(head -1 "$1")"
	fi
}
# run <label> <shell> <script>: run <script> with <shell> -c in the repo
run() {
	local label=$1 sh=$2 script=$3 err=$HOME/err
	fresh
	(cd "$R" && env -i HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
		LC_ALL=C GIT_CONFIG_NOSYSTEM=1 PATH="$P" "$sh" -c "$script") \
		>/dev/null 2>"$err"
	printf '%-8s %-40s ' "${sh##*/}" "$label"; verdict "$err"
}

shells=''
for s in /bin/zsh /bin/tcsh /bin/csh /bin/ksh /bin/dash /bin/sh /bin/bash \
	"$(command -v fish 2>/dev/null)"; do
	[ -n "$s" ] && [ -x "$s" ] && shells="$shells $s"
done
command -v fish >/dev/null || echo "fish: not installed, not measured"

echo "== S1: PATH set before the shell starts"
P=$SHIMDIR:$BASEPATH
for s in $shells; do run 'git reset --hard' "$s" 'git reset --hard'; done

echo "== S2: PATH set inside the shell (the line install prints)"
P=$BASEPATH
for s in $shells; do
	case ${s##*/} in
	csh | tcsh) line="setenv PATH \"$SHIMDIR:\$PATH\"" ;;
	fish) line="fish_add_path --path --prepend $SHIMDIR" ;;
	*) line="export PATH=\"$SHIMDIR:\$PATH\"" ;;
	esac
	run 'set PATH; git reset --hard' "$s" "$line
git reset --hard"
done

echo "== S3: real git hashed first, then PATH changed in the same shell"
P=$BASEPATH
for s in $shells; do
	case ${s##*/} in
	csh | tcsh) line="setenv PATH \"$SHIMDIR:\$PATH\"" ;;
	fish) line="fish_add_path --path --prepend $SHIMDIR" ;;
	*) line="export PATH=\"$SHIMDIR:\$PATH\"" ;;
	esac
	run 'git --version; set PATH; reset --hard' "$s" "git --version
$line
git reset --hard"
done

echo "== S4: real git hashed, then shim copied into a dir already on PATH"
P=$PREDIR:$BASEPATH
for s in $shells; do
	rm -f "$PREDIR"/*
	run 'git --version; cp shim; reset --hard' "$s" "git --version
cp '$SHIMDIR/git' '$SHIMDIR/git-salvage' '$SHIMDIR/git-salvage-view.html' '$PREDIR/'
git reset --hard"
done
for s in $shells; do
	case ${s##*/} in
	csh | tcsh) re=rehash ;; zsh) re=rehash ;; fish) continue ;; *) re='hash -r' ;;
	esac
	rm -f "$PREDIR"/*
	run "... same, then $re" "$s" "git --version
cp '$SHIMDIR/git' '$SHIMDIR/git-salvage' '$SHIMDIR/git-salvage-view.html' '$PREDIR/'
$re
git reset --hard"
done
rm -f "$PREDIR"/*

echo "== S5: alias and function"
P=$SHIMDIR:$BASEPATH
for s in $shells; do
	case ${s##*/} in
	csh | tcsh) al="alias grhh 'git reset --hard'" ;;
	fish) al="alias grhh 'git reset --hard'" ;;
	bash) al="shopt -s expand_aliases
alias grhh='git reset --hard'" ;;
	*) al="alias grhh='git reset --hard'" ;;
	esac
	# eval: zsh reads a whole -c string before running it, so an alias
	# defined in it only expands in code parsed later.
	run 'alias grhh; eval grhh' "$s" "$al
eval grhh"
done
for s in $shells; do
	case ${s##*/} in
	csh | tcsh) continue ;;   # no shell functions
	fish) fn='function git; command git $argv; end' ;;
	*) fn='git() { command git "$@"; }' ;;
	esac
	run 'git() { command git ...; }; git reset' "$s" "$fn
git reset --hard"
done
run "alias git=<real git>; eval git reset" /bin/zsh "alias git='$REALDIR/git'
eval git reset --hard"
