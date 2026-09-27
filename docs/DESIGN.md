# git-salvage design

## What it is, and what it is not

git-salvage snapshots **uncommitted work** (the index and the working tree,
including untracked files) right before a git command that could destroy it,
so the command can be undone with `git salvage restore`.

git already protects *commits* (the reflog). It does not protect anything that
was never committed: `git reset --hard`, `git restore`, `git checkout -- f`,
`git clean -f` destroy it with no way back. That gap is the whole product.

Second, smaller job: `git salvage view` draws the repository as a local web
page -- branches, where you are, the three areas (HEAD, index, working tree),
and a timeline of what recent commands did, each explained in plain words.
It is read-only and exists so people can see what git just did to them (and
which snapshot undoes it). See "The view page".

**Ceiling, stated up front:** this is a small safety net that sits next to the
real `git`. It is not a git replacement and does not change what any git
command does. It only catches `git` invocations that go through the `git`
found on `PATH` (see "Coverage limits").

## Why a PATH shim (measured, `dev/measure-premise.sh`, git 2.55.0)

- A git alias cannot shadow a builtin: with `alias.reset` set, `git reset`
  still runs the builtin (Q1).
- No hook fires *before* the data is gone. `restore` / `checkout -- f` only
  fire `post-checkout`; `clean -f` fires no hook at all (Q2). Even for
  `reset --hard`, at the earliest hook (`reference-transaction preparing`) the
  file on disk already holds the reset content (Q2b).
- So the only interception point is a program named `git` placed ahead of the
  real one on `PATH`, which snapshots and then `exec`s the real git with the
  exact same argv.
- The snapshot recipe (copy the index to a temp file, `add -A` into the copy,
  `write-tree`) leaves the real index and working tree byte-identical (Q3).

Re-run `dev/measure-premise.sh` after a git upgrade; the answers are git's.

## Components

```
~/.local/share/git-salvage/bin/git      <- the shim (install puts it here;
        |                                  user prepends this dir to PATH)
        |  1. parse global options + subcommand
        |  2. destructive? -> "$REAL_GIT" <globals> salvage _pre <argv...>
        |  3. exec "$REAL_GIT" "$@"   (always, unchanged argv)
        v
git-salvage (on PATH, reached through real git's external-command dispatch,
             so -C / --git-dir / --work-tree / -c are already applied)
```

- `bin/git-salvage` -- bash, **must run on macOS's bash 3.2** (no `declare -A`,
  no `${x,,}`, no `mapfile`, no `|&`). All user-facing subcommands.
- `shim/git` -- bash, same constraint. Kept as small as possible: it runs on
  every git invocation, including an IDE's status polling.
- Recursion guard: git-salvage exports `GIT_SALVAGE_ACTIVE=1`; the shim, seeing
  it, immediately execs the real git with no parsing. Every `git` call inside
  git-salvage therefore reaches real git even though the shim is on PATH.
- git itself prepends its exec-path (`libexec/git-core`, which holds a `git`)
  to PATH before running an external command (measured). So git-salvage's own
  git calls reach real git even without the guard, and `doctor` skips that
  PATH entry.
- Finding real git (shim): `GIT_SALVAGE_REAL_GIT` if set (and not the shim
  itself); otherwise the first
  executable `git` on PATH whose resolved directory is not the shim's own
  directory. If none is found, print `git-salvage: cannot find the real git on
  PATH` and exit 1.

## Storage format

One ref per snapshot: `refs/salvage/<id>`,
`id = <10-digit epoch>-<6-digit seq>-<10-digit pid>`, so that
`for-each-ref --sort=-refname` is newest first. `seq` is one past the seq of
the newest ref from the same second (0 if none), so the order within one
second does not depend on pids, which can wrap. The pid only keeps two
concurrent processes that pick the same seq from colliding. Refs under
`refs/salvage/` are local only: neither `push` nor `clone`/`fetch` touch them
by default.

Each ref points at a commit made with `git commit-tree`, **with identity forced
to `git-salvage <git-salvage@localhost>`** (author and committer, via env), so
a missing `user.name` can never make a snapshot fail.

