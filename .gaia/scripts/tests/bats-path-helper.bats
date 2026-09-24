#!/usr/bin/env bats
# The shared PATH primitives in .gaia/tests/helpers/path.sh.
#
# A bats suite that drives a "tool is not installed" arm on a developer machine
# where the tool really is installed needs a PATH with that tool guaranteed
# absent. The need arrived independently in suites across the tree, each with
# its own hand-rolled rebuild loop; a tree-wide grep for `helpers/path.sh`
# answers which suites are clients today. Separately, and not at every one of
# those loops, the membership test was written as `[ -x "$dir/$name" ]`.
#
# That predicate is wrong in one direction. `-x` is true for a searchable
# DIRECTORY named for the tool, not only for an executable file, so a PATH
# entry that merely holds such a directory was dropped along with every real
# tool it provides. bash's own PATH lookup accepts a regular file that is
# executable, which is `-f` and `-x` together.
#
# The direction is safe -- an over-strip removes a needed tool and fails the
# command under test rather than greening it -- so what makes this worth a
# primitive is the DUPLICATION rather than the defect. A rule with two homes
# gets repaired in one of them, and the copy nobody edited has nothing red to
# catch the drift. This file holds the single home to the standard the copies
# could not be held to: it drives the over-strip case directly, with a control
# proving the old predicate really does accept it.
#
# The same DUPLICATION argument, and not the predicate defect, is what brings
# the additive shape here too: building an allowlist directory shares no code
# with subtracting a providing directory, but it arrived as its own set of
# hand-rolled copies in the same way and drifts in the same way. Its cases sit
# at the end of this file, and what they pin is a different property, since
# there is no providing directory for them to reason about.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"

  DIR="$BATS_TEST_TMPDIR/dir"
  mkdir -p "$DIR"
}

# real_tool <dir> <name>: an executable regular file, what a real install looks
# like.
real_tool() {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/$2"
  chmod +x "$1/$2"
}

@test "path_dir_provides accepts an executable regular file" {
  real_tool "$DIR" uvx
  path_dir_provides "$DIR" uvx
}

@test "path_dir_provides rejects a searchable directory named for the tool" {
  mkdir -p "$DIR/uvx"

  # The bad case as a positive match, per the bats-assertions rule: a helper
  # that accepts this has decayed back into the `-x`-only predicate.
  path_dir_provides "$DIR" uvx && {
    echo "the helper accepts a directory named for the tool; it has decayed into the -x-only predicate" >&2
    return 1
  }

  # The control: the predicate this replaced DOES accept it, so the fixture
  # demonstrates the real defect rather than a hypothetical one.
  [ -x "$DIR/uvx" ] || {
    echo "control broken: the fixture no longer demonstrates the -x over-strip" >&2
    return 1
  }

  # And the authority both agree they are modelling: bash's own lookup.
  PATH="$DIR" command -v uvx >/dev/null 2>&1 && {
    echo "control broken: bash resolves a directory as a command" >&2
    return 1
  }
  true
}

@test "path_dir_provides rejects a regular file that is not executable" {
  : > "$DIR/uvx"
  path_dir_provides "$DIR" uvx && return 1
  true
}

@test "path_dir_provides rejects a name the directory does not hold at all" {
  path_dir_provides "$DIR" uvx && return 1
  true
}

@test "path_without drops the directory that provides the tool" {
  local holds="$BATS_TEST_TMPDIR/holds" clean="$BATS_TEST_TMPDIR/clean"
  mkdir -p "$holds" "$clean"
  real_tool "$holds" uvx

  local result
  result="$(PATH="$holds:$clean" path_without uvx)"
  [ "$result" = "$clean" ]
}

@test "path_without keeps a directory whose only match is a directory named for the tool" {
  local decoy="$BATS_TEST_TMPDIR/decoy" clean="$BATS_TEST_TMPDIR/clean"
  mkdir -p "$decoy/uvx" "$clean"

  local result
  result="$(PATH="$decoy:$clean" path_without uvx)"
  [ "$result" = "$decoy:$clean" ]
}

@test "path_without leaves a PATH on which the tool does not resolve" {
  local holds="$BATS_TEST_TMPDIR/holds" clean="$BATS_TEST_TMPDIR/clean"
  mkdir -p "$holds" "$clean"
  real_tool "$holds" uvx

  # The property both call sites actually want, asserted through bash's lookup
  # rather than through the helper's own notion of membership.
  local result
  result="$(PATH="$holds:$clean" path_without uvx)"
  PATH="$result" command -v uvx >/dev/null 2>&1 && {
    echo "the tool still resolves on the rebuilt PATH" >&2
    return 1
  }
  true
}

@test "path_without preserves the order of the directories it keeps" {
  local a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b" c="$BATS_TEST_TMPDIR/c"
  mkdir -p "$a" "$b" "$c"
  real_tool "$b" uvx

  local result
  result="$(PATH="$a:$b:$c" path_without uvx)"
  [ "$result" = "$a:$c" ]
}

