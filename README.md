# git-salvage

An undo for the git commands that destroy work you never committed.

`git reset --hard`, `git checkout -- file`, `git restore`, `git clean -f`,
`git branch -D`, `git stash drop`: git's reflog cannot bring back what these
throw away, because it was never committed. git-salvage takes a snapshot
right before such a command runs, so it can be undone:

```console
$ git reset --hard
git-salvage: saved snapshot 1 (undo with: git salvage restore 1)
HEAD is now at 9fc1335 init
$ git clean -fd
git-salvage: saved snapshot 1 (undo with: git salvage restore 1)
Removing idea.md
$ git salvage list
  1  2026-09-24 08:39:13  worktree  git clean -fd  (1 paths)
  2  2026-09-24 08:39:13  worktree  git reset --hard  (2 paths)
$ git salvage restore 2
restored snapshot 2
```

It is a small safety net next to the real git, not a replacement: every git
command still runs unchanged, with git's own output and exit code.

## How it works

git gives no way to run code before these commands (no hook fires early
enough, and an alias cannot shadow a builtin; see `dev/measure-premise.sh`).
So git-salvage installs a tiny `git` shim ahead of the real git on `PATH`.
For a destructive command, the shim runs `git salvage _pre` to take a
snapshot, then `exec`s the real git with the same arguments. For anything
else it only `exec`s the real git.

A snapshot is a commit stored under `refs/salvage/`, holding the working tree
(untracked files included) and the index. Your index, working tree, branches
and reflog are not touched. The refs are local: `push`, `fetch` and `clone`
do not transfer them.

If a snapshot that should be taken cannot be taken, the command does **not**
run:

```
git-salvage: could not save a snapshot (<reason>); 'git reset --hard' was not run.
git-salvage: set GIT_SALVAGE_SKIP=1 to run it without a snapshot.
```

## Install

Requires bash (macOS's `/bin/bash` 3.2 is enough) and git.

```console
$ git clone https://github.com/JerryFlyTiger/git-salvage
$ git-salvage/bin/git-salvage install
installed /Users/you/.local/share/git-salvage/bin/git and /Users/you/.local/share/git-salvage/bin/git-salvage
add this line to your shell profile (then open a new shell):
  export PATH="/Users/you/.local/share/git-salvage/bin:$PATH"
```

Then, in a new shell:

```console
$ git salvage doctor
git-salvage: /Users/you/.local/share/git-salvage/bin/git-salvage
first git on PATH: /Users/you/.local/share/git-salvage/bin/git
it is the git-salvage shim: yes
real git: /opt/homebrew/bin/git
...
```

`install --dir D` installs somewhere else. `git salvage uninstall` removes the
two files; snapshots already taken stay in each repo under `refs/salvage/`.

## What triggers a snapshot

| command | when |
|---|---|
| `reset` | anything except `--soft` |
| `checkout`, `restore` | always |
| `switch` | `-f`, `--force`, `--discard-changes`, `-m`, `--merge` |
| `clean` | unless `-n`; with `-x`/`-X` ignored files are saved too |
| `rm` | `-f`, `--force` |
| `merge`, `rebase`, `cherry-pick`, `revert`, `am` | `--abort`, `--skip` |
| `stash drop`, `stash pop`, `stash clear` | always (the stash entries) |
| `branch -d/-D` | always (the branch tips) |
| `branch -M/-C`, or `-m/-c` with `-f` | when the target branch exists |

One level of alias is followed (`alias.nuke = reset --hard` is caught).
Nothing is saved when there is nothing uncommitted, or when the state is the
same as the newest snapshot.

## Commands

```
git salvage list
git salvage show <n> [--stat | -p]
git salvage restore <n> [--index] [-- <path>...]
git salvage snapshot [-m <message>]
git salvage drop <n>
git salvage prune [--keep <k>] [--older-than <days>]
git salvage install [--dir <dir>] | uninstall [--dir <dir>] | doctor
```

Snapshots are numbered 1 = newest.

- `restore` writes the saved files back. It never deletes a file and does
  not change the index (`--index` also restores the index). It first takes a
  snapshot of the current state, so a restore can itself be undone.
- A branch snapshot restores the branch (refused if the name exists); a stash
  snapshot goes back on the stash list.
- The newest 200 snapshots are kept per repo (`git config salvage.keep N`).

Settings: `GIT_SALVAGE_QUIET=1` or `salvage.quiet=true` hides the
`saved snapshot` line; `GIT_SALVAGE_SKIP=1` runs one command without a
snapshot; `GIT_SALVAGE_REAL_GIT=/path/to/git` names the real git.

## Limits

- Only `git` found through `PATH` is covered. A program that runs git by an
  absolute path, bundles its own git, or uses a git library (libgit2, JGit,
  go-git) bypasses the shim. Hooks run by git bypass it too.
- Not covered: `worktree remove --force`, `checkout-index -f`, `read-tree -u`,
  `gc --prune=now`, `reflog expire`, and anything outside git (`rm`, an editor).
- Nested repositories inside untracked directories are recorded as links;
  their contents are not saved.
- Snapshots keep large untracked files alive until they are pruned.

The full design, with the measurements behind each decision, is in
[`docs/DESIGN.md`](docs/DESIGN.md).

## Development

```bash
bash tests/run.sh      # prints "tests: N/M passed"
shellcheck bin/git-salvage shim/git tests/run.sh
dev/mutate.sh          # breaks the code one way at a time; every line should say KILLED
```

## License

MIT
