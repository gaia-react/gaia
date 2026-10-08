#!/usr/bin/env bats

# Suite for .gaia/tests/whole-tree-mark-guard.sh, the guard that flags a bats
# suite enumerating the tracked tree through a recognized idiom without the
# whole-tree mark. It runs the guard over the real tracked tree, so it carries
# the mark itself.
#
# Fixture suites live under $BATS_TEST_TMPDIR. A fixture that must carry the
# tag gets its line from write_mark, which assembles it at run time, so the
# tag line sits at column 0 in this file only where this suite's own mark does
# and neither discovery nor bats tags the fixtures' text.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GUARD="$REPO_ROOT/.gaia/tests/whole-tree-mark-guard.sh"
  FIXTURE_DIRECTORY="$BATS_TEST_TMPDIR/fixture-suites"
  mkdir -p "$FIXTURE_DIRECTORY"
}

write_mark() {
  printf '# bats %s\n' 'file_tags=whole-tree'
}

# write_seed <kind>: the real-root assignment, per rooting shape.
write_seed() {
  case "$1" in
    dirname)
      printf '%s\n' 'ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
      ;;
    filename)
      printf '%s\n' 'ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"'
      ;;
    second-assignment)
      printf '%s\n' 'THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"'
      printf '%s\n' 'ROOT="$THIS_DIRECTORY/../.."'
      ;;
  esac
}

# write_idiom <idiom>: one test body line enumerating under $ROOT.
write_idiom() {
  case "$1" in
    git-ls-files)
      printf '%s\n' '  run git -C "$ROOT" ls-'files
      ;;
    git-grep)
      printf '%s\n' '  run git -C "$ROOT" grep -l needle -- .'
      ;;
    find)
      printf '%s\n' '  run find "$ROOT/.claude" -name "*.md"'
      ;;
    glob-loop)
      printf '%s\n' '  for agent in "$ROOT"/.claude/agents/*.md; do [ -f "$agent" ]; done'
      ;;
  esac
}

# write_fixture <path> <seed> <idiom> <yes | no | tag list>
write_fixture() {
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' '# header comment'
    printf '\n'
    if [ "$4" = yes ]; then
      write_mark
      printf '\n'
    elif [ "$4" != no ]; then
      printf '# bats file_tags=%s\n\n' "$4"
    fi
    printf '%s\n' 'setup() {'
    write_seed "$2" | sed 's/^/  /'
    printf '%s\n' '}'
    printf '\n'
    printf '%s\n' '@test "fixture" {'
    write_idiom "$3"
    printf '%s\n' '}'
  } >"$1"
}

IDIOMS="git-ls-files git-grep find glob-loop"
SEEDS="dirname filename second-assignment"

@test "the guard passes over the real tracked tree" {
  run bash "$GUARD" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "every idiom under every rooting shape, unmarked, is flagged with the suite file and the mark to add" {
  local seed idiom suite
  for seed in $SEEDS; do
    for idiom in $IDIOMS; do
      suite="$FIXTURE_DIRECTORY/unmarked-$seed-$idiom.bats"
      write_fixture "$suite" "$seed" "$idiom" no
      run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
      if [ "$status" -ne 1 ]; then
        echo "expected exit 1 for $seed/$idiom, got $status: $output" >&2
        return 1
      fi
      case "$output" in
        *"unmarked-$seed-$idiom.bats: enumerates the tracked tree ("*"without the whole-tree mark; add the line '# bats file_tags=whole-tree' before its first test"*) ;;
        *)
          echo "no mark-to-add line for $seed/$idiom: $output" >&2
          return 1
          ;;
      esac
    done
  done
}

@test "the same fixtures carrying the mark pass" {
  local seed idiom suite
  for seed in $SEEDS; do
    for idiom in $IDIOMS; do
      suite="$FIXTURE_DIRECTORY/marked-$seed-$idiom.bats"
      write_fixture "$suite" "$seed" "$idiom" yes
      run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
      if [ "$status" -ne 0 ]; then
        echo "expected exit 0 for $seed/$idiom, got $status: $output" >&2
        return 1
      fi
    done
  done
}

@test "a mark joined into a comma list of tags counts" {
  local suite="$FIXTURE_DIRECTORY/tag-list.bats"
  write_fixture "$suite" dirname find other,whole-tree
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ]
  write_fixture "$suite" dirname find other,unrelated
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 1 ]
}

@test "every idiom against a fixture repository under the test temp directory is not flagged" {
  local suite="$FIXTURE_DIRECTORY/fixture-repo-only.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '  . "$ROOT/.gaia/scripts/lib.sh"'
    printf '%s\n' '  FIXTURE_REPO="$BATS_TEST_TMPDIR/repo"'
    printf '%s\n' '  FIXTURE_COPY="$FIXTURE_REPO/copy"'
    printf '%s\n' '}'
    printf '%s\n' '@test "fixture only" {'
    printf '%s\n' '  run git -C "$FIXTURE_REPO" ls-'files
    printf '%s\n' '  run git -C "$FIXTURE_COPY" -c core.quotepath=off grep -l needle'
    printf '%s\n' '  run find "$FIXTURE_REPO/.claude" -name "*.md"'
    printf '%s\n' '  for agent in "$FIXTURE_REPO"/.claude/agents/*.md; do :; done'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ]
}

