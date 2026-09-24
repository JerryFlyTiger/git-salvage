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
unset GIT_SALVAGE_SKIP GIT_SALVAGE_QUIET GIT_SALVAGE_ACTIVE GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

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
check() { # check <name> <command...>
	local name=$1
	shift
	TOTAL=$((TOTAL + 1))
	if "$@"; then
		PASS=$((PASS + 1))
	else
		FAILED+=("$name")
		echo "FAIL $name"
	fi
}

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
# bounded <secs> <cmd...>: run it under timeout(1) when there is one.
bounded() {
	local t=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$t" "$@"
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$t" "$@"
	else
		"$@"
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

# ---------------------------------------------------------- install / uninstall

SHIMDIR="$WORK/shimbin"
SPATH="$SHIMDIR:$ORIG_PATH"
check "install: exits 0" sh -c 'git salvage install --dir "$1" >/dev/null' _ "$SHIMDIR"
check "install: shim in place" test -x "$SHIMDIR/git"
check "install: git-salvage beside it" test -x "$SHIMDIR/git-salvage"
check "install: twice is fine" sh -c 'git salvage install --dir "$1" >/dev/null' _ "$SHIMDIR"
check "install from an installed copy" sh -c '"$1/git-salvage" install --dir "$2" >/dev/null && test -x "$2/git"' _ "$SHIMDIR" "$WORK/shim2"
mkdir -p "$WORK/foreign" && printf 'not ours\n' >"$WORK/foreign/git"
check "install refuses a foreign git" sh -c '! git salvage install --dir "$1" >/dev/null 2>&1' _ "$WORK/foreign"
check "uninstall refuses a foreign git" sh -c '! git salvage uninstall --dir "$1" >/dev/null 2>&1' _ "$WORK/foreign"
check "foreign git untouched" test "$(cat "$WORK/foreign/git")" = "not ours"
check "uninstall: exits 0" sh -c 'git salvage uninstall --dir "$1" >/dev/null' _ "$WORK/shim2"
check "uninstall: files gone" test ! -e "$WORK/shim2/git" -a ! -e "$WORK/shim2/git-salvage"

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
mkdir -p "$WORK/nogit" && ln -s "$(command -v bash)" "$WORK/nogit/bash"
err=$(PATH="$SHIMDIR:$WORK/nogit" "$SHIMDIR/git" status 2>&1)
rc=$?
check "shim: no real git: exit 1" test "$rc" = 1
check "shim: no real git: message" test "$err" = "git-salvage: cannot find the real git on PATH"

# doctor
out=$(sgit salvage doctor 2>&1)
rc=$?
check "doctor with the shim: exit 0" test "$rc" = 0
check "doctor with the shim: says yes" contains "it is the git-salvage shim: yes" "$out"
out=$(git salvage doctor 2>&1)
rc=$?
check "doctor without the shim: exit 1" test "$rc" = 1
check "doctor without the shim: says NO" contains "it is the git-salvage shim: NO" "$out"

echo "tests: $PASS/$TOTAL passed"
[ "$PASS" = "$TOTAL" ] && [ "$TOTAL" -gt 0 ]
