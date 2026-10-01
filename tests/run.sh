#!/usr/bin/env bash
# git-salvage test suite. Oracle: the real git. Prints "tests: N/M passed".
# Run with /bin/bash (macOS bash 3.2) as well as any newer bash.
# shellcheck disable=SC2016 # sh -c '...' _ args: $1 is expanded by that sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REAL_GIT=$(command -v git) || { echo "tests: no git on PATH"; exit 1; }
ORIG_PATH=$PATH
export PATH="$ROOT/bin:$PATH"
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_EDITOR=true GIT_PAGER=cat PAGER=cat
unset GIT_SALVAGE_SKIP GIT_SALVAGE_QUIET GIT_SALVAGE_ACTIVE GIT_SALVAGE_REAL_GIT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

WORK=$(mktemp -d "${TMPDIR:-/tmp}/salvage-test.XXXXXX")
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config"
mkdir -p "$HOME"
"$REAL_GIT" config --global user.name tester
"$REAL_GIT" config --global user.email tester@example.com
"$REAL_GIT" config --global init.defaultBranch main
cleanup() { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0
TOTAL=0
FAILED=()
# FAIL lines go to fd 3, the suite's own stdout, so that `check ... >/dev/null`
# hides only the command's output (dev/mutate.sh reads the FAIL lines).
exec 3>&1
check() { # check <name> <command...>
	local name=$1
	shift
	TOTAL=$((TOTAL + 1))
	if "$@"; then
		PASS=$((PASS + 1))
	else
		FAILED+=("$name")
		echo "FAIL $name" >&3
	fi
}
# skip <name> <why>: a check that cannot run here; M is smaller by one.
skip() { echo "SKIP $1 ($2)" >&3; }

N=0
new_repo() { # -> cd into a fresh repo with one commit; sets R
	N=$((N + 1))
	R="$WORK/r$N"
	git init -q "$R" && cd "$R" || exit 1
	printf 'one\n' >tracked
	printf 'keep\n' >other
	mkdir -p dir
	printf 'deep\n' >dir/nested
	git add -A && git commit -qm base
}
nrefs() { git for-each-ref refs/salvage/ | wc -l | tr -d ' '; }
same() { cmp -s "$1" "$2"; }
# bounded <secs> <cmd...>: run it under timeout(1), else under perl's alarm,
# which survives the exec and kills the command (SIGALRM) when it runs over.
bounded() {
	local t=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$t" "$@"
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$t" "$@"
	else
		perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$t" "$@"
	fi
}
# contains <needle> <haystack>
contains() { case $2 in *"$1"*) return 0 ;; esac; return 1; }
# pre_count <n> <git args...>: _pre succeeds and leaves n refs in total.
pre_count() {
	local n=$1
	shift
	git salvage _pre "$@" && test "$(nrefs)" = "$n"
}
save() { cp -p "$1" "$WORK/saved.$2"; }

# ---------------------------------------------------------- restore per trigger

# Dirty state: modified, staged-only, untracked, odd names, symlink, exec bit.
make_dirty() {
	printf 'modified\n' >>tracked
	printf 'staged\n' >>other
	git add other
	printf 'staged then edited\n' >>other
	printf 'new file\n' >untracked
	printf 'space\n' >'with space'
	printf 'dash\n' >-leading
	printf 'utf8\n' >"$(printf 'caf\303\251')"
	printf 'x\n' >script && chmod +x script
	ln -s tracked link
	for f in tracked other untracked 'with space' -leading "$(printf 'caf\303\251')" script; do
		save "./$f" "$(printf '%s' "$f" | tr -c 'A-Za-z0-9' _)"
	done
}
all_back() {
	local f
	for f in tracked other untracked 'with space' -leading "$(printf 'caf\303\251')" script; do
		same "./$f" "$WORK/saved.$(printf '%s' "$f" | tr -c 'A-Za-z0-9' _)" || { echo "  differs: $f"; return 1; }
	done
	[ -x script ] || { echo "  script lost +x"; return 1; }
	[ -L link ] && [ "$(readlink link)" = tracked ] || { echo "  link not a symlink to tracked"; return 1; }
}

# trigger_case <name> <git args...>: take the snapshot via _pre, run the real
# command, prove the tracked edit is gone, restore, prove everything is back.
trigger_case() {
	local name=$1
	shift
	new_repo
	make_dirty
	check "$name: _pre exits 0" git salvage _pre "$@"
	check "$name: one snapshot" test "$(nrefs)" = 1
	git "$@" >/dev/null 2>&1
	check "$name: command destroyed the edit" test "$(cat tracked)" = one
	check "$name: restore exits 0" git salvage restore 1 >/dev/null 2>&1
	check "$name: everything back byte-for-byte" all_back
}
trigger_case "reset --hard" reset --hard
trigger_case "checkout -f" checkout -f
trigger_case "checkout -- ." checkout -- .
trigger_case "restore ." restore .
# switch -f to the same branch rewrites the tracked files too.
trigger_case "switch -f" switch -f main

# clean: untracked only (tracked edits survive clean by definition).
clean_case() {
	local name=$1
	shift
	new_repo
	printf 'ign\n' >.gitignore
	git add .gitignore && git commit -qm ignore
	printf 'u\n' >untracked
	printf 'i\n' >ign
	check "$name: _pre exits 0" git salvage _pre "$@"
	git "$@" >/dev/null 2>&1
	check "$name: untracked deleted" test ! -e untracked
	check "$name: restore exits 0" git salvage restore 1 >/dev/null 2>&1
	check "$name: untracked back" test "$(cat untracked 2>/dev/null)" = u
}
clean_case "clean -fd" clean -fd
check "clean -fd: ignored file was not deleted" test "$(cat ign)" = i
check "clean -fd: ignored file not in snapshot" \
	test -z "$(git ls-tree --name-only "$(git for-each-ref --format='%(refname)' refs/salvage/ | head -n 1):worktree" ign)"
clean_case "clean -xfd" clean -xfd
check "clean -xfd: ignored file back" test "$(cat ign 2>/dev/null)" = i

# rm -f of a modified file.
new_repo
printf 'mod\n' >>tracked
save tracked rmf
check "rm -f: _pre" git salvage _pre rm -f tracked
git rm -qf tracked
check "rm -f: gone" test ! -e tracked
git salvage restore 1 >/dev/null 2>&1
check "rm -f: back" same tracked "$WORK/saved.rmf"

# restore -- <dir> expands the directory; restore -- <file> only that file.
new_repo
printf 'a\n' >>dir/nested
printf 'b\n' >>tracked
save dir/nested n1
git salvage _pre reset --hard && git reset -q --hard
check "restore -- dir: exits 0" git salvage restore 1 -- dir >/dev/null 2>&1
check "restore -- dir: dir file back" same dir/nested "$WORK/saved.n1"
check "restore -- dir: other file untouched" test "$(cat tracked)" = one
check "restore -- missing path: refused" sh -c '! git salvage restore 2 -- nope >/dev/null 2>&1'
# pathspec relative to the cwd, from a subdirectory
new_repo
printf 'sub\n' >>dir/nested
save dir/nested n2
git salvage _pre reset --hard && git reset -q --hard
(cd dir && git salvage restore 1 -- nested >/dev/null 2>&1)
check "restore from subdir: relative path" same dir/nested "$WORK/saved.n2"
# restore without paths, run from a subdirectory, still covers the whole tree
new_repo
printf 'top\n' >>tracked
save tracked t3
git salvage _pre reset --hard && git reset -q --hard
(cd dir && git salvage restore 1 >/dev/null 2>&1)
check "restore from subdir: whole tree" same tracked "$WORK/saved.t3"

# Names git quotes in its line output: newline, tab, double quote, backslash.
# Two committed and edited, two untracked; the untracked are deleted by hand.
QNAMES=("$(printf 'new\nline')" "$(printf 'tab\there')" 'dq"uote' 'back\slash')
new_repo
printf 'q0\n' >"${QNAMES[0]}" && printf 'q1\n' >"${QNAMES[1]}"
git add -A && git commit -qm quoted
qi=0
for f in "${QNAMES[@]}"; do
	printf 'dirty %s\n' "$qi" >>"$f"
	save "$f" "q$qi"
	qi=$((qi + 1))
