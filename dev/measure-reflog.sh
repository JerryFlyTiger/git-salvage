#!/usr/bin/env bash
# Measures what `git salvage view` reads from the real git:
#   Q1  the reflog messages (%gs) of the everyday commands, which the page
#       explains in plain words; and whether a localized git translates them
#   Q2  whether one `git log -g <ref>...` walks several reflogs at once, and
#       what %gD / %gd print with --date=unix
#   Q3  whether for-each-ref's %(trailers:key=...) reads Salvage-Kind, and
#       whether two such atoms in one format stay independent
#   Q4  what a deleted branch leaves in `git reflog` (is its log gone?)
#   Q6  default expiry of reflog entries whose commit is on no branch
#   Q5  messages of rename, rebase --abort, a merge concluded by commit, clone,
#       a fast-forward pull
# Usage: bash dev/measure-reflog.sh [<locale to compare with C>]
set -u
LOC=${1:-zh_TW.UTF-8}
HOME=$(mktemp -d)
export GIT_CONFIG_NOSYSTEM=1 HOME XDG_CONFIG_HOME="$HOME/.config" GIT_SALVAGE_ACTIVE=1
export GIT_EDITOR=true GIT_PAGER=cat
git --version
git config --global user.name t
git config --global user.email t@example.com
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# scenario <dir>: the same command history, run under the current locale.
scenario() {
	git init -q "$1" && cd "$1" || exit 1
	# Every commit writes its own file: no step can conflict.
	c() { echo "$1" >"$1" && git add "$1" && git commit -qm "$1"; }
	c one
	c two
	git branch feature
	git switch -q feature
	c f1
	git switch -q main
	c three
	git merge -q --no-edit feature
	git reset -q --hard HEAD~1
	git checkout -q -b topic
	c t1
	git rebase -q feature
	git switch -q main
	git merge -q --no-edit topic
	git switch -q -c side
	c s1
	git switch -q main
	git cherry-pick side >/dev/null
	git revert --no-edit HEAD >/dev/null
	git commit -q --amend -m "revert amended"
	git branch -f feature HEAD~2
	git branch -m topic topic2
	git checkout -q HEAD~1
	git checkout -q main
	echo w >>one && git stash -q && git stash pop -q && git checkout -q -- one
	git switch -q feature && git merge -q main && git switch -q main
	git init -q --bare "$1.remote.git"
	git remote add origin "$1.remote.git"
	git push -q origin main 2>/dev/null
	git clone -q "$1.remote.git" "$1.clone" 2>/dev/null
	(cd "$1.clone" && echo r1 >r1 && git add r1 && git commit -qm r1 && git push -q 2>/dev/null)
	git fetch -q origin
	c local1
	git pull -q --rebase origin main
	(cd "$1.clone" && echo r2 >r2 && git add r2 && git commit -qm r2 && git push -q 2>/dev/null)
	git pull -q --no-rebase --no-edit origin main
	git branch -D topic2 >/dev/null
}

echo "== Q1 HEAD reflog messages, oldest first (LC_ALL=C)"
(LC_ALL=C scenario "$HOME/c" && LC_ALL=C git reflog show --format=%gs HEAD | sed '1!G;h;$!d')
echo "== Q1 other reflogs (LC_ALL=C)"
(cd "$HOME/c" && for r in refs/heads/main refs/heads/feature refs/remotes/origin/main refs/stash; do
	printf -- '-- %s\n' "$r"
	LC_ALL=C git reflog show --format=%gs "$r" 2>&1 | sed '1!G;h;$!d'
done)
echo "== Q1 same history under $LOC: diff of HEAD reflog messages vs C (empty = not localized)"
(LC_ALL=$LOC LANG=$LOC scenario "$HOME/l" >/dev/null 2>&1)
# Commit ids differ (different timestamps); mask them.
msgs() { (cd "$1" && git reflog show --format=%gs HEAD | sed 's/[0-9a-f]\{40\}/<id>/g'); }
diff <(msgs "$HOME/c") <(msgs "$HOME/l") && echo "(identical)"

