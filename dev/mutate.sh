#!/usr/bin/env bash
# Mutation check for tests/run.sh: each mutation breaks one thing in a copy of
# the tree (never the real one), runs the suite there, and reports whether the
# named check went red.
#   KILLED        an expected check failed
#   KILLED-OTHER  the suite failed, but not on an expected check (read why)
#   SURVIVED      the suite stayed green: a missing test
#   ABORTED       no FAIL line and no N/N summary: the suite died
#   NOT-APPLIED   the substitution matched nothing: the mutation is stale
# usage: dev/mutate.sh [name-substring]   (default: all)
# shellcheck disable=SC2016 # the $ in every perl expression is perl's, not the shell's
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCR=$(mktemp -d "${TMPDIR:-/tmp}/salvage-mut.XXXXXX")
trap 'chmod -R u+w "$SCR" 2>/dev/null; rm -rf "$SCR"' EXIT INT TERM
FILTER=${1:-}
JOBS=${JOBS:-4}
I=0

# mut <name> <file> <expected-fail-regex> <perl -0pe expression>
mut() {
	local name=$1 file=$2 expect=$3 expr=$4 d
	case $name in *"$FILTER"*) ;; *) return 0 ;; esac
	I=$((I + 1))
	d="$SCR/m$I"
	mkdir -p "$d"
	cp -R "$ROOT/bin" "$ROOT/tests" "$d/"
	[ -d "$ROOT/shim" ] && cp -R "$ROOT/shim" "$d/"
	perl -0pi -e "$expr" "$d/$file"
	if cmp -s "$ROOT/$file" "$d/$file"; then
		printf '%-12s %s\n' NOT-APPLIED "$name" >"$d/result"
		return 0
	fi
	(
		timeout 300 /bin/bash "$d/tests/run.sh" >"$d/log" 2>&1
		fails=$(grep '^FAIL ' "$d/log" | sed 's/^FAIL //')
		if [ -z "$fails" ]; then
			if grep -Eq '^tests: ([0-9]+)/\1 passed$' "$d/log"; then
				printf '%-12s %s\n' SURVIVED "$name" >"$d/result"
			else
				printf '%-12s %s  (no FAIL line; last: %s)\n' ABORTED "$name" "$(tail -n 1 "$d/log")" >"$d/result"
			fi
			exit 0
		fi
		if printf '%s\n' "$fails" | grep -Eq -- "$expect"; then
			printf '%-12s %s\n' KILLED "$name" >"$d/result"
		else
			printf '%-12s %s  (failed: %s; last: %s)\n' KILLED-OTHER "$name" \
				"$(printf '%s' "$fails" | tr '\n' '|')" "$(tail -n 1 "$d/log")" >"$d/result"
		fi
	) &
	[ $((I % JOBS)) = 0 ] && wait
	return 0
}

S=bin/git-salvage

# --- snapshot content
mut "add -A becomes add -u (untracked lost)" $S 'everything back|untracked back' \
	's/local addflags=\(-A\)/local addflags=(-u)/'
mut "clean -x: no add -f (ignored lost)" $S 'clean -xfd: ignored file back' \
	's/\[ "\$ignored" = 1 \] && addflags\+=\(-f\)/:/'
mut "no-index repo: keep the 0-byte temp file" $S 'no index yet' \
	's/\t\trm -f "\$tmp"\n\tfi\n\t# Tracked/\t\t:\n\tfi\n\t# Tracked/'
mut "unmerged index treated as failure" $S 'merge --abort' \
	's/if \[ -n "\$\(git ls-files -u \| head -n 1\)" \]; then/if false; then/'

# --- skip rules
mut "untracked-at-risk rule flipped" $S 'untracked only' \
	's/if \[ "\$untracked" = 1 \]; then/if [ "\$untracked" = 0 ]; then/'
mut "clean does not put untracked at risk" $S 'untracked only \+ clean' \
	's/\t\t\tPRE_KIND=worktree\n\t\t\tPRE_UNTRACKED=1\n/\t\t\tPRE_KIND=worktree\n/'
mut "no dedupe against newest snapshot" $S 'same dirty state twice' \
	's/\[ "\$tw" = "\$ntw" \] && \[ "\$ti" = "\$nti" \] && return 0/:/'

# --- classification
mut "reset --soft triggers" $S 'reset --soft' \
	's/has_opt --soft \|\| PRE_KIND=worktree/PRE_KIND=worktree/'
mut "-h/--help triggers" $S 'checkout -h' \
	's/\thas_opt -h --help && return 0\n//'
mut "alias not expanded" $S 'alias to reset --hard' \
	's/\t\tset -- \$alias_val "\$@"\n//'
mut "-- does not end options" $S 'clean -f -- -n' \
	's/\t\t--\) dd=1 ;;\n//'
mut "clean -e takes no argument" $S 'clean -f -en' \
	's/\tclean\) printf .e. ;;\n//'
mut "stash drop <n> ignores n" $S 'stash drop 1' \
	's/\*\) printf .stash@\{%s\}\\n. "\$1" ;;/*) printf "stash\@{0}\\n" ;;/'
mut "branch -r reads refs/heads" $S 'branch -dr' \
	's/\thas_opt -r --remotes && prefix=refs\/remotes\/\n//'
mut "branch -M not recorded" $S 'branch -M onto existing' \
	's/elif has_opt -M -C; then/elif false; then/'
mut "branch -t takes an argument" $S 'branch -t -M onto existing' \
	's/branch\) printf .u. ;;/branch) printf "tu" ;;/'
mut "-h after an option not seen" $S 'reset --help' \
	's/has_opt -h --help && return 0/has_opt -h \&\& return 0/'