done
git salvage _pre reset --hard && git reset -q --hard
rm -f "${QNAMES[2]}" "${QNAMES[3]}"
check "quoted names: list counts 4 paths" sh -c 'git salvage list | grep -q "(4 paths)\$"'
check "quoted names: restore exits 0" git salvage restore 1 >/dev/null 2>&1
qall() {
	local i=0 f
	for f in "${QNAMES[@]}"; do
		same "$f" "$WORK/saved.q$i" || { echo "  differs: $(printf '%q' "$f")"; return 1; }
		i=$((i + 1))
	done
}
check "quoted names: all back byte-for-byte" qall
# restore -- <path> passes the name through ls-files -z / checkout-index -z.
for qi in 0 1 2 3; do
	new_repo
	printf 'dirty\n' >"${QNAMES[$qi]}"
	printf 'other\n' >>tracked
	save "${QNAMES[$qi]}" "p$qi"
	git salvage _pre checkout -f && git checkout -qf && rm -f "${QNAMES[$qi]}"
	check "quoted names: restore -- name $qi exits 0" git salvage restore 1 -- "${QNAMES[$qi]}" >/dev/null 2>&1
	check "quoted names: restore -- name $qi back" same "${QNAMES[$qi]}" "$WORK/saved.p$qi"
	check "quoted names: restore -- name $qi only" test "$(cat tracked)" = one
done

# ------------------------------------------------------ worktree remove

# wt_repo: new_repo that ignores *.log, plus a linked worktree $W on wb.
wt_repo() {
	new_repo
	printf '*.log\n' >.gitignore
	git add .gitignore && git commit -qm ignore
	W="$WORK/w$N"
	git worktree add -q -b wb "$W"
}
newest_ref() { git for-each-ref --sort=-refname --count=1 --format='%(refname)' refs/salvage/; }
WT_FILES="tracked other untracked x.log"
wt_all_back() {
	local f
	for f in $WT_FILES; do
		same "$W/$f" "$WORK/saved.wt_$f" || { echo "  differs: $f"; return 1; }
	done
}

wt_repo
printf 'mod\n' >>"$W/tracked"
printf 'staged\n' >>"$W/other" && git -C "$W" add other
printf 'new\n' >"$W/untracked"
printf 'log\n' >"$W/x.log"
for f in $WT_FILES; do save "$W/$f" "wt_$f"; done
check "worktree remove -f: _pre exits 0" git salvage _pre worktree remove -f "$W"
check "worktree remove -f: one snapshot" test "$(nrefs)" = 1
check "worktree remove -f: Salvage-Head is the worktree's branch" \
	test "$(git log -1 --format='%(trailers:key=Salvage-Head,valueonly)' "$(newest_ref)")" = refs/heads/wb
git worktree remove -f "$W"
check "worktree remove -f: worktree gone" test ! -e "$W"
git worktree add -q "$W" wb
check "worktree remove -f: restore --index in the re-added worktree" \
	sh -c 'cd "$1" && git salvage restore 1 --index >/dev/null 2>&1' _ "$W"
check "worktree remove -f: everything back, ignored file too" wt_all_back
check "worktree remove -f: index back" test "$(git -C "$W" diff --cached --name-only)" = other

# Plain remove deletes ignored files (DESIGN.md), so it is caught too.
wt_repo
printf 'log\n' >"$W/x.log"
check "worktree remove, ignored file only: snapshot" pre_count 1 worktree remove "$W"
check "worktree remove, ignored file only: file saved" git cat-file -e "$(newest_ref):worktree/x.log"
wt_no_tmp() {
	local f
	for f in "$R/.git/salvage-tmp."* "$R/.git/worktrees/w$N/salvage-tmp."*; do
		[ -e "$f" ] && return 1
	done
	return 0
}
check "worktree remove: no temp files left" wt_no_tmp
git worktree remove "$W"
check "worktree remove, ignored file only: git deleted it" test ! -e "$W"
wt_repo
check "worktree remove, clean worktree: no snapshot" pre_count 0 worktree remove "$W"

# How the argument names the worktree (dev/measure-worktree-remove.sh).
wt_repo
printf 'by name\n' >>"$W/tracked"
check "worktree remove: by last path component" pre_count 1 worktree remove -f "w$N"
check "worktree remove: by last path component: that worktree saved" \
	test "$(git show "$(newest_ref):worktree/tracked" | tail -n 1)" = 'by name'
# No <wt>: git prints its usage. Run from the worktree's top, where ./ would
# be the worktree itself.
wt_repo
printf 'noarg\n' >>"$W/tracked"
check "worktree remove with no path: no snapshot" \
	sh -c 'cd "$1" && out=$(git salvage _pre worktree remove -f 2>&1) && test -z "$out" && test "$(git for-each-ref refs/salvage/ | wc -l)" -eq 0' _ "$W"
check "worktree remove with an empty path: no snapshot" \
	sh -c 'cd "$1" && out=$(git salvage _pre worktree remove -f "" 2>&1) && test -z "$out" && test "$(git for-each-ref refs/salvage/ | wc -l)" -eq 0' _ "$W"
# A second, stale worktree (directory gone) is compared by path too: no cd
# error may reach stderr.
wt_repo
git worktree add -q -b stale "$WORK/stale$N" && rm -rf "$WORK/stale$N"
printf 'rel2\n' >>"$W/tracked"
out=$(cd dir && git salvage _pre worktree remove -f "../../w$N" 2>&1)
check "worktree remove with a stale worktree: only the saved line" \
	test "$out" = 'git-salvage: saved snapshot 1 (to undo the removal: add the worktree again, then run git salvage restore 1 in it)'
# Linux: git refuses (core.ignorecase is false), the snapshot costs nothing.
wt_repo
git worktree add -q -b cs "$WORK/Cs$N"
printf 'case\n' >>"$WORK/Cs$N/tracked"
check "worktree remove: last component in other letter case" pre_count 1 worktree remove -f "cS$N"
# ../cP is not the end of any worktree path: only the path compare can
# match. On a case-sensitive file system the mkdir makes a real cP beside
# Cp, which matches once both sides are lowercased (one harmless extra
# snapshot; git would refuse); elsewhere it is the same directory.
wt_repo
git worktree add -q -b cp "$WORK/Cp$N"
mkdir -p "$WORK/cP$N"
printf 'case path\n' >>"$WORK/Cp$N/tracked"
check "worktree remove: relative path in other letter case" pre_count 1 worktree remove -f "../cP$N"
# Entered in another letter case, pwd -P keeps it (measured, N8). Only a
# case-insensitive file system can enter it that way.
wt_repo
printf 'case cwd\n' >>"$W/tracked"
if [ -d "$WORK/W$N" ]; then
	check "worktree remove: . from inside, entered in other letter case" \
		sh -c 'cd "$1" && git salvage _pre worktree remove -f . && test "$(git for-each-ref refs/salvage/ | wc -l)" -eq 1' _ "$WORK/W$N"
else
	skip "worktree remove: . from inside, entered in other letter case" "case-sensitive file system"
fi
wt_repo
printf 'rel\n' >>"$W/tracked"
check "worktree remove: relative path through .." \
	sh -c 'cd dir && git salvage _pre worktree remove -f "../../w$1" && test "$(git for-each-ref refs/salvage/ | wc -l)" -eq 1' _ "$N"
wt_repo
printf 'here\n' >>"$W/tracked"
check "worktree remove: . from inside the worktree" \
	sh -c 'cd "$1" && git salvage _pre worktree remove -f . && test "$(git for-each-ref refs/salvage/ | wc -l)" -eq 1' _ "$W"
wt_repo
printf 'slash\n' >>"$W/tracked"
check "worktree remove: absolute path with trailing slash" pre_count 1 worktree remove -f "$W/"
# lnk is worktree B's last component and, as a path, worktree A: git takes
# B (measured), git-salvage saves both.
wt_repo
git worktree add -q -b xb "$WORK/x$N/real" && git worktree add -q -b yb "$WORK/y$N/lnk"
printf 'A\n' >>"$WORK/x$N/real/tracked" && printf 'B\n' >>"$WORK/y$N/lnk/tracked"
ln -s "$WORK/x$N/real" lnk
out=$(git salvage _pre worktree remove -f lnk 2>&1)
check "worktree remove: name and path disagree: both saved" test "$(nrefs)" = 2
check "worktree remove: name and path disagree: saved line" \
	test "$out" = 'git-salvage: saved snapshots 1-2 (see: git salvage list)'