cd "$HOME/c" || exit 1
export LC_ALL=C
echo "== Q2 git log -g HEAD refs/heads/main refs/heads/feature (first 6)"
git log -g --date=unix --format='%gD | %gs' HEAD refs/heads/main refs/heads/feature | grep -v '^HEAD' | head -4
git log -g --format=%gD HEAD refs/heads/main refs/heads/feature | sed 's/@.*//' | uniq -c
echo "== Q2 exit code with a ref that has no reflog"
git update-ref refs/heads/nolog HEAD
git log -g --format=%gD refs/heads/nolog HEAD >/dev/null 2>&1
echo "exit $?"
echo "== Q2 exit code with a ref that does not exist"
git log -g --format=%gD refs/heads/nosuch HEAD >/dev/null 2>&1
echo "exit $?"
echo "== Q2 -n 3 over several reflogs: total lines (3 = total, not per ref)"
git log -g -n 3 --format=%gD HEAD refs/heads/main refs/heads/feature | wc -l | tr -d ' '
echo "== Q2 log -n 010 and -n 08: decimal? (prints the counts)"
echo "$(git log -n 010 --format=%H | wc -l | tr -d ' ') $(git log -n 08 --format=%H | wc -l | tr -d ' ')"
echo "== Q2 exit code of log -g HEAD on an unborn branch"
(git init -q "$HOME/unborn" && cd "$HOME/unborn" && git log -g --format=%gD HEAD >/dev/null 2>&1; echo "exit $?")
echo "== Q2 git reflog show --date=unix --format='%H %gD %gs' main -n 2"
git reflog show --date=unix --format='%H %gD %gs' main -n 2

echo "== Q3 for-each-ref trailers"
T=$(git commit-tree -m "git reset --hard" -m "Salvage-Kind: worktree
Salvage-Head: refs/heads/main" "$(git rev-parse "HEAD^{tree}")" -p HEAD)
git update-ref refs/salvage/x "$T"
git for-each-ref --format='[%(subject)] [%(trailers:key=Salvage-Kind,valueonly)] [%(parent)] [%(committerdate:unix)]' refs/salvage/
echo "== Q3 two %(trailers:key=...) atoms in one format (each should show one key)"
git for-each-ref --format='[%(trailers:key=Salvage-Kind,valueonly,separator=%x2C)] [%(trailers:key=Salvage-Head,valueonly,separator=%x2C)]' refs/salvage/
echo "== Q3 one atom, several keys, U+001F separated (shown as ^_)"
git for-each-ref --format='[%(trailers:key=Salvage-Kind,key=Salvage-Ref,key=Salvage-Head,separator=%x1F)]' refs/salvage/ | cat -v

echo "== Q4 after branch -D topic2: reflog of the deleted branch"
git reflog show refs/heads/topic2 2>&1 | head -2
echo "exit ${PIPESTATUS[0]}"
echo "== Q5 more messages: rename, rebase --abort, merge resolved by commit, clone, ff pull"
(
	git init -q "$HOME/q5" && cd "$HOME/q5" || exit 1
	echo a >f && git add f && git commit -qm a
	git switch -q -c b && echo b >f && git commit -qam b
	git switch -q main && echo m >f && git commit -qam m
	git branch -m b b2
	git switch -q b2 && git rebase -q main >/dev/null 2>&1; git rebase --abort
	git switch -q main && git merge -q b2 >/dev/null 2>&1; echo r >f && git add f && git commit -q --no-edit
	git clone -q "$HOME/q5" "$HOME/q5c" && cd "$HOME/q5c" || exit 1
	(cd "$HOME/q5" && echo p >f && git commit -qam p)
	git pull -q --ff-only
	git log -g --format='%gD | %gs' HEAD refs/heads/main refs/remotes/origin/main
) | sed 's/@{[0-9]*}//'
(cd "$HOME/q5" && git log -g --format='%gD | %gs' HEAD refs/heads/b2 refs/heads/main | sed 's/@{[0-9]*}//' | sed '1!G;h;$!d')
for days in 29 31; do
	echo "== Q6 default reflog expiry: entries dated $days days ago, dry run (prune lines)"
	(
		git init -q "$HOME/q6-$days" && cd "$HOME/q6-$days" || exit 1
		export GIT_COMMITTER_DATE="$(($(date +%s) - days * 86400)) +0000"
		echo a >f && git add f && git commit -qm kept
		echo b >f && git commit -qam left && git reset -q --hard HEAD~1
		unset GIT_COMMITTER_DATE
		echo c >f && git commit -qam now
		git reflog expire --dry-run --verbose HEAD 2>&1 | grep -i prune
	)
done
rm -rf "$HOME"
