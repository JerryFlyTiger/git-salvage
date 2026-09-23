#!/usr/bin/env bash
# Measures how the real git parses its global options, which shim/git must
# mirror to find the subcommand:
#   - which options take a value, and in which form (separate word, =, both)
#   - which value-less options git accepts before a subcommand
# "accepted" = git went on to run the subcommand (exit 0, or 128 "not a git
# repository" because the value points nowhere useful); 129 = unknown option.
set -u
HOME=$(mktemp -d)
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1 HOME XDG_CONFIG_HOME="$HOME/.config"
git --version
cd "$HOME" && git init -q r && cd r || exit 1

# " ran" when the subcommand's own output (.git) came out: the option did not
# end git early (--exec-path, --html-path ... print a path and exit).
ran() { case $1 in *.git*) printf ' ran' ;; *) printf ' not-run' ;; esac; }

echo "== options with a value: exit code as '<opt> <v>' and '<opt>=<v>'"
for o in -C -c --git-dir --work-tree --namespace --config-env --attr-source \
	--exec-path --list-cmds --super-prefix; do
	case $o in
	-c) v=a.b=1 ;;
	--config-env) v=a.b=HOME ;;
	--attr-source) v=HEAD ;;
	--list-cmds) v=main ;;
	--exec-path) v=/nonexistent ;;
	--git-dir) v=.git ;;
	*) v=. ;;
	esac
	out=$(git "$o" "$v" rev-parse --git-dir 2>/dev/null)
	s1="$?$(ran "$out")"
	out=$(git "$o=$v" rev-parse --git-dir 2>/dev/null)
	s2="$?$(ran "$out")"
	printf '%-15s separate=%-10s equals=%s\n' "$o" "$s1" "$s2"
done

echo "== value-less options before a subcommand: exit code"
for o in --literal-pathspecs --glob-pathspecs --noglob-pathspecs \
	--icase-pathspecs --no-replace-objects --no-lazy-fetch --no-optional-locks \
	--no-advice --bare -p --paginate -P --no-pager --html-path --man-path \
	--info-path --bogus; do
	out=$(git "$o" rev-parse --git-dir 2>/dev/null)
	printf '%-20s %s%s\n' "$o" "$?" "$(ran "$out")"
done