# With CDPATH=., cd prints the directory it found, which a path match
# reading cd's output would take as part of the path.
wt_repo
printf 'cdpath\n' >>"$W/tracked"
ln -s "$W" cur
check "worktree remove: symlink path under CDPATH=." sh -c 'CDPATH=. git salvage _pre worktree remove -f cur && test "$(git for-each-ref refs/salvage/ | wc -l)" -eq 1'
wt_repo
printf 'main\n' >>tracked
check "worktree remove: the main worktree is not saved" pre_count 0 worktree remove -f "$R"
wt_repo
rm -rf "$W"
# By last component: git still lists the worktree, so it is a match.
out=$(git salvage _pre worktree remove -f "w$N" 2>&1)
check "worktree remove: directory already gone: no snapshot" test "$(nrefs)" = 0
check "worktree remove: directory already gone: no output" test -z "$out"
wt_repo
printf 'x\n' >>"$W/tracked"
check "worktree remove via alias" sh -c 'git -c alias.wr="worktree remove -f" salvage _pre wr "$1" 2>/dev/null && test "$(git for-each-ref refs/salvage/ | wc -l)" -eq 1' _ "$W"

# --git-dir / --work-tree name the main worktree; the snapshot is still of $W.
wt_repo
printf 'main\n' >>tracked
printf 'linked\n' >>"$W/tracked"
check "worktree remove under --git-dir/--work-tree: _pre" \
	git --git-dir="$R/.git" --work-tree="$R" salvage _pre worktree remove -f "$W" 2>/dev/null
check "worktree remove under --git-dir/--work-tree: the linked worktree saved" \
	test "$(git show "$(newest_ref):worktree/tracked" | tail -n 1)" = linked
# GIT_DIR alone still gets the files right (git takes the cwd as the work
# tree), but HEAD and the index are the main worktree's.
check "worktree remove under --git-dir/--work-tree: the linked worktree's HEAD" \
	test "$(git log -1 --format='%(trailers:key=Salvage-Head,valueonly)' "$(newest_ref)")" = refs/heads/wb

# A bare repository with a linked worktree.
wt_repo
B="$WORK/bare$N.git"
git clone -q --bare "$R" "$B" && git -C "$B" worktree add -q "$WORK/bw$N" main
printf 'bare\n' >>"$WORK/bw$N/tracked"
check "worktree remove from a bare repository: _pre" git -C "$B" salvage _pre worktree remove -f "$WORK/bw$N" 2>/dev/null
check "worktree remove from a bare repository: one snapshot" \
	test "$(git -C "$B" for-each-ref refs/salvage/ | wc -l | tr -d ' ')" = 1

wt_repo
printf 'say\n' >>"$W/tracked"
check "worktree remove: saved line" sh -c 'git salvage _pre worktree remove -f "$1" 2>&1 >/dev/null | grep -qx "git-salvage: saved snapshot 1 (to undo the removal: add the worktree again, then run git salvage restore 1 in it)"' _ "$W"
wt_repo
printf 'ro\n' >>"$W/tracked"
chmod -R a-w .git/objects
git salvage _pre worktree remove -f "$W" 2>/dev/null
rc=$?
chmod -R u+w .git/objects
check "worktree remove: fail closed" test "$rc" = 1

# A directory that exists but cannot be entered: no cd error on stderr
# (root can enter it anyway).
wt_repo
mkdir noperm && chmod 000 noperm
out=$(git salvage _pre worktree remove -f noperm 2>&1)
chmod 755 noperm
if [ "$(id -u)" != 0 ]; then
	check "worktree remove: unenterable directory: no output" test -z "$out"
else
	skip "worktree remove: unenterable directory: no output" "root enters it"
fi
# Under a UTF-8 locale macOS tr fails on an invalid byte, with an error on
# stderr. Run only where tr does fail that way.
if ! printf 'A\377\n' | LC_ALL=en_US.UTF-8 tr '[:upper:]' '[:lower:]' >/dev/null 2>&1; then
	wt_repo
	out=$(LC_ALL=en_US.UTF-8 git salvage _pre worktree remove -f "$(printf 'w\377')" 2>&1)
	check "worktree remove: invalid byte under UTF-8: no output" test -z "$out"
else
	skip "worktree remove: invalid byte under UTF-8: no output" "tr does not fail here"
fi

cd "$WORK" || exit 1
out=$(git salvage _pre worktree remove x 2>&1)
rc=$?
check "outside a repo: worktree remove: exit 0" test "$rc" = 0
check "outside a repo: worktree remove: no output" test -z "$out"

# git-salvage run directly, so a fake git first on PATH is the one it calls
# (git puts its own exec-path first for `git salvage`).
mkdir -p "$WORK/oldgit" "$WORK/listfail"
printf '#!/bin/sh\ncase " $* " in *" worktree list "*-z*) echo "error: unknown switch" >&2; exit 129 ;; esac\nexec "%s" "$@"\n' "$REAL_GIT" >"$WORK/oldgit/git"
printf '#!/bin/sh\ncase " $* " in *" worktree list "*) echo "fatal: no" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$REAL_GIT" >"$WORK/listfail/git"
chmod +x "$WORK/oldgit/git" "$WORK/listfail/git"
wt_repo
printf 'old\n' >>"$W/tracked"
out=$(PATH="$WORK/oldgit:$PATH" git-salvage _pre worktree remove -f "w$N" 2>&1)
check "worktree remove: git without list -z: only the saved line" \
	test "$out" = 'git-salvage: saved snapshot 1 (to undo the removal: add the worktree again, then run git salvage restore 1 in it)'
check "worktree remove: git without list -z: that worktree saved" \
	test "$(git show "$(newest_ref):worktree/tracked" | tail -n 1)" = old
out=$(PATH="$WORK/listfail:$PATH" git-salvage _pre worktree remove -f "w$N" 2>&1)
rc=$?
check "worktree remove: worktree list fails: exit 1" test "$rc" = 1
check "worktree remove: worktree list fails: says why" contains "(git worktree list failed)" "$out"
check "worktree remove: worktree list fails: git's error not shown" sh -c 'case $1 in *"fatal: no"*) exit 1 ;; esac' _ "$out"

# ------------------------------------------------------ restore's own guarantees

new_repo
printf 'v1\n' >>tracked
git salvage _pre reset --hard && git reset -q --hard
printf 'keepme\n' >newfile
printf 'staged\n' >>other && git add other
idx_before=$(cksum <.git/index)
git salvage restore 2 >/dev/null 2>&1 || true
git salvage restore 1 >/dev/null 2>&1
check "restore never deletes a file" test "$(cat newfile)" = keepme
check "restore does not change the index" test "$(cksum <.git/index)" = "$idx_before"
check "restore saved the current state first" test "$(nrefs)" = 2
check "the pre-restore snapshot holds newfile" \
	test "$(git show "$(git for-each-ref --sort=-refname --format='%(refname)' refs/salvage/ | head -n 1):worktree/newfile")" = keepme

# --index
new_repo
printf 'idx\n' >>other && git add other
save other oidx
git salvage _pre reset --hard && git reset -q --hard
git salvage restore 1 --index >/dev/null 2>&1
check "restore --index: staged content back in index" \
	test "$(git show :other)" = "$(cat "$WORK/saved.oidx")"

# ---------------------------------------------------------- merge --abort

new_repo
git switch -qc side
printf 'side\n' >tracked && git commit -qam side
git switch -q main
printf 'main\n' >tracked && git commit -qam main
git merge side >/dev/null 2>&1
printf 'my resolution\n' >tracked
save tracked res
check "merge --abort: _pre" git salvage _pre merge --abort
ref=$(git for-each-ref --format='%(refname)' refs/salvage/ | head -n 1)
check "merge --abort: index marked unmerged" \
	test "$(git log -1 --format='%(trailers:key=Salvage-Index,valueonly)' "$ref")" = unmerged-not-captured