@test "path_without drops empty PATH entries rather than emitting bare colons" {
  local a="$BATS_TEST_TMPDIR/a"
  mkdir -p "$a"

  local result
  result="$(PATH="$a::" path_without uvx)"
  [ "$result" = "$a" ]
}

# The shim primitive builds a directory of symlinks, so unlike the pure-builtin
# `path_without` above it needs `mkdir` and `ln` on the PATH it RUNS under. The
# fixture directory therefore leads the real PATH rather than replacing it; a
# bare fixture PATH takes the two commands the primitive itself calls away from
# it. Prepending stays hermetic for what these tests assert: a real `uvx` further
# down is mirrored out exactly like the fixture's, which is the property under
# test, and the other fixture names carry a `gaia-fixture-` prefix so no
# installed command can supply one. That prefix is doing real work rather than
# reading as decoration: a plain `mate` is TextMate's own CLI, and on a host
# that ships it the dropping-form control below would have gone red on an
# ambient binary rather than on the property it pins.
@test "path_shim_without leaves the tool unresolvable while its directory-mates still resolve" {
  local shared="$BATS_TEST_TMPDIR/shared"
  mkdir -p "$shared"
  real_tool "$shared" uvx
  real_tool "$shared" gaia-fixture-mate

  local result
  result="$(PATH="$shared:$PATH" path_shim_without uvx)"

  # The property every caller actually wants, asserted through bash's lookup
  # rather than through the helper's own notion of membership.
  PATH="$result" command -v uvx >/dev/null 2>&1 && {
    echo "the tool still resolves on the shimmed PATH" >&2
    return 1
  }
  PATH="$result" command -v gaia-fixture-mate >/dev/null 2>&1 || {
    echo "a directory-mate stopped resolving; the shim took more than the tool" >&2
    return 1
  }
  true
}

@test "path_shim_without preserves a mate that path_without would have taken" {
  # The control for this primitive's whole reason to exist. Dropping the
  # directory wholesale is the cheaper rebuild and it takes every other command
  # that directory provides, which is why a caller whose subject still needs one
  # of them mirrors instead. If this control ever passes on the dropping form,
  # the two shapes have stopped differing and one of them is redundant.
  local shared="$BATS_TEST_TMPDIR/shared"
  mkdir -p "$shared"
  real_tool "$shared" uvx
  real_tool "$shared" gaia-fixture-mate

  local dropped
  dropped="$(PATH="$shared:$PATH" path_without uvx)"
  PATH="$dropped" command -v gaia-fixture-mate >/dev/null 2>&1 && {
    echo "control broken: path_without kept a mate of the dropped tool" >&2
    return 1
  }

  local shimmed
  shimmed="$(PATH="$shared:$PATH" path_shim_without uvx)"
  PATH="$shimmed" command -v gaia-fixture-mate >/dev/null 2>&1 || return 1
  true
}

@test "path_shim_without keeps a directory that does not provide the tool, rather than mirroring it" {
  local holds="$BATS_TEST_TMPDIR/holds" clean="$BATS_TEST_TMPDIR/clean"
  mkdir -p "$holds" "$clean"
  real_tool "$holds" uvx
  real_tool "$clean" gaia-fixture-other

  local result
  result="$(PATH="$holds:$clean:$PATH" path_shim_without uvx)"
  grep -qF ":$clean" <<<"$result" || {
    echo "a directory providing nothing was not kept by its own name" >&2
    return 1
  }
  grep -qF "$holds" <<<"$result" && {
    echo "the providing directory survived on the rebuilt PATH" >&2
    return 1
  }
  true
}

@test "path_shim_without refuses rather than writing outside a bats per-test temp dir" {
  # Sourced outside a test there is nowhere sanctioned to build the shim, and
  # picking one anyway would write where no caller asked. Asserted on the
  # diagnostic rather than on the status alone: a non-zero status is also what a
  # failed mkdir at an unwritable guessed path returns, so the status cannot
  # tell the refusal apart from the accident it exists to replace.
  local out rc=0
  out="$(BATS_TEST_TMPDIR="" path_shim_without uvx 2>&1)" || rc=$?
  [ "$rc" -ne 0 ]
  grep -qF 'BATS_TEST_TMPDIR is unset' <<<"$out"
}

