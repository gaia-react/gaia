#!/usr/bin/env bats
# audit-fix-verify.sh: the deterministic gate between a fixer sub-agent and the
# Quality Gate. Every case builds a scratch git repo under BATS_TEST_TMPDIR and
# drives the script into its refusal; AUDIT_FIX_VERIFY_SCRIPT points the suite at a mutant
# copy for the mutation proofs.

SCRIPT="${AUDIT_FIX_VERIFY_SCRIPT:-$BATS_TEST_DIRNAME/../audit-fix-verify.sh}"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../audit-fix-verify.sh"

sha() { shasum -a 256 <"$1" | cut -d' ' -f1; }

make_repo() {
  local directory="$1"
  mkdir -p "$directory"
  git -C "$directory" init -q
  git -C "$directory" config user.email t@example.com
  git -C "$directory" config user.name t
  git -C "$directory" config commit.gpgsign false
  printf '.gaia/local/\n' >"$directory/.gitignore"
  local file_name
  for file_name in a.txt b.txt c.txt stray.txt "with space.txt" CHANGELOG.md; do
    printf 'base %s\n' "$file_name" >"$directory/$file_name"
  done
  git -C "$directory" add -A
  git -C "$directory" commit -q -m base
}

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  make_repo "$REPO"
  RUN_FOLDER="$REPO/.gaia/local/runs/b"
  mkdir -p "$RUN_FOLDER"
  DISPOSITIONS_FILE="$RUN_FOLDER/dispositions-1.json"
  BASELINE_FILE="$RUN_FOLDER/baseline-1.json"
  RESULT_FILE="$RUN_FOLDER/fixer-1-audit.json"
  VERIFIER_OUTPUT_FILE="$RUN_FOLDER/verifier-1-1.json"
  ATTEMPT=1
}

# write_dispositions <entries-json> [allowed-json]
write_dispositions() {
  jq -n --argjson entries "$1" --argjson allowed_paths "${2:-[]}" \
    '{schema: 1, round: 1, tree: "abc", root: "x", enforcement_paths_allowed: $allowed_paths, entries: $entries}' >"$DISPOSITIONS_FILE"
}

# Two fix entries (a.txt, b.txt) and one accepted residual.
default_entries() {
  printf '%s' '[
    {"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fix"},
    {"member":"m","finding_class":"c2","path":"b.txt","line":5,"disposition":"fix"},
    {"member":"m","finding_class":"c3","path":"c.txt","line":null,"disposition":"accept-residual"}]'
}

default_result() {
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[
    {"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fixed","reason":"r","changed_paths":["a.txt"]},
    {"member":"m","finding_class":"c2","path":"b.txt","line":5,"disposition":"fixed","reason":"r","changed_paths":["b.txt"]}],
    "changed_paths":["a.txt","b.txt"],"reverted_paths":[]}'
}

take_baseline() {
  bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
}

take_digests() {
  DISPOSITIONS_SHA="$(sha "$DISPOSITIONS_FILE")"
  BASELINE_SHA="$(sha "$BASELINE_FILE")"
}

# Commit the real audit roster and digest library into the fixture, so the
# verifier can resolve member content digests there. The fixture then has
# member digests a marker's file name can collide with.
with_harness() {
  mkdir -p "$REPO/.gaia" "$REPO/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../../audit-ci.yml" "$REPO/.gaia/audit-ci.yml"
  cp -R "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" "$REPO/.claude/hooks/lib"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m harness
}

# member_digest [<ref>]: one member content digest of the fixture at <ref>.
member_digest() {
  bash -c '. "$1/.claude/hooks/lib/audit-digest.sh" && audit_digests_all "$1" "$2"' _ "$REPO" "${1:-HEAD}" |
    cut -f2 | sort -u | head -1
}

# forge <name> <body-json>: an audit file written after the baseline.
forge() {
  mkdir -p "$REPO/.gaia/local/audit"
  printf '%s\n' "$2" >"$REPO/.gaia/local/audit/$1"
  touch -t 203001010000 "$REPO/.gaia/local/audit/$1"
}