| kind | tree of the commit | parents | trailers in message |
|---|---|---|---|
| `worktree` | `worktree/` = tree of index+worktree+untracked, `index/` = tree of the real index (omitted when the index has unmerged entries) | HEAD commit, if HEAD exists | `Salvage-Kind: worktree`, `Salvage-Head: <symbolic HEAD or "detached">`, `Salvage-Index: captured\|unmerged-not-captured` |
| `branch` | empty tree | the deleted/overwritten branch tip | `Salvage-Kind: branch`, `Salvage-Ref: refs/heads/<name>` |
| `stash` | empty tree | the stash commit being dropped | `Salvage-Kind: stash`, `Salvage-Ref: stash@{n}` at record time |

The first line of the message is the command that triggered it, e.g.
`git reset --hard` (or the text given to `git salvage snapshot -m`).
The parents are what keep the saved objects reachable, so `git gc` cannot
collect them while the ref exists.

### Worktree snapshot recipe

```
tmp=$(mktemp)                      # inside $GIT_DIR, removed by trap
cp "$GIT_DIR/index" "$tmp"         # absent index (fresh repo) -> start empty
GIT_INDEX_FILE=$tmp git -c advice.addEmbeddedRepo=false add -A [-f]
T_w=$(GIT_INDEX_FILE=$tmp git write-tree)
cp "$GIT_DIR/index" "$tmp"; T_i=$(GIT_INDEX_FILE=$tmp git write-tree)  # may fail: unmerged
```

- `-f` (include ignored files) only when the triggering command will delete
  ignored files: `clean` with `-x` or `-X`.
- A 0-byte `GIT_INDEX_FILE` is an error ("index file smaller than expected"),
  so with no real index the temp file is deleted and git starts from none.
- Run from the work-tree top level so `add -A` covers the whole tree.
- **Skip (no ref, no output)** when there is nothing uncommitted:
  `T_w == T_i == HEAD^{tree}` (unborn HEAD: both equal the empty tree).
  Untracked files only count as uncommitted for commands that can delete
  them: `clean`, `reset --hard`, `checkout -f/--force`,
  `switch -f/--force/--discard-changes`. Otherwise every branch switch with an
  untracked file lying around would print a new snapshot. `git salvage
  snapshot` and restore's own pre-restore snapshot always count them. When a
  snapshot is taken, it always contains the untracked files.
- **Skip** when `T_w`/`T_i` equal those of the newest existing worktree
  snapshot (repeated command on an unchanged tree).
- Bare repository, or not inside a repository: no snapshot; the command runs
  and git reports whatever it reports.

### Global options in the shim (measured, `dev/measure-globals.sh`)

- `-C`, `-c` take the next word. `--git-dir`, `--work-tree`, `--namespace`,
  `--config-env`, `--attr-source` take `=value` or the next word.
- `--exec-path` (no `=`), `--html-path`, `--man-path`, `--info-path`,
  `--list-cmds=`, `-v`/`--version`, `-h`/`--help` run no subcommand: exec at
  once.
- `-p`, `-P`, `--paginate`, `--no-pager` are not passed on to `_pre`; all other
  globals are, so `_pre` sees the same repository as the command.
- `_pre` runs with stdin from `/dev/null`: the command may still need stdin
  (`reset --pathspec-from-file=-`).

## Which commands trigger what

Detection works on the argv after global options, and after expanding **one
level** of a non-`!` alias (`git config --get alias.<cmd>`, split on
whitespace). The alias lookup is skipped for a hardcoded list of common
non-destructive builtins (`status log diff show add commit fetch push pull
rev-parse ls-files cat-file config remote tag describe blame grep` and so on),
so an IDE's polling costs no extra process. Any argument `-h`/`--help` -> no
snapshot. An argument after `--` is never read as an option.

| command | trigger | kind |
|---|---|---|
| `reset` | anything except `--soft` | worktree |
| `checkout` | always | worktree |
| `restore` | always | worktree |
| `switch` | `-f`, `--force`, `--discard-changes`, `-m`, `--merge` | worktree |
| `clean` | unless `-n`/`--dry-run` (with `-x`/`-X`: include ignored) | worktree |
| `rm` | `-f`/`--force` | worktree |
| `merge` `rebase` `cherry-pick` `revert` `am` | `--abort` or `--skip` | worktree |
| `stash drop [<s>]`, `stash pop [<s>]` | always | stash (the entry being removed; default `stash@{0}`) |
| `stash clear` | always | one stash record per entry |
| `branch -d/-D/--delete <names>` | always (`-r`: `refs/remotes/`) | branch, one per existing name |
| `branch -M/-C <old> <new>`, or `-m/-c` with `-f` | when `<new>` exists | branch (old tip of `<new>`) |