# The ADDITIVE primitive builds its directory instead of deriving it from the
# current PATH, so unlike the subtractive shapes above it has no notion of a
# "providing directory" to assert against. What it owes instead is the property
# that makes it the right shape for an enumerable fixture: exactly the named
# commands resolve, and nothing that merely shares a directory with them comes
# along. The fixture names carry the same `gaia-fixture-` prefix as the shim
# cases above, for the same reason -- an installed command of that name would
# satisfy an assertion the primitive had nothing to do with.
@test "path_allowlist provides the named commands and nothing else" {
  local shared="$BATS_TEST_TMPDIR/shared"
  mkdir -p "$shared"
  real_tool "$shared" gaia-fixture-wanted
  real_tool "$shared" gaia-fixture-mate

  # The control: on the ambient PATH the mate really is reachable, so the
  # absence asserted below is this primitive's doing rather than the fixture's.
  PATH="$shared:$PATH" command -v gaia-fixture-mate >/dev/null 2>&1 || {
    echo "control broken: the mate does not resolve even before the rebuild" >&2
    return 1
  }

  local result
  result="$(PATH="$shared:$PATH" path_allowlist gaia-fixture-wanted)"

  PATH="$result" command -v gaia-fixture-wanted >/dev/null 2>&1 || {
    echo "a named command does not resolve on the allowlisted PATH" >&2
    return 1
  }
  PATH="$result" command -v gaia-fixture-mate >/dev/null 2>&1 && {
    echo "a directory-mate of a named command came along; the allowlist is not one" >&2
    return 1
  }
  true
}

@test "path_allowlist skips a name the current PATH does not provide" {
  # A caller naming both `shasum` and `sha256sum` wants whichever the host
  # ships, and a stock macOS ships only the first while many Linux hosts ship
  # only the second. So an unprovided name is a host fact rather than a caller
  # error, and refusing on one would red the suite on the host instead of on
  # the subject.
  local shared="$BATS_TEST_TMPDIR/shared"
  mkdir -p "$shared"
  real_tool "$shared" gaia-fixture-wanted

  local result rc=0
  result="$(PATH="$shared:$PATH" path_allowlist gaia-fixture-wanted gaia-fixture-absent)" || rc=$?
  [ "$rc" -eq 0 ]

  PATH="$result" command -v gaia-fixture-wanted >/dev/null 2>&1 || {
    echo "the provided name was dropped alongside the unprovided one" >&2
    return 1
  }
  PATH="$result" command -v gaia-fixture-absent >/dev/null 2>&1 && {
    echo "a name the host does not provide resolved anyway" >&2
    return 1
  }
  true
}

@test "path_allowlist links a name this shell answers as a builtin to the file on PATH" {
  # `command -v printf` answers with the bare word `printf`, because bash
  # resolves it as a builtin before consulting PATH. Linking that answer
  # verbatim makes a relative link to nothing, which is neither of the two
  # documented outcomes, and a subject reaching the command through `env`
  # rather than through its own shell finds a broken link there. Both names the
  # converted callers pass that hit this, `printf` and `test`, are builtins.
  case "$(command -v printf)" in
    /*) skip "this shell answers printf with a path, so the fixture pins nothing" ;;
  esac

  # Planted rather than borrowed from the host, so the assertion pins the walk
  # rather than whether this machine ships /usr/bin/printf.
  local shared="$BATS_TEST_TMPDIR/shared"
  mkdir -p "$shared"
  real_tool "$shared" printf

  local result
  result="$(PATH="$shared:$PATH" path_allowlist printf)"
  [ -x "$result/printf" ]
}

@test "path_allowlist gives each call its own directory, so a suite can hold more than one list" {
  # The property that lets each converted caller keep its own enumeration: a
  # suite pinning two different missing-tool fixtures for the same subject
  # (a jq-absent case and a sha256-absent case, say) needs two different
  # enumerations of that subject's needs, and a primitive with one directory
  # per suite would have the second call overwrite the first.
  local shared="$BATS_TEST_TMPDIR/shared"
  mkdir -p "$shared"
  real_tool "$shared" gaia-fixture-first
  real_tool "$shared" gaia-fixture-second

  local one two
  one="$(PATH="$shared:$PATH" path_allowlist gaia-fixture-first)"
  two="$(PATH="$shared:$PATH" path_allowlist gaia-fixture-second)"

  [ "$one" != "$two" ]
  PATH="$one" command -v gaia-fixture-second >/dev/null 2>&1 && {
    echo "the second call's name leaked into the first call's directory" >&2
    return 1
  }
  PATH="$two" command -v gaia-fixture-first >/dev/null 2>&1 && {
    echo "the first call's name leaked into the second call's directory" >&2
    return 1
  }
  true
}

@test "path_allowlist refuses rather than writing outside a bats per-test temp dir" {
  # Same refusal, and the same reason, as path_shim_without's: the directory is
  # torn down with the test that built it, so outside a test there is nowhere
  # sanctioned to build one. Asserted on the diagnostic rather than the status
  # alone, because a failed mkdir at a guessed path returns non-zero too.
  local out rc=0
  out="$(BATS_TEST_TMPDIR="" path_allowlist gaia-fixture-wanted 2>&1)" || rc=$?
  [ "$rc" -ne 0 ]
  grep -qF 'BATS_TEST_TMPDIR is unset' <<<"$out"
}
