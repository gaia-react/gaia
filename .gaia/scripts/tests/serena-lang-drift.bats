#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/lib/serena-lang.sh (SPEC-016 Serena Language
# Sync). Covers three surfaces of the shared library:
#
#   1. Detection: serena_language_drift / the `drift` subcommand across the SPEC's
#      false-positive and false-negative UATs (UAT-001..010), plus the two
#      cases that exercise the real refresher .gaia/scripts/check-updates.sh
#      end to end (UAT-011 with jq, UAT-012 without jq).
#   2. Subcommand dispatch: the executable surface /gaia-serena-sync actually
#      calls (`registered`, `drift`, `classify`, `valid`). A routing/stdout/exit
#      bug here breaks the command while every function-level test still passes.
#   3. Apply path: serena_language_append / the `append` subcommand. Golden-file
#      byte-identity across block (0-indent, 2-indent) and flow forms
#      (UAT-019..021), idempotency (UAT-024), token normalization, and the
#      prompt-only fallback checklist (UAT-026).
#
# Hermeticity: every fixture lives under a per-test mktemp -d with a fake $HOME.
# Nothing touches the real repo's .serena/project.yml, ~/.claude.json, or
# .gaia/local/cache/shared/. The library function/subcommand is invoked directly for the
# unit cases; only UAT-011/012 run check-updates.sh, and those neuter its
# gh/curl/gaia side effects (stubbed gh/curl, absent GAIA_BIN).
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# Valid-YAML reparse: the apply tests assert byte-identity structurally with
# `diff` (always), and additionally reparse the result with python3 + PyYAML to
# confirm the `languages:` set equals the intended union. The PyYAML reparse is
# guarded by a presence check (have_pyyaml) so a missing optional module never
# fails the suite; the structural assertions still run.

# ---------- bash-3.2-safe assertion helpers ----------
assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

refute_contains() {
  if grep -qF -- "$1" <<<"$output"; then
    echo "unexpected match: $1" >&2
    return 1
  fi
}

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  # shellcheck source=.gaia/tests/helpers/path.sh
  . "$( cd "$THIS_DIRECTORY/../../.." && pwd )/.gaia/tests/helpers/path.sh"
  LIBRARY="$THIS_DIRECTORY/../lib/serena-lang.sh"
  CHECK_SOURCE="$THIS_DIRECTORY/../check-updates.sh"
  [ -f "$LIBRARY" ] || skip "serena-lang.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  # Canonicalize via `pwd -P`: macOS resolves /var -> /private/var inside
  # `git rev-parse`, and detection reports paths from the canonical form.
  TEMPORARY_ROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/gaia-serena-drift-XXXXXX")"
  TEMPORARY_ROOT="$(cd "$TEMPORARY_ROOT_RAW" && pwd -P)"

  # Git identity for staging inside the sandbox (CI without a configured user).
  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  # Fake homes: one registers Serena as an MCP server, one does not.
  HOME_YES="$TEMPORARY_ROOT/home-yes"
  HOME_NO="$TEMPORARY_ROOT/home-no"
  mkdir -p "$HOME_YES" "$HOME_NO"
  printf '{"mcpServers":{"serena":{"command":"serena"}}}\n' > "$HOME_YES/.claude.json"
  printf '{"mcpServers":{}}\n' > "$HOME_NO/.claude.json"
}

teardown() {
  if [ -n "${TEMPORARY_ROOT:-}" ] && [ -d "$TEMPORARY_ROOT" ]; then
    rm -rf "$TEMPORARY_ROOT"
  fi
  if [ -n "${TEMPORARY_ROOT_RAW:-}" ] && [ "$TEMPORARY_ROOT_RAW" != "${TEMPORARY_ROOT:-}" ] && [ -d "$TEMPORARY_ROOT_RAW" ]; then
    rm -rf "$TEMPORARY_ROOT_RAW"
  fi
}

# ---------- fixture + reparse helpers ----------

# write_file <file> <content-with-\n-escapes>: create parent dirs, write via %b so
# \n in the content becomes newlines.
write_file() {
  local file_path="$1"; shift
  mkdir -p "$(dirname "$file_path")"
  printf '%b' "$*" > "$file_path"
}