foreign_tree() { printf 'f%.0s' {1..40}; }

# Standard setup: dispositions, baseline, digests.
prepare() {
  write_dispositions "$(default_entries)" "${1:-[]}"
  take_baseline
  take_digests
}

do_check() {
  run bash "$SCRIPT" check --root "$REPO" --round 1 --attempt "$ATTEMPT" \
    --dispositions "$DISPOSITIONS_FILE" --dispositions-sha "$DISPOSITIONS_SHA" \
    --baseline "$BASELINE_FILE" --baseline-sha "$BASELINE_SHA" \
    --result "$RESULT_FILE" --out "$VERIFIER_OUTPUT_FILE" "$@"
}

edit() { printf 'fixer edit\n' >>"$REPO/$1"; }

# prepare_with_dirty_record <path>: a baseline that records <path> as dirty
# with its edited content. The real baseline subcommand refuses a dirty tree,
# so this forges the record to keep the check's revert and further-edit
# comparison proven against a baseline that carries a dirty entry.
prepare_with_dirty_record() {
  write_dispositions "$(default_entries)"
  take_baseline
  edit "$1"
  local blob
  blob="$(git -C "$REPO" hash-object -- "$1")"
  jq --arg dirty_path "$1" --arg blob "$blob" '.dirty[$dirty_path] = $blob' "$BASELINE_FILE" >"$BASELINE_FILE.new"
  mv "$BASELINE_FILE.new" "$BASELINE_FILE"
  take_digests
}

assert_fail_kind() {
  local kind="$1" needle="${2:-}"
  [ "$status" -eq 1 ] || {
    echo "status=$status output=$output"
    return 1
  }
  [ "$(jq -r '.pass' "$VERIFIER_OUTPUT_FILE")" = false ] || return 1
  jq -e --arg kind "$kind" '[.errors[].kind] | index($kind) != null' "$VERIFIER_OUTPUT_FILE" >/dev/null || {
    echo "no $kind error: $(cat "$VERIFIER_OUTPUT_FILE")"
    return 1
  }
  case "$output" in
    *"$kind"*) ;;
    *)
      echo "stderr lacks $kind: $output"
      return 1
      ;;
  esac
  if [ -n "$needle" ]; then
    case "$output" in
      *"$needle"*) ;;
      *)
        echo "stderr lacks '$needle': $output"
        return 1
        ;;
    esac
  fi
  return 0
}

@test "clean pass: clean baseline, two declared fixer edits, one result per fix entry" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
  [ "$(jq -r '.pass' "$VERIFIER_OUTPUT_FILE")" = true ]
  [ "$(jq -r '.errors | length' "$VERIFIER_OUTPUT_FILE")" = 0 ]
}

@test "UAT-002a: a result omitting one fix entry fails missing-disposition naming the key" {
  prepare
  edit a.txt
  default_result | jq 'del(.results[1])' >"$RESULT_FILE"
  do_check
  assert_fail_kind missing-disposition "m c2 b.txt 5"
}

@test "UAT-002a: a result with a disposition outside the allowed set counts as missing" {
  prepare
  edit a.txt
  edit b.txt
  default_result | jq '.results[0].disposition = "done"' >"$RESULT_FILE"
  do_check
  assert_fail_kind missing-disposition "m c1 a.txt 3"
}

@test "UAT-002b: an undeclared edit to a tracked file fails undeclared-path" {
  prepare
  edit a.txt
  edit b.txt
  edit c.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind undeclared-path c.txt
}

@test "UAT-002c: a new undeclared untracked file fails undeclared-path" {
  prepare
  edit a.txt
  edit b.txt
  printf 'new\n' >"$REPO/new.txt"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind undeclared-path new.txt
}