Plain `-m`/`-c` refuse an existing `<new>` (exit 128, measured), so they
record nothing without `-f`.

Over-triggering is cheap (the skip rule makes a clean tree cost one `add -A`);
under-triggering loses data. When in doubt, trigger.

## Failure policy: fail closed

If a snapshot that *should* be taken fails, the destructive command does
**not** run:

```
git-salvage: could not save a snapshot (<reason>); 'git reset --hard' was not run.
git-salvage: set GIT_SALVAGE_SKIP=1 to run it without a snapshot.
```

exit 1. `GIT_SALVAGE_SKIP=1` makes the shim exec real git with no snapshot.
A skipped snapshot (nothing to save) is not a failure.

An unrecognised global option: the shim cannot know where the repo is, so it
prints `git-salvage: unrecognized option '<opt>', no snapshot taken` to stderr
and execs real git.

## Output

- On a saved snapshot, one stderr line:
  `git-salvage: saved snapshot 1 (undo with: git salvage restore 1)`.
  `GIT_SALVAGE_QUIET=1` or `salvage.quiet=true` suppresses it.
- Otherwise the shim adds nothing: real git's stdout, stderr and exit code
  reach the caller unchanged, because the shim `exec`s it.

## User commands

Snapshots are numbered 1 = newest, in `list` order.

- `git salvage list` -- `N  YYYY-MM-DD HH:MM:SS  <kind>  <command>`; for
  worktree kind also the number of changed paths vs. the HEAD it was taken on.
- `git salvage show N [--stat | -p]` -- worktree: diff from the HEAD it was
  taken on to its `worktree/` tree (default `--stat`); branch/stash: the ref
  and the commit it saved.
- `git salvage restore N [-- <path>...]`
  - worktree: first takes a snapshot of the current state (message
    `restore of <id>`), then writes the files of `worktree/` back into the
    working tree **without deleting anything** and **without touching the
    index**: `GIT_INDEX_FILE=<tmp> read-tree`, then `checkout-index -f -a` (or
    the given paths). Symlinks and the executable bit come back as saved.
    Without paths, `checkout-index` runs from the top level: from a
    subdirectory it would only write that subtree (measured). `checkout-index`
    takes no directories, so `-- <path>` is expanded with `ls-files -z`
    against the snapshot; paths are relative to the current directory.
  - `--index` additionally loads `index/` as the real index (refuse if that
    snapshot has `Salvage-Index: unmerged-not-captured`).
  - branch: `git branch <name> <tip>`; refuse if the branch exists.
  - stash: `git stash store -m <original message> <commit>`.
  - The snapshot is kept after a restore.
- `git salvage snapshot [-m <msg>]` -- take one by hand.
- `git salvage drop N`, `git salvage prune [--keep K] [--older-than DAYS]`.
- Automatic retention: after each new snapshot, keep the newest
  `salvage.keep` (default 200) and delete older refs.
- `git salvage install [--dir D]` -- copy the shim to
  `~/.local/share/git-salvage/bin/git` (or D), and `git-salvage` and
  `git-salvage-view.html` beside it, and print the one `PATH` line to add to the shell profile. One PATH entry
  then reaches both: real git finds `git-salvage` through PATH for
  `git salvage`. Install refuses to overwrite a `git` in D that is not the
  shim. `git salvage uninstall` removes the three files. `git salvage
  doctor` reports: which `git` is first on PATH, whether it is the shim, and
  the real git it resolves to.

## The view page (`git salvage view`)

```
git salvage view [-o <file>] [-n <max-commits>] [--no-open]
```

Writes one self-contained HTML file (default `$GIT_DIR/salvage-view.html`,
so it is never tracked), prints `wrote <path>`, and opens it: `open` on
macOS, else `xdg-open` if present, else it only prints. `--no-open` never
opens. No server, no network: the page loads nothing from outside.

**Read-only.** It changes no ref, no file in the working tree, and not the
index: status runs as `git --no-optional-locks status`, which does not write
back the refreshed index. Needs a work tree (same rule as the other commands).

### Why the reflog, not the shim

