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

Requires bash on PATH (macOS's `/bin/bash` 3.2 is enough) and git. bash
only has to be installed: you can type in zsh, csh/tcsh, ksh or fish.

```console
$ git clone https://github.com/JerryFlyTiger/git-salvage
$ git-salvage/bin/git-salvage install
installed /Users/you/.local/share/git-salvage/bin/git, /Users/you/.local/share/git-salvage/bin/git-salvage and /Users/you/.local/share/git-salvage/bin/git-salvage-view.html
add this line to your shell profile (then open a new shell):
  export PATH="/Users/you/.local/share/git-salvage/bin:$PATH"
```

Then, in a new shell:

```console
$ git salvage doctor
git-salvage: /Users/you/.local/share/git-salvage/bin/git-salvage
first git on PATH: /Users/you/.local/share/git-salvage/bin/git
it is the git-salvage shim: yes
  (a shell opened before the install may still run the git it found
   then: open a new shell, or run hash -r / rehash in it)
real git: /opt/homebrew/bin/git
...
```

`install` prints the PATH line for the shell named by `$SHELL`:

| Shell | Profile file (the usual one; not measured) | Line |
|---|---|---|
| zsh | `~/.zshrc` | `export PATH="<dir>:$PATH"` |
| bash | `~/.bashrc` (`~/.bash_profile` on macOS) | `export PATH="<dir>:$PATH"` |
| csh / tcsh | `~/.cshrc` / `~/.tcshrc` | `setenv PATH "<dir>:$PATH"` |
| fish | `~/.config/fish/config.fish` | `set -gx PATH "<dir>" $PATH` |

If you install into a directory that is already on your PATH (`--dir
~/bin`, say), bash, sh and zsh keep running the git they found before until
you open a new shell or run `hash -r` (zsh: `rehash`); `install` says so.
Measured shell by shell in `dev/measure-shells.sh`; see "Other shells" in
[docs/DESIGN.md](docs/DESIGN.md).

`install --dir D` installs somewhere else. `git salvage uninstall` removes the
three files (`git`, `git-salvage`, `git-salvage-view.html`); snapshots
already taken stay in each repo under `refs/salvage/`.

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
| `worktree remove` | always (that worktree, ignored files included) |

Starting a merge or rebase takes no snapshot: git either refuses to start
over uncommitted changes or leaves them in place (measured; see
`docs/DESIGN.md`). Only the way out, `--abort` or `--skip`, can throw them away.

`worktree remove` deletes the worktree's ignored files even without `-f`
(measured), so it is always caught. To undo it, add the worktree again
(`git worktree add <path> <branch>`) and run `git salvage restore N` inside
it. Ignored files can be large (`node_modules`, build output); each such
removal stores them as a snapshot until it is pruned.

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
git salvage view [-o <file>] [-n <max-commits>] [--no-open]
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

## See what git did: `git salvage view`

`git salvage view` writes one self-contained web page (by default
`.git/salvage-view.html`, so it is never committed) and opens it in your
browser. It shows:

- where you are: the branch, ahead/behind its upstream, what is uncommitted;
- the three areas (last commit, staged, working tree) and which command moves
  changes between them;
- the branches as a graph, with the commits a `reset` or `rebase` left behind
  drawn greyed next to the ones that replaced them;
- a timeline of recent commands, newest first, each explained in plain words,
  with the commit it moved from and to, and the command that gets a lost
  commit or a snapshot back.

The timeline comes from git's own reflog and the snapshots, so it also covers
commands run without the shim. The page is read-only (it changes no ref, no
file and not the index), loads nothing from the network, and needs no server.
`-n` caps the commits drawn (default 300); `--no-open` only writes the file.

## Limits

- Only `git` found through `PATH` is covered. A program that runs git by an
  absolute path, bundles its own git, or uses a git library (libgit2, JGit,
  go-git) bypasses the shim. Hooks run by git bypass it too.
- Not covered: commits that only a removed detached worktree reached,
  `checkout-index -f`, `read-tree -u`,
  `gc --prune=now`, `reflog expire`, and anything outside git (`rm`, an editor).
- Nested repositories inside untracked directories are recorded as links;
  their contents are not saved.
- Snapshots keep large untracked files alive until they are pruned.

The full design, with the measurements behind each decision, is in
[`docs/DESIGN.md`](docs/DESIGN.md).

## Development

```bash
bash tests/run.sh      # prints "tests: N/M passed"
shellcheck bin/git-salvage shim/git tests/run.sh dev/*.sh
bash dev/mutate.sh     # breaks the code one way at a time; every line should say KILLED
```

A full `dev/mutate.sh` run also rewrites `dev/mutate-results.txt` (committed)
and prints its slowest suite run against the per-mutation timeout.

The view page's logic (between `BEGIN LOGIC` / `END LOGIC` in
`bin/git-salvage-view.html`) is tested by `tests/view-test.js`, which
`tests/run.sh` runs with `osascript -l JavaScript` on macOS, else `node`.

## License

MIT