@test "a declared new untracked file passes" {
  prepare
  edit a.txt
  edit b.txt
  printf 'new\n' >"$REPO/new.txt"
  default_result | jq '.changed_paths += ["new.txt"]' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "UAT-002d, UAT-023: reverting a path the baseline records dirty, undeclared, fails undeclared-revert naming the path" {
  prepare_with_dirty_record stray.txt
  edit a.txt
  edit b.txt
  printf 'base stray.txt\n' >"$REPO/stray.txt"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind undeclared-revert stray.txt
}

@test "a revert of a baseline-dirty path declared in reverted_paths passes" {
  prepare_with_dirty_record stray.txt
  edit a.txt
  edit b.txt
  printf 'base stray.txt\n' >"$REPO/stray.txt"
  default_result | jq '.reverted_paths = ["stray.txt"]' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "UAT-002e: a further undeclared edit to a path the baseline records dirty fails undeclared-path" {
  prepare_with_dirty_record stray.txt
  edit a.txt
  edit b.txt
  edit stray.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind undeclared-path stray.txt
}

@test "UAT-002f: HEAD moved by a commit fails head-moved" {
  prepare
  edit a.txt
  edit b.txt
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m fixer
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind head-moved
}

@test "UAT-002g: a staged change fails index-changed" {
  prepare
  edit a.txt
  edit b.txt
  git -C "$REPO" add a.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind index-changed
}

@test "directive 2: a declared edit to CHANGELOG.md fails forbidden-path" {
  prepare
  edit a.txt
  edit b.txt
  edit CHANGELOG.md
  default_result | jq '.changed_paths += ["CHANGELOG.md"]' >"$RESULT_FILE"
  do_check
  assert_fail_kind forbidden-path CHANGELOG.md
}

enforcement_paths() {
  sed -n '/^ENFORCEMENT_PATHS=(/,/^)/p' "$REAL_SCRIPT" | sed -n "s/^  '\([^']*\)'.*/\1/p"
}

# The size of the set before the SPEC-093 append.
PRE_SPEC093_ENFORCEMENT_COUNT=11

# The SPEC-093 additions; each is expected on the list when it exists in the tree.
spec093_enforcement_paths() {
  printf '%s\n' \
    '.claude/hooks/audit-loop-ask-grant.sh' \
    '.gaia/scripts/context-checkpoint-lib.sh' \
    '.gaia/scripts/audit-dispositions-check.sh' \
    '.gaia/scripts/audit-loop-signals-lib.sh' \
    '.claude/agents/audit-loop-unit.md' \
    '.gaia/statusline/gaia-statusline.sh' \
    '.gaia/statusline/context-reading.sh' \
    '.gaia/statusline/left-side.sh'
}

@test "UAT-032: the enforcement set holds every existing SPEC-093 path and grew by exactly that count" {
  local repo_root="$BATS_TEST_DIRNAME/../../.." file_path added=0
  while IFS= read -r file_path; do
    [ -e "$repo_root/$file_path" ] || continue
    added=$((added + 1))
    enforcement_paths | grep -Fxq "$file_path" || {
      echo "missing from ENFORCEMENT_PATHS: $file_path"
      return 1
    }
  done < <(spec093_enforcement_paths)
  [ "$added" -ge 1 ]
  [ "$(enforcement_paths | wc -l | tr -d ' ')" -eq $((PRE_SPEC093_ENFORCEMENT_COUNT + added)) ]
  enforcement_paths | grep -Fxq '.claude/settings.local.json'
}

# One fixture repo per enforcement path: seed it, baseline, edit it, check.
enforcement_case() {
  local file_path="$1" case_label="$2"
  REPO="$BATS_TEST_TMPDIR/enf$case_label"
  make_repo "$REPO"
  mkdir -p "$REPO/$(dirname "$file_path")"
  printf 'orig\n' >"$REPO/$file_path"
  git -C "$REPO" add -f -A
  git -C "$REPO" commit -q -m enforcement
  RUN_FOLDER="$REPO/.gaia/local/runs/b"
  mkdir -p "$RUN_FOLDER"
  DISPOSITIONS_FILE="$RUN_FOLDER/dispositions-1.json"
  BASELINE_FILE="$RUN_FOLDER/baseline-1.json"
  RESULT_FILE="$RUN_FOLDER/fixer-1-audit.json"
  VERIFIER_OUTPUT_FILE="$RUN_FOLDER/verifier-1-1.json"
  write_dispositions '[{"member":"m","finding_class":"c1","path":"'"$file_path"'","line":1,"disposition":"fix"}]'
  take_baseline
  take_digests
  edit "$file_path"
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"'"$file_path"'","line":1,"disposition":"fixed","reason":"r","changed_paths":["'"$file_path"'"]}],"changed_paths":["'"$file_path"'"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 1 ] || {
    echo "$file_path did not fail: $output"
    return 1
  }
  jq -e '[.errors[].kind] | index("enforcement-path") != null' "$VERIFIER_OUTPUT_FILE" >/dev/null || {
    echo "$file_path: no enforcement-path error"
    return 1
  }
  case "$output" in
    *"$file_path"*) return 0 ;;
  esac
  echo "$file_path not named: $output"
  return 1
}

