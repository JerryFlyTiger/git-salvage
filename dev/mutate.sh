#!/usr/bin/env bash
# Mutation check for tests/run.sh: each mutation breaks one thing in a copy of
# the tree (never the real one), runs the suite there, and reports whether the
# named check went red.
#   KILLED        an expected check failed
#   KILLED-OTHER  the suite failed, but not on an expected check (read why)
#   SURVIVED      the suite stayed green: a missing test
#   ABORTED       no FAIL line and no N/N summary: the suite died
#   NOT-APPLIED   the substitution matched nothing: the mutation is stale
#   SYNTAX        the mutated file no longer parses: the mutation is broken
#   TIMEOUT       the suite ran past MUT_TIMEOUT: nothing was proven
# usage: dev/mutate.sh [name-substring]   (default: all)
# A full run (no filter) also writes dev/mutate-results.txt, which is
# committed, so a status that changes shows up in the diff.
# shellcheck disable=SC2016 # the $ in every perl expression is perl's, not the shell's
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCR=$(mktemp -d "${TMPDIR:-/tmp}/salvage-mut.XXXXXX")
trap 'chmod -R u+w "$SCR" 2>/dev/null; rm -rf "$SCR"' EXIT INT TERM
FILTER=${1:-}
JOBS=${JOBS:-4}
MUT_TIMEOUT=${MUT_TIMEOUT:-300}
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
	# A mutation that breaks the syntax turns nearly every check red, so its
	# KILLED would prove nothing about the check it names.
	case $file in
	*.html | *.js) ;;
	*) if ! /bin/bash -n "$d/$file" 2>/dev/null; then
		printf '%-12s %s\n' SYNTAX "$name" >"$d/result"
		return 0
	fi ;;
	esac
	(
		start=$(date +%s)
		timeout "$MUT_TIMEOUT" /bin/bash "$d/tests/run.sh" >"$d/log" 2>&1
		rc=$?
		printf '%s %s\n' "$(($(date +%s) - start))" "$name" >"$d/time"
		if [ "$rc" = 124 ]; then
			printf '%-12s %s  (over %ss)\n' TIMEOUT "$name" "$MUT_TIMEOUT" >"$d/result"
			exit 0
		fi
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

mut "ref id: seq ignores same-second refs" $S 'ref order: newer snapshot|ref order: seq' \
	's/\*\) n=\$\(\(10#\$last \+ 1\)\) ;;/*) n=0 ;;/'
mut "ref id: pid before seq" $S 'ref order: seq' \
	's/"\$REF_PREFIX" "\$now" "\$n" "\$\$"/"\$REF_PREFIX" "\$now" "\$\$" "\$n"/'

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
# Not listed: dropping -z on both ls-files and checkout-index. Without -z,
# checkout-index --stdin unquotes ls-files' "a\nb" lines (measured, git
# 2.55.0), so it is an equivalent mutation.
mut "restore -- paths: ls-files without -z" $S 'quoted names: restore -- name [0-3] (exits 0|back)' \
	's/git ls-files -z -- /git ls-files -- /'
mut "restore -- paths: newline taken as separator" $S 'quoted names: restore -- name 0 (exits 0|back)' \
	's/git ls-files -z -- "\$\{paths\[@\]\}" >"\$list"/git ls-files -z -- "\${paths[@]}" | tr "\\n" "\\0" >"\$list"/'
mut "list: count paths split on NUL" $S 'quoted names: list counts' \
	's/git diff-tree -r --name-only "\$base" "\$ref:worktree" \|/git diff-tree -r -z --name-only "\$base" "\$ref:worktree" | tr "\\0" "\\n" |/'
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
mut "shim: GIT_SALVAGE_REAL_GIT ignored" $G 'GIT_SALVAGE_REAL_GIT is used' \
	's/if \[ -n "\$\{GIT_SALVAGE_REAL_GIT:-\}" \]/if false/'
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

mut "install: view template not copied" $S 'view template beside it' \
	's/\tcopy_into "\$here\/\$VIEW_TEMPLATE" "\$DIR\/\$VIEW_TEMPLATE"\n\tchmod 755 "\$DIR\/git" "\$DIR\/git-salvage" \|\| die "[^"]*"\n\tchmod 644 "\$DIR\/\$VIEW_TEMPLATE" \|\| die "[^"]*"\n/\tchmod 755 "\$DIR\/git" "\$DIR\/git-salvage" || die "x"\n/'
mut "uninstall: view template kept" $S 'uninstall: files gone' \
	's/for f in git git-salvage "\$VIEW_TEMPLATE"; do/for f in git git-salvage; do/'
mut "install hint: csh gets export" $S 'tcsh gets setenv|csh gets setenv' \
	's/\tcsh \| tcsh\) printf/\tcsh-x) printf/'
mut "install hint: fish gets export" $S 'fish gets set -gx' \
	's/\tfish\) printf/\tfish-x) printf/'
mut "install hint: zsh rehash becomes hash -r" $S 'already first, zsh: rehash' \
	's/zsh \| csh \| tcsh\) rehash=rehash/csh | tcsh) rehash=rehash/'
mut "install hint: already-first never seen" $S 'already first' \
	's/\[ "\$\(cd -P -- "\$\{first%\/\*\}" 2>\/dev\/null && pwd -P\)" = "\$real" \]/false/'
mut "install hint: in_path always false" $S 'on PATH after the real git' \
	's/(in_path\(\) \{[^\n]*\n)/$1\treturn 1\n/'
mut "install hint: in_path ignores -P" $S 'PATH entry is a symlink' \
	's/\[ "\$\(cd -P -- "\$d" 2>\/dev\/null && pwd -P\)" = "\$1" \]/[ "\$d" = "\$1" ]/'
mut "doctor: no stale-shell note" $S 'doctor with the shim: stale-shell note' \
	's/\t\techo "  \(a shell opened before the install[^\n]*\n[^\n]*\n//'

# --- view (bash side)
mut "view: status may write the index" $S 'view: repo unchanged' \
	's/git --no-optional-locks status --porcelain=v2/git status --porcelain=v2/'
mut "view: reflog ids not drawn" $S 'left behind by reset' \
	's/\{ \[ -z "\$ids" \] \|\| printf .%s\\n. "\$ids"; \} \|/{ :; } |/'
mut "view: -n ignored" $S 'view -n 2' \
	's/--date-order -n "\$max"/--date-order -n 300/'
mut "view: one trailer key only" $S 'view data: snapshot fields' \
	's/key=Salvage-Kind,key=Salvage-Ref,key=Salvage-Head/key=Salvage-Kind/'
mut "view: data not base64" $S 'view data' \
	's/view_data "\$max" \| base64 >"\$raw"/view_data "\$max" >"\$raw"/'
mut "view: unborn HEAD given to log -g" $S 'view unborn' \
	's/\tif \[ -n "\$head" \]; then refs\+=\(HEAD\); fi\n\tall=/\trefs+=(HEAD)\n\tall=/'

# --- view (page logic, tests/view-test.js)
V=bin/git-salvage-view.html
mut "view js: passing lane loses its bottom" $V 'layout: branch and merge' \
	's/if \(passing\[j\] && lanes\[j\] !== null\)/if (passing[j] \&\& lanes[j] !== null \&\& !fromCommit[j])/'
mut "view js: checkout target always a branch" $V 'not a local branch' \
	's/m && branches && Object.prototype.hasOwnProperty.call\(branches, m\[2\]\)/m/'
mut "view js: snapshots numbered from 0" $V 'parseData: snapshots' \
	's/s\.n = k \+ 1;/s.n = k;/'
mut "view js: HEAD and branch entries not merged" $V 'one event' \
	's/if \(same\) \{/if (false) {/'
mut "view js: unknown phase explained" $V 'unknown messages' \
	's/else if \(phase === "merge"\) r\.text/else r.text/'

mut "view js: HEAD-only entry treated as a branch" $V 'no branch entry, nothing said' \
	's/var br = onBranch !== false;/var br = true;/'
mut "view js: event ref = second move" $V 'eventRef' \
	's/if \(\/\^refs\\\/heads\\\/\/\.test\(moves\[i\]\.ref\)\) return moves\[i\]\.ref;/if (i === 1) return moves[i].ref;/'
mut "view js: equal HEAD entries collapse" $V 'two equal HEAD entries' \
	's/if \(!same && !h\.moves\.some\(function \(m\) \{ return m\.ref === ref; \}\)\) same = h;/same = h;/'
mut "view js: rebase finish not merged" $V 'finish on HEAD and on the branch are one event' \
	's/ \|\| find\(finishKey\(e\), e\.ref\)//'
mut "view js: finish key ignores time" $V 'other branch, time or id not' \
	's/"finish " \+ e\.time \+ " " \+ e\.id/"finish " + e.id/'
mut "view js: finish key ignores id" $V 'other branch, time or id not' \
	's/"finish " \+ e\.time \+ " " \+ e\.id \+ " " \+/"finish " + e.time + " " +/'
mut "view js: finish key ignores branch" $V 'other branch, time or id not' \
	's/ \+ " " \+ m\[1\] \+ " " \+ m\[2\] :/ + " " + m[1] :/'
mut "view js: left behind named at every move" $V 'named once' \
	's/ \|\| reach\[o\] \|\| named\[o\]\) return;/ || reach[o]) return;/'
mut "view js: left behind ignores ancestry" $V 'on top of X' \
	's/\t+if \(m\.id && reachable\(commits, \[m\.id\]\)\[o\]\) return;\n//'
mut "view js: left behind ignores reachable" $V 'reachable, unloaded' \
	's/ \|\| reach\[o\] \|\|/ ||/'
# Not listed: dropping max=$((10#$max)). git reads -n 010 as 10 too
# (measured, git 2.43.0 and 2.55.0), so it is an equivalent mutation.
mut "view: -n 00 accepted" $S "view refuses '-n 00'" \
	's/\t\[ "\$\(\(10#\$max\)\)" -gt 0 \] \|\| die "[^"]*"\n//'
mut "view: 10-digit -n accepted" $S "view refuses '-n 1234567890'" \
	's/ \| \?\?\?\?\?\?\?\?\?\?\*\) die "not a commit count/) die "not a commit count/'
mut "view: -o <dir> accepted" $S 'adir' \
	's/\t\[ ! -d "\$out" \] \|\| die "[^"]*"\n//'
mut "view: newline kept in the repo name" $S 'newline in the repo name keeps' \
	's/ \| tr .\\n. . .\)/)/'
mut "view: data may end without a newline" $S 'base64 without a final newline' \
	's/if \[ -n "\$\(tail -c 1 "\$raw"\)" \]; then/if false; then/'

wait
RESULTS=$(cat "$SCR"/m*/result 2>/dev/null | sort)
# Slowest suite run under JOBS parallel runs: it must stay well under the
# timeout, or a slower machine turns KILLED into TIMEOUT.
SLOWEST=$(cat "$SCR"/m*/time 2>/dev/null | sort -n | tail -n 1)
echo "== mutations ($I)"
printf '%s\n' "$RESULTS"
if [ -n "$SLOWEST" ]; then
	echo "slowest: ${SLOWEST%% *}s (${SLOWEST#* }), JOBS=$JOBS, timeout ${MUT_TIMEOUT}s"
	[ $((${SLOWEST%% *} * 2)) -le "$MUT_TIMEOUT" ] ||
		echo "WARNING: slowest run is over half the timeout; lower JOBS or raise MUT_TIMEOUT"
fi
if [ -z "$FILTER" ]; then
	{
		echo "# dev/mutate.sh $(date +%Y-%m-%d), $(git --version), JOBS=$JOBS, slowest ${SLOWEST%% *}s of ${MUT_TIMEOUT}s"
		printf '%s\n' "$RESULTS"
	} >"$ROOT/dev/mutate-results.txt"
fi
