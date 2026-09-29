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
declined: none. Round 3 cold read: no findings. Committed 7c96e77.

## Resume here (2026-09-29)

M2 done: numbers and the no-pre-check decision are in DESIGN.md ("Cost on
large repos"). `dev/measure-perf.sh` and `dev/measure-shells.sh` now skip an
installed shim when looking for the real git (both took the first `git` on
PATH). Cold read: 4 rounds. Declined: `for d in $PATH` drops a
trailing empty entry, so a trailing `:` never looks in `.` (same as
`shim/git`, pre-existing; a leading or middle empty entry is still checked as
`.`). A second line matching `SHIM_MARKER="..."` in bin/git-salvage would
make MARKER two lines, and `grep -F` then matches either one (measured):
wider, not broken. No such line exists.

M3 done. Cold read: no bugs. Declined, all pre-existing: `check ... >/dev/null`
also hides the FAIL line; `dev/mutate.sh` calls bare `timeout` (no
`gtimeout` fallback); `dev/mutate.sh`'s own logic has no automated test.
Its new TIMEOUT / WARNING / results-file logic was exercised by hand instead:
`MUT_TIMEOUT=5` gives TIMEOUT plus the WARNING and leaves
`dev/mutate-results.txt` untouched under a filter; with the rc=124 branch
removed the same run reports ABORTED. Next: M4.

## M2: large-repo cost

Every destructive command runs a full-tree `git add -A` into a temp index,
even when the result is "nothing to save".

- [x] `dev/measure-perf.sh`: snapshot cost at 10k and 100k files.
      Measured 2026-09-28 (Apple M4, git 2.55.0, ms median of 5, real / shim):
      1k: status 26/14, reset clean 11/173, reset dirty 20/178, checkout -- f 8/166;
      10k: 22/27, 39/206, 29/219, 13/152;
      100k: 131/136, 235/583, 252/730, 36/492.
      Pass-through cost is noise; a destructive command costs 140-190 ms more
      than real git up to 10k files, and 350-480 ms more at 100k. Decision: no pre-check (it would itself cost a
      `git status`, ~130 ms at 100k, and a wrong answer skips a snapshot).
- [x] Record the numbers in DESIGN.md.
- [ ] (not done, decided against) Only if too slow: a cheaper "anything uncommitted?" pre-check that
      also sees untracked files, proven equal to the current skip rule by an
      oracle before it replaces anything.

## M3: tests and evidence

- [x] Round-trip file names with an embedded newline, tab and double quote
      (and backslash): full restore, `restore -- <name>`, `list`'s count.
      Measured: without `-z`, `checkout-index --stdin` unquotes ls-files'
      `"a\nb"` lines, so dropping `-z` on both sides is equivalent (noted in
      `dev/mutate.sh`); dropping it on ls-files only, or splitting on
      newlines, is KILLED.
- [x] `dev/mutate.sh` keeps its results (`dev/mutate-results.txt`, committed).
- [x] Check `JOBS` x slowest mutation against the per-mutation timeout:
      each run's time is recorded; a timed-out run is TIMEOUT (was ABORTED);
      the summary prints the slowest and warns past half of `MUT_TIMEOUT`.
      Solo suite run: 49 s; full battery 83/83 KILLED, slowest run 57 s at
      JOBS=4 against a 300 s timeout (Apple M4, 10 cores, git 2.55.0).
- [x] CLAUDE.md: classify a SURVIVED mutation as blind spot, redundant guard
      or unobservable (from Small_Git).

## M4: small

- [ ] Typo suggestion for an unknown `git salvage <sub>`.
- [ ] DESIGN.md: why a plain `merge` / `rebase` start takes no snapshot
      (only uncommitted work is protected; `--abort` / `--skip` are caught).
