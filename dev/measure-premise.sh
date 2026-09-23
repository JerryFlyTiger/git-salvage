#!/usr/bin/env bash
# Measures the premise git-salvage rests on, against the real git on PATH:
#   Q1  can a git alias shadow a builtin (so `git reset` could be redirected)?
#   Q2  which hooks, if any, fire before/after each destructive command?
#   Q3  does the snapshot recipe (copy of the index + `add -A` into it +
#       write-tree) leave the real index and working tree byte-identical?
# Re-run after a git upgrade; the answers are git's, not ours.
set -u
HOME=$(mktemp -d)
# XDG_CONFIG_HOME too: git reads $XDG_CONFIG_HOME/git/config regardless of HOME.
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1 HOME XDG_CONFIG_HOME="$HOME/.config"
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main
git --version
T=$(mktemp -d); cd "$T" && git init -q r && cd r || exit 1
echo base > a; git add a; git commit -qm base

echo "== Q1: alias shadowing a builtin"
git config alias.reset '!echo ALIAS-RAN'
out=$(git reset 2>&1); echo "git reset -> [${out:-<empty>}]"
git config --unset alias.reset

echo "== Q2: hooks fired per destructive command"
LOG="$T/hooks.log"
for h in pre-commit post-checkout post-merge reference-transaction \
         pre-rebase post-rewrite pre-auto-gc post-index-change; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$h" "$LOG" > .git/hooks/$h
  chmod +x .git/hooks/$h
done
run() { : > "$LOG"; echo dirty >> a; echo u > untracked
        "$@" >/dev/null 2>&1
        printf '%-32s ' "$*"; if [ -s "$LOG" ]; then
          cut -d' ' -f1-2 "$LOG" | sort -u | tr '\n' ';'; echo; else echo "(no hook)"; fi; }
run git reset --hard
run git restore a
run git checkout -- a
run git checkout -f
run git clean -fd
git stash -q 2>/dev/null; run git stash drop
git branch tmp; run git branch -D tmp
rm -f untracked

echo "== Q3: snapshot recipe leaves real index/worktree untouched"
echo dirty2 >> a; echo new > n; git add a
before_idx=$(shasum < .git/index); before_wt=$(cat a n | shasum)
tmp=$(mktemp); cp .git/index "$tmp"
GIT_INDEX_FILE="$tmp" git add -A
tw=$(GIT_INDEX_FILE="$tmp" git write-tree)
cp .git/index "$tmp"; ti=$(GIT_INDEX_FILE="$tmp" git write-tree); rm -f "$tmp"
[ "$(shasum < .git/index)" = "$before_idx" ] && echo "index: unchanged" || echo "index: CHANGED"
[ "$(cat a n | shasum)" = "$before_wt" ] && echo "worktree: unchanged" || echo "worktree: CHANGED"
echo "worktree tree has n: $(git ls-tree --name-only "$tw" | grep -cx n)  index tree has n: $(git ls-tree --name-only "$ti" | grep -cx n)"
git status --porcelain

echo "== Q2b: is uncommitted work still on disk at the EARLIEST hook of reset --hard?"
cd "$T" && git init -q r2 && cd r2 && echo base > a && git add a && git commit -qm b
# shellcheck disable=SC2016 # expands inside the hook, not here
printf '#!/bin/sh\n[ "$1" = preparing ] && echo "a at preparing: $(cat a)" >&2\nexit 0\n' \
  > .git/hooks/reference-transaction && chmod +x .git/hooks/reference-transaction
echo DIRTY >> a; git reset --hard 2>&1 | grep -m1 'a at'