@test "directive 2: a declared edit to every enforcement-set path fails enforcement-path" {
  local path_count=0 file_path
  while IFS= read -r file_path; do
    path_count=$((path_count + 1))
    enforcement_case "$file_path" "$path_count" || return 1
  done < <(enforcement_paths)
  [ "$path_count" -eq "$(enforcement_paths | wc -l | tr -d ' ')" ]
  [ "$path_count" -gt "$PRE_SPEC093_ENFORCEMENT_COUNT" ]
}

@test "UAT-032: an unlisted edit to each SPEC-093 enforcement path fails enforcement-path" {
  local repo_root="$BATS_TEST_DIRNAME/../../.." path_count=0 file_path
  while IFS= read -r file_path; do
    [ -e "$repo_root/$file_path" ] || continue
    path_count=$((path_count + 1))
    enforcement_case "$file_path" "s$path_count" || return 1
  done < <(spec093_enforcement_paths)
  [ "$path_count" -ge 1 ]
}

@test "UAT-032 control: a listed edit to a SPEC-093 enforcement path with a fix entry passes" {
  local file_path='.gaia/scripts/audit-dispositions-check.sh'
  mkdir -p "$REPO/.gaia/scripts"
  printf 'orig\n' >"$REPO/$file_path"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m enforcement
  write_dispositions '[{"member":"m","finding_class":"c1","path":"'"$file_path"'","line":1,"disposition":"fix"}]' '["'"$file_path"'"]'
  take_baseline
  take_digests
  edit "$file_path"
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"'"$file_path"'","line":1,"disposition":"fixed","reason":"r","changed_paths":["'"$file_path"'"]}],"changed_paths":["'"$file_path"'"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "a waive-out-of-scope entry carrying basis cross-remit passes the shape check" {
  write_dispositions '[
    {"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fix"},
    {"member":"m","finding_class":"c2","path":"b.txt","line":5,"disposition":"waive-out-of-scope","basis":"cross-remit","reason":"r"}]'
  take_baseline
  take_digests
  edit a.txt
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fixed","reason":"r","changed_paths":["a.txt"]}],"changed_paths":["a.txt"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "a divert entry passes the shape check and needs no fixer result" {
  write_dispositions '[
    {"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fix"},
    {"member":"m","finding_class":"c2","path":"b.txt","line":5,"disposition":"divert","reason":"security class from outside the branch"}]'
  take_baseline
  take_digests
  edit a.txt
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fixed","reason":"r","changed_paths":["a.txt"]}],"changed_paths":["a.txt"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  grep -qF -- 'fix|accept-residual|waive-out-of-scope|file|divert' "$REAL_SCRIPT"
}

@test "the run-folder header drops the stale writer label and names the new shapes" {
  if grep -Fq 'dispositions-<r>.json (main thread)' "$REAL_SCRIPT"; then
    echo "stale writer label still present"
    return 1
  fi
  local literal
  for literal in basis vetoes.json 'unit-<u>.json' effective_from_round stop_reason; do
    grep -Fq -- "$literal" "$REAL_SCRIPT" || {
      echo "header lacks $literal"
      return 1
    }
  done
}

