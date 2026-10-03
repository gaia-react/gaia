#!/usr/bin/env bats
# Conformance suite for .gaia/scripts/check-retired-paths.sh, the gate that fails
# on a harness citation of a root path that moved under frontend/.
#
# Every test builds a temporary git repository holding a copy of the gate, so
# the verdict never depends on the real tree's state or on git history. One test
# runs the gate over the real working tree. The failing states (a hit, a stale
# or malformed allowlist row, a tracked retired path, an empty scan set) are
# each driven on their own, and the over-match negatives pin the other
# direction: a gate that flagged `frontend/app/` would fail every run.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-retired-paths.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/retired-paths"
}

# make_repo <name>: a git repo under BATS_TEST_TMPDIR holding a copy of the gate
# and one clean scanned hook, so the scan set is never empty by accident.
make_repo() {
  local repo="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$repo/.gaia/scripts" "$repo/.claude/hooks"
  git -C "$repo" init -q
  cp "$SCRIPT_DIRECTORY/check-retired-paths.sh" "$repo/.gaia/scripts/check-retired-paths.sh"
  printf '#!/usr/bin/env bash\necho ok\n' >"$repo/.claude/hooks/ok.sh"
  printf '%s' "$repo"
}

# stage_all <repo>: track every file so the gate's git ls-files sees it.
stage_all() {
  git -C "$1" add -A
}

run_gate() {
  run bash "$1/.gaia/scripts/check-retired-paths.sh" "${@:2}"
}

@test "the real working tree is clean" {
  run bash "$SCRIPT_DIRECTORY/check-retired-paths.sh" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF -- "check-retired-paths: clean" <<<"$output"
}

@test "a root app/ citation in a hook names the file and line and fails" {
  local repo
  repo="$(make_repo hit)"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'RETIRED .claude/hooks/x.sh:2: source_file="app/routes.ts"' <<<"$output"
}

@test "a command citing a moved .claude unit at its old root path fails" {
  local repo
  repo="$(make_repo unit)"
  mkdir -p "$repo/.claude/commands"
  cp "$FIXTURES/command-cites-moved-instruction.md" "$repo/.claude/commands/x.md"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'RETIRED .claude/commands/x.md:3:' <<<"$output"
}

@test "the same citation under frontend/ does not trip the gate" {
  local repo
  repo="$(make_repo negative)"
  cp "$FIXTURES/over-match-negatives.txt" "$repo/.claude/hooks/x.sh"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "check-retired-paths: clean" <<<"$output"
}

@test "a comment-only line in a code file is skipped but a trailing comment is not" {
  local repo
  repo="$(make_repo comments)"
  printf '%s\n' '#!/usr/bin/env bash' '# the app/ layout is package-relative' >"$repo/.claude/hooks/x.sh"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' '#!/usr/bin/env bash' 'target=app/x.ts # trailing' >"$repo/.claude/hooks/x.sh"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'RETIRED .claude/hooks/x.sh:2:' <<<"$output"
}

@test "a Markdown line is scanned even when it starts with a bullet or a hash" {
  local repo
  repo="$(make_repo markdown)"
  mkdir -p "$repo/.claude/skills/demo"
  printf '%s\n' '# Demo' '* edit app/x.ts first' >"$repo/.claude/skills/demo/SKILL.md"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'RETIRED .claude/skills/demo/SKILL.md:2:' <<<"$output"
}

@test "a rule's frontmatter paths are scanned and its body is not" {
  local repo
  repo="$(make_repo rule)"
  mkdir -p "$repo/.claude/rules"
  printf '%s\n' '---' 'paths:' '  - "frontend/app/**"' '---' 'Prose about app/x.ts in the body.' >"$repo/.claude/rules/r.md"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 0 ]
  printf '%s\n' '---' 'paths:' '  - "app/**"' '---' 'Body.' >"$repo/.claude/rules/r.md"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'RETIRED .claude/rules/r.md:3:' <<<"$output"
}

@test "files under tests and fixtures directories and package-relative harness are not scanned" {
  local repo
  repo="$(make_repo excluded)"
  mkdir -p "$repo/.gaia/scripts/tests/fixtures" "$repo/frontend/.claude/hooks"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.gaia/scripts/tests/fixtures/x.sh"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.gaia/scripts/tests/y.sh"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/frontend/.claude/hooks/z.sh"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 0 ]
}

