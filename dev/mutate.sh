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
# A mutation that hangs the suite must end as TIMEOUT. timeout(1) signals the
# whole process group; nothing short of it is used.
TIMEOUT_CMD=$(command -v timeout || command -v gtimeout) || {
	echo "dev/mutate.sh: needs timeout or gtimeout (GNU coreutils)" >&2
	exit 1
}

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
		"$TIMEOUT_CMD" "$MUT_TIMEOUT" /bin/bash "$d/tests/run.sh" >"$d/log" 2>&1
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

# --- worktree remove
mut "worktree remove not recorded" $S 'worktree remove -f: one snapshot' \
	's/\t\t\tPRE_KIND=worktree-remove\n//'
mut "worktree not a trigger command" $S 'worktree remove -f: one snapshot' \
	's/ revert am stash branch worktree "/ revert am stash branch "/'
mut "worktree remove: ignored files not saved" $S 'ignored file (only: file saved|too)' \
	's/\t\t\tPRE_IGNORED=1\n//'
mut "worktree remove: untracked not at risk" $S 'ignored file only: snapshot' \
	's/(PRE_IGNORED=1\n)\t\t\tPRE_UNTRACKED=1\n/$1/'
mut "worktree remove: no last-component match" $S 'by last path component' \
	's/\t\tcase \/\$\(lower "\$p"\) in\n\t\t\*\/"\$larg"\)\n\t\t\tpaths\+=\("\$p"\)\n\t\t\tcontinue\n\t\t\t;;\n\t\tesac\n//'
mut "worktree remove: argument case kept" $S 'other letter case' \
	's/larg=\$\(lower "\$arg"\)/larg=\$arg/'
mut "worktree remove: path case kept" $S 'other letter case' \
	's/case \/\$\(lower "\$p"\) in/case \/\$p in/'
mut "worktree remove: no path match" $S 'relative path through|from inside|trailing slash|disagree: both' \
	's/if \[ -n "\$real" \] && \[ "\$\(cd/if false \&\& [ "\$(cd/'
mut "worktree remove: path compare keeps case" $S 'relative path in other letter case' \
	's/real=\$\(cd -- "\$d" 2>\/dev\/null && lower "\$\(pwd -P\)"\)/real=\$(cd -- "\$d" 2>\/dev\/null \&\& pwd -P)/'
mut "worktree remove: loop side of the path compare keeps case" $S 'relative path in other letter case|entered in other letter case' \
	's/\[ "\$\(cd -- "\$p" 2>\/dev\/null && lower "\$\(pwd -P\)"\)"/[ "\$(cd -- "\$p" 2>\/dev\/null \&\& pwd -P)"/'
mut "worktree remove: cd error in the argument shown" $S 'unenterable directory: no output' \
	's/real=\$\(cd -- "\$d" 2>\/dev\/null && lower/real=\$(cd -- "\$d" \&\& lower/'
mut "worktree remove: lower under the caller's locale" $S 'invalid byte under UTF-8' \
	's/LC_ALL=C tr /tr /'
mut "worktree remove: empty argument read as ." $S 'with (no|an empty) path: no snapshot' \
	's/\t\[ -n "\$arg" \] \|\| return 0\n//'
mut "worktree remove: absolute path read as relative" $S 'absolute path with trailing slash' \
	's/case \$arg in \/\*\) d=\$arg ;; \*\) d=\.\/\$arg ;; esac/d=.\/\$arg/'
mut "worktree remove: cd error in the path compare shown" $S 'stale worktree: only the saved line' \
	's/\[ "\$\(cd -- "\$p" 2>\/dev\/null && lower/[ "\$(cd -- "\$p" \&\& lower/'
mut "worktree remove: list -z error shown" $S 'git without list -z: only the saved line' \
	's/git worktree list --porcelain -z >"\$TMP_LAST" 2>\/dev\/null/git worktree list --porcelain -z >"\$TMP_LAST"/'
