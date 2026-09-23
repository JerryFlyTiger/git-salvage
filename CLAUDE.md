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