@test "an allowlist row with a matching file and needle allows the hit" {
  local repo
  repo="$(make_repo allowed)"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  printf '.claude/hooks/x.sh\tapp/routes.ts\tpackage-relative default\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 0 ]
}

@test "an allowlist row for a different file does not allow the hit" {
  local repo
  repo="$(make_repo other-file)"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  printf '.claude/hooks/ok.sh\tapp/routes.ts\treason\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'RETIRED .claude/hooks/x.sh:2:' <<<"$output"
  grep -qF -- 'STALE-ALLOW .claude/hooks/ok.sh app/routes.ts' <<<"$output"
}

@test "a stale allowlist row fails the gate" {
  local repo
  repo="$(make_repo stale)"
  printf '.claude/hooks/ok.sh\tapp/gone.ts\ta citation that no longer exists\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'STALE-ALLOW .claude/hooks/ok.sh app/gone.ts' <<<"$output"
}

@test "an allowlist row with an empty reason fails the gate" {
  local repo
  repo="$(make_repo no-reason)"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  printf '.claude/hooks/x.sh\tapp/routes.ts\t\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'BAD-ALLOW 1:' <<<"$output"
}

@test "an allowlist row with no reason column fails the gate" {
  local repo
  repo="$(make_repo no-column)"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  printf '.claude/hooks/x.sh\tapp/routes.ts\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'BAD-ALLOW 1:' <<<"$output"
}

@test "a tracked root app/ file fails with TRACKED" {
  local repo
  repo="$(make_repo tracked)"
  mkdir -p "$repo/app"
  printf 'export {};\n' >"$repo/app/x.ts"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qxF -- 'TRACKED app/x.ts' <<<"$output"
}

@test "a tracked moved root config file and a tracked moved unit both fail with TRACKED" {
  local repo
  repo="$(make_repo tracked-config)"
  mkdir -p "$repo/.claude/skills/tailwind"
  printf '{}\n' >"$repo/tsconfig.json"
  printf 'x\n' >"$repo/.claude/skills/tailwind/SKILL.md"
  stage_all "$repo"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qxF -- 'TRACKED tsconfig.json' <<<"$output"
  grep -qxF -- 'TRACKED .claude/skills/tailwind/SKILL.md' <<<"$output"
}

@test "a tracked file under frontend/ and an untracked root app/ file do not trip TRACKED" {
  local repo
  repo="$(make_repo tracked-negative)"
  mkdir -p "$repo/frontend/app" "$repo/app"
  printf 'export {};\n' >"$repo/frontend/app/x.ts"
  printf '{}\n' >"$repo/.gaia/packages-sample.json"
  stage_all "$repo"
  printf 'export {};\n' >"$repo/app/untracked.ts"
  run_gate "$repo"
  [ "$status" -eq 0 ]
}

@test "an empty scan set exits 2 and never reports clean" {
  local repo="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$repo/.gaia/scripts" "$repo/docs"
  git -C "$repo" init -q
  cp "$SCRIPT_DIRECTORY/check-retired-paths.sh" "$repo/.gaia/scripts/check-retired-paths.sh"
  printf 'note\n' >"$repo/docs/a.txt"
  stage_all "$repo"
  run bash "$repo/.gaia/scripts/check-retired-paths.sh" --root "$repo"
  [ "$status" -eq 2 ]
  grep -qF -- "the scan set is empty" <<<"$output"
  if grep -qF -- "clean" <<<"$output"; then
    return 1
  fi
}

@test "a directory that is not a git repository exits 2" {
  local plain="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$plain/.claude/hooks"
  printf 'echo ok\n' >"$plain/.claude/hooks/ok.sh"
  run bash "$SCRIPT_DIRECTORY/check-retired-paths.sh" --root "$plain"
  [ "$status" -eq 2 ]
}

@test "a usage error exits 2" {
  run bash "$SCRIPT_DIRECTORY/check-retired-paths.sh" --bogus
  [ "$status" -eq 2 ]
  run bash "$SCRIPT_DIRECTORY/check-retired-paths.sh" --root
  [ "$status" -eq 2 ]
  run bash "$SCRIPT_DIRECTORY/check-retired-paths.sh" --root "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}