git merge --abort
check "merge --abort: restore --index refused" sh -c '! git salvage restore 1 --index >/dev/null 2>&1'
check "merge --abort: refused restore wrote nothing" test "$(cat tracked)" = main
git salvage restore 1 >/dev/null 2>&1
check "merge --abort: resolution back" same tracked "$WORK/saved.res"

# ---------------------------------------------------------- unborn HEAD

N=$((N + 1))
git init -q "$WORK/unborn" && cd "$WORK/unborn" || exit 1
printf 'first\n' >f && git add f
check "unborn: snapshot" git salvage _pre rm -f --cached f
check "unborn: one ref" test "$(nrefs)" = 1
git rm -q --cached f && rm f
git salvage restore 1 >/dev/null 2>&1
check "unborn: restored" test "$(cat f 2>/dev/null)" = first

# ---------------------------------------------------------- branch and stash

new_repo
git branch doomed
printf 'x\n' >x && git add x && git commit -qm x -q && git branch doomed2 && git reset -q --hard HEAD~1
tip=$(git rev-parse doomed2)
check "branch -D: _pre" git salvage _pre branch -D doomed doomed2
check "branch -D: two records" test "$(nrefs)" = 2
git branch -qD doomed doomed2
git salvage restore 1 >/dev/null 2>&1
git salvage restore 2 >/dev/null 2>&1
check "branch -D: both back" sh -c "git rev-parse -q --verify doomed >/dev/null && test \"\$(git rev-parse doomed2)\" = $tip"
out=$(git salvage restore 1 2>&1)
rc=$?
check "branch restore refuses an existing branch" test "$rc" != 0
check "branch restore: says it exists" contains "already exists; not overwriting it" "$out"

new_repo
git branch a && git branch b
check "branch -m (no -f) onto existing: nothing recorded" pre_count 0 branch -m a b
check "branch -M onto existing: recorded" pre_count 1 branch -M a b

# -t takes no argument: it must not swallow the -M after it.
new_repo
git branch a && git branch b
check "branch -t -M onto existing: recorded" pre_count 1 branch -t -M a b

new_repo
printf 's1\n' >>tracked && git stash -q
printf 's2\n' >>tracked && git stash -q
s0=$(git rev-parse 'stash@{0}')
s1=$(git rev-parse 'stash@{1}')
check "stash drop: _pre" git salvage _pre stash drop
git stash drop -q
git salvage restore 1 >/dev/null 2>&1
check "stash drop: entry back" test "$(git rev-parse 'stash@{0}')" = "$s0"
check "stash clear: _pre" git salvage _pre stash clear
check "stash clear: one record per entry" test "$(nrefs)" = 3
git stash clear
git salvage restore 1 >/dev/null 2>&1
check "stash clear: an entry back" sh -c "git rev-parse 'stash@{0}' | grep -qx -e $s0 -e $s1"

# ---------------------------------------------------------- skip rules

new_repo
check "clean tree: reset --hard saves nothing" sh -c 'git salvage _pre reset --hard 2>&1 | wc -c | grep -qx " *0"'
check "clean tree: no ref" test "$(nrefs)" = 0
printf 'u\n' >untracked
check "untracked only + checkout <branch>: nothing" pre_count 0 checkout main
check "untracked only + clean: saved" pre_count 1 clean -f
rm untracked
printf 'd\n' >>tracked
git salvage _pre reset --hard 2>/dev/null
git salvage _pre reset --hard 2>/dev/null
check "same dirty state twice: one ref" test "$(nrefs)" = 2
for args in "status" "reset --soft HEAD" "switch main" "clean -n" "checkout -h" "reset --help" "log" "stash list" "branch -v"; do
	printf '%s\n' "$args" >>tracked
	before=$(nrefs)
	# shellcheck disable=SC2086
	git salvage _pre $args
	check "no snapshot for: $args" test "$(nrefs)" = "$before"
done

# ---------------------------------------------------------- argument parsing

new_repo
printf 'u\n' >-n
check "clean -f -- -n: -n after -- is a path" pre_count 1 clean -f -- -n
rm -- -n
printf 'u\n' >u1
check "clean -f -en: -e takes n as its pattern" pre_count 2 clean -f -en

new_repo
printf 's1\n' >>tracked && git stash -q
printf 's2\n' >>tracked && git stash -q
s1=$(git rev-parse 'stash@{1}')
check "stash drop 1: _pre" git salvage _pre stash drop 1
check "stash drop 1: recorded stash@{1}" test "$(git rev-parse "$(git for-each-ref --format='%(refname)' refs/salvage/)^1")" = "$s1"

new_repo
git update-ref refs/remotes/origin/gone HEAD
git branch gone
printf 'x\n' >x && git add x && git commit -qm x && git branch -f gone
check "branch -dr: _pre" git salvage _pre branch -dr origin/gone
check "branch -dr: recorded the remote ref" test "$(git log -1 --format='%(trailers:key=Salvage-Ref,valueonly)' "$(git for-each-ref --format='%(refname)' refs/salvage/)")" = refs/remotes/origin/gone
check "branch -dr: at the remote tip" test "$(git rev-parse "$(git for-each-ref --format='%(refname)' refs/salvage/)^1")" = "$(git rev-parse HEAD~1)"

# ---------------------------------------------------------- repo with no index yet

N=$((N + 1))
git init -q "$WORK/noindex" && cd "$WORK/noindex" || exit 1
printf 'u\n' >u
check "no index yet: file really absent" test ! -e .git/index
check "no index yet: clean -f snapshots" pre_count 1 clean -f
git clean -qf
git salvage restore 1 >/dev/null 2>&1
check "no index yet: restored" test "$(cat u 2>/dev/null)" = u

# ---------------------------------------------------------- aliases

new_repo
git config alias.nuke 'reset --hard'
git config alias.sh-nuke '!git reset --hard'
printf 'al\n' >>tracked
check "alias to reset --hard: saved" pre_count 1 nuke
git config alias.st status
printf 'al2\n' >>tracked
check "alias to status: nothing" pre_count 1 st

# ---------------------------------------------------------- fail closed

new_repo
printf 'precious\n' >>tracked
save tracked fc
chmod -R a-w .git/objects
out=$(git salvage _pre reset --hard 2>&1)
rc=$?
chmod -R u+w .git/objects
check "fail closed: exit 1" test "$rc" = 1
check "fail closed: message names the command" contains "'git reset --hard' was not run" "$out"
check "fail closed: mentions GIT_SALVAGE_SKIP" contains GIT_SALVAGE_SKIP=1 "$out"
check "fail closed: worktree untouched" same tracked "$WORK/saved.fc"
check "GIT_SALVAGE_SKIP=1: exit 0" env GIT_SALVAGE_SKIP=1 git salvage _pre reset --hard
check "GIT_SALVAGE_SKIP=1: nothing saved" test "$(nrefs)" = 0
no_tmp_left() { local f; for f in .git/salvage-tmp.*; do [ -e "$f" ] && return 1; done; return 0; }
check "no temp files left in .git" no_tmp_left

# ---------------------------------------------------------- identity, retention, output

new_repo
git config --global --unset user.name
git config --global --unset user.email
git config --global user.useConfigOnly true
printf 'noid\n' >>tracked
check "no user identity: snapshot still works" git salvage _pre reset --hard
git config --global --unset user.useConfigOnly
git config --global user.name tester
git config --global user.email tester@example.com

new_repo
git config salvage.keep 3
for i in 1 2 3 4 5; do
	printf '%s\n' "$i" >>tracked
	git salvage _pre reset --hard 2>/dev/null
done
check "retention: keep=3 leaves 3" test "$(nrefs)" = 3
check "retention: newest kept" test "$(git show "$(git for-each-ref --sort=-refname --format='%(refname)' refs/salvage/ | head -n 1):worktree/tracked" | tail -n 1)" = 5
printf 'r\n' >>tracked
check "restore of the oldest kept snapshot at keep" git salvage restore 3
check "restore of the oldest kept: content back" test "$(tail -n 1 tracked)" = 3

