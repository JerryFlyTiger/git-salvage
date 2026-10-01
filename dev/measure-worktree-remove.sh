#!/usr/bin/env bash
# Measures what `git worktree remove` does to a linked worktree's uncommitted
# work, and how it picks the worktree from its argument, to back DESIGN.md's
# trigger rule for `worktree remove`:
#   P1  plain remove, clean worktree
#   P2  plain remove, modified tracked file
#   P3  plain remove, staged change only
#   P4  plain remove, untracked file only
#   P5  plain remove, ignored file only
#   F1  remove -f, modified tracked file
#   F2  remove -f, ignored file only
#   L1  locked worktree, remove -f, modified tracked file
#   L2  locked worktree, remove -f -f, modified tracked file
#   L3  locked worktree, remove --force --force
#   N1  argument is the worktree's last path component, not a path from cwd
#   N2  argument is a symlink in cwd to worktree A, and also the unique last
#       component of worktree B: which one goes
#   N3  argument matches two worktrees' last component and no path from cwd
#   N4  argument is a relative path through `..`
#   N5  argument is the last component with a trailing slash
#   I1  remove the worktree the command runs in (cwd inside it)
#   M1  remove -f a worktree whose directory is already gone
#   N6  argument is the last component in another letter case
#   N7  argument is a relative path whose last component is in another case
#   N8  cwd is the worktree entered in another letter case, argument .
#   N9  no argument; an empty argument
#   D1  plain remove, clean detached worktree whose commit no ref reaches
#   A1  worktree add -f into an existing non-empty directory
# Each line: rc, whether the uncommitted file is still on disk ("kept") or
# not ("LOST"; "-" when there is no such file), and git's first error line.
# D1 instead says whether the commit is still reachable from any ref or reflog.
# Re-run after a git upgrade; the answers are git's, not ours.
set -u
HOME=$(mktemp -d) || exit 1
HOME=$(cd "$HOME" && pwd -P) || exit 1
trap 'rm -rf "$HOME"' EXIT
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1 HOME XDG_CONFIG_HOME="$HOME/.config"
# Bypass an installed shim: this measures git itself.
export GIT_SALVAGE_ACTIVE=1
git config --global user.name t
git config --global user.email t@t
git config --global init.defaultBranch main

# repo r: main has a and .gitignore (ignores *.log); worktree w on branch wb.
setup() {
	cd "$HOME" || exit 1
	rm -rf "$HOME/r" "$HOME/w" "$HOME/x" "$HOME/y"
	git init -q "$HOME/r"
	cd "$HOME/r" || exit 1
	printf 'a\n' >a
	printf '*.log\n' >.gitignore
	git add . && git commit -qm base
	git worktree add -q -b wb "$HOME/w"
}

# report <label> <rc> <file> <expected content> <errfile>
report() {
	local kept=LOST
	[ "$(cat "$3" 2>/dev/null)" = "$4" ] && kept=kept
	[ "$3" = /dev/null ] && kept=-
	printf '%-3s rc=%-3s %s  %s\n' "$1" "$2" "$kept" "$(grep -m1 -E '^(error|fatal)' "$5")"
}

# exists <label> <dir>...: which of the worktree directories are still there
exists() {
	local l=$1 d out=
	shift
	for d in "$@"; do
		if [ -d "$d" ]; then out="$out ${d#"$HOME"/}=there"; else out="$out ${d#"$HOME"/}=gone"; fi
	done
	printf '    %s:%s\n' "$l" "$out"
}

run() { "$@" >"$HOME/out" 2>&1; }

setup
run git worktree remove "$HOME/w"; rc=$?
report P1 $rc /dev/null '' "$HOME/out"; exists P1 "$HOME/w"

setup; printf 'dirty\n' >"$HOME/w/a"
run git worktree remove "$HOME/w"; report P2 $? "$HOME/w/a" dirty "$HOME/out"

setup; printf 'staged\n' >"$HOME/w/a"; git -C "$HOME/w" add a
run git worktree remove "$HOME/w"; report P3 $? "$HOME/w/a" staged "$HOME/out"

setup; printf 'new\n' >"$HOME/w/n"
run git worktree remove "$HOME/w"; report P4 $? "$HOME/w/n" new "$HOME/out"

setup; printf 'log\n' >"$HOME/w/x.log"
run git worktree remove "$HOME/w"; report P5 $? "$HOME/w/x.log" log "$HOME/out"

setup; printf 'dirty\n' >"$HOME/w/a"
run git worktree remove -f "$HOME/w"; report F1 $? "$HOME/w/a" dirty "$HOME/out"

setup; printf 'log\n' >"$HOME/w/x.log"
run git worktree remove -f "$HOME/w"; report F2 $? "$HOME/w/x.log" log "$HOME/out"