# new_repo <name>: init a fresh git repo under TEMPORARY_ROOT; echo its path.
new_repo() {
  local repo="$TEMPORARY_ROOT/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '%s' "$repo"
}

have_pyyaml() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1
}

# reparsed_languages <file>: print the file's `languages:` tokens, sorted, comma-joined,
# via a real YAML reparse. Only called when have_pyyaml is true.
reparsed_languages() {
  python3 - "$1" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
languages = data.get("languages") or []
print(",".join(sorted(languages)))
PY
}

# added/removed line counts between two files (diff normal format).
diff_added() { diff "$1" "$2" | grep -c '^> '; }
diff_removed() { diff "$1" "$2" | grep -c '^< '; }

# Detection (serena_language_drift / the `drift` subcommand)

@test "UAT-001 drift: registered + git-tracked go.mod + config lists only typescript -> [go]" {
  local repo; repo="$(new_repo repo001)"
  write_file "$repo/go.mod" 'module x\n'
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$repo" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '["go"]' ]
}

@test "UAT-002 drift: no tsconfig.json at root still yields [go] (detection does not gate on tsconfig)" {
  local repo; repo="$(new_repo repo002)"
  write_file "$repo/go.mod" 'module x\n'
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  # Deliberately NO tsconfig.json anywhere.
  git -C "$repo" add -A
  [ ! -f "$repo/tsconfig.json" ]
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '["go"]' ]
}

@test "UAT-003 drift: a lone git-tracked *.py with no manifest does not yield python" {
  local repo; repo="$(new_repo repo003)"
  write_file "$repo/foo.py" 'print("hi")\n'
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$repo" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  refute_contains 'python'
}