# Same second, the older ref from a process with a higher pid (pid wrap):
# the new ref must still sort newest. Retried if a second boundary falls
# between the two snapshots.
new_repo
same_sec=
for try in $(seq 1 20); do
	git for-each-ref --format='delete %(refname)' refs/salvage/ | git update-ref --stdin
	printf 'a%s\n' "$try" >>tracked
	git salvage _pre reset --hard 2>/dev/null
	a=$(git for-each-ref --format='%(refname)' refs/salvage/)
	ea=${a#refs/salvage/}
	ea=${ea%%-*}
	git update-ref "refs/salvage/$ea-000000-9999999999" "$a" && git update-ref -d "$a"
	printf 'b\n' >>tracked
	git salvage _pre reset --hard 2>/dev/null
	b=$(git for-each-ref --sort=-refname --count=1 --format='%(refname)' refs/salvage/)
	eb=${b#refs/salvage/}
	if [ "${eb%%-*}" = "$ea" ]; then
		same_sec=1
		break
	fi
done
check "ref order: both snapshots in one second" test "$same_sec" = 1
check "ref order: newer snapshot sorts first despite lower pid" test "$(git show "$b:worktree/tracked" | tail -n 1)" = b
check "ref order: seq is one past the older ref's" test "$(printf '%s\n' "$b" | cut -d- -f2)" = 000001

new_repo
printf 'q\n' >>tracked
check "saved line on stderr" sh -c 'git salvage _pre reset --hard 2>&1 >/dev/null | grep -qx "git-salvage: saved snapshot 1 (undo with: git salvage restore 1)"'
printf 'q2\n' >>tracked
out=$(GIT_SALVAGE_QUIET=1 git salvage _pre reset --hard 2>&1)
check "GIT_SALVAGE_QUIET=1: silent" test -z "$out"
printf 'q3\n' >>tracked
out=$(git -c salvage.quiet=true salvage _pre reset --hard 2>&1)
check "salvage.quiet=true: silent" test -z "$out"

# ---------------------------------------------------------- global options

new_repo
printf 'c\n' >>tracked
cd "$WORK" || exit 1
check "git -C <repo> salvage _pre" git -C "$R" salvage _pre reset --hard 2>/dev/null
check "git -C: ref landed in that repo" test "$(git -C "$R" for-each-ref refs/salvage/ | wc -l | tr -d ' ')" = 1
printf 'd\n' >>"$R/tracked"
check "--git-dir/--work-tree" git --git-dir="$R/.git" --work-tree="$R" salvage _pre reset --hard 2>/dev/null
check "--git-dir: ref landed" test "$(git -C "$R" for-each-ref refs/salvage/ | wc -l | tr -d ' ')" = 2
check "outside a repo: _pre exits 0" git salvage _pre reset --hard

# ---------------------------------------------------------- list / show / drop / prune

new_repo
printf 'l\n' >>tracked
git salvage _pre reset --hard 2>/dev/null
check "list shows one line" sh -c 'git salvage list | grep -c "git reset --hard" | grep -qx 1'
check "show --stat names the file" sh -c 'git salvage show 1 | grep -q tracked'
check "show -p has the line" sh -c 'git salvage show 1 -p | grep -qx "+l"'
check "bad number refused" sh -c '! git salvage show 9 >/dev/null 2>&1'
git salvage drop 1 >/dev/null
check "drop" test "$(nrefs)" = 0
check "prune needs an option" sh -c '! git salvage prune >/dev/null 2>&1'

# ---------------------------------------------------------- unknown subcommand

# unknown <typo> <expected stderr>: exit 1, nothing on stdout, exact stderr.
unknown() {
	local out err rc
	out=$(git salvage "$1" 2>"$WORK/unknown.err")
	rc=$?
	err=$(cat "$WORK/unknown.err")
	test "$rc" = 1 && test -z "$out" && test "$err" = "$2"
}
tab=$(printf '\t')
check "unknown: one suggestion" unknown resotre "git-salvage: unknown subcommand: resotre

The most similar subcommand is
${tab}restore"
check "unknown: two at the same distance" unknown ninstall "git-salvage: unknown subcommand: ninstall

The most similar subcommands are
${tab}install
${tab}uninstall"
# Only a swap of two adjacent letters makes this distance 1.
check "unknown: swapped letters" unknown lsit "git-salvage: unknown subcommand: lsit

The most similar subcommand is
${tab}list"
# restore is reached only as a prefix; list is distance 2, over the limit
# for 4 characters.
check "unknown: prefix, no far match" unknown rest "git-salvage: unknown subcommand: rest

The most similar subcommand is
${tab}restore"
check "unknown: near and prefix listed once" unknown prun "git-salvage: unknown subcommand: prun

The most similar subcommand is
${tab}prune"
check "unknown: 2-letter prefix is no match" unknown sn "git-salvage: unknown subcommand: sn
$(git salvage help)"
# Without the length filter, 2000 characters take 11 s (measured, Apple M4).
long_typo() {
	bounded 3 git salvage "$(printf '%2000s' '' | tr ' ' a)" >/dev/null 2>&1
	test $? = 1
}
check "unknown: long argument answers fast" long_typo
check "unknown: no suggestion prints usage" unknown xyzzy "git-salvage: unknown subcommand: xyzzy
$(git salvage help)"

# ---------------------------------------------------------- view

VIEW_TPL="$ROOT/bin/git-salvage-view.html"
# view_decode <page> <out>: the embedded data, NUL shown as '|'. The page is
# the template with its @@SALVAGE_DATA@@ line replaced by the base64 lines.
view_decode() {
	local n t o
	n=$(grep -n -x '@@SALVAGE_DATA@@' "$VIEW_TPL" | cut -d: -f1)
	t=$(wc -l <"$VIEW_TPL")
	o=$(wc -l <"$1")
	sed -n "${n},$((o - t + n))p" "$1" | base64 --decode | tr '\0' '|' >"$2"
}
# view_frame <page>: everything but the data is the template, unchanged.
view_frame() {
	local n t
	n=$(grep -n -x '@@SALVAGE_DATA@@' "$VIEW_TPL" | cut -d: -f1)
	t=$(wc -l <"$VIEW_TPL")
	[ "$(head -n "$((n - 1))" "$1")" = "$(head -n "$((n - 1))" "$VIEW_TPL")" ] &&
		[ "$(tail -n "$((t - n))" "$1")" = "$(tail -n "$((t - n))" "$VIEW_TPL")" ]
}
# view_state: refs, reflogs, index bytes and work tree of the current repo.
view_state() {
	git for-each-ref --format='%(refname) %(objectname)'
	git log -g --format='%gD %H %gs' HEAD --branches 2>/dev/null
	cksum <.git/index
	find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done
}
vlines() { grep -c "^$1|" "$2"; }
# vids <tag> <data>: the second field of every record with that tag, sorted.
vids() { grep "^$1|" "$2" | cut -d'|' -f2 | LC_ALL=C sort; }

new_repo
git init -q --bare "$WORK/view-remote.git"
git remote add origin "$WORK/view-remote.git"
git push -q -u origin main 2>/dev/null
git switch -q -c feature && printf 'f\n' >f && git add f && git commit -qm feat
git tag -a v1 -m v1 && git tag light
git switch -q main
printf 'l\n' >l && git add l && git commit -qm left
LEFT=$(git rev-parse HEAD)
git reset -q --hard HEAD~1
printf 'x\n' >>tracked && git salvage snapshot -m s1 >/dev/null
printf 'y\n' >>tracked && git salvage snapshot -m s2 >/dev/null
printf 'u\n' >'un tracked'
# A newer mtime makes the index stat-dirty: a status that may write the
# index would rewrite it now.
touch -t 203001010000 other
before=$(view_state)
out=$(git salvage view -o "$WORK/v.html" --no-open)
check "view: exits 0" test $? = 0
check "view: says where it wrote" test "$out" = "wrote $WORK/v.html"
check "view: repo unchanged (refs, reflogs, index bytes, work tree)" test "$(view_state)" = "$before"
check "view: page is the template around the data" view_frame "$WORK/v.html"
view_decode "$WORK/v.html" "$WORK/v.data"
D="$WORK/v.data"
check "view data: version" test "$(head -n 1 "$D")" = "V|1"
check "view data: meta" grep -qx "M|${R##*/}|[0-9]*|$(git --version)" "$D"
check "view data: head" grep -qx "H|refs/heads/main|$(git rev-parse HEAD)" "$D"
check "view data: status branch" grep -qx "S|# branch.head main" "$D"
check "view data: status modified" grep -q "^S|1 \.M .* tracked$" "$D"
check "view data: status untracked with space" grep -qx "S|? un tracked" "$D"
exp_refs() {
	printf 'R|refs/heads/feature|%s|||\n' "$(git rev-parse feature)"
	printf 'R|refs/heads/main|%s||refs/remotes/origin/main|\n' "$(git rev-parse main)"
	printf 'R|refs/remotes/origin/main|%s|||\n' "$(git rev-parse origin/main)"
	printf 'R|refs/tags/light|%s|||\n' "$(git rev-parse feature)"
	printf 'R|refs/tags/v1|%s|%s||\n' "$(git rev-parse v1)" "$(git rev-parse feature)"
}
check "view data: refs (annotated tag peeled, upstream)" test "$(grep '^R|' "$D")" = "$(exp_refs)"
check "view data: commits = reachable + left behind by reset" \
	test "$(vids C "$D")" = "$( (git rev-list HEAD --branches --remotes --tags && echo "$LEFT") | LC_ALL=C sort)"
check "view data: commit fields" grep -qx "C|$(git rev-parse feature)|$(git rev-parse main)|$(git log -1 --format=%ct feature)|tester|feat" "$D"
check "view data: reflog has the reset" grep -q "^L|HEAD@{[0-9]*}|$(git rev-parse HEAD)|reset: moving to HEAD~1$" "$D"
check "view data: reflog has the left-behind commit" grep -q "^L|refs/heads/main@{[0-9]*}|$LEFT|commit: left$" "$D"
check "view data: reflog of every ref, same count as git" \
	test "$(vlines L "$D")" = "$(git log -g --format=tformat:x HEAD refs/heads/feature refs/heads/main refs/remotes/origin/main | wc -l | tr -d ' ')"
check "view data: snapshots newest first" test "$(grep '^P|' "$D" | cut -d'|' -f5)" = "$(printf 's2\ns1')"
# The page numbers P records by order: that must be `git salvage list`'s order.
check "view data: snapshot order = git salvage list" \
	test "$(grep '^P|' "$D" | cut -d'|' -f5 | tr '\n' ' ')" = "$(git salvage list | sed 's/^ *[0-9]*  [^ ]* [^ ]*  [^ ]*  *//; s/  ([0-9]* paths)$//' | tr '\n' ' ')"
check "view data: snapshot fields" grep -qx "P|[^|]*|[0-9a-f]*|[0-9]*|s2|$(git rev-parse HEAD)|Salvage-Kind: worktree$(printf '\037')Salvage-Head: refs/heads/main" "$D"
check "view: default output in .git" sh -c 'git salvage view --no-open >/dev/null && test -s .git/salvage-view.html'

# Subjects that could break out of a <script> or an attribute.
new_repo
SUBJ="a </script><b>\"q\" 'x' & $(printf 'caf\303\251 \344\270\255')"
git commit -q --allow-empty -m "$SUBJ"
git salvage view -o "$WORK/v2.html" --no-open >/dev/null
view_decode "$WORK/v2.html" "$WORK/v2.data"
check "view special subject: survives byte-exact" grep -qxF "C|$(git rev-parse HEAD)|$(git rev-parse HEAD~1)|$(git log -1 --format=%ct)|tester|$SUBJ" "$WORK/v2.data"
check "view special subject: no raw </script> added to the page" \
	test "$(grep -c '</script>' "$WORK/v2.html")" = "$(grep -c '</script>' "$VIEW_TPL")"

# -n limits the commits.
for i in 1 2 3; do git commit -q --allow-empty -m "c$i"; done
git salvage view -o "$WORK/v3.html" -n 2 --no-open >/dev/null
view_decode "$WORK/v3.html" "$WORK/v3.data"
check "view -n 2: two newest commits" test "$(grep '^C|' "$WORK/v3.data" | cut -d'|' -f6)" = "$(printf 'c3\nc2')"
git salvage view -o "$WORK/v3.html" -n 02 --no-open >/dev/null
view_decode "$WORK/v3.html" "$WORK/v3.data"
check "view -n 02: two commits" test "$(grep -c '^C|' "$WORK/v3.data")" = 2
# base64 that does not end its output with a newline (as some may not):
# the page must still have the data and the template's next line apart.
mkdir -p "$WORK/b64" && printf '#!/bin/sh\nprintf %%s "$("%s" "$@")"\n' "$(command -v base64)" >"$WORK/b64/base64" &&
	chmod +x "$WORK/b64/base64"
PATH="$WORK/b64:$PATH" git salvage view -o "$WORK/v8.html" --no-open >/dev/null
check "view: base64 without a final newline" view_frame "$WORK/v8.html"

# Detached HEAD.
git checkout -q --detach HEAD~1
git salvage view -o "$WORK/v4.html" --no-open >/dev/null
view_decode "$WORK/v4.html" "$WORK/v4.data"
check "view detached: head record" grep -qx "H||$(git rev-parse HEAD)" "$WORK/v4.data"
check "view detached: status says detached" grep -qx "S|# branch.head (detached)" "$WORK/v4.data"

# Bad arguments: refused, nothing written.
mkdir -p "$WORK/adir"
for a in "-n 0" "-n 00" "-n 1234567890" "-n x" "-n" "-o" "-o $WORK/adir" "--bogus" "extra"; do
	# shellcheck disable=SC2086 # split on purpose
	check "view refuses '$a'" sh -c '! git salvage view --no-open $1 >/dev/null 2>&1 && test ! -e .git/salvage-view.html' _ "$a"
done

# Unborn HEAD: no commits, no reflog.
N=$((N + 1))
git init -q "$WORK/r$N" && cd "$WORK/r$N" || exit 1
printf 'u\n' >u
check "view unborn: exits 0" sh -c 'git salvage view -o "$1" --no-open >/dev/null' _ "$WORK/v5.html"
view_decode "$WORK/v5.html" "$WORK/v5.data"
check "view unborn: head record" grep -qx "H|refs/heads/main|" "$WORK/v5.data"
check "view unborn: no commits, no reflog" test "$(vlines C "$WORK/v5.data") $(vlines L "$WORK/v5.data")" = "0 0"
check "view unborn: status" grep -qx "S|# branch.oid (initial)" "$WORK/v5.data"
check "view -o <dir>: nothing written in it" test -z "$(ls "$WORK/adir")"
# A newline in the repo's directory name must not split the M record.
NLDIR="$WORK/nl
dir"
git init -q "$NLDIR"
check "view: newline in the repo name" sh -c 'cd "$1" && git salvage view -o "$2" --no-open >/dev/null' _ "$NLDIR" "$WORK/v7.html"
view_decode "$WORK/v7.html" "$WORK/v7.data"
check "view: newline in the repo name keeps one M record" grep -qx "M|nl dir|[0-9]*|$(git --version)" "$WORK/v7.data"
check "view outside a repo fails" sh -c 'cd "$1" && ! git salvage view --no-open >/dev/null 2>&1' _ "$WORK"
cd "$R" || exit 1

# ---------------------------------------------------------- install / uninstall

SHIMDIR="$WORK/shimbin"
SPATH="$SHIMDIR:$ORIG_PATH"
check "install: exits 0" sh -c 'git salvage install --dir "$1" >/dev/null' _ "$SHIMDIR"
check "install: shim in place" test -x "$SHIMDIR/git"
check "install: git-salvage beside it" test -x "$SHIMDIR/git-salvage"
check "install: view template beside it" test -f "$SHIMDIR/git-salvage-view.html"
check "install: twice is fine" sh -c 'git salvage install --dir "$1" >/dev/null' _ "$SHIMDIR"
check "install from an installed copy" sh -c '"$1/git-salvage" install --dir "$2" >/dev/null && test -x "$2/git"' _ "$SHIMDIR" "$WORK/shim2"
mkdir -p "$WORK/foreign" && printf 'not ours\n' >"$WORK/foreign/git"
check "install refuses a foreign git" sh -c '! git salvage install --dir "$1" >/dev/null 2>&1' _ "$WORK/foreign"
check "uninstall refuses a foreign git" sh -c '! git salvage uninstall --dir "$1" >/dev/null 2>&1' _ "$WORK/foreign"
check "foreign git untouched" test "$(cat "$WORK/foreign/git")" = "not ours"
check "view from an installed copy" sh -c '"$1/git-salvage" view -o "$2" --no-open >/dev/null && test -s "$2"' _ "$WORK/shim2" "$WORK/v6.html"
check "uninstall: exits 0" sh -c 'git salvage uninstall --dir "$1" >/dev/null' _ "$WORK/shim2"
check "uninstall: files gone" test ! -e "$WORK/shim2/git" -a ! -e "$WORK/shim2/git-salvage" -a ! -e "$WORK/shim2/git-salvage-view.html"
mkdir -p "$WORK/shim3" && printf 'x\n' >"$WORK/shim3/git-salvage-view.html"
check "uninstall: a lone view template is removed" \
	sh -c 'git salvage uninstall --dir "$1" >/dev/null && test ! -e "$1/git-salvage-view.html"' _ "$WORK/shim3"
mkdir -p "$WORK/shim3" && printf 'x\n' >"$WORK/shim3/git-salvage-view.html"
check "uninstall: names only what it removed" \
	test "$(git salvage uninstall --dir "$WORK/shim3" | head -n 1)" = "removed $WORK/shim3/git-salvage-view.html"

# The PATH hint after install: the login shell's syntax (dev/measure-shells.sh).
# hint <shell> <dir> <path>: install into <dir> with that SHELL and PATH.
hint() { env SHELL="$1" PATH="$3" git salvage install --dir "$2" 2>&1 | sed 1d; }
out=$(hint /bin/zsh "$WORK/h1" "$PATH")
check "install hint: zsh gets export" test "$out" = "add this line to your shell profile (then open a new shell):
  export PATH=\"$WORK/h1:\$PATH\""
out=$(hint /bin/tcsh "$WORK/h2" "$PATH")
check "install hint: tcsh gets setenv" contains "  setenv PATH \"$WORK/h2:\$PATH\"" "$out"
out=$(hint /bin/csh "$WORK/h3" "$PATH")
check "install hint: csh gets setenv" contains "  setenv PATH \"$WORK/h3:\$PATH\"" "$out"
out=$(hint /opt/homebrew/bin/fish "$WORK/h4" "$PATH")
check "install hint: fish gets set -gx" contains "  set -gx PATH \"$WORK/h4\" \$PATH" "$out"
out=$(hint '' "$WORK/h5" "$PATH")
check "install hint: no SHELL gets export" contains "  export PATH=\"$WORK/h5:\$PATH\"" "$out"
out=$(hint /bin/zsh "$WORK/h6" "$WORK/h6:$PATH")
check "install hint: already first, zsh: rehash" test "$out" = "$WORK/h6 is already first on PATH; in shells that are already open, run:
  rehash"
out=$(hint /bin/bash "$WORK/h7" "$WORK/h7:$PATH")
check "install hint: already first, bash: hash -r" contains "
  hash -r" "$out"
out=$(hint /bin/bash "$WORK/h8" "$PATH:$WORK/h8")
check "install hint: on PATH after the real git" \
	contains "$WORK/h8 is on PATH but after $REAL_GIT; move it in front" "$out"
# PATH names the directory through a symlink: still recognised as on PATH.
mkdir -p "$WORK/h9" && ln -s h9 "$WORK/h9link"
out=$(hint /bin/bash "$WORK/h9" "$PATH:$WORK/h9link")
check "install hint: PATH entry is a symlink to the dir" \
	contains "$WORK/h9 is on PATH but after $REAL_GIT; move it in front" "$out"

# ---------------------------------------------------------- shim: transparency

# sgit: git as a user with the shim installed first on PATH reaches it.
sgit() { (PATH=$SPATH && git "$@"); }
FIXED_DATES="GIT_AUTHOR_DATE=2001-02-03T04:05:06Z GIT_COMMITTER_DATE=2001-02-03T04:05:06Z"
# twin <name> <setup-fn> <git args...>: the same command on the same repo
# state (same path, restored from a copy in between), once through the shim
# and once through the real git: stdout, stderr (minus git-salvage: lines)
# and exit code must match. Stdin comes from $TWIN_IN (default /dev/null).
twin() {
	local name=$1 setup=$2 rc1 rc2
	shift 2
	new_repo
	"$setup"
	cp -Rp "$R" "$R.orig"
	# shellcheck disable=SC2086 # FIXED_DATES is a list of assignments
	(cd "$R" && env $FIXED_DATES PATH="$SPATH" git "$@") \
		<"${TWIN_IN:-/dev/null}" >"$WORK/t.out1" 2>"$WORK/t.err1"
	rc1=$?
	cd "$WORK" && rm -rf "$R" && mv "$R.orig" "$R" && cd "$R" || exit 1
	# shellcheck disable=SC2086
	(env $FIXED_DATES "$REAL_GIT" "$@") <"${TWIN_IN:-/dev/null}" >"$WORK/t.out2" 2>"$WORK/t.err2"
	rc2=$?
	grep -v '^git-salvage: ' "$WORK/t.err1" >"$WORK/t.err1f"
	check "twin $name: exit code ($rc1 vs $rc2)" test "$rc1" = "$rc2"
	check "twin $name: stdout" same "$WORK/t.out1" "$WORK/t.out2"
	check "twin $name: stderr" same "$WORK/t.err1f" "$WORK/t.err2"
}
setup_clean() { :; }
setup_dirty() { printf 'x\n' >>tracked; printf 'u\n' >untracked; }
setup_staged() { printf 'x\n' >>tracked; git add tracked; }
setup_stash() { printf 's\n' >>tracked; git stash -q; }
setup_branch() { git branch doomed; }

twin "no arguments" setup_clean
twin "--version" setup_clean --version
twin "--exec-path" setup_clean --exec-path
twin "status" setup_dirty status
twin "status --porcelain" setup_dirty status --porcelain
twin "rev-parse --show-toplevel" setup_clean rev-parse --show-toplevel
twin "-C dir status" setup_dirty -C dir status --short
twin "unknown option" setup_clean --bogus status
twin "diff --exit-code" setup_dirty diff --exit-code
twin "checkout of a missing branch" setup_dirty checkout nope
twin "reset --hard" setup_dirty reset --hard
twin "clean -n" setup_dirty clean -n
twin "clean -fd" setup_dirty clean -fd
twin "stash drop" setup_stash stash drop
twin "branch -D" setup_branch branch -D doomed
twin "alias from -c" setup_dirty -c alias.nuke='reset --hard' nuke
twin "commit message spacing" setup_dirty commit -am "$(printf 'two  spaces\n\n  indented')"
printf 'tracked\n' >"$WORK/pathspec"
TWIN_IN="$WORK/pathspec" twin "reset --pathspec-from-file=-" setup_staged reset --pathspec-from-file=-
# The worktree sits inside $R, so the copy between the two runs keeps it.
setup_worktree() { git worktree add -q -b wb wt && printf 'x\n' >>wt/tracked && printf 'l\n' >wt/x.log; }
twin "worktree remove -f" setup_worktree worktree remove -f wt
twin "worktree remove, dirty: refused" setup_worktree worktree remove wt
twin "worktree list" setup_worktree worktree list --porcelain
printf 'blob data\n' >"$WORK/blob"
TWIN_IN="$WORK/blob" twin "hash-object --stdin" setup_clean hash-object --stdin

# ---------------------------------------------------------- shim: behaviour

new_repo
printf 'via shim\n' >>tracked
save tracked sh1
out=$(sgit reset --hard 2>"$WORK/err")
check "shim: reset --hard saved" test "$(nrefs)" = 1
check "shim: the one stderr line" test "$(cat "$WORK/err")" = \
	'git-salvage: saved snapshot 1 (undo with: git salvage restore 1)'
check "shim: git's stdout untouched" test "$out" = "HEAD is now at $(git rev-parse --short HEAD) base"
check "shim: command ran" test "$(cat tracked)" = one
sgit salvage restore 1 >/dev/null 2>&1
check "shim: restore brings it back" same tracked "$WORK/saved.sh1"
check "shim: restore onto a clean tree saves nothing first" test "$(nrefs)" = 1

printf 'outside\n' >>tracked
(cd "$WORK" && sgit -C "$R" reset -q --hard 2>/dev/null)
check "shim: git -C <repo> from outside saved in that repo" test "$(nrefs)" = 2

printf 'alias\n' >>tracked
sgit -c alias.nuke='reset --hard' nuke -q 2>/dev/null
check "shim: -c alias.x=... is seen by _pre" test "$(nrefs)" = 3

printf 'skip\n' >>tracked
GIT_SALVAGE_SKIP=1 sgit reset -q --hard 2>/dev/null
check "shim: GIT_SALVAGE_SKIP=1 runs without a snapshot" sh -c 'test "$1" = 3 && test "$(cat tracked)" = one' _ "$(nrefs)"
printf 'active\n' >>tracked
GIT_SALVAGE_ACTIVE=1 sgit reset -q --hard 2>/dev/null
check "shim: GIT_SALVAGE_ACTIVE=1 passes straight through" sh -c 'test "$1" = 3 && test "$(cat tracked)" = one' _ "$(nrefs)"

printf 'precious\n' >>tracked
save tracked sh2
chmod -R a-w .git/objects
sgit reset --hard >/dev/null 2>&1
rc=$?
chmod -R u+w .git/objects
check "shim fail closed: exit 1" test "$rc" = 1
check "shim fail closed: command not run" same tracked "$WORK/saved.sh2"

# worktree: only remove reaches _pre (a git-salvage that always fails shows
# which commands do).
mkdir -p "$WORK/badsalvage" && printf '#!/bin/sh\nexit 1\n' >"$WORK/badsalvage/git-salvage" && chmod +x "$WORK/badsalvage/git-salvage"
git worktree add -q -b shimwt "$WORK/shimwt$N"
check "shim: worktree list does not run _pre" \
	sh -c 'PATH="$1" git worktree list >/dev/null 2>&1' _ "$WORK/badsalvage:$SPATH"
check "shim: worktree remove runs _pre" \
	sh -c '! PATH="$1" git worktree remove "$2" >/dev/null 2>&1 && test -d "$2"' _ "$WORK/badsalvage:$SPATH" "$WORK/shimwt$N"
printf 'via shim\n' >>"$WORK/shimwt$N/tracked"
before=$(nrefs)
sgit worktree remove -f "$WORK/shimwt$N" 2>/dev/null
check "shim: worktree remove -f saved and ran" sh -c 'test "$1" = "$(($2 + 1))" && test ! -e "$3"' _ "$(nrefs)" "$before" "$WORK/shimwt$N"

err=$(sgit --bogus status 2>&1 >/dev/null)
check "shim: unrecognized option line" contains "git-salvage: unrecognized option '--bogus', no snapshot taken" "$err"

# Finding the real git.
real_version=$("$REAL_GIT" --version)
mkdir -p "$WORK/shimlink" && ln -s "$SHIMDIR/git" "$WORK/shimlink/git"
check "shim: symlinked shim earlier on PATH is skipped" \
	test "$(PATH="$WORK/shimlink:$SPATH" git --version 2>&1)" = "$real_version"
mkdir -p "$WORK/fakegit" && printf '#!/bin/sh\necho "fake git $*"\n' >"$WORK/fakegit/git" && chmod +x "$WORK/fakegit/git"
check "shim: GIT_SALVAGE_REAL_GIT is used" \
	test "$(GIT_SALVAGE_REAL_GIT="$WORK/fakegit/git" env PATH="$SPATH" "$SHIMDIR/git" --version 2>&1)" = "fake git --version"
# Accepting it would exec the shim forever: bounded, so that shows as a FAIL.
check "shim: GIT_SALVAGE_REAL_GIT pointing at the shim is ignored" \
	test "$(GIT_SALVAGE_REAL_GIT="$SHIMDIR/git" bounded 10 env PATH="$SPATH" "$SHIMDIR/git" --version 2>&1)" = "$real_version"
# An empty PATH entry is `.`; bash word splitting drops a trailing one, so a
# trailing `:` is not searched (DESIGN.md "Coverage limits").
check "shim: empty PATH entry searched as ." \
	test "$(cd "$WORK/fakegit" && PATH="$SHIMDIR::$SPATH" "$SHIMDIR/git" --version 2>&1)" = "fake git --version"
mkdir -p "$WORK/nogit" && ln -s "$(command -v bash)" "$WORK/nogit/bash"
err=$(PATH="$SHIMDIR:$WORK/nogit" "$SHIMDIR/git" status 2>&1)
rc=$?
check "shim: no real git: exit 1" test "$rc" = 1
check "shim: no real git: message" test "$err" = "git-salvage: cannot find the real git on PATH"
# The fake git in . is the only other git; a searched trailing entry finds it.
check "shim: trailing : in PATH not searched" \
	test "$(cd "$WORK/fakegit" && PATH="$WORK/nogit:" "$SHIMDIR/git" --version 2>&1)" = "git-salvage: cannot find the real git on PATH"

# doctor
out=$(sgit salvage doctor 2>&1)
rc=$?
check "doctor with the shim: exit 0" test "$rc" = 0
check "doctor with the shim: says yes" contains "it is the git-salvage shim: yes" "$out"
check "doctor with the shim: stale-shell note" contains "run hash -r / rehash in it)" "$out"
out=$(git salvage doctor 2>&1)
rc=$?
check "doctor without the shim: exit 1" test "$rc" = 1
check "doctor without the shim: says NO" contains "it is the git-salvage shim: NO" "$out"

# ---------------------------------------------------------- view page logic (JS)

# The template's LOGIC block + tests/view-test.js, run under JXA where there
# is one (macOS: osascript, often no node), else node. JXA first, so the macOS
# CI job tests the JXA path although its runner has node too. Each "ok" /
# "not ok" line is one check.
TPL="$ROOT/bin/git-salvage-view.html"
check "view js: one BEGIN/END LOGIC pair" \
	test "$(grep -c -x '// BEGIN LOGIC' "$TPL") $(grep -c -x '// END LOGIC' "$TPL")" = "1 1"
# Strict, as in the page: the page says "use strict" just above BEGIN LOGIC.
{ echo '"use strict";' && sed -n '/^\/\/ BEGIN LOGIC$/,/^\/\/ END LOGIC$/p' "$TPL" &&
	cat "$ROOT/tests/view-test.js"; } >"$WORK/view-test.js"
if command -v osascript >/dev/null 2>&1; then
	echo "view js: osascript -l JavaScript"
	jsout=$(bounded 60 osascript -l JavaScript "$WORK/view-test.js" 2>&1)
elif command -v node >/dev/null 2>&1; then
	echo "view js: node $(node --version 2>/dev/null)"
	jsout=$(bounded 60 node "$WORK/view-test.js" 2>&1)
else
	jsout="# neither node nor osascript found"
fi
jsn=0
while IFS= read -r line; do
	case $line in
	"ok "*)
		check "view js: ${line#ok }" true
		jsn=$((jsn + 1))
		;;
	"not ok "*)
		check "view js: ${line#not ok }" false
		jsn=$((jsn + 1))
		;;
	"done "*) ;;
	*) echo "  $line" ;;
	esac
done <<EOF
$jsout
EOF
check "view js: ran to the end (done $jsn)" test "$(printf '%s\n' "$jsout" | tail -n 1)" = "done $jsn"

# Not `FAIL `: dev/mutate.sh reads `^FAIL ` lines as the failed checks.
for name in ${FAILED[@]+"${FAILED[@]}"}; do echo "failed: $name"; done
echo "tests: $PASS/$TOTAL passed"
[ "$PASS" = "$TOTAL" ] && [ "$TOTAL" -gt 0 ]