@test "directive 3: an enforcement edit passes when allowed and a fix entry names it" {
  local file_path='.gaia/scripts/audit-loop-eval.sh'
  mkdir -p "$REPO/.gaia/scripts"
  printf 'orig\n' >"$REPO/$file_path"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m enforcement
  write_dispositions '[{"member":"m","finding_class":"c1","path":"'"$file_path"'","line":1,"disposition":"fix"}]' '["'"$file_path"'"]'
  take_baseline
  take_digests
  edit "$file_path"
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"'"$file_path"'","line":1,"disposition":"fixed","reason":"r","changed_paths":["'"$file_path"'"]}],"changed_paths":["'"$file_path"'"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "directive 3: an enforcement_paths_allowed entry no fix entry names fails bad-input" {
  write_dispositions "$(default_entries)" '[".gaia/scripts/audit-loop-eval.sh"]'
  take_baseline
  take_digests
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "no fix entry names"
}

@test "directive 2: a *.ok marker written under .gaia/local/audit after the baseline fails audit-artifact-written" {
  prepare
  edit a.txt
  edit b.txt
  mkdir -p "$REPO/.gaia/local/audit"
  printf 'ok\n' >"$REPO/.gaia/local/audit/x.ok"
  touch -t 203001010000 "$REPO/.gaia/local/audit/x.ok"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written x.ok
}

@test "directive 2: a *.findings.json sidecar written after the baseline fails audit-artifact-written" {
  prepare
  edit a.txt
  edit b.txt
  mkdir -p "$REPO/.gaia/local/audit"
  slug="$(git -C "$REPO" branch --show-current)"
  printf '{}\n' >"$REPO/.gaia/local/audit/t.$slug.m.findings.json"
  touch -t 203001010000 "$REPO/.gaia/local/audit/t.$slug.m.findings.json"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written findings.json
}

@test "a foreign branch's sidecar written after the baseline still passes" {
  prepare
  edit a.txt
  edit b.txt
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{}\n' >"$REPO/.gaia/local/audit/t.other-branch.m.findings.json"
  touch -t 203001010000 "$REPO/.gaia/local/audit/t.other-branch.m.findings.json"
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "a foreign root's marker and refusal written after the baseline still pass" {
  with_harness
  prepare
  edit a.txt
  edit b.txt
  body="$(printf '{"tree":"%s","sha":"%s"}' "$(foreign_tree)" "$(printf 'e%.0s' {1..40})")"
  forge foreign.ok "$body"
  forge foreign.refused "$body"
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "a marker whose body has neither a tree nor a sha fails audit-artifact-written" {
  with_harness
  prepare
  edit a.txt
  edit b.txt
  forge "$(printf 'a%.0s' {1..64}).ok" '{"digest":"x","member":"code-audit-frontend","provenance":"earned"}'
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written
}

@test "a marker whose tree is not a well-formed object id fails audit-artifact-written" {
  with_harness
  prepare
  edit a.txt
  edit b.txt
  forge bad-tree.ok '{"tree":"not-a-tree","sha":"abc"}'
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written bad-tree.ok
}

@test "a foreign-tree marker named by one of this root's member digests fails audit-artifact-written" {
  with_harness
  prepare
  edit a.txt
  edit b.txt
  digest="$(member_digest HEAD)"
  [ -n "$digest" ]
  forge "$digest.ok" "$(printf '{"digest":"%s","tree":"%s","sha":"abc"}' "$digest" "$(foreign_tree)")"
  forge "$digest.code-audit-frontend.refused" "$(printf '{"digest":"%s","tree":"%s","sha":"abc"}' "$digest" "$(foreign_tree)")"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written "$digest"
}

@test "a foreign-tree marker named by a member digest of the working content fails audit-artifact-written" {
  with_harness
  prepare
  edit a.txt
  edit b.txt
  # A change to the shared machinery rotates every member digest.
  printf '# fixer edit\n' >>"$REPO/.claude/hooks/lib/audit-digest.sh"
  index_file="$BATS_TEST_TMPDIR/wt-index"
  GIT_INDEX_FILE="$index_file" git -C "$REPO" read-tree HEAD
  GIT_INDEX_FILE="$index_file" git -C "$REPO" add -A
  worktree_tree="$(GIT_INDEX_FILE="$index_file" git -C "$REPO" write-tree)"
  digest="$(member_digest "$worktree_tree")"
  [ -n "$digest" ]
  [ "$digest" != "$(member_digest HEAD)" ]
  forge "$digest.ok" "$(printf '{"digest":"%s","tree":"%s","sha":"abc"}' "$digest" "$(foreign_tree)")"
  default_result >"$RESULT_FILE"
  jq '.changed_paths += [".claude/hooks/lib/audit-digest.sh"]' "$RESULT_FILE" >"$RESULT_FILE.n"
  mv "$RESULT_FILE.n" "$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written "$digest"
}

@test "when member digests cannot be resolved a foreign-tree marker counts" {
  prepare
  edit a.txt
  edit b.txt
  forge foreign.ok "$(printf '{"tree":"%s","sha":"abc"}' "$(foreign_tree)")"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written foreign.ok
}

@test "a marker carrying this root's HEAD tree fails audit-artifact-written" {
  prepare
  edit a.txt
  edit b.txt
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"tree":"%s","sha":"x"}\n' "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" >"$REPO/.gaia/local/audit/own.ok"
  touch -t 203001010000 "$REPO/.gaia/local/audit/own.ok"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written own.ok
}

@test "an audit file older than the baseline does not fail" {
  mkdir -p "$REPO/.gaia/local/audit"
  printf 'ok\n' >"$REPO/.gaia/local/audit/old.ok"
  touch -t 200001010000 "$REPO/.gaia/local/audit/old.ok"
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "COV-004: a dispositions file edited after its digest fails bad-input" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  jq '.enforcement_paths_allowed += [".claude/settings.json"]' "$DISPOSITIONS_FILE" >"$DISPOSITIONS_FILE.new"
  mv "$DISPOSITIONS_FILE.new" "$DISPOSITIONS_FILE"
  do_check
  assert_fail_kind bad-input "dispositions file digest"
}

@test "COV-004: a baseline file edited after its digest fails bad-input" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  jq '.dirty = {"a.txt": "deleted"}' "$BASELINE_FILE" >"$BASELINE_FILE.new"
  mv "$BASELINE_FILE.new" "$BASELINE_FILE"
  do_check
  assert_fail_kind bad-input "baseline file digest"
}

@test "COV-004: with correct digests the edited inputs are judged on their merits" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  jq '.enforcement_paths_allowed += [".claude/settings.json"]' "$DISPOSITIONS_FILE" >"$DISPOSITIONS_FILE.new"
  mv "$DISPOSITIONS_FILE.new" "$DISPOSITIONS_FILE"
  take_digests
  do_check
  assert_fail_kind bad-input "no fix entry names"
}