The timeline comes from git's own reflogs plus `refs/salvage/`, not from the
shim. The shim `exec`s real git, so it no longer exists when the command ends
and cannot see the after-state without giving up `exec` (and with it the
transparency rule). The reflog already has, for every ref move, the new id,
the time and a message naming the command -- also for commits made by tools
that bypass the shim. The commands that move no ref (`restore`, `clean`,
`checkout -- f`, `stash drop`) are exactly the ones that leave a snapshot,
and a snapshot's subject is the command. Measured (`dev/measure-reflog.sh`,
git 2.55.0 on macOS; items marked 2.43.0 were measured on Linux, where the
Q1 messages, Q2 and Q4 also match -- the Q1 locale comparison was not run
there):

- Reflog messages are not localized: the same history under `zh_TW.UTF-8` and
  `C` gives identical messages (Q1).
- One `git log -g <ref>...` walks several reflogs merged newest first; `%gD`
  with `--date=unix` prints `<full refname>@{<unix time>}`; `-n` caps the
  total (Q2). A ref that does not exist is fatal (exit 128), and so is `HEAD`
  on an unborn branch; a ref with no reflog is silently skipped.
- A deleted branch's own reflog is deleted with it; `HEAD`'s keeps the
  entries (Q4).
- `pull` writes its whole argv into the message (`pull -q --rebase origin
  main (start): ...`), and a rebase writes `(start)`, `(pick)`, `(finish)`.
- More messages (Q5): `Branch: renamed refs/heads/b to refs/heads/b2`
  (capital `B`), `rebase (abort): returning to refs/heads/b2`,
  `commit (merge): Merge branch 'b2'` (a merge concluded by `commit` after a
  conflict), `clone: from <path>`, `pull -q --ff-only: Fast-forward` (and
  `...: fast-forward` on the remote ref; measured on git 2.43.0). `git stash` writes
  `reset: moving to HEAD` to `HEAD`'s reflog.
- A reflog entry whose commit is on no branch expires after 30 days by
  default: dated 29 days ago it is kept, 31 days ago `reflog expire` prunes
  it (Q6, git 2.43.0). The page says so for left-behind commits.

### Data handed to the page

bash collects everything with a fixed set of git calls (no per-commit or
per-ref process), writes it as lines of NUL-separated fields, base64-encodes
the whole, and substitutes it for the line `@@SALVAGE_DATA@@` of the template
`bin/git-salvage-view.html` (installed next to `git-salvage`). base64 means no
subject, path or ref name can break out of the page, whatever it contains.
Fields never contain NUL or newline: git formats `%s` and reflog messages as
one line, status quotes unusual paths, and a newline in the repo's directory
name is replaced by a space.

| tag | fields | source |
|---|---|---|
| `V` | format version (`1`) | |
| `M` | repo directory name (a newline in it becomes a space), generated unix time, `git --version` | |
| `H` | symbolic HEAD ref (empty if detached), HEAD commit (empty if unborn) | `symbolic-ref -q`, `rev-parse` |
| `S` | one line of status | `--no-optional-locks status --porcelain=v2 --branch --show-stash` |
| `R` | refname, object, peeled commit (annotated tags), upstream, track | `for-each-ref refs/heads refs/remotes refs/tags` |
| `C` | commit, parents (space-separated), committer unix time, author name, subject | `log --date-order -n <max>` from HEAD, all branches, remotes, tags and the reflog ids below that still exist (`cat-file --batch-check`) |
| `L` | `%gD`, new commit, message | `log -g -n 300 --date=unix` over HEAD (if born), `refs/heads/*`, `refs/remotes/*` |
| `P` | refname, commit, unix time, subject, parents (space-separated), the `Salvage-Kind`, `Salvage-Ref` and `Salvage-Head` trailers as `Key: value` separated by U+001F | one `for-each-ref --sort=-refname refs/salvage/` |

The trailers come from a single `%(trailers:key=...,key=...)` atom: with one
atom per key in the same format, git 2.43 applies the union of all their keys
to each atom (measured, Q3; not yet measured on 2.55, and one atom is right
either way), so a kind would read `worktree,refs/heads/main`.
`P` records carry no number: they come newest first, and the page numbers
them by that order (1 = newest), the same numbers as `git salvage list`.

`-n` defaults to 300 commits and caps only the `C` records (the reflogs have
their own fixed cap of 300 entries). It takes 1 to 9 digits, so bash
arithmetic cannot wrap; git reads a leading zero as decimal anyway (`-n 010`
is 10, measured on git 2.43.0). The reflog ids are included so that commits a
`reset` or `rebase` left behind are drawn (greyed) next to the ones that
replaced them.

### What the page shows