mut "worktree remove: list error shown" $S "list fails: git's error not shown" \
	's/git worktree list --porcelain >"\$TMP_LAST" 2>\/dev\/null/git worktree list --porcelain >"\$TMP_LAST"/'
# Three worktree checks run only where they can fail (the suite prints a
# SKIP line otherwise): "entered in other letter case" (case-insensitive
# file system), "unenterable directory" (not root), "invalid byte under
# UTF-8" (a tr that fails there, as macOS's does). So on Linux "lower under
# the caller's locale" comes out SURVIVED, and as root "cd error in the
# argument shown" does too. The committed results are from macOS, not root.
mut "worktree remove: CDPATH applies" $S 'CDPATH' \
	's/case \$arg in \/\*\) d=\$arg ;; \*\) d=\.\/\$arg ;; esac/d=\$arg/'
mut "worktree remove: no fallback without -z" $S 'git without list -z' \
	's/\t\tgit worktree list --porcelain >"\$TMP_LAST"/\t\tfalse/'
mut "worktree remove: fallback read as -z" $S 'git without list -z: that worktree' \
	's/\t\tdelim=\$.\\n.\n//'
mut "worktree remove: list failure ignored" $S 'worktree list fails' \
	's/ \|\|\n\t\t\t\{ SNAP_ERR="git worktree list failed"; return 1; \}/ || true/'
mut "worktree remove: outside a repo not skipped" $S 'outside a repo: worktree remove' \
	's/(GITDIR=\$\(git rev-parse --absolute-git-dir 2>\/dev\/null\)) \|\| return 0/$1/'
mut "worktree remove: temp file outside TMPFILES" $S 'worktree remove: no temp files' \
	's/\tmktmp \|\| \{ SNAP_ERR="cannot create a temporary file in \$GITDIR"; return 1; \}\n\tif ! git/\tTMP_LAST=\$(mktemp "\$GITDIR\/salvage-tmp.XXXXXX")\n\tif ! git/'
mut "worktree remove: main worktree saved" $S 'main worktree is not saved' \
	's/\t\tif \[ "\$first" = 1 \]; then\n\t\t\tfirst=0\n\t\t\tcontinue\n\t\tfi\n//'
mut "worktree remove: caller's GIT_DIR kept" $S 'under --git-dir/--work-tree: the linked' \
	's/\tunset GIT_DIR GIT_WORK_TREE\n//'
mut "worktree remove: only GIT_DIR unset" $S 'under --git-dir/--work-tree: the linked' \
	's/\tunset GIT_DIR GIT_WORK_TREE\n/\tunset GIT_DIR\n/'
mut "worktree remove: only GIT_WORK_TREE unset" $S 'under --git-dir/--work-tree: the linked' \
	's/\tunset GIT_DIR GIT_WORK_TREE\n/\tunset GIT_WORK_TREE\n/'
mut "worktree remove: bare repository skipped" $S 'from a bare repository' \
	's/\[ "\$PRE_KIND" = worktree-remove \] \|\| repo_setup/repo_setup/'
mut "worktree remove: cd error shown" $S 'already gone: no output' \
	's/cd -- "\$p" 2>\/dev\/null \|\| continue/cd -- "\$p" || continue/'
mut "worktree remove: snapshot failure ignored" $S 'worktree remove: fail closed' \
	's/snapshot_removed_worktree "\$display" "\$\{ARGS\[1\]:-\}" \|\| ok=1/snapshot_removed_worktree "\$display" "\${ARGS[1]:-}" || true/'
mut "worktree remove: failure inside the loop ignored" $S 'worktree remove: fail closed' \
	's/"\$PRE_UNTRACKED" \|\| return 1\n\t\ttotal=/"\$PRE_UNTRACKED" || true\n\t\ttotal=/'
mut "worktree remove: count not summed" $S 'disagree: saved line' \
	's/\tSAVED=\$total\n//'
mut "worktree remove: generic undo line" $S 'worktree remove: saved line' \
	's/\] && \[ "\$PRE_KIND" = worktree-remove \]; then/] \&\& false; then/'