@test "UAT-004 drift: go.mod present but Serena NOT registered -> []" {
  local repo; repo="$(new_repo repo004)"
  write_file "$repo/go.mod" 'module x\n'
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$repo" add -A
  run env HOME="$HOME_NO" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-005 drift: go.mod present but no .serena/project.yml -> []" {
  local repo; repo="$(new_repo repo005)"
  write_file "$repo/go.mod" 'module x\n'
  git -C "$repo" add -A
  [ ! -f "$repo/.serena/project.yml" ]
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-006 drift: go.mod inside a gitignored/untracked dir does not yield go" {
  local repo; repo="$(new_repo repo006)"
  write_file "$repo/.gitignore" 'vendor/\n'
  write_file "$repo/vendor/go.mod" 'module vendored\n'
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  write_file "$repo/README.md" 'x\n'
  git -C "$repo" add -A
  # The vendored manifest is not tracked. Captured directly rather than through
  # `run`/refute_contains: bats' $output is a command substitution and would
  # discard the NUL separators `-z` adds, so the NUL-safe capture and the
  # substring check both happen here instead.
  local tracked
  tracked="$(git -C "$repo" ls-files -z | tr '\0' '\n')"
  grep -qF -- 'vendor/go.mod' <<<"$tracked" && return 1
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-007 drift: project.local.yml sets languages: [typescript, go] -> no go drift" {
  local repo; repo="$(new_repo repo007)"
  write_file "$repo/go.mod" 'module x\n'
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  write_file "$repo/.serena/project.local.yml" 'languages: [typescript, go]\n'
  git -C "$repo" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "regression: a full-line comment inside the languages: block does not hide later items" {
  local repo; repo="$(new_repo repo_comment)"
  write_file "$repo/go.mod" 'module x\n'
  # `go` is listed AFTER a mid-list comment. A YAML comment does not end a
  # block sequence, so `go` IS configured and must not drift. If the reader
  # treated the comment as terminating the list, go would be invisible and
  # drift would false-positive with ["go"].
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n# go for the worker service\n- go\n'
  git -C "$repo" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-008 drift: legacy singular language: go read as a one-element set -> no go drift" {
  local repo; repo="$(new_repo repo008)"
  write_file "$repo/go.mod" 'module x\n'
  write_file "$repo/.serena/project.yml" 'language: go\n'
  git -C "$repo" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-009 drift: languages: [python_jedi] variant + pyproject.toml -> no python drift" {
  local repo; repo="$(new_repo repo009)"
  write_file "$repo/pyproject.toml" '[project]\nname = "z"\n'
  write_file "$repo/.serena/project.yml" 'languages: [python_jedi]\n'
  git -C "$repo" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-010 drift: git-tracked Foo.csproj (glob marker) -> [csharp]" {
  local repo; repo="$(new_repo repo010)"
  write_file "$repo/Foo.csproj" '<Project></Project>\n'
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$repo" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '["csharp"]' ]
}

# ---------- UAT-011/012: end-to-end through check-updates.sh ----------

# build_refresher_sandbox <name>: a project root carrying real copies of
# check-updates.sh + the lib, a git-tracked go.mod, a typescript-only
# project.yml, and a full pre-existing update-check.json aged past the 6h TTL.
# Echoes the root path.
build_refresher_sandbox() {
  [ -f "$CHECK_SOURCE" ] || skip "check-updates.sh missing"
  local sandbox="$TEMPORARY_ROOT/$1"
  mkdir -p "$sandbox/.gaia/scripts/lib" "$sandbox/.gaia/local/cache/shared" "$sandbox/.serena"
  cp "$CHECK_SOURCE" "$sandbox/.gaia/scripts/check-updates.sh"
  cp "$LIBRARY" "$sandbox/.gaia/scripts/lib/serena-lang.sh"
  chmod +x "$sandbox/.gaia/scripts/check-updates.sh"
  printf '1.2.3\n' > "$sandbox/.gaia/VERSION"
  git -C "$sandbox" init -q
  printf 'module x\n' > "$sandbox/go.mod"
  printf 'languages:\n- typescript\n' > "$sandbox/.serena/project.yml"
  git -C "$sandbox" add -A
  # A full, current-schema cache, checkedAt far in the past so the TTL gate
  # does not early-exit.
  cat > "$sandbox/.gaia/local/cache/shared/update-check.json" <<'JSON'
{"checkedAt":1000000000,"outdatedCount":7,"gaiaCurrent":"1.2.3","gaiaLatest":"1.2.3","gaiaHasUpdate":false,"hardenCandidateCount":2,"auditNudge":false,"auditNudgeReason":"","auditLastAppliedAt":0,"auditMemoryCount":0,"auditMemoryBaseline":0,"serenaLangDrift":[]}
JSON
  printf '%s' "$sandbox"
}

@test "UAT-011 refresher: aged full cache in a drifting project keeps every field and sets serenaLangDrift" {
  local sandbox; sandbox="$(build_refresher_sandbox refresh011)"
  local cache="$sandbox/.gaia/local/cache/shared/update-check.json"
  # Stub gh + curl so the network fields resolve without hitting the network;
  # GAIA_BIN ($GAIA_DIRECTORY/cli/gaia) is absent so no gaia/harden shell-outs fire.
  local stub="$TEMPORARY_ROOT/stub011"; mkdir -p "$stub"
  printf '#!/bin/sh\nexit 0\n' > "$stub/gh"; chmod +x "$stub/gh"
  printf '#!/bin/sh\nexit 0\n' > "$stub/curl"; chmod +x "$stub/curl"

  run env HOME="$HOME_YES" PATH="$stub:$PATH" bash "$sandbox/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]

  # JSON is valid and carries the correct drift.
  run jq -e . "$cache"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.serenaLangDrift' "$cache")" = '["go"]' ]

  # Every pre-existing field is still present.
  for key in checkedAt outdatedCount gaiaCurrent gaiaLatest gaiaHasUpdate \
    hardenCandidateCount hardenUnclassifiedCount hardenNudgeReason \
    auditNudge auditNudgeReason auditLastAppliedAt \
    auditMemoryCount auditMemoryBaseline serenaLangDrift; do
    [ "$(jq "has(\"$key\")" "$cache")" = "true" ] || return 1
  done

  # A representative pre-existing value survives (GAIA_BIN absent -> preserved).
  [ "$(jq -r '.outdatedCount' "$cache")" = "7" ]
  [ "$(jq -r '.gaiaCurrent' "$cache")" = "1.2.3" ]
}

@test "UAT-012 refresher: no jq on PATH -> valid JSON with serenaLangDrift []" {
  local sandbox; sandbox="$(build_refresher_sandbox refresh012)"
  local cache="$sandbox/.gaia/local/cache/shared/update-check.json"
  # A symlink farm of the tools the refresher needs, deliberately WITHOUT jq,
  # so `command -v jq` fails and the printf write branch runs.
  local farm; farm="$(path_allowlist git date mkdir mktemp mv rm find wc tr sed grep awk ls stat sort head tail cut dirname cat env bash)"
  # Sanity: jq is not reachable through the farm.
  run env PATH="$farm" bash -c 'command -v jq'
  [ "$status" -ne 0 ]

  run env HOME="$HOME_YES" PATH="$farm" bash "$sandbox/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]

  # The file was rewritten (not left as the aged seed) and is valid JSON with
  # an empty drift array. Reparse with the host jq (outside the farm).
  run jq -e . "$cache"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.serenaLangDrift' "$cache")" = '[]' ]
  # checkedAt advanced past the aged seed value.
  [ "$(jq -r '.checkedAt' "$cache")" != "1000000000" ]
}

# Subcommand dispatch (the surface /gaia-serena-sync calls)

@test "dispatch registered: exit 0 when ~/.claude.json registers Serena, non-zero when it does not" {
  local repo; repo="$(new_repo dispatch-reg)"
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  run env HOME="$HOME_YES" bash "$LIBRARY" registered "$repo"
  [ "$status" -eq 0 ]
  run env HOME="$HOME_NO" bash "$LIBRARY" registered "$repo"
  [ "$status" -ne 0 ]
}

@test "dispatch drift: the subcommand prints the same JSON as the serena_language_drift function" {
  local repo; repo="$(new_repo dispatch-drift)"
  write_file "$repo/go.mod" 'module x\n'
  write_file "$repo/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$repo" add -A
  local function_output subcommand_output
  function_output="$(env HOME="$HOME_YES" bash -c 'source "$1"; serena_language_drift "$2"' _ "$LIBRARY" "$repo")"
  subcommand_output="$(env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo")"
  [ "$function_output" = '["go"]' ]
  [ "$function_output" = "$subcommand_output" ]
}

@test "dispatch classify: prints block:<indent> | flow | unsafe:<reason> with matching exit codes" {
  local two_space_indent; two_space_indent="$(printf '  ')"

  write_file "$TEMPORARY_ROOT/c0.yml" 'languages:\n- typescript\n'
  run bash "$LIBRARY" classify "$TEMPORARY_ROOT/c0.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "block:" ]

  write_file "$TEMPORARY_ROOT/c2.yml" 'languages:\n  - typescript\n'
  run bash "$LIBRARY" classify "$TEMPORARY_ROOT/c2.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "block:$two_space_indent" ]

  write_file "$TEMPORARY_ROOT/cf.yml" 'languages: [typescript]\n'
  run bash "$LIBRARY" classify "$TEMPORARY_ROOT/cf.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "flow" ]

  write_file "$TEMPORARY_ROOT/cx.yml" 'project_name: x\n'
  run bash "$LIBRARY" classify "$TEMPORARY_ROOT/cx.yml"
  [ "$status" -ne 0 ]
  [ "$output" = "unsafe:no-key" ]
}

@test "dispatch valid: exit 0 for known base/variant tokens, non-zero for unknown" {
  run bash "$LIBRARY" valid go
  [ "$status" -eq 0 ]
  run bash "$LIBRARY" valid python_jedi
  [ "$status" -eq 0 ]
  run bash "$LIBRARY" valid notalang
  [ "$status" -ne 0 ]
}

# Apply path (serena_language_append / the `append` subcommand)

@test "UAT-019 append: 0-indent block gains '- go' at 0-indent, valid YAML, every other line byte-identical" {
  local yaml_file="$TEMPORARY_ROOT/a0.yml" snapshot="$TEMPORARY_ROOT/a0.snap"
  write_file "$yaml_file" 'project_name: x\nlanguages:\n- typescript\ndefaults: {}\n'
  cp "$yaml_file" "$snapshot"
  run bash "$LIBRARY" append "$yaml_file" go
  [ "$status" -eq 0 ]
  # Exactly one line added, none removed/changed.
  [ "$(diff_added "$snapshot" "$yaml_file")" -eq 1 ]
  [ "$(diff_removed "$snapshot" "$yaml_file")" -eq 0 ]
  # The inserted line is at column 0.
  run grep -n '^- go$' "$yaml_file"
  [ "$status" -eq 0 ]
  if have_pyyaml; then
    [ "$(reparsed_languages "$yaml_file")" = "go,typescript" ]
  fi
}

@test "UAT-020 append: 2-indent block gains '  - go' at matching indent, valid YAML, byte-identical" {
  local yaml_file="$TEMPORARY_ROOT/a2.yml" snapshot="$TEMPORARY_ROOT/a2.snap"
  write_file "$yaml_file" 'languages:\n  - typescript\nother: 1\n'
  cp "$yaml_file" "$snapshot"
  run bash "$LIBRARY" append "$yaml_file" go
  [ "$status" -eq 0 ]
  [ "$(diff_added "$snapshot" "$yaml_file")" -eq 1 ]
  [ "$(diff_removed "$snapshot" "$yaml_file")" -eq 0 ]
  run grep -n '^  - go$' "$yaml_file"
  [ "$status" -eq 0 ]
  if have_pyyaml; then
    [ "$(reparsed_languages "$yaml_file")" = "go,typescript" ]
  fi
}

@test "UAT-021 append: flow list becomes [typescript, go], valid YAML, every other line byte-identical" {
  local yaml_file="$TEMPORARY_ROOT/af.yml" snapshot="$TEMPORARY_ROOT/af.snap"
  write_file "$yaml_file" 'languages: [typescript]\nx: 1\n'
  cp "$yaml_file" "$snapshot"
  run bash "$LIBRARY" append "$yaml_file" go
  [ "$status" -eq 0 ]
  # Flow append rewrites the single languages line: exactly one changed line.
  [ "$(diff_added "$snapshot" "$yaml_file")" -eq 1 ]
  [ "$(diff_removed "$snapshot" "$yaml_file")" -eq 1 ]
  run grep -n '^languages: \[typescript, go\]$' "$yaml_file"
  [ "$status" -eq 0 ]
  # The only removed line is the original languages line (all others intact).
  run diff "$snapshot" "$yaml_file"
  assert_contains '< languages: [typescript]'
  if have_pyyaml; then
    [ "$(reparsed_languages "$yaml_file")" = "go,typescript" ]
  fi
}

@test "UAT-024 append: re-running with an already-present token performs no write (idempotent set-union)" {
  local yaml_file="$TEMPORARY_ROOT/idem.yml" snapshot="$TEMPORARY_ROOT/idem.snap"
  write_file "$yaml_file" 'languages: [typescript, go]\n'
  cp "$yaml_file" "$snapshot"
  run bash "$LIBRARY" append "$yaml_file" go
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Byte-identical: no diff.
  run diff "$snapshot" "$yaml_file"
  [ "$status" -eq 0 ]
}

@test "append normalization: a project already covered by a variant is left unchanged when appending the base token" {
  local yaml_file="$TEMPORARY_ROOT/norm.yml" snapshot="$TEMPORARY_ROOT/norm.snap"
  write_file "$yaml_file" 'languages: [python_jedi]\n'
  cp "$yaml_file" "$snapshot"
  run bash "$LIBRARY" append "$yaml_file" python
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run diff "$snapshot" "$yaml_file"
  [ "$status" -eq 0 ]
}

# ---------- UAT-026: prompt-only fallback checklist (no write) ----------
#
# Each unsafe form routes append to FALLBACK:<reason>, exit non-zero, and leaves
# the file byte-identical. assert_fallback <fixture-content> <reason> <token>.
assert_fallback() {
  local content="$1" reason="$2" token="$3"
  local yaml_file="$TEMPORARY_ROOT/fb.yml" snapshot="$TEMPORARY_ROOT/fb.snap"
  write_file "$yaml_file" "$content"
  cp "$yaml_file" "$snapshot"
  run bash "$LIBRARY" append "$yaml_file" "$token"
  [ "$status" -ne 0 ] || return 1
  grep -qF -- "FALLBACK:$reason" <<<"$output" || return 1
  # No write occurred.
  diff "$snapshot" "$yaml_file" || return 1
}

@test "UAT-026 fallback: malformed YAML (inconsistent block indent) -> FALLBACK:malformed, no write" {
  assert_fallback 'languages:\n  - typescript\n    - go\n' 'malformed' go
}

@test "UAT-026 fallback: no languages: key -> FALLBACK:no-key, no write" {
  assert_fallback 'project_name: x\n' 'no-key' go
}

@test "UAT-026 fallback: languages: is a scalar, not a list -> FALLBACK:not-a-list, no write" {
  assert_fallback 'languages: typescript\n' 'not-a-list' go
}

@test "UAT-026 fallback: more than one languages: key -> FALLBACK:multiple-keys, no write" {
  assert_fallback 'languages:\n- typescript\nlanguages:\n- go\n' 'multiple-keys' go
}

@test "UAT-026 fallback: languages: appears only in a comment -> FALLBACK:comment-only, no write" {
  assert_fallback 'project_name: x\n# languages: [typescript]\n' 'comment-only' go
}

@test "UAT-026 fallback: legacy singular language: scalar with no list -> FALLBACK:legacy-scalar, no write" {
  assert_fallback 'language: go\n' 'legacy-scalar' python
}

@test "UAT-026 fallback: multi-line flow list -> FALLBACK:complex, no write" {
  assert_fallback 'languages: [\n  typescript\n]\n' 'complex' go
}

@test "UAT-026 fallback: an invalid/unknown token against a safe form -> FALLBACK:invalid-token, no write" {
  assert_fallback 'languages: [typescript]\n' 'invalid-token' notalang
}

# ---------- language_servers: key (Serena v1.7) and new tokens ----------

# file_sha256 <file>: print the file's sha256 with whichever tool the host has.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

@test "language_servers block form: same drift verdict as languages, append lands under language_servers at matching indent, other lines byte-identical" {
  local repo_old repo_new yaml_file snapshot
  repo_old="$(new_repo repo-ls-old)"
  repo_new="$(new_repo repo-ls-new)"
  write_file "$repo_old/go.mod" 'module x\n'
  write_file "$repo_new/go.mod" 'module x\n'
  write_file "$repo_old/.serena/project.yml" 'project_name: x\nlanguages:\n  - typescript\ndefaults: {}\n'
  write_file "$repo_new/.serena/project.yml" 'project_name: x\nlanguage_servers:\n  - typescript\ndefaults: {}\n'
  git -C "$repo_old" add -A
  git -C "$repo_new" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo_old"
  [ "$output" = '["go"]' ]
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo_new"
  [ "$status" -eq 0 ]
  [ "$output" = '["go"]' ]

  yaml_file="$repo_new/.serena/project.yml"
  snapshot="$TEMPORARY_ROOT/ls-block.snap"
  cp "$yaml_file" "$snapshot"
  run bash "$LIBRARY" classify "$yaml_file"
  [ "$status" -eq 0 ]
  [ "$output" = 'block:  ' ]
  run bash "$LIBRARY" append "$yaml_file" go
  [ "$status" -eq 0 ]
  [ "$(diff_added "$snapshot" "$yaml_file")" -eq 1 ]
  [ "$(diff_removed "$snapshot" "$yaml_file")" -eq 0 ]
  [ "$(sed -n '4p' "$yaml_file")" = '  - go' ]
  [ "$(sed -n '2p' "$yaml_file")" = 'language_servers:' ]
}

@test "language_servers flow form: append goes inside the flow list, every other line byte-identical" {
  local yaml_file="$TEMPORARY_ROOT/ls-flow.yml" snapshot="$TEMPORARY_ROOT/ls-flow.snap"
  write_file "$yaml_file" 'project_name: x\nlanguage_servers: [typescript]\nother: 1\n'
  cp "$yaml_file" "$snapshot"
  run bash "$LIBRARY" classify "$yaml_file"
  [ "$status" -eq 0 ]
  [ "$output" = 'flow' ]
  run bash "$LIBRARY" append "$yaml_file" go
  [ "$status" -eq 0 ]
  [ "$(sed -n '2p' "$yaml_file")" = 'language_servers: [typescript, go]' ]
  [ "$(diff_added "$snapshot" "$yaml_file")" -eq 1 ]
  [ "$(diff_removed "$snapshot" "$yaml_file")" -eq 1 ]
  [ "$(sed -n '1p;3p' "$yaml_file")" = "$(sed -n '1p;3p' "$snapshot")" ]
}

@test "language_servers in project.local.yml contributes to effective and suppresses matching drift" {
  local repo; repo="$(new_repo repo-ls-local)"
  write_file "$repo/go.mod" 'module x\n'
  write_file "$repo/.serena/project.yml" 'language_servers:\n  - typescript\n'
  write_file "$repo/.serena/project.local.yml" 'language_servers:\n  - go\n'
  git -C "$repo" add -A
  run bash "$LIBRARY" effective "$repo"
  [ "$status" -eq 0 ]
  assert_contains 'go'
  assert_contains 'typescript'
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "both languages and language_servers present: classify is unsafe:multiple-keys and append leaves the file's hash unchanged" {
  local yaml_file="$TEMPORARY_ROOT/both.yml" before after
  write_file "$yaml_file" 'languages:\n  - typescript\nlanguage_servers:\n  - typescript\n'
  before="$(file_sha256 "$yaml_file")"
  run bash "$LIBRARY" classify "$yaml_file"
  [ "$status" -ne 0 ]
  [ "$output" = 'unsafe:multiple-keys' ]
  run bash "$LIBRARY" append "$yaml_file" go
  [ "$status" -ne 0 ]
  [ "$output" = 'FALLBACK:multiple-keys' ]
  after="$(file_sha256 "$yaml_file")"
  [ -n "$before" ]
  [ "$before" = "$after" ]
}

@test "variant servers count as their base language: pyrefly and basedpyright cover python, phpantom covers php" {
  local variant repo
  for variant in python_pyrefly python_basedpyright; do
    repo="$(new_repo "repo-$variant")"
    write_file "$repo/pyproject.toml" '[project]\n'
    write_file "$repo/.serena/project.yml" "language_servers: [$variant]\n"
    git -C "$repo" add -A
    run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
    [ "$status" -eq 0 ]
    [ "$output" = '[]' ]
  done
  repo="$(new_repo repo-phpantom)"
  write_file "$repo/composer.json" '{}\n'
  write_file "$repo/.serena/project.yml" 'language_servers: [php_phpantom]\n'
  git -C "$repo" add -A
  run env HOME="$HOME_YES" bash "$LIBRARY" drift "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "normalize maps the new python and php variants to their base language" {
  run bash "$LIBRARY" normalize python_pyrefly
  [ "$output" = 'python' ]
  run bash "$LIBRARY" normalize python_basedpyright
  [ "$output" = 'python' ]
  run bash "$LIBRARY" normalize php_phpantom
  [ "$output" = 'php' ]
}

@test "valid accepts every v1.7 token and rejects an unknown one" {
  local token
  for token in angular svelte scss html deno gleam python_pyrefly python_basedpyright php_phpantom; do
    run bash "$LIBRARY" valid "$token"
    [ "$status" -eq 0 ] || { echo "rejected: $token" >&2; return 1; }
  done
  run bash "$LIBRARY" valid notalanguage
  [ "$status" -ne 0 ]
}

@test "guard can fail: a copy of the library with language_servers reverted at the flow-append site cannot append to a language_servers flow list" {
  local mutated="$TEMPORARY_ROOT/serena-lang-mutated.sh" yaml_file="$TEMPORARY_ROOT/mut.yml" before
  write_file "$yaml_file" 'language_servers: [typescript]\n'
  # Control: the real library appends.
  run bash "$LIBRARY" append "$yaml_file" go
  [ "$status" -eq 0 ]
  write_file "$yaml_file" 'language_servers: [typescript]\n'
  # Revert the key lookup inside _serena_append_flow only to the pre-1.7 spelling.
  awk '
    /^_serena_append_flow\(\)/ { inside = 1 }
    inside && /key_line_number=\$\(grep -nE/ {
      sub(/\$\{SERENA_LIST_KEY_ERE\}/, "languages"); inside = 0
    }
    { print }
  ' "$LIBRARY" > "$mutated"
  if cmp -s "$LIBRARY" "$mutated"; then
    echo "mutation did not change the copy" >&2
    return 1
  fi
  before="$(file_sha256 "$yaml_file")"
  run bash "$mutated" append "$yaml_file" go
  [ "$status" -ne 0 ]
  [ "$(file_sha256 "$yaml_file")" = "$before" ]
}