@test "--extra-declared: an autofix-changed path in the file passes, without the flag it fails undeclared-path" {
  prepare
  edit a.txt
  edit b.txt
  edit c.txt
  default_result >"$RESULT_FILE"
  printf 'c.txt\n' >"$RUN_FOLDER/gate-1-1.paths"
  do_check
  assert_fail_kind undeclared-path c.txt
  do_check --extra-declared "$RUN_FOLDER/gate-1-1.paths"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.pass' "$VERIFIER_OUTPUT_FILE")" = true ]
}

@test "baseline refuses with exit 3 and writes nothing when the index has a staged change" {
  edit a.txt
  git -C "$REPO" add a.txt
  write_dispositions "$(default_entries)"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 3 ]
  [ ! -e "$BASELINE_FILE" ]
  case "$output" in
    *"index differs from HEAD"*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "UAT-007: baseline over a modified tracked file exits 4, prints member-wave-dirty and a dirty line, writes nothing" {
  edit a.txt
  write_dispositions "$(default_entries)"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 4 ]
  [ ! -e "$BASELINE_FILE" ]
  [ ! -e "$RUN_FOLDER/verifier-bin-1" ]
  printf '%s\n' "$output" | grep -qx 'member-wave-dirty'
  printf '%s\n' "$output" | grep -qx 'dirty a.txt'
}