mut "rm -f not recorded" $S 'rm -f' \
	's/\trm\) has_opt -f --force && PRE_KIND=worktree ;;\n//'

# --- fail closed
mut "fail closed returns 0" $S 'fail closed: exit 1' \
	's/(was not run\."\n.*\n)\t\treturn 1/$1\t\treturn 0/'
mut "snapshot failure ignored" $S 'fail closed' \
	's/snapshot_worktree "\$display" "\$PRE_IGNORED" "\$PRE_UNTRACKED" \|\| ok=1/snapshot_worktree "\$display" "\$PRE_IGNORED" "\$PRE_UNTRACKED" || true/'
mut "temp files not cleaned up" $S 'no temp files left' \
	's/^trap cleanup EXIT$/trap "" EXIT/m'

# --- commit identity / signing
# Not listed: dropping --no-gpg-sign. commit-tree does not read
# commit.gpgSign (measured, git 2.55.0), so that mutation is equivalent;
# the flag stays as a guard against a future git that does.
mut "identity not forced" $S 'no user identity' \
	's/GIT_AUTHOR_NAME=\$SALVAGE_IDENT_NAME GIT_AUTHOR_EMAIL=\$SALVAGE_IDENT_EMAIL \\\n\t*GIT_COMMITTER_NAME=\$SALVAGE_IDENT_NAME GIT_COMMITTER_EMAIL=\$SALVAGE_IDENT_EMAIL \\\n\t*//'

# --- retention / output
mut "retention off by one" $S 'retention: keep=3' \
	's/\$\(\(keep \+ 1\)\)/\$((keep + 2))/'
mut "quiet env ignored" $S 'GIT_SALVAGE_QUIET' \
	's/\[ "\$\{GIT_SALVAGE_QUIET:-\}" = 1 \] && return 0/:/'

# --- restore
mut "restore -a runs from the cwd" $S 'restore from subdir: whole tree' \
	's/\(cd "\$TOP" && GIT_INDEX_FILE=\$tmp git checkout-index -f -a\)/(GIT_INDEX_FILE=\$tmp git checkout-index -f -a)/'
mut "restore reads the snapshot by ref name" $S 'restore of the oldest kept' \
	's/\tref=\$\(git rev-parse --verify -q "\$ref\^\{commit\}"\) \|\| die "[^"]*"\n//'
mut "restore does not save the current state" $S 'restore saved the current state|pre-restore' \
	's/\t\tsnapshot_worktree "restore of \$id" 0 \|\|\n\t*die "[^\n]*"\n/\t\tSAVED=0\n/'
mut "restore --index ignored" $S 'restore --index: staged' \
	's/\t\t\tgit read-tree "\$ref:index" \|\| die "[^"]*"\n/\t\t\t:\n/'
mut "restore --index allowed on unmerged" $S 'merge --abort: refused' \
	's/\] && \[ "\$\(trailer "\$ref" Salvage-Index\)" != captured \]; then/] \&\& false; then/'
mut "restore -- paths ignored" $S 'restore -- dir: other file untouched' \
	's/if \[ \$\{#paths\[@\]\} -gt 0 \]; then/if false; then/'
mut "branch restore overwrites existing" $S 'branch restore' \
	's/git show-ref -q --verify "\$label" && die/git show-ref -q --verify "\$label" \&\& false \&\& die/'

# --- shim
G=shim/git
mut "shim: -C read as value-less" $G 'git -C <repo> from outside' \
	's/\t-C \| -c \| --git-dir/\t-c | --git-dir/'
mut "shim: globals not passed to _pre" $G 'git -C <repo> from outside' \
	's/ \$\{GLOBALS\[@\]\+"\$\{GLOBALS\[@\]\}"\} \\\n/ \\\n/'
# Not listed: the shim ignoring GIT_SALVAGE_SKIP. _pre checks it again, so
# the shim's check only saves a process: an equivalent mutation.
mut "shim: _pre failure ignored" $G 'shim fail closed' \
	's/<\/dev\/null \|\| exit 1/<\/dev\/null || true/'
mut "shim: reset in the fast path" $G 'shim: reset --hard saved' \
	's/\nstatus \| log \|/\nreset | status | log |/'
mut "shim: REAL_GIT pointing at itself accepted" $G 'GIT_SALVAGE_REAL_GIT' \
	's/ &&\n\t\t! \[ "\$GIT_SALVAGE_REAL_GIT" -ef "\$self" \]; then/; then/'
mut "shim: no unrecognized-option line" $G 'unrecognized option' \
	's/\t\tprintf .%s\\n. "git-salvage: unrecognized option[^\n]*\n//'

# --- install / doctor
mut "install: git-salvage not copied" $S 'git-salvage beside it' \
	's/\tcopy_into "\$self" "\$DIR\/git-salvage"\n//'
mut "install: foreign git overwritten" $S 'install refuses a foreign git' \
	's/if \[ -e "\$DIR\/git" \] && ! is_shim "\$DIR\/git"; then/if false; then/'
mut "uninstall: foreign git removed" $S 'uninstall refuses a foreign git|foreign git untouched' \
	's/is_shim "\$DIR\/git" \|\| die "\$DIR\/git is not/: || die "\$DIR\/git is not/'
mut "doctor: always exit 0" $S 'doctor without the shim: exit 1' \
	's/\treturn "\$problems"/\treturn 0/'
mut "doctor: git's exec-path not skipped" $S 'doctor with the shim' \
	's/\t\t\[ "\$d" = "\$execdir" \] && continue\n//'

wait
echo "== mutations ($I)"
cat "$SCR"/m*/result 2>/dev/null | sort
