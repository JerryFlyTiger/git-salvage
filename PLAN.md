# git-salvage -- working plan (handoff file; delete when v0.1 ships)

## Status (2026-09-23)
- Done: dev/measure-premise.sh (premise holds: PATH shim is the only
  interception point), docs/DESIGN.md, CLAUDE.md, LICENSE,
  bin/git-salvage core (shellcheck clean), tests/run.sh for the core:
  now 120/120 under /bin/bash 3.2.
- Step 1 done: dev/mutate.sh (29 mutations, all KILLED). It found 11
  survivors first; fixed by new tests + strengthening weak ones. Findings:
  - tests (and dev/measure-premise.sh) leaked the user's own git config:
    git reads $XDG_CONFIG_HOME/git/config regardless of HOME. Both now set
    XDG_CONFIG_HOME inside the scratch HOME.
  - "no user identity" only bites with user.useConfigOnly=true (otherwise
    git guesses an identity); the test sets it.
  - commit-tree ignores commit.gpgSign (measured): dropping --no-gpg-sign is
    an equivalent mutation. Flag kept as a guard.
  - the "no snapshot for" loop was hidden by the same-state dedupe; each
    command now gets a fresh dirty state.
- Remote: https://github.com/JerryFlyTiger/git-salvage (public, empty, nothing pushed).

- Step 2 done: shim/git, git salvage install/uninstall/doctor,
  dev/measure-globals.sh, shim + install + transparency tests.
- Cold read round 1 (2026-09-23, whole tree): 10 findings. Fixed 2, tests
  211/211, shellcheck clean, both new mutations KILLED:
  - restore at the salvage.keep edge deleted the snapshot it was restoring
    (retention ran before read-tree "$ref:..."). Now resolved to a commit id.
  - short_arg_letters branch had -t as taking an argument: `branch -t -M a b`
    swallowed -M, no record (measured: git renames a over b, exit 0).
  Declined, with reasons:
  - --super-prefix not in the shim: git 2.55 rejects it (129, measured by
    dev/measure-globals.sh), so the fallback lets nothing destructive run.
  - install's $0 without a slash: measured, a script run via PATH gets the
    full path in $0.
  - stash_spec reads all-digit <stash> as stash@{n}: git does the same.
  - newest_worktree_ref spawns git log per ref (perf, worst case keep=200):
    not measured as a problem.
  - retention/store stderr not wrapped: retention failure must not block;
    git's own message is the diagnostic.
  - uninstall "removed X and Y" when only Y existed; restore -3 says
    "unknown option": wording only.
  - DESIGN.md lagging: already listed under "Decisions made after DESIGN.md".
- Cold read round 2 (the 64-line fix diff): no findings. Checked the same
  class for clean 'e', switch 'cC', checkout 'bB': all take an argument.
  Noted, not fixed: no test for restore --index at the keep edge (same
  resolved $ref as the tested path).

## Why the main conversation writes code here
The global `subagent-git-guard` hook blocks subagents from write-tree /
commit-tree / reset / checkout etc. -- which is the whole product and every
test. So implementation + tests run in the MAIN conversation. reviewer
(read-only) can still be dispatched. Do not edit the hook.

## Decisions made after DESIGN.md (fold into DESIGN.md before shipping)
- Untracked files only make a snapshot "worth saving" for commands that can
  destroy them: clean, reset --hard, checkout -f/--force, switch -f/--force/
  --discard-changes. Otherwise every branch switch with an untracked file
  would print a new snapshot. The snapshot still CONTAINS untracked files.
- branch -m/-c: measured, they refuse an existing target (exit 128) unless -f;
  so only -M/-C, or -m/-c with -f, record the target's old tip.
- checkout-index -a from a subdirectory only writes that subtree (measured):
  restore without paths runs it from the top level.
- A 0-byte GIT_INDEX_FILE errors ("index file smaller than expected"): with
  no real index the temp file is deleted instead.
- restore -- <paths> expands via ls-files -z (checkout-index takes no dirs).

- git prepends its exec-path (libexec/git-core, which holds a `git`) to
  PATH before running an external command (measured). So git-salvage's own
  git calls never see the shim, doctor skips that PATH entry, and hooks run
  by git bypass the shim (add to "Coverage limits").
- install copies the shim AND git-salvage into D: one PATH entry reaches
  both, and `git salvage` is found by the real git through PATH.
- shim global options follow dev/measure-globals.sh: -C/-c take the next
  word; --git-dir/--work-tree/--namespace/--config-env/--attr-source take
  `=v` or the next word; --exec-path (no =), --html-path, --man-path,
  --info-path, --list-cmds=, -v/--version, -h/--help run no subcommand ->
  exec at once; -p/-P/--paginate/--no-pager are not passed to _pre.
- shim runs _pre with </dev/null (reset --pathspec-from-file=- keeps stdin).
- A second COPY (not a symlink) of the shim later on PATH is taken as the
  real git: it works, _pre just runs twice (dedupe stops a second ref).
  Documented, not fixed (grepping the real git binary on every call costs).

## Open issues (not fixed yet)
- Ref id `<epoch>-<pid>-<n>`: within one second, "1 = newest" relies on
  pids increasing; a pid wrap inverts the order. Proposed: `<epoch>-<seq>-<pid>`
  with seq = 1 + the newest same-second ref's seq. Spec change -> DESIGN.md.
- macOS: first exec of a freshly copied script costs 0.35-0.7 s (scan). One
  run stalled ~2 min in `env bash <new file>` (tests: "install from an
  installed copy"); not reproducible, machine was under load.

## Mutation status
- Full run of dev/mutate.sh after step 2: see the line below (update it).
  LAST RUN (2026-09-23): 40/40 KILLED. Equivalent mutations left out, with
  the reason written in dev/mutate.sh: dropping --no-gpg-sign, and the shim
  ignoring GIT_SALVAGE_SKIP (_pre checks it again).
  The "REAL_GIT pointing at the shim" test runs under `bounded 10`: without
  that guard the shim execs itself forever and the suite hangs instead of
  going red.

## Next steps
1. Mutation-prove tests/run.sh against bin/git-salvage: copy the tree to a
   scratch dir per mutation, break one thing, confirm the named check goes
   red for the right reason. Minimum set: drop the `add -A` (untracked lost),
   drop `-f` for clean -x, flip the untracked-at-risk skip rule, make
   restore run checkout-index from cwd instead of TOP, remove the fail-closed
   `return 1`, drop `--no-gpg-sign`/forced identity, break retention off-by-one,
   drop alias expansion, drop `has_opt --soft`.
2. (done) shim/git + install/uninstall/doctor + shim transparency tests.
3. CI workflow (ubuntu + macos, shellcheck + tests).
4. reviewer cold read of the full diff; fix; tail-diff re-review until empty.
5. Mutation-verify the tests (main conversation).
6. README (from actual behaviour), commit, push, check CI.
