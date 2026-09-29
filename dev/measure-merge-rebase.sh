#!/usr/bin/env bash
# Measures what a plain merge / rebase start (no --abort / --skip) does to
# uncommitted work, to back DESIGN.md's "no snapshot on start" rule:
#   M1  merge, dirty tracked file the merge changes
#   M2  merge, dirty tracked file the merge does not touch
#   M3  merge, staged change to a file the merge does not touch
#   M4  merge, untracked file the merge would create
#   M5  merge that conflicts, dirty tracked file it does not touch
#   M6  fast-forward merge, dirty tracked file the merge changes
#   R1  rebase, dirty tracked file the rebase does not touch
#   R2  rebase, staged change to a file the rebase does not touch
#   R3  rebase that replays a commit, untracked file the new base would create
#   R4  rebase --autostash, dirty tracked file the rebase changes, conflicting
# Each line: rc, whether the uncommitted content is still in the work tree
# ("kept"; R4: in stash@{0}) or not ("LOST"), and git's first error line.
# Re-run after a git upgrade; the answers are git's, not ours.
set -u
HOME=$(mktemp -d)
trap 'rm -rf "$HOME"' EXIT
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1 HOME XDG_CONFIG_HOME="$HOME/.config"
# Bypass an installed shim: this measures git itself.
export GIT_SALVAGE_ACTIVE=1
git config --global user.name t
git config --global user.email t@t
git config --global init.defaultBranch main

# repo: main has a, b, c; branch "side" (from main's first commit) changes a,
# adds n. "ff" is main plus one commit changing a.
setup() {
	rm -rf "$HOME/r"
	git init -q "$HOME/r"
	cd "$HOME/r" || exit 1
	printf 'a\n' >a
	printf 'b\n' >b
	printf 'c\n' >c
	git add . && git commit -qm base
	git branch side
	git branch ff
	printf 'c2\n' >c && git commit -qam main-c
	git checkout -q side
	printf 'a-side\n' >a
	printf 'n\n' >n
	git add . && git commit -qm side
	git checkout -q ff
	git merge -q main
	printf 'a-ff\n' >a && git commit -qam ff-a
	git checkout -q main
}

# report <label> <rc> <file> <expected content> <errfile>
report() {
	local kept=LOST
	[ "$(cat "$3" 2>/dev/null)" = "$4" ] && kept=kept
	printf '%-3s rc=%-3s %s  %s\n' "$1" "$2" "$kept" "$(grep -m1 -E '^(error|fatal)' "$5")"
}

run() { "$@" >"$HOME/out" 2>&1; }

setup; printf 'dirty\n' >a
run git merge --no-edit side; report M1 $? a dirty "$HOME/out"

setup; printf 'dirty\n' >b
run git merge --no-edit side; report M2 $? b dirty "$HOME/out"

setup; printf 'staged\n' >b; git add b
run git merge --no-edit side; report M3 $? b staged "$HOME/out"

setup; printf 'mine\n' >n
run git merge --no-edit side; report M4 $? n mine "$HOME/out"

setup; printf 'a-main\n' >a && git commit -qam main-a; printf 'dirty\n' >b
run git merge --no-edit side; report M5 $? b dirty "$HOME/out"
git merge --abort 2>/dev/null

setup; printf 'dirty\n' >a
run git merge ff; report M6 $? a dirty "$HOME/out"

setup; git checkout -q side; printf 'dirty\n' >b
run git rebase main; report R1 $? b dirty "$HOME/out"

setup; git checkout -q side; printf 'staged\n' >b; git add b
run git rebase main; report R2 $? b staged "$HOME/out"

# "up" has a commit of its own, so the rebase replays it onto side (which
# adds n) instead of fast-forwarding.
setup; git checkout -q -b up main~1; printf 'up\n' >u; git add u
git commit -qm up; printf 'mine\n' >n
run git rebase side; report R3 $? n mine "$HOME/out"
git rebase --abort 2>/dev/null

setup; git checkout -q side; printf 'dirty\n' >c
run git rebase --autostash main; rc=$?
# The autostash does not apply cleanly, so git keeps it in the stash list.
git show 'stash@{0}:c' >"$HOME/stashed" 2>/dev/null
report R4 $rc "$HOME/stashed" dirty "$HOME/out"
printf '    R4 work tree: %s; %s\n' "$(git status --short c)" "$(git stash list | head -1)"
