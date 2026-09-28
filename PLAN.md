# PLAN: v0.2 `git salvage view` (in progress)

User asked (2026-09-25) for a GUI that helps people see their branches and how
git works, carried over from Small_Git's "CLI/UX confusion" pain point. Agreed
direction: a local HTML page with a command timeline, inside git-salvage (not
a separate project). The user authorized the whole thing; keep going without
asking.

## Decisions already made (all in docs/DESIGN.md "The view page")

- Timeline comes from git's reflog + `refs/salvage/`, NOT from the shim: the
  shim `exec`s real git and cannot see the after-state without breaking the
  transparency rule.
- One self-contained HTML file, data base64-embedded at the line
  `@@SALVAGE_DATA@@` of `bin/git-salvage-view.html` (installed beside
  `git-salvage`). Default output `$GIT_DIR/salvage-view.html`.
- Page text is English (the project is English).
- JS logic between `// BEGIN LOGIC` / `// END LOGIC` is pure (no DOM, no
  atob/TextDecoder) so tests can run it under `node` or
  `osascript -l JavaScript` (macOS has no node here). Measured on this Mac:
  JXA supports ES6 (arrow, template, Map, spread); `atob`/`TextDecoder` are
  undefined; `console.log` goes to stderr, the script's final expression
  value goes to stdout.

## Status (2026-09-27, end of the cloud session)

Steps 1, 2, 3, 5, 6 of the list below are done in the cloud session on
`v0.2-view`; **step 4 is next, on the Mac**. Not merged to main.

Commits on `v0.2-view` after main (df0b155):

| commit | what | cold-read |
|---|---|---|
| 8c7fa2b | WIP: page, oracle, DESIGN section | round 1 |
| 10ef3b3 | tests (JS + bash), README, CI, P-trailer fix, shellcheck fix | round 1 |
| 319ad5e | round-1 fixes | round 2 |
| 5fd6564 | round-2 fixes | round 3 |
| b870a95 | round-3 fixes | round 4: no high/medium findings, no code changed after it |
| (this one) | PLAN.md only | not reviewed (notes, no code) |

**Unreviewed code: none.** Any change made in step 4 is a new batch and
needs its own reviewer pass (tail diff from the last commit here).

CI on b870a95 (run 10): ubuntu, macos (bash 3.2 + `osascript -l
JavaScript`, checked by the "view js runtime" step) and shellcheck all
green. Local (Linux, git 2.43.0, as a non-root user): `tests: 341/341
passed`, shellcheck clean, `dev/mutate.sh` 66/66 KILLED.

Notes for the Mac:
- The container runs as root, so the chmod-based fail-closed tests fail
  there (6 of them); run the suite as a normal user. Not an issue on the Mac.
- A headless Chromium smoke test (not step 4) loaded a generated page at
  390 px wide: no JS errors, no horizontal scroll, a subject with
  `<img onerror>` shown as text, Enter selects a timeline item.
- Real bug found and fixed: on git 2.43 several `%(trailers:key=...)` atoms
  in one for-each-ref format get the union of their keys (oracle Q3).
- 2026-09-28: the user ran `dev/measure-reflog.sh` on the Mac (git 2.55.0,
  at e2f7326). Recorded in DESIGN.md: Q3 atoms are independent on 2.55.0
  (the union is a 2.43 behaviour; one atom is right on both); Q2 (`-n 010`
  = 10, missing ref / unborn HEAD exit 128, `-n` is a total), Q5 ff pull and
  Q6 (29 days kept, 31 pruned) match 2.43.0. New on 2.55.0: the 31-day Q6
  run also prunes `commit (initial): kept`, a still-reachable commit's
  entry; reason not measured, the page's claim is unaffected. That commit
  changed docs and comments only (DESIGN.md, PLAN.md, a dev/mutate.sh
  comment): not cold-read.

Review findings recorded, not fixed (with reason):
- Layout: a parent outside the loaded window keeps its lane to the bottom
  of the graph (history continues past the window). Intended; pinned by a
  test.
- Many explain() test needles are the page's own wording; behaviour tests
  (detached / HEAD-only, reset without "left behind", unknown messages)
  were added instead of rewording them.
- Timeline `li` has tabindex + Enter/Space + `aria-current` when
  selected, but no role (role=button broke list semantics). Revisit in
  step 4 if keyboard/screen-reader use matters.
- Oracle Q2 `-n 010` header does not say "10 8 = decimal", and needs main
  to keep >= 10 commits (it has ~13). Output seen: `10 8`.