@test "UAT-007: baseline over an untracked non-ignored file exits 4 and names it" {
  printf 'new\n' >"$REPO/fresh.txt"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 4 ]
  [ ! -e "$BASELINE_FILE" ]
  printf '%s\n' "$output" | grep -qx 'member-wave-dirty'
  printf '%s\n' "$output" | grep -qx 'dirty fresh.txt'
}

@test "UAT-007: baseline names every dirty path, modified and untracked together" {
  edit a.txt
  edit "with space.txt"
  printf 'new\n' >"$REPO/fresh.txt"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 4 ]
  printf '%s\n' "$output" | grep -qx 'dirty a.txt'
  printf '%s\n' "$output" | grep -qx 'dirty with space.txt'
  printf '%s\n' "$output" | grep -qx 'dirty fresh.txt'
}

@test "UAT-007: baseline passes when the only new file is git-ignored" {
  mkdir -p "$REPO/.gaia/local/audit"
  printf 'x\n' >"$REPO/.gaia/local/audit/sidecar.json"
  printf 'ignored.log\n' >>"$REPO/.git/info/exclude"
  printf 'x\n' >"$REPO/ignored.log"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 0 ]
  [ -e "$BASELINE_FILE" ]
}

@test "bad-input: the wrong round fails" {
  prepare
  edit a.txt
  edit b.txt
  default_result | jq '.round = 2' >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "wrong round"
}

@test "bad-input: a dispositions file with the wrong round fails" {
  write_dispositions "$(default_entries)"
  jq '.round = 2' "$DISPOSITIONS_FILE" >"$DISPOSITIONS_FILE.new"
  mv "$DISPOSITIONS_FILE.new" "$DISPOSITIONS_FILE"
  take_baseline
  take_digests
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "wrong round"
}

@test "bad-input: a result attempt 1 against --attempt 2 (the continuation case) fails" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  ATTEMPT=2
  VERIFIER_OUTPUT_FILE="$RUN_FOLDER/verifier-1-2.json"
  do_check
  assert_fail_kind bad-input "attempt"
  [ "$(jq -r '.attempt' "$VERIFIER_OUTPUT_FILE")" = 2 ]
}

@test "bad-input: unparseable JSON fails" {
  prepare
  edit a.txt
  printf '{not json' >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "result file"
}

@test "bad-input: a result path with a .. segment fails" {
  prepare
  edit a.txt
  edit b.txt
  default_result | jq '.changed_paths += ["../x"]' >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "../x"
}

@test "bad-input: an absolute and a dash-leading result path fail" {
  prepare
  edit a.txt
  edit b.txt
  default_result | jq '.changed_paths += ["/etc/passwd", "-rf"]' >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "/etc/passwd"
  case "$output" in
    *"-rf"*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "paths with spaces are hashed and compared correctly" {
  write_dispositions '[{"member":"m","finding_class":"c1","path":"with space.txt","line":1,"disposition":"fix"}]'
  take_baseline
  take_digests
  edit "with space.txt"
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"with space.txt","line":1,"disposition":"fixed","reason":"r","changed_paths":["with space.txt"]}],"changed_paths":["with space.txt"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
  printf 'x\n' >"$REPO/other space.txt"
  do_check
  assert_fail_kind undeclared-path "other space.txt"
}

@test "round-check: gate logs with passing verifiers exit 0, a missing or failing verifier exits 1 naming the log" {
  local runs_directory="$BATS_TEST_TMPDIR/runs" attempt_number
  mkdir -p "$runs_directory"
  for attempt_number in 1 2 3; do
    : >"$runs_directory/gate-3-$attempt_number.log"
    printf '{"pass":true}\n' >"$runs_directory/verifier-3-$attempt_number.json"
  done
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 0 ]
  rm "$runs_directory/verifier-3-2.json"
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 1 ]
  case "$output" in
    *gate-3-2.log*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
  printf '{"pass":false}\n' >"$runs_directory/verifier-3-2.json"
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 1 ]
  case "$output" in
    *gate-3-2.log*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "round-check: no gate logs, or logs of another round, exit 0" {
  local runs_directory="$BATS_TEST_TMPDIR/runs"
  mkdir -p "$runs_directory"
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 0 ]
  : >"$runs_directory/gate-2-1.log"
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 0 ]
}

