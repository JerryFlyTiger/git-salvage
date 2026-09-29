# git-salvage

A PATH shim + `git salvage` subcommand that snapshots uncommitted work before
destructive git commands. Spec: `docs/DESIGN.md` (source of truth -- if code
and spec disagree, stop and report, do not silently pick one).

## Rules

- **bash 3.2 compatible** (macOS `/bin/bash`): no `declare -A`, `mapfile`,
  `${x,,}`, `|&`, `;&`. Test with `/bin/bash`, not a brew bash.
- **The shim is transparent**: it must `exec` the real git with the unmodified
  argv. Its only permitted output is the one `git-salvage:` stderr line.
- **Fail closed**: a snapshot that should be taken and fails blocks the
  destructive command (exit 1), never silently lets it run.
- Every `git` call inside `bin/git-salvage` runs with `GIT_SALVAGE_ACTIVE=1`
  so it never re-enters the shim.
- Measure git's behaviour, never recall it. Oracle scripts go in `dev/`.
- Local git is zh_TW-localized: set `LC_ALL=C` in every test and oracle.

## Verification (completion criteria)

```bash
bash tests/run.sh          # prints "tests: N/M passed"; N must equal M
shellcheck bin/git-salvage shim/git tests/run.sh
```

Read the `N/M` line itself; a smaller M means a section aborted.
After adding a test, prove it can fail (mutate the code, see it red).

`dev/mutate.sh` runs the mutation battery; a full run rewrites the committed
`dev/mutate-results.txt`. A SURVIVED mutation is one of three things. Name
which one before acting, because only the first needs a test:

- **Blind spot**: nothing tests that behaviour. Add a test whose oracle is
  the real git, then see the mutation KILLED.
- **Redundant guard**: a later layer already stops the same input. Check
  both that the result is the same and that nothing on the way (a file
  write, a git call, a ref update) runs on input the guard used to stop.
  Only then delete the guard or move the mutation to the real defence.
- **Unobservable / equivalent**: the mutated code behaves the same
  (for example, git unquotes what it quoted). Measure it, then drop the
  mutation with a `# Not listed:` note in `dev/mutate.sh` that says what
  was measured.

TIMEOUT, ABORTED and SYNTAX prove nothing about the named check. Rerun or
fix the mutation; never count them as KILLED.
