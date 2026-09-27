#!/usr/bin/env bash
# Shared bats primitives for building a PATH with a named tool absent.
#
# Sourced from a suite's `setup()`, from any bats directory. The path is
# repo-root-absolute, so what varies between call sites is only how the suite
# names its own repo root:
#
#   . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
#   . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
#
# `REPO_ROOT` is a `.gaia/scripts/tests/` convention rather than a repo-wide
# one; a suite that carries no such variable uses the second form, whose `..`
# depth is that suite's own rather than a constant to copy.
#
# This is a CROSS-DIRECTORY helper, alongside `files.sh` and
# `hook-registration.sh` and distinct from the per-suite-directory
# `.gaia/tests/lib/helpers/` and `.gaia/tests/hooks/helpers/` by REACH rather
# than by how a file there is invoked: a suite in any bats directory may source
# what lives here, while those two serve their own directory's suites, whatever
# invocation style a file in them happens to use.
#
# API:
#   path_dir_provides DIR NAME  - true when DIR/NAME is something bash's PATH
#                                 lookup would run as a command
#   path_without NAME           - print $PATH with every directory that
#                                 provides NAME removed
#   path_shim_without NAME      - print a $PATH on which NAME does not resolve
#                                 and every other command still does
#   path_allowlist NAME...      - print a $PATH of one built directory holding
#                                 just the named commands
#
# WHY THIS EXISTS, and why the obvious predicate is the bug it replaces.
#
# A suite that drives a "tool is not installed" arm has to guarantee the tool is
# absent, and cannot assume it: a real `uvx`, `specify` or `pnpm` may live
# anywhere further down a developer's PATH. Two strategies reach that guarantee,
# and both live here for the DUPLICATION reason argued below, which is
# indifferent to which of them a rule belongs to. Which one fits is decided by
# whether the subject's binary needs are enumerable.
#
# SUBTRACTIVE, for a subject whose needs are open-ended. Ask one question of
# each PATH directory, does this directory provide <name> as a command, and
# rebuild a PATH from the answer, so the host keeps providing whatever it
# provides and only the named tool goes. Two rebuild shapes exist for that
# question and both live here. Dropping each providing directory is the cheaper
# one and is right whenever the command under test needs nothing else those
# directories hold. Mirroring each providing directory into a shim of symlinks
# with the tool left out is the one to reach for when it does: on a Homebrew
# host or a Linux runner the tool shares a prefix with git, jq, bash, grep and
# cat, and dropping the directory takes all of them with it.
#
# ADDITIVE, for a subject whose needs enumerate. Build one directory holding a
# symlink to each binary the fixture names and run with that as the whole PATH.
# It asks nothing about any PATH directory, so it takes nothing from one, which
# is what makes it the right shape where the subtractive form's collateral would
# bite. The enumeration is the caller's: two callers naming different binaries
# are two subjects with different needs rather than one list that drifted, and
# this file owns the mechanism precisely so each caller's list can stay its own.
#
# A tree-wide grep for these function names answers which suites call which.
#
# The tempting way to write the question is:
#
#   [ -x "$dir/$name" ]
#
# `-x` is true for a searchable DIRECTORY named for the tool, not only for an
# executable file. So a PATH entry that merely holds a directory called `uvx`
# is treated as providing it, and the caller drops or shims an entry over a
# tool that was never there, taking every real tool that entry provides with
# it. bash's own lookup accepts a regular file that is executable, which is
# `-f` and `-x` together, and that is what `path_dir_provides` tests.
#
# The direction is safe: an over-strip removes a tool the command under test
# needs and fails it, rather than greening a test that should be red. So the
# reason this is a shared primitive rather than a fix applied twice is the
# DUPLICATION. A rule with two homes gets repaired in one of them, and the copy
# nobody edited has nothing red to catch the drift, so the two disagree with no
# gate anywhere between them. Two homes for one rule is the condition; a single
# home is the repair. That argument is why the rebuild shapes live here too and
# not with their callers: a second caller reaching for one of them is the moment
# the condition arrives, not a later one.
#
# `.gaia/scripts/tests/bats-path-helper.bats` pins that the two builders refuse
# to write outside a bats per-test temp dir.

# path_dir_provides <dir> <name>: true when <dir>/<name> is a command bash's
# PATH lookup would accept -- a regular file with the execute bit -- and false
# for a directory of that name, a non-executable file, or nothing at all.
path_dir_provides() {
  [ -f "$1/$2" ] && [ -x "$1/$2" ]
}

