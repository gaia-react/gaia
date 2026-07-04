#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/lib/serena-lang.sh (SPEC-016 Serena Language
# Sync). Covers three surfaces of the shared library:
#
#   1. Detection: serena_lang_drift / the `drift` subcommand across the SPEC's
#      false-positive and false-negative UATs (UAT-001..010), plus the two
#      cases that exercise the real refresher .gaia/scripts/check-updates.sh
#      end to end (UAT-011 with jq, UAT-012 without jq).
#   2. Subcommand dispatch: the executable surface /gaia-serena-sync actually
#      calls (`registered`, `drift`, `classify`, `valid`). A routing/stdout/exit
#      bug here breaks the command while every function-level test still passes.
#   3. Apply path: serena_lang_append / the `append` subcommand. Golden-file
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
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` for
# equality/status, `grep -qF` for substrings, explicit `return 1` branches, so
# a false mid-test check fails on macOS's bash 3.2 as well as CI's bash 5.
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
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  LIB="$THIS_DIR/../lib/serena-lang.sh"
  CHECK_SRC="$THIS_DIR/../check-updates.sh"
  [ -f "$LIB" ] || skip "serena-lang.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  # Canonicalize via `pwd -P`: macOS resolves /var -> /private/var inside
  # `git rev-parse`, and detection reports paths from the canonical form.
  TMPROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/gaia-serena-drift-XXXXXX")"
  TMPROOT="$(cd "$TMPROOT_RAW" && pwd -P)"

  # Git identity for staging inside the sandbox (CI without a configured user).
  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  # Fake homes: one registers Serena as an MCP server, one does not.
  HOME_YES="$TMPROOT/home-yes"
  HOME_NO="$TMPROOT/home-no"
  mkdir -p "$HOME_YES" "$HOME_NO"
  printf '{"mcpServers":{"serena":{"command":"serena"}}}\n' > "$HOME_YES/.claude.json"
  printf '{"mcpServers":{}}\n' > "$HOME_NO/.claude.json"
}

teardown() {
  if [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ]; then
    rm -rf "$TMPROOT"
  fi
  if [ -n "${TMPROOT_RAW:-}" ] && [ "$TMPROOT_RAW" != "${TMPROOT:-}" ] && [ -d "$TMPROOT_RAW" ]; then
    rm -rf "$TMPROOT_RAW"
  fi
}

# ---------- fixture + reparse helpers ----------

# writef <file> <content-with-\n-escapes>: create parent dirs, write via %b so
# \n in the content becomes newlines.
writef() {
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  printf '%b' "$*" > "$f"
}

# new_repo <name>: init a fresh git repo under TMPROOT; echo its path.
new_repo() {
  local r="$TMPROOT/$1"
  mkdir -p "$r"
  git -C "$r" init -q
  printf '%s' "$r"
}

have_pyyaml() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1
}

# py_langs <file>: print the file's `languages:` tokens, sorted, comma-joined,
# via a real YAML reparse. Only called when have_pyyaml is true.
py_langs() {
  python3 - "$1" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
langs = data.get("languages") or []
print(",".join(sorted(langs)))
PY
}

# added/removed line counts between two files (diff normal format).
diff_added() { diff "$1" "$2" | grep -c '^> '; }
diff_removed() { diff "$1" "$2" | grep -c '^< '; }

# ============================================================
# Detection (serena_lang_drift / the `drift` subcommand)
# ============================================================

@test "UAT-001 drift: registered + git-tracked go.mod + config lists only typescript -> [go]" {
  local r; r="$(new_repo repo001)"
  writef "$r/go.mod" 'module x\n'
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$r" add -A
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '["go"]' ]
}

@test "UAT-002 drift: no tsconfig.json at root still yields [go] (detection does not gate on tsconfig)" {
  local r; r="$(new_repo repo002)"
  writef "$r/go.mod" 'module x\n'
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  # Deliberately NO tsconfig.json anywhere.
  git -C "$r" add -A
  [ ! -f "$r/tsconfig.json" ]
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '["go"]' ]
}

@test "UAT-003 drift: a lone git-tracked *.py with no manifest does not yield python" {
  local r; r="$(new_repo repo003)"
  writef "$r/foo.py" 'print("hi")\n'
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$r" add -A
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  refute_contains 'python'
}

@test "UAT-004 drift: go.mod present but Serena NOT registered -> []" {
  local r; r="$(new_repo repo004)"
  writef "$r/go.mod" 'module x\n'
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$r" add -A
  run env HOME="$HOME_NO" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-005 drift: go.mod present but no .serena/project.yml -> []" {
  local r; r="$(new_repo repo005)"
  writef "$r/go.mod" 'module x\n'
  git -C "$r" add -A
  [ ! -f "$r/.serena/project.yml" ]
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-006 drift: go.mod inside a gitignored/untracked dir does not yield go" {
  local r; r="$(new_repo repo006)"
  writef "$r/.gitignore" 'vendor/\n'
  writef "$r/vendor/go.mod" 'module vendored\n'
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  writef "$r/README.md" 'x\n'
  git -C "$r" add -A
  # The vendored manifest is not tracked.
  run git -C "$r" ls-files
  refute_contains 'vendor/go.mod'
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-007 drift: project.local.yml sets languages: [typescript, go] -> no go drift" {
  local r; r="$(new_repo repo007)"
  writef "$r/go.mod" 'module x\n'
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  writef "$r/.serena/project.local.yml" 'languages: [typescript, go]\n'
  git -C "$r" add -A
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "regression: a full-line comment inside the languages: block does not hide later items" {
  local r; r="$(new_repo repo_comment)"
  writef "$r/go.mod" 'module x\n'
  # `go` is listed AFTER a mid-list comment. A YAML comment does not end a
  # block sequence, so `go` IS configured and must not drift. If the reader
  # treated the comment as terminating the list, go would be invisible and
  # drift would false-positive with ["go"].
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n# go for the worker service\n- go\n'
  git -C "$r" add -A
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-008 drift: legacy singular language: go read as a one-element set -> no go drift" {
  local r; r="$(new_repo repo008)"
  writef "$r/go.mod" 'module x\n'
  writef "$r/.serena/project.yml" 'language: go\n'
  git -C "$r" add -A
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-009 drift: languages: [python_jedi] variant + pyproject.toml -> no python drift" {
  local r; r="$(new_repo repo009)"
  writef "$r/pyproject.toml" '[project]\nname = "z"\n'
  writef "$r/.serena/project.yml" 'languages: [python_jedi]\n'
  git -C "$r" add -A
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "UAT-010 drift: git-tracked Foo.csproj (glob marker) -> [csharp]" {
  local r; r="$(new_repo repo010)"
  writef "$r/Foo.csproj" '<Project></Project>\n'
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$r" add -A
  run env HOME="$HOME_YES" bash "$LIB" drift "$r"
  [ "$status" -eq 0 ]
  [ "$output" = '["csharp"]' ]
}

# ---------- UAT-011/012: end-to-end through check-updates.sh ----------

# build_refresher_sandbox <name>: a project root carrying real copies of
# check-updates.sh + the lib, a git-tracked go.mod, a typescript-only
# project.yml, and a full pre-existing update-check.json aged past the 6h TTL.
# Echoes the root path.
build_refresher_sandbox() {
  [ -f "$CHECK_SRC" ] || skip "check-updates.sh missing"
  local s="$TMPROOT/$1"
  mkdir -p "$s/.gaia/scripts/lib" "$s/.gaia/local/cache/shared" "$s/.serena"
  cp "$CHECK_SRC" "$s/.gaia/scripts/check-updates.sh"
  cp "$LIB" "$s/.gaia/scripts/lib/serena-lang.sh"
  chmod +x "$s/.gaia/scripts/check-updates.sh"
  printf '1.2.3\n' > "$s/.gaia/VERSION"
  git -C "$s" init -q
  printf 'module x\n' > "$s/go.mod"
  printf 'languages:\n- typescript\n' > "$s/.serena/project.yml"
  git -C "$s" add -A
  # A full, current-schema cache, checkedAt far in the past so the TTL gate
  # does not early-exit.
  cat > "$s/.gaia/local/cache/shared/update-check.json" <<'JSON'
{"checkedAt":1000000000,"outdatedCount":7,"gaiaCurrent":"1.2.3","gaiaLatest":"1.2.3","gaiaHasUpdate":false,"hardenCandidateCount":2,"auditNudge":false,"auditNudgeReason":"","auditLastAppliedAt":0,"auditMemoryCount":0,"auditMemoryBaseline":0,"serenaLangDrift":[]}
JSON
  printf '%s' "$s"
}

@test "UAT-011 refresher: aged full cache in a drifting project keeps every field and sets serenaLangDrift" {
  local s; s="$(build_refresher_sandbox refresh011)"
  local cache="$s/.gaia/local/cache/shared/update-check.json"
  # Stub gh + curl so the network fields resolve without hitting the network;
  # GAIA_BIN ($GAIA_DIR/cli/gaia) is absent so no gaia/harden shell-outs fire.
  local stub="$TMPROOT/stub011"; mkdir -p "$stub"
  printf '#!/bin/sh\nexit 0\n' > "$stub/gh"; chmod +x "$stub/gh"
  printf '#!/bin/sh\nexit 0\n' > "$stub/curl"; chmod +x "$stub/curl"

  run env HOME="$HOME_YES" PATH="$stub:$PATH" bash "$s/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]

  # JSON is valid and carries the correct drift.
  run jq -e . "$cache"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.serenaLangDrift' "$cache")" = '["go"]' ]

  # Every pre-existing field is still present.
  for key in checkedAt outdatedCount gaiaCurrent gaiaLatest gaiaHasUpdate \
    hardenCandidateCount auditNudge auditNudgeReason auditLastAppliedAt \
    auditMemoryCount auditMemoryBaseline serenaLangDrift; do
    [ "$(jq "has(\"$key\")" "$cache")" = "true" ] || return 1
  done

  # A representative pre-existing value survives (GAIA_BIN absent -> preserved).
  [ "$(jq -r '.outdatedCount' "$cache")" = "7" ]
  [ "$(jq -r '.gaiaCurrent' "$cache")" = "1.2.3" ]
}

@test "UAT-012 refresher: no jq on PATH -> valid JSON with serenaLangDrift []" {
  local s; s="$(build_refresher_sandbox refresh012)"
  local cache="$s/.gaia/local/cache/shared/update-check.json"
  # A symlink farm of the tools the refresher needs, deliberately WITHOUT jq,
  # so `command -v jq` fails and the printf write branch runs.
  local farm="$TMPROOT/nojq012"; mkdir -p "$farm"
  local t p
  for t in git date mkdir mktemp mv rm find wc tr sed grep awk ls stat sort head tail cut dirname cat env bash; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$farm/$t"
  done
  # Sanity: jq is not reachable through the farm.
  run env PATH="$farm" bash -c 'command -v jq'
  [ "$status" -ne 0 ]

  run env HOME="$HOME_YES" PATH="$farm" bash "$s/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]

  # The file was rewritten (not left as the aged seed) and is valid JSON with
  # an empty drift array. Reparse with the host jq (outside the farm).
  run jq -e . "$cache"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.serenaLangDrift' "$cache")" = '[]' ]
  # checkedAt advanced past the aged seed value.
  [ "$(jq -r '.checkedAt' "$cache")" != "1000000000" ]
}

# ============================================================
# Subcommand dispatch (the surface /gaia-serena-sync calls)
# ============================================================

@test "dispatch registered: exit 0 when ~/.claude.json registers Serena, non-zero when it does not" {
  local r; r="$(new_repo dispatch-reg)"
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  run env HOME="$HOME_YES" bash "$LIB" registered "$r"
  [ "$status" -eq 0 ]
  run env HOME="$HOME_NO" bash "$LIB" registered "$r"
  [ "$status" -ne 0 ]
}

@test "dispatch drift: the subcommand prints the same JSON as the serena_lang_drift function" {
  local r; r="$(new_repo dispatch-drift)"
  writef "$r/go.mod" 'module x\n'
  writef "$r/.serena/project.yml" 'languages:\n- typescript\n'
  git -C "$r" add -A
  local fn sub
  fn="$(env HOME="$HOME_YES" bash -c 'source "$1"; serena_lang_drift "$2"' _ "$LIB" "$r")"
  sub="$(env HOME="$HOME_YES" bash "$LIB" drift "$r")"
  [ "$fn" = '["go"]' ]
  [ "$fn" = "$sub" ]
}

@test "dispatch classify: prints block:<indent> | flow | unsafe:<reason> with matching exit codes" {
  local two; two="$(printf '  ')"

  writef "$TMPROOT/c0.yml" 'languages:\n- typescript\n'
  run bash "$LIB" classify "$TMPROOT/c0.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "block:" ]

  writef "$TMPROOT/c2.yml" 'languages:\n  - typescript\n'
  run bash "$LIB" classify "$TMPROOT/c2.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "block:$two" ]

  writef "$TMPROOT/cf.yml" 'languages: [typescript]\n'
  run bash "$LIB" classify "$TMPROOT/cf.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "flow" ]

  writef "$TMPROOT/cx.yml" 'project_name: x\n'
  run bash "$LIB" classify "$TMPROOT/cx.yml"
  [ "$status" -ne 0 ]
  [ "$output" = "unsafe:no-key" ]
}

@test "dispatch valid: exit 0 for known base/variant tokens, non-zero for unknown" {
  run bash "$LIB" valid go
  [ "$status" -eq 0 ]
  run bash "$LIB" valid python_jedi
  [ "$status" -eq 0 ]
  run bash "$LIB" valid notalang
  [ "$status" -ne 0 ]
}

# ============================================================
# Apply path (serena_lang_append / the `append` subcommand)
# ============================================================

@test "UAT-019 append: 0-indent block gains '- go' at 0-indent, valid YAML, every other line byte-identical" {
  local f="$TMPROOT/a0.yml" snap="$TMPROOT/a0.snap"
  writef "$f" 'project_name: x\nlanguages:\n- typescript\ndefaults: {}\n'
  cp "$f" "$snap"
  run bash "$LIB" append "$f" go
  [ "$status" -eq 0 ]
  # Exactly one line added, none removed/changed.
  [ "$(diff_added "$snap" "$f")" -eq 1 ]
  [ "$(diff_removed "$snap" "$f")" -eq 0 ]
  # The inserted line is at column 0.
  run grep -n '^- go$' "$f"
  [ "$status" -eq 0 ]
  if have_pyyaml; then
    [ "$(py_langs "$f")" = "go,typescript" ]
  fi
}

@test "UAT-020 append: 2-indent block gains '  - go' at matching indent, valid YAML, byte-identical" {
  local f="$TMPROOT/a2.yml" snap="$TMPROOT/a2.snap"
  writef "$f" 'languages:\n  - typescript\nother: 1\n'
  cp "$f" "$snap"
  run bash "$LIB" append "$f" go
  [ "$status" -eq 0 ]
  [ "$(diff_added "$snap" "$f")" -eq 1 ]
  [ "$(diff_removed "$snap" "$f")" -eq 0 ]
  run grep -n '^  - go$' "$f"
  [ "$status" -eq 0 ]
  if have_pyyaml; then
    [ "$(py_langs "$f")" = "go,typescript" ]
  fi
}

@test "UAT-021 append: flow list becomes [typescript, go], valid YAML, every other line byte-identical" {
  local f="$TMPROOT/af.yml" snap="$TMPROOT/af.snap"
  writef "$f" 'languages: [typescript]\nx: 1\n'
  cp "$f" "$snap"
  run bash "$LIB" append "$f" go
  [ "$status" -eq 0 ]
  # Flow append rewrites the single languages line: exactly one changed line.
  [ "$(diff_added "$snap" "$f")" -eq 1 ]
  [ "$(diff_removed "$snap" "$f")" -eq 1 ]
  run grep -n '^languages: \[typescript, go\]$' "$f"
  [ "$status" -eq 0 ]
  # The only removed line is the original languages line (all others intact).
  run diff "$snap" "$f"
  assert_contains '< languages: [typescript]'
  if have_pyyaml; then
    [ "$(py_langs "$f")" = "go,typescript" ]
  fi
}

@test "UAT-024 append: re-running with an already-present token performs no write (idempotent set-union)" {
  local f="$TMPROOT/idem.yml" snap="$TMPROOT/idem.snap"
  writef "$f" 'languages: [typescript, go]\n'
  cp "$f" "$snap"
  run bash "$LIB" append "$f" go
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Byte-identical: no diff.
  run diff "$snap" "$f"
  [ "$status" -eq 0 ]
}

@test "append normalization: a project already covered by a variant is left unchanged when appending the base token" {
  local f="$TMPROOT/norm.yml" snap="$TMPROOT/norm.snap"
  writef "$f" 'languages: [python_jedi]\n'
  cp "$f" "$snap"
  run bash "$LIB" append "$f" python
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run diff "$snap" "$f"
  [ "$status" -eq 0 ]
}

# ---------- UAT-026: prompt-only fallback checklist (no write) ----------
#
# Each unsafe form routes append to FALLBACK:<reason>, exit non-zero, and leaves
# the file byte-identical. assert_fallback <fixture-content> <reason> <token>.
assert_fallback() {
  local content="$1" reason="$2" token="$3"
  local f="$TMPROOT/fb.yml" snap="$TMPROOT/fb.snap"
  writef "$f" "$content"
  cp "$f" "$snap"
  run bash "$LIB" append "$f" "$token"
  [ "$status" -ne 0 ] || return 1
  grep -qF -- "FALLBACK:$reason" <<<"$output" || return 1
  # No write occurred.
  diff "$snap" "$f" || return 1
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
