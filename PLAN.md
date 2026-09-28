# v0.3 plan

Started 2026-09-28. Sources: the shell question (zsh/csh/fish users) and a
survey of Small_Git for things git-salvage can borrow. Implementation, tests
and mutations run in the main session (subagents are blocked by git-guard);
reviewer is dispatched read-only. Each milestone: `tests/run.sh` N/M all
passed, shellcheck clean, reviewer cold read, then commit.

## M1: shells other than bash

The shim and `git-salvage` run under bash via their shebang, so the user's
interactive shell only has to find the shim on PATH. To measure, not assume:

- [x] `dev/measure-shells.sh`: invoke the shim from zsh, tcsh, ksh, dash
      (and fish if present); a shell that already hashed the real git before
      PATH changed; an alias like oh-my-zsh's `grhh` (`git reset --hard`).
- [x] `install` prints the PATH line in the syntax of `$SHELL`
      (bash/zsh/ksh/sh: `export`; csh/tcsh: `setenv`; fish: `set -gx`,
      not measured); already first on PATH: `rehash` / `hash -r`; on PATH
      after the real git: move it in front.
- [x] `doctor` runs under bash and cannot see the parent shell's hash
      table: with the shim found, it says an older shell may need a new
      shell or `hash -r` / `rehash`.
- [x] README: per-shell setup, `rehash` / `hash -r` in already-open shells.

Review round 1 (staged batch): 5 findings, all fixed in round 2 --
the csh mutation broke the file's syntax (so its KILLED proved nothing;
`mutate.sh` now reports such mutations as SYNTAX); `$SHELL` unset under
`set -u`; the `-P` mutation only observable where `$TMPDIR` is a symlink
(explicit symlink test added); rehash hint for tcsh/csh/ksh kept, since S4 was
measured with `-c` only and interactive shells could not be driven; README
profile file names marked as not measured. `$SHELL` unset is not observable
here (bash refills it from the passwd entry): fixed by reading, no test.
Round 2: tests 356/356, full mutation battery 80/80 KILLED, shellcheck
clean; its cold read found no bug, 3 wording/consistency items fixed in
round 3 (DESIGN rehash wording, `/bin/bash -n` in the gate, PLAN wording);
declined: none. Round 3 is unstaged on top of the index.

M2 numbers are measured (scratchpad script, not yet in `dev/`): see M2.

## M2: large-repo cost

Every destructive command runs a full-tree `git add -A` into a temp index,
even when the result is "nothing to save".

- [ ] `dev/measure-perf.sh`: snapshot cost at 10k and 100k files.
      Measured 2026-09-28 (Apple M4, git 2.55.0, ms median of 5, real / shim):
      1k: status 26/14, reset clean 11/173, reset dirty 20/178, checkout -- f 8/166;
      10k: 22/27, 39/206, 29/219, 13/152;
      100k: 131/136, 235/583, 252/730, 36/492.
      Pass-through cost is noise; a destructive command costs ~150 ms more
      than real git up to 10k files, and 350-480 ms more at 100k. Decision: no pre-check (it would itself cost a
      `git status`, ~130 ms at 100k, and a wrong answer skips a snapshot).
- [ ] Record the numbers in DESIGN.md.
- [ ] Only if too slow: a cheaper "anything uncommitted?" pre-check that
      also sees untracked files, proven equal to the current skip rule by an
      oracle before it replaces anything.

## M3: tests and evidence

- [ ] Round-trip file names with an embedded newline, tab and double quote.
- [ ] `dev/mutate.sh` keeps its results (`dev/mutate-results.txt`, committed).
- [ ] Check `JOBS` x slowest mutation against the per-mutation timeout.
- [ ] CLAUDE.md: classify a SURVIVED mutation as blind spot, redundant guard
      or unobservable (from Small_Git).

## M4: small

- [ ] Typo suggestion for an unknown `git salvage <sub>`.
- [ ] DESIGN.md: why a plain `merge` / `rebase` start takes no snapshot
      (only uncommitted work is protected; `--abort` / `--skip` are caught).