# path_without <name>: print $PATH with every directory that provides <name>
# removed, order preserved and empty entries dropped. A caller assigns the
# result, either for the rest of the test (`PATH="$(path_without uvx)"`) or for
# one command (`PATH="$(path_without pnpm)" run bash "$HOOK"`).
path_without() {
  local name="$1" kept="" dir
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    path_dir_provides "$dir" "$name" && continue
    kept="${kept:+$kept:}$dir"
  done <<<"${PATH//:/$'\n'}"
  printf '%s\n' "$kept"
}

# path_shim_without <name>: print a $PATH on which <name> does not resolve and
# every other command the current $PATH provides still does. Each providing
# directory is mirrored into a shim of symlinks with <name> left out; every
# other directory is kept by its own name, so nothing is copied that does not
# have to be. A caller assigns the result the same way it assigns
# `path_without`'s, either for the rest of the test or for one command.
#
# The honest limit: this does not preserve lookup ORDER. The shim leads the
# rebuilt PATH, so a command that a kept earlier directory and a mirrored later
# one both provide resolves to the mirrored copy rather than to the one bash
# would have found. Callers here want the named tool gone with everything else
# still runnable, which that satisfies; a caller who needs true resolution order
# preserved needs a rebuild that splices each shim in at its own position.
#
# The shim lives under the bats per-test temp directory, so it is torn down with
# the test that built it and two tests cannot share one. That makes this a
# bats-only primitive, and it says so rather than writing somewhere a caller did
# not ask for: sourced outside a test, it refuses.
path_shim_without() {
  local name="$1" shim kept="" dir bin base
  if [ -z "${BATS_TEST_TMPDIR:-}" ]; then
    printf 'path_shim_without: BATS_TEST_TMPDIR is unset; this primitive needs a bats per-test temp dir\n' >&2
    return 1
  fi
  shim="$BATS_TEST_TMPDIR/path-shim-without-$name"
  mkdir -p "$shim" || return 1
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    if path_dir_provides "$dir" "$name"; then
      for bin in "$dir"/*; do
        base="${bin##*/}"
        [ "$base" = "$name" ] && continue
        # First writer wins, so among the MIRRORED directories an earlier one
        # keeps its precedence over a later one providing the same command.
        # That is the whole of the ordering this preserves, and the docblock
        # above states the limit: the shim leads, so a command that a kept
        # earlier directory and a mirrored later one both provide now resolves
        # to the mirrored copy.
        [ -e "$shim/$base" ] || ln -s "$bin" "$shim/$base" 2>/dev/null || true
      done
    else
      kept="${kept:+$kept:}$dir"
    fi
  done <<<"${PATH//:/$'\n'}"
  printf '%s\n' "$shim${kept:+:$kept}"
}

# path_allowlist <name>...: print a $PATH of exactly one directory, holding a
# symlink to the file each named command resolves to. The additive shape:
# a caller assigns the result the way it assigns the other two primitives'
# (`PATH="$(path_allowlist env bash jq)" run bash "$SCRIPT"`), and the tool it
# wants absent is absent by never being named.
#
# A name the current $PATH does not provide is skipped rather than refused. A
# caller naming both `shasum` and `sha256sum` wants whichever the host ships,
# and a stock macOS ships only the first while many Linux hosts ship only the
# second; refusing would red the suite on the host rather than on the subject.
# The safe direction is the same one `path_dir_provides` fails in: a name that
# silently does not arrive fails the command under test rather than greening it.
#
# Each call builds its own directory, so a suite whose subject needs a different
# enumeration per fixture gets one per fixture rather than the second call
# overwriting the first.
#
# bats-only, and for the same reason as `path_shim_without`: the directory lives
# under the per-test temp dir, so it is torn down with the test that built it and
# two tests cannot share one. Sourced outside a test, it refuses.
path_allowlist() {
  local dir name resolved d
  if [ -z "${BATS_TEST_TMPDIR:-}" ]; then
    printf 'path_allowlist: BATS_TEST_TMPDIR is unset; this primitive needs a bats per-test temp dir\n' >&2
    return 1
  fi
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/path-allowlist-XXXXXX")" || return 1
  for name in "$@"; do
    resolved="$(command -v "$name" 2>/dev/null)"
    # `command -v` answers a builtin, keyword or function with the bare name
    # rather than a path, and `printf` and `test` are both builtins here. Linking
    # that answer verbatim would make a relative link to nothing, which is
    # neither of the two outcomes above; the command may still exist as the file
    # a subject reaching it through `env` or `xargs` needs, so ask the PATH.
    case "$resolved" in
      /*) ;;
      *)
        resolved=""
        while IFS= read -r d; do
          [ -n "$d" ] || continue
          path_dir_provides "$d" "$name" && { resolved="$d/$name"; break; }
        done <<<"${PATH//:/$'\n'}"
        ;;
    esac
    if [ -n "$resolved" ]; then
      ln -sf "$resolved" "$dir/$name"
    fi
  done
  printf '%s\n' "$dir"
}