1. **Where you are**, one sentence: the branch (or "detached at <id>"),
   ahead/behind its upstream, and what is uncommitted.
2. **The three areas**: HEAD commit -> index (staged) -> working tree
   (modified, untracked, conflicted), with counts, and which command moves
   changes between them (`add`, `commit`, `restore`, `restore --staged`).
3. **The graph**: commits in date order with lanes, labels for local
   branches, remote branches, tags and HEAD. A commit reachable from no ref
   and no HEAD (only from the reflog) is drawn greyed, "left behind".
4. **The timeline**, newest first: reflog entries and snapshots merged by
   time. A branch entry with the same time, new id and message as a `HEAD`
   entry is the same event (a commit moves both) and is shown once, naming
   the branch; two equal `HEAD` entries stay two events, each taking at most
   one entry per branch. The event is explained for its local branch if it
   moved one (a clone also moves the remote ref). A `HEAD` entry with no
   branch entry is not called "detached": a deleted branch's reflog is gone
   (Q4), a branch may have no reflog, and the 300-entry cap on the reflogs
   (one cap over all refs, Q2) may cut its entry off; the
   text then says only what HEAD did. Each event gives the command, a plain-words explanation, and
   before -> after ids (before = the same ref's next-older entry). Selecting
   an event highlights both commits in the graph. When "before" is left
   behind, the event says so and gives `git branch <name> <id>` to get it
   back. A snapshot event gives `git salvage restore <n>`.

Explanations are chosen by the message's action, the text before the first
`: ` with a trailing ` (start|pick|finish|...)` and `pull`'s argv peeled off:
`commit`, `commit (initial|amend|merge)`, `checkout` (`moving from A to B`;
the message alone cannot tell a branch B from a tag or a commit, so B counts
as a branch only when it is in the list of local branches from the `R`
records),
`reset` (`moving to X`), `merge <x>` (`Fast-forward` or a merge commit),
`rebase`/`pull --rebase` (start, pick, finish, abort), `pull`,
`cherry-pick`, `revert`, `branch` (`Created from`, `Reset to`), `Branch` (`renamed`),
`fetch`/`update by push` (remote refs), `clone`. Anything else is shown
with its raw message and no explanation -- never a guessed one.

### Testing the page

bash side, in `tests/run.sh`: decode the embedded data and check its records
against the real git; the repo is unchanged (refs, index bytes, work tree);
a subject containing `</script>`, quotes and non-ASCII survives; unborn HEAD,
detached HEAD and no reflog work. Page logic (parsing, lanes, explanations,
event merging) is plain functions between `BEGIN LOGIC` / `END LOGIC` in the
template, run by `tests/view-test.js` under `node`, or `osascript -l
JavaScript` on macOS (no node there by default). The logic avoids browser-only
APIs; only the decoding and drawing code outside the markers uses them.

## Coverage limits (documented, not bugs)

- Anything that runs git by absolute path (`/usr/bin/git`), or through a
  library (libgit2, JGit, go-git), bypasses the shim. IDEs usually look git up
  on PATH, but some have a "git path" setting or bundle their own git.
- Not covered: `worktree remove --force`, `checkout-index -f`, `read-tree -u`,
  `gc --prune=now`, `reflog expire`, and plain file operations outside git
  (`rm`, an editor overwriting a file).
- Hooks run by git reach real git, not the shim: git puts its exec-path in
  front of PATH (see "Components"). A hook that runs `git reset --hard` is
  not caught.
- A second *copy* (not a symlink) of the shim later on PATH is taken as the
  real git. It still works; `_pre` just runs twice, and the same-state skip
  stops a second ref. Detecting it would mean reading the real git binary on
  every call.
- Nested repositories inside untracked directories are recorded as gitlinks;
  their contents are not saved.
- Snapshots keep large untracked files alive until pruned.

## Testing

`tests/run.sh` (bash) is the only test entry point; CI runs it on ubuntu and
macOS plus `shellcheck`. Oracle = the real git: every destructive case asserts
(1) the work is gone after the command, (2) `restore` brings it back
byte-for-byte; every transparency case runs the same command through the shim
and through real git in twin repos and compares stdout, stderr (minus the one
salvage line) and exit code.

Known timing quirk (macOS, not fixed): the first exec of a freshly copied
script costs 0.35-0.7 s (the OS scans it). One run stalled ~2 min in
`env bash <new file>` ("install from an installed copy") while the machine
was under load; not reproducible.