setup; printf 'dirty\n' >"$HOME/w/a"; git worktree lock "$HOME/w"
run git worktree remove -f "$HOME/w"; report L1 $? "$HOME/w/a" dirty "$HOME/out"

setup; printf 'dirty\n' >"$HOME/w/a"; git worktree lock "$HOME/w"
run git worktree remove -f -f "$HOME/w"; report L2 $? "$HOME/w/a" dirty "$HOME/out"

setup; printf 'dirty\n' >"$HOME/w/a"; git worktree lock "$HOME/w"
run git worktree remove --force --force "$HOME/w"; report L3 $? "$HOME/w/a" dirty "$HOME/out"

# N1: cwd is r; there is no ./w, but w is the last component of $HOME/w.
setup; printf 'dirty\n' >"$HOME/w/a"
run git worktree remove -f w; report N1 $? "$HOME/w/a" dirty "$HOME/out"

# N2: worktree A at $HOME/x/real, worktree B at $HOME/y/lnk; cwd r holds a
# symlink lnk -> $HOME/x/real. "lnk" is B's unique last component and, as a
# path from cwd, A.
setup; git worktree add -q -b xb "$HOME/x/real"; git worktree add -q -b yb "$HOME/y/lnk"
printf 'A\n' >"$HOME/x/real/a"; printf 'B\n' >"$HOME/y/lnk/a"
ln -s "$HOME/x/real" "$HOME/r/lnk"
run git worktree remove -f lnk; rc=$?
report N2 $rc "$HOME/x/real/a" A "$HOME/out"; exists N2 "$HOME/x/real" "$HOME/y/lnk"

# N3: two worktrees end in "same"; no ./same in cwd.
setup; git worktree add -q -b xb "$HOME/x/same"; git worktree add -q -b yb "$HOME/y/same"
run git worktree remove -f same; rc=$?
report N3 $rc /dev/null '' "$HOME/out"; exists N3 "$HOME/x/same" "$HOME/y/same"

# N4: relative path through ..
setup; printf 'dirty\n' >"$HOME/w/a"; mkdir "$HOME/r/sub"
(cd "$HOME/r/sub" && run git worktree remove -f ../../w); rc=$?
report N4 $rc "$HOME/w/a" dirty "$HOME/out"

setup; printf 'dirty\n' >"$HOME/w/a"
run git worktree remove -f w/; report N5 $? "$HOME/w/a" dirty "$HOME/out"

# N6: core.ignorecase is true on a case-insensitive file system (macOS).
setup; printf 'dirty\n' >"$HOME/w/a"
run git worktree remove -f W; report N6 $? "$HOME/w/a" dirty "$HOME/out"
printf '    N6 core.ignorecase=%s\n' "$(git config core.ignorecase)"

# N7/N8: ../W and ../w are not the end of any worktree path, so only a path
# comparison can match them.
setup; printf 'dirty\n' >"$HOME/w/a"
run git worktree remove -f ../W; report N7 $? "$HOME/w/a" dirty "$HOME/out"
setup; printf 'dirty\n' >"$HOME/w/a"
if (cd "$HOME/W" 2>/dev/null); then
	inside=$(cd "$HOME/W" && pwd -P)
	(cd "$HOME/W" && run git worktree remove -f .); rc=$?
	report N8 $rc "$HOME/w/a" dirty "$HOME/out"
	printf '    N8 pwd -P inside: %s\n' "${inside#"$HOME"/}"
else
	printf 'N8  n/a (case-sensitive file system)\n'
fi

setup; printf 'dirty\n' >"$HOME/w/a"
(cd "$HOME/w" && run git worktree remove -f); rc=$?
report N9a $rc "$HOME/w/a" dirty "$HOME/out"
(cd "$HOME/w" && run git worktree remove -f ''); rc=$?
report N9b $rc "$HOME/w/a" dirty "$HOME/out"

setup; git worktree add -q --detach "$HOME/x"
git -C "$HOME/x" commit -q --allow-empty -m lone
lone=$(git -C "$HOME/x" rev-parse HEAD)
run git worktree remove "$HOME/x"; rc=$?
reach=unreachable
git rev-list --all --reflog | grep -q "$lone" && reach=reachable
printf '%-3s rc=%-3s commit %s\n' D1 "$rc" "$reach"

setup; printf 'dirty\n' >"$HOME/w/a"
(cd "$HOME/w" && run git worktree remove -f .); rc=$?
report I1 $rc "$HOME/w/a" dirty "$HOME/out"

setup; rm -rf "$HOME/w"
run git worktree remove -f "$HOME/w"; rc=$?
report M1 $rc /dev/null '' "$HOME/out"; printf '    M1 list: %s\n' "$(git worktree list | wc -l | tr -d ' ') entries"

setup; mkdir "$HOME/x"; printf 'mine\n' >"$HOME/x/f"
run git worktree add -f "$HOME/x" main; report A1 $? "$HOME/x/f" mine "$HOME/out"