- `M` record: a newline in the repo directory name becomes a space; other
  control characters in the name are kept (fine: base64 carries them).

## Remaining, in order (original list; 1-3, 5, 6 done)

1. DESIGN.md fixes:
   - `P` record has no number field; the page numbers snapshots by order
     (1 = newest). Fields: refname, commit, unix time, kind, subject,
     parents, Salvage-Ref/Salvage-Head.
   - Add Q5 measured messages: `Branch: renamed refs/heads/b to refs/heads/b2`
     (capital B), `rebase (abort): returning to refs/heads/b2`,
     `commit (merge): Merge branch 'b2'`, `clone: from <path>`,
     `reset: moving to HEAD` is what `git stash` writes.
   - checkout explanation uses the list of local branches (message alone
     cannot tell branch from tag/commit).
2. `tests/view-test.js` + hook into `tests/run.sh`: concatenate the LOGIC
   block and the test file, run with node, else `osascript -l JavaScript`;
   each test prints `ok <name>` / `not ok <name>`, plus a final `done <N>`
   line that run.sh requires. Cover: parseData, parseStatus (types 1/2/u/?,
   paths with spaces, branch.ab), buildEvents (HEAD+branch merge, old ids,
   snapshot ordering within a second), explain (every measured message; an
   unknown one gives text null), layout (linear, branch+merge, merge whose
   parent already has a lane: passing lane keeps its bottom segment),
   reachable, whereSentence (unborn, detached, ahead/behind, gone upstream).
3. bash tests in `tests/run.sh` for `view`: decoded data vs real git; repo
   unchanged (refs, index bytes, work tree); special-char subject; unborn
   HEAD; detached HEAD; `-n` limit; bad args; install copies the template
   and uninstall removes it (existing test "uninstall: files gone" should
   also check the template).
4. Open the page in a browser (Claude in Chrome) on a realistic repo; fix what
   looks wrong.
5. README section + CI (ubuntu has node; macOS runner has osascript).
6. Mutation-prove new tests; reviewer loop (read-only reviewer: see memory
   `reviewer-deleted-foreign-tmpdir` for the exact prohibitions); commit.

Remember: implementation and tests must be done in the main conversation
(memory `subagents-blocked-by-git-guard`).

## Cloud handoff (2026-09-27)

Work moves to a Claude Code cloud session (Linux) on branch `v0.2-view`.
The user's global rules and hooks live in `~/.claude` on their Mac and are
NOT present in the cloud, so the ones that matter are copied here.

- **Unreviewed batch**: the first commit on `v0.2-view` ("WIP: unreviewed")
  was never cold-read. The reviewer loop must cover it before merging to main.
- **bash 3.2**: Linux `/bin/bash` is 5.x, so local runs do not check 3.2
  compatibility. The gate is the CI `macos-latest` job; push and read its
  result (both CI jobs must be green). The same job is the only check of the
  `osascript -l JavaScript` fallback.
- **Step 4 (open the page in a browser) stays on the Mac.** Do steps 1, 2, 3,
  5, 6 in the cloud, then stop and write where to resume.
- **No git-guard hook in the cloud**, so subagents can implement and run tests
  here (the Mac-only rule "implementation in the main conversation" does not
  apply). Still: an implementer task must fit ~60 tool calls; write build and
  test output to a file and read only FAIL/error lines.
- **Reviewer loop**: after implementing, `git add -A`, hand the diff to a
  read-only reviewer whose job is to refute the change and report every
  finding with a confidence level. Fixes made after the reviewer read the
  diff are a new unreviewed batch: send only that tail diff, repeat until the
  tail is empty. Findings not fixed are recorded here with the reason.
- **Reviewer prohibitions** (it once `rm -rf`'d a directory it guessed was its
  own): read and reason only; no command that writes, deletes or creates
  (rm, mktemp, git init, touch, `>`); do not run tests/ or dev/ scripts.
  Anything that needs running is done by the main conversation.
- **Isolate git config in tests and oracles**: `HOME` alone is not enough;
  `export HOME=<tmp> XDG_CONFIG_HOME=<tmp>/.config GIT_CONFIG_NOSYSTEM=1`.
  A "no identity" test also needs `user.useConfigOnly=true`.
- **No leftover processes**: nothing may outlive a task (`nohup`, `&`,
  `until`/`while` polling, `tail -f`, `watch`). Anything that may hang gets
  `timeout`. No interactive editors (`git difftool`, `rebase -i`, `less`).
- Reply to the user in Traditional Chinese; report progress as statements,
  not questions.