@test "drift: exit 0 on a tree equal to the baseline" {
  take_baseline
  run bash "$SCRIPT" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 0 ]
}

@test "drift: exit 1 naming the path after a further edit" {
  take_baseline
  edit stray.txt
  run bash "$SCRIPT" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 1 ]
  case "$output" in
    *stray.txt*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "drift: exit 1 naming the path after a new untracked file" {
  take_baseline
  printf 'n\n' >"$REPO/fresh.txt"
  run bash "$SCRIPT" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 1 ]
  case "$output" in
    *fresh.txt*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "drift: exit 1 after a staged change" {
  take_baseline
  edit a.txt
  git -C "$REPO" add a.txt
  run bash "$SCRIPT" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 1 ]
  case "$output" in
    *index-changed*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "usage: a missing option and an unknown subcommand exit 2" {
  run bash "$SCRIPT" check --root "$REPO"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" nope
  [ "$status" -eq 2 ]
}

@test "the verifier output is written atomically with the C9 shape on failure" {
  prepare
  edit c.txt
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 1 ]
  jq -e '.schema == 1 and .round == 1 and .attempt == 1 and .pass == false and (.errors | length > 0)' "$VERIFIER_OUTPUT_FILE" >/dev/null
  [ -z "$(find "$RUN_FOLDER" -name 'verifier-1-1.json.*')" ]
}

# --- the pinned verifier ---

@test "baseline pins the verifier and its libraries beside the baseline file and records their digest" {
  prepare
  for file_name in audit-fix-verify.sh main-root-lib.sh audit-key-lib.sh; do
    cmp "$RUN_FOLDER/verifier-bin-1/$file_name" "$BATS_TEST_DIRNAME/../$file_name"
  done
  jq -e '(.verifier_files | sort) == ["audit-fix-verify.sh","audit-key-lib.sh","main-root-lib.sh"]
    and (.verifier_digest | test("^[0-9a-f]{64}$"))' "$BASELINE_FILE" >/dev/null
}

@test "check, drift and round-check run from the pinned copy and pass" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" check --root "$REPO" --round 1 --attempt 1 \
    --dispositions "$DISPOSITIONS_FILE" --dispositions-sha "$DISPOSITIONS_SHA" --baseline "$BASELINE_FILE" --baseline-sha "$BASELINE_SHA" \
    --result "$RESULT_FILE" --out "$VERIFIER_OUTPUT_FILE"
  [ "$status" -eq 0 ]
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" round-check --run-folder "$RUN_FOLDER" --round 1
  [ "$status" -eq 0 ]
}

@test "a tampered pinned copy fails check with bad-input" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  printf '# edited\n' >>"$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh"
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" check --root "$REPO" --round 1 --attempt 1 \
    --dispositions "$DISPOSITIONS_FILE" --dispositions-sha "$DISPOSITIONS_SHA" --baseline "$BASELINE_FILE" --baseline-sha "$BASELINE_SHA" \
    --result "$RESULT_FILE" --out "$VERIFIER_OUTPUT_FILE"
  [ "$status" -eq 1 ]
  jq -e '[.errors[].kind] | index("bad-input") != null' "$VERIFIER_OUTPUT_FILE" >/dev/null
  [[ "$output" == *"pinned"* ]]
}

@test "a tampered pinned library fails drift and round-check" {
  prepare
  printf '# edited\n' >>"$RUN_FOLDER/verifier-bin-1/main-root-lib.sh"
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pinned"* ]]
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" round-check --run-folder "$RUN_FOLDER" --round 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"pinned"* ]]
}

@test "a baseline that records no pin fails check with bad-input" {
  prepare
  jq 'del(.verifier_digest)' "$BASELINE_FILE" >"$BASELINE_FILE.n"
  mv "$BASELINE_FILE.n" "$BASELINE_FILE"
  take_digests
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input pinned
}
