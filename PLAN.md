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

## Done (staged with `git add -A`, NOT reviewed, NOT committed)

- `dev/measure-reflog.sh` oracle (Q1-Q5). Results are in DESIGN.md except Q5.
- `docs/DESIGN.md`: new section "The view page"; install copies 3 files.
- `bin/git-salvage`: `view_data`, `cmd_view`, usage line, install/uninstall
  of the template. shellcheck clean. Smoke-tested by hand in a scratch repo:
  data decodes; `</script>`, quotes, CJK survive; the commit a `reset` left
  behind is included.
- `bin/git-salvage-view.html`: page (where-you-are sentence, three areas,
  lane graph, timeline with plain-words explanations, left-behind notes,
  snapshot undo commands). Never opened in a browser yet.

## Remaining, in order

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