# Not listed: dropping the `= remove` test in classify. Every other worktree
# subcommand either has no second word or names a path that is not yet a
# worktree (`add`), so the over-trigger finds nothing to save: equivalent.

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
# Not listed: dropping `[ "$j" -le $# ]` in the shim's worktree case. The
# shim has no `set -u`, and bash 3.2 expands an out-of-range ${!j} to
# nothing, which is not `remove`: equivalent.
mut "shim: worktree remove in the fast path" $G 'shim: worktree remove (runs _pre|-f saved)' \
	's/\t\[ "\$j" -le \$# \] && \[ "\$\{!j\}" = remove \] \|\| exec/\texec/'
mut "shim: every worktree command reaches _pre" $G 'shim: worktree list does not run _pre' \
	's/# Only `worktree remove`[^\n]*\nworktree\)\n[^\n]*\n[^\n]*\n\t;;\n//'
mut "shim: REAL_GIT pointing at itself accepted" $G 'GIT_SALVAGE_REAL_GIT' \
	's/ &&\n\t\t! \[ "\$GIT_SALVAGE_REAL_GIT" -ef "\$self" \]; then/; then/'
mut "shim: empty PATH entry skipped" $G 'empty PATH entry searched as \.' \
	's/\t\t\[ -n "\$d" \] \|\| d=\.\n//'
mut "shim: trailing PATH entry searched" $G 'trailing : in PATH not searched' \
	's/for d in \$PATH; do/for d in \$PATH:; do/'
mut "shim: GIT_SALVAGE_REAL_GIT ignored" $G 'GIT_SALVAGE_REAL_GIT is used' \
	's/if \[ -n "\$\{GIT_SALVAGE_REAL_GIT:-\}" \]/if false/'
mut "shim: no unrecognized-option line" $G 'unrecognized option' \
	's/\t\tprintf .%s\\n. "git-salvage: unrecognized option[^\n]*\n//'

# --- install / doctor
# Not listed: `${SHELL:-}` in path_hint becoming `$SHELL`. With SHELL
# unset, bash fills it from the passwd entry before the script runs
# (measured, /bin/bash 3.2, `env -u SHELL`), so `set -u` never sees it unset.
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

# --- unknown subcommand
mut "unknown: no adjacent swap" $S 'swapped letters' \
	's/v=\$\(\(pp\[j - 2\] \+ 1\)\)/:/'
mut "unknown: limit 2 for short input" $S 'prefix, no far match' \
	's/\[ \$\{#typo\} -le 4 \] && max=1/:/'
mut "unknown: over the limit kept" $S 'prefix, no far match' \
	's/if \[ "\$d" -gt "\$max" \]; then\n\t\t\tcontinue\n\t\telif/if/'
mut "unknown: ties dropped" $S 'two at the same distance' \
	's/\t\telif \[ "\$d" = "\$best" \]; then\n\t\t\tnear="\$near \$cmd"\n//'
mut "unknown: no prefix match" $S 'prefix, no far match' \
	's/\[ \$\{#typo\} -ge 3 \] && pre="\$pre \$cmd"/:/'
mut "unknown: prefix of any length" $S '2-letter prefix' \
	's/\[ \$\{#typo\} -ge 3 \] && pre=/pre=/'
mut "unknown: no dedupe" $S 'listed once' \
	's/\t\tcase " \$out " in \*" \$cmd "\*\) continue ;; esac\n//'
mut "unknown: always plural" $S 'one suggestion' \
	's/if \[ "\$n" = 1 \]; then/if false; then/'
mut "unknown: no usage without a suggestion" $S 'no suggestion prints usage' \
	's/suggest "\$sub" >&2 \|\| usage >&2/suggest "\$sub" >\&2/'
mut "unknown: no length filter" $S 'long argument' \
	's/\t\t\[ "\$d" -le "\$max" \] && \[ "\$d" -ge \$\(\(-max\)\) \] \|\| continue\n//'

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