@test "a root under a fixtures directory is not flagged" {
  local suite="$FIXTURE_DIRECTORY/fixtures-root.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '  CORPUS="$ROOT/.gaia/tests/fixtures/corpus"'
    printf '%s\n' '  REPORTS="$BATS_TEST_DIRNAME/fixtures/reports"'
    printf '%s\n' '}'
    printf '%s\n' '@test "fixtures only" {'
    printf '%s\n' '  for case_directory in "$CORPUS"/*/; do :; done'
    printf '%s\n' '  for report in "$REPORTS"/*.json; do :; done'
    printf '%s\n' '  run find "$ROOT/.gaia/tests/fixtures/binding" -type f'
    printf '%s\n' '  for entry in "$ROOT"/tests/fixtures/*.json; do :; done'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a listing that names literal paths is not flagged" {
  local suite="$FIXTURE_DIRECTORY/named-paths.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '}'
    printf '%s\n' '@test "named" {'
    printf '%s\n' '  done < <(git -C "$ROOT" ls-files -z -- frontend/.dockerignore frontend/Dockerfile)'
    printf '%s\n' '  run git -C "$ROOT" ls-files -s -z .githooks/pre-commit'
    printf '%s\n' '  git -C "$ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a listing of a tracked directory, a root-level path, a glob, a magic pathspec or a variable is still flagged" {
  local repository="$BATS_TEST_TMPDIR/repository" suite operand
  mkdir -p "$repository/.claude/agents"
  printf 'agent\n' >"$repository/.claude/agents/a.md"
  git -C "$repository" init -q
  git -C "$repository" add -A
  for operand in '-- .claude/agents' '-z -- .dockerignore Dockerfile' "-z '*.sh'" '-- "$directory"' '-z -- ":(glob)frontend/x"'; do
    suite="$repository/listing.bats"
    {
      printf '%s\n' '#!/usr/bin/env bats'
      printf '%s\n' 'setup() {'
      printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
      printf '%s\n' '}'
      printf '%s\n' '@test "lists" {'
      printf '  run git -C "$ROOT" ls-%s %s\n' files "$operand"
      printf '%s\n' '}'
    } >"$suite"
    run bash "$GUARD" --root "$repository" "$suite"
    if [ "$status" -ne 1 ]; then
      echo "expected exit 1 for operand $operand, got $status: $output" >&2
      return 1
    fi
  done
}

@test "a suite that only calls a script that lists tracked files is not flagged, and the guard states that limit" {
  local suite="$FIXTURE_DIRECTORY/delegated.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' 'setup() {'
    printf '%s\n' '  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"'
    printf '%s\n' '}'
    printf '%s\n' '@test "delegates" {'
    printf '%s\n' '  run bash "$ROOT/.gaia/scripts/lint-everything.sh"'
    printf '%s\n' '}'
  } >"$suite"
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 0 ]
  case "$output" in
    *"outside this guard's claim"*) ;;
    *) echo "pass output omits the delegation limit: $output" >&2; return 1 ;;
  esac
  local header_text
  header_text="$(sed -n '1,40p' "$GUARD")"
  case "$header_text" in
    *"delegated to a script the suite calls"*) ;;
    *) echo "header omits the delegation limit" >&2; return 1 ;;
  esac
}

@test "the failure output ends by stating the recognized idioms and the delegation limit" {
  local suite="$FIXTURE_DIRECTORY/unmarked-limit.bats"
  write_fixture "$suite" dirname git-ls-files no
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$suite"
  [ "$status" -eq 1 ]
  local last_line
  last_line="$(printf '%s\n' "$output" | tail -n 1)"
  case "$last_line" in
    *"Only the idioms in this script's header are recognized"*"delegated to a script the suite calls is outside this guard's claim"*) ;;
    *) echo "last line omits the claim: $last_line" >&2; return 1 ;;
  esac
}

@test "an unmarked copy of a real marked suite is flagged" {
  local source_suite="$REPO_ROOT/.gaia/scripts/tests/check-hook-scope-manifest.bats"
  local copy="$FIXTURE_DIRECTORY/check-hook-scope-manifest.bats"
  grep -q '^# bats file_tags=whole-tree$' "$source_suite"
  grep -v '^# bats file_tags=whole-tree$' "$source_suite" >"$copy"
  run bash "$GUARD" --root "$REPO_ROOT" "$copy"
  [ "$status" -eq 1 ]
  case "$output" in
    *"$copy: enumerates the tracked tree"*) ;;
    *) echo "copy not named: $output" >&2; return 1 ;;
  esac
}

@test "a root with no tracked suite exits 2, not 0" {
  local empty_repo="$BATS_TEST_TMPDIR/empty-repo"
  mkdir -p "$empty_repo"
  git -C "$empty_repo" init -q
  run bash "$GUARD" --root "$empty_repo"
  [ "$status" -eq 2 ]
}

@test "a usage error exits 2" {
  run bash "$GUARD" --no-such-flag
  [ "$status" -eq 2 ]
  run bash "$GUARD" --root
  [ "$status" -eq 2 ]
}

@test "a missing suite operand exits 2" {
  run bash "$GUARD" --root "$FIXTURE_DIRECTORY" "$FIXTURE_DIRECTORY/absent.bats"
  [ "$status" -eq 2 ]
}
