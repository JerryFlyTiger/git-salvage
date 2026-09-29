#!/usr/bin/env bash
# Measures what the shim costs on top of the real git, by repo size:
#   status             a non-destructive command (the shim's pass-through cost)
#   reset --hard clean a destructive command with nothing to save (skip path:
#                      the full add -A + write-tree still runs)
#   reset --hard dirty one modified file: a snapshot is taken
#   checkout -- f      one modified file, a path-limited destructive command
# Each cell: median of RUNS wall-clock runs, in ms, real git / through the shim.
# usage: SIZES="1000 10000 100000" RUNS=5 dev/measure-perf.sh
set -u
HERE=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)
SIZES=${SIZES:-1000 10000 100000}
RUNS=${RUNS:-5}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config LC_ALL=C GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
# The real git: the first `git` on PATH that is not a git-salvage shim, so an
# installed shim cannot end up in the "real git" column. Put first on PATH.
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
PATH=${REAL%/*}:$PATH
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main
"$HERE/bin/git-salvage" install --dir "$T/shimbin" >/dev/null || exit 1
SHIMPATH=$T/shimbin:$PATH
echo "git $(git --version | cut -d' ' -f3); $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"

ms() { # ms <cmd...>: wall-clock ms of one run, output discarded
	perl -MTime::HiRes=time -e '$o = shift; open STDOUT, ">", "/dev/null";
		open STDERR, ">", "/dev/null"; $t = time; $r = system @ARGV;
		open F, ">", $o; printf F "%d\n", (time - $t) * 1000; exit($r != 0)' "$T/ms" "$@" ||
		echo "measure-perf: failed, timing still counted: $*" >&2
	cat "$T/ms"
}
median() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }
# cell <setup-fn> <git args...>: "real / shim" medians
cell() {
	local setup=$1 r s
	shift
	r=$(for _ in $(seq "$RUNS"); do "$setup"; ms env PATH="$PATH" "$REAL" "$@" </dev/null; done | median)
	s=$(for _ in $(seq "$RUNS"); do "$setup"; ms env PATH="$SHIMPATH" git "$@" </dev/null; done | median)
	printf '%7s / %-7s ' "$r" "$s"
}
nothing() { :; }
dirty() { echo x >>d0/f0; }

printf '%8s  %-17s %-17s %-17s %-17s\n' files status 'reset clean' 'reset dirty' 'checkout -- f'
for n in $SIZES; do
	R=$T/r$n
	mkdir -p "$R" && cd "$R" || exit 1
	git init -q
	perl -e 'for $i (0 .. $ARGV[0] - 1) { $d = "d" . int($i / 100); mkdir $d; open F, ">", "$d/f" . ($i % 100) or die; print F "line $i\n"; close F }' "$n"
	git add -A && git commit -qm base && git status >/dev/null
	printf '%8s  ' "$n"
	cell nothing status
	cell nothing reset --hard
	cell dirty reset --hard
	cell dirty checkout -- d0/f0
	echo
	cd "$T" && rm -rf "$R"
done
echo "(ms, median of $RUNS: real git / through the shim)"
