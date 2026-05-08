#!/usr/bin/env bats
# Tests for `.github/forensics/parse-verdict.sh`.
#
# Coverage maps to SPEC-002 UAT-003 case (b) — the classifier output is
# parsed deterministically; ambiguity routes to `needs-human` without any
# LLM fallback.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  PARSER="$THIS_DIR/../parse-verdict.sh"
}

# ---------------------------------------------------------------------------
# Clean verdicts — one verdict line, last non-blank line, value in the
# closed set.
# ---------------------------------------------------------------------------

@test "clean non-issue verdict parses to non-issue" {
  body_file="$BATS_TEST_TMPDIR/clean-non-issue.txt"
  cat > "$body_file" <<'EOF'
The reporter is missing the `gh` CLI prerequisite documented in the
README. This is a user-config issue, not a GAIA defect.

GAIA-VERDICT: non-issue
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"non-issue"'* ]]
}

@test "clean needs-human verdict parses to needs-human" {
  body_file="$BATS_TEST_TMPDIR/clean-needs-human.txt"
  cat > "$body_file" <<'EOF'
The fix would require touching `app/routes/`, which is on the canonical
denylist. Escalating to the maintainer.

GAIA-VERDICT: needs-human
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"needs-human"'* ]]
}

@test "clean auto-fixable with proposed paths parses to auto-fixable" {
  body_file="$BATS_TEST_TMPDIR/clean-auto-fixable.txt"
  cat > "$body_file" <<'EOF'
The hook at `.claude/hooks/wiki-session-stop.sh` references a function
that no longer exists in `.gaia/cli/wiki/sync.ts`.

### Proposed paths

```
.claude/hooks/wiki-session-stop.sh
.gaia/cli/wiki/sync.ts
```

GAIA-VERDICT: auto-fixable
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"auto-fixable"'* ]]
  [[ "$output" == *'"proposed_paths":["'.claude/hooks/wiki-session-stop.sh'","'.gaia/cli/wiki/sync.ts'"]'* ]]
}

@test "auto-fixable proposed_paths preserved in order" {
  body_file="$BATS_TEST_TMPDIR/paths-order.txt"
  cat > "$body_file" <<'EOF'
Reasoning.

### Proposed paths

```
zzz/last.ts
aaa/first.ts
mmm/middle.ts
```

GAIA-VERDICT: auto-fixable
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"proposed_paths":["zzz/last.ts","aaa/first.ts","mmm/middle.ts"]'* ]]
}

# ---------------------------------------------------------------------------
# Ambiguity — no verdict line.
# ---------------------------------------------------------------------------

@test "no GAIA-VERDICT line returns ambiguous" {
  body_file="$BATS_TEST_TMPDIR/no-verdict.txt"
  cat > "$body_file" <<'EOF'
The reporter has a misconfigured environment. They should fix it.
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
}

@test "empty input returns ambiguous" {
  body_file="$BATS_TEST_TMPDIR/empty.txt"
  : > "$body_file"
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
}

# ---------------------------------------------------------------------------
# Ambiguity — multiple GAIA-VERDICT lines (UAT-003 case b).
# ---------------------------------------------------------------------------

@test "two conflicting verdict lines return ambiguous" {
  body_file="$BATS_TEST_TMPDIR/two-conflicting.txt"
  cat > "$body_file" <<'EOF'
First take: this is a non-issue.

GAIA-VERDICT: non-issue

Wait, on reflection it should be needs-human.

GAIA-VERDICT: needs-human
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
}

@test "two duplicate verdict lines return ambiguous (strict one-line contract)" {
  body_file="$BATS_TEST_TMPDIR/two-duplicate.txt"
  cat > "$body_file" <<'EOF'
GAIA-VERDICT: non-issue

GAIA-VERDICT: non-issue
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
}

# ---------------------------------------------------------------------------
# Ambiguity — malformed verdict value.
# ---------------------------------------------------------------------------

@test "verdict value outside closed set returns ambiguous" {
  body_file="$BATS_TEST_TMPDIR/bad-value.txt"
  cat > "$body_file" <<'EOF'
Reasoning.

GAIA-VERDICT: maybe
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
}

@test "verdict value with trailing punctuation returns ambiguous" {
  body_file="$BATS_TEST_TMPDIR/punctuation.txt"
  cat > "$body_file" <<'EOF'
Reasoning.

GAIA-VERDICT: non-issue.
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
}

# ---------------------------------------------------------------------------
# Ambiguity — verdict line is not the last non-blank line.
# ---------------------------------------------------------------------------

@test "verdict line followed by content returns ambiguous" {
  body_file="$BATS_TEST_TMPDIR/trailing-content.txt"
  cat > "$body_file" <<'EOF'
Reasoning.

GAIA-VERDICT: non-issue

Note: actually I changed my mind.
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
}

# ---------------------------------------------------------------------------
# auto-fixable contract — must include a parseable proposed-paths fence.
# ---------------------------------------------------------------------------

@test "auto-fixable verdict without proposed_paths section downgrades to ambiguous" {
  body_file="$BATS_TEST_TMPDIR/auto-no-paths.txt"
  cat > "$body_file" <<'EOF'
Looks fixable to me.

GAIA-VERDICT: auto-fixable
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
  [[ "$output" == *'"proposed_paths":[]'* ]]
}

@test "auto-fixable verdict with header but no fence downgrades to ambiguous" {
  body_file="$BATS_TEST_TMPDIR/paths-no-fence.txt"
  cat > "$body_file" <<'EOF'
Looks fixable.

### Proposed paths

.gaia/cli/foo.ts
.claude/hooks/bar.sh

GAIA-VERDICT: auto-fixable
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
  [[ "$output" == *'"proposed_paths":[]'* ]]
}

@test "auto-fixable verdict with empty fence downgrades to ambiguous" {
  body_file="$BATS_TEST_TMPDIR/paths-empty-fence.txt"
  cat > "$body_file" <<'EOF'
Looks fixable.

### Proposed paths

```
```

GAIA-VERDICT: auto-fixable
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"ambiguous"'* ]]
  [[ "$output" == *'"proposed_paths":[]'* ]]
}

@test "auto-fixable with fence using language tag still parses paths" {
  body_file="$BATS_TEST_TMPDIR/fence-lang.txt"
  cat > "$body_file" <<'EOF'
Reasoning.

### Proposed paths

```text
.gaia/cli/x.ts
```

GAIA-VERDICT: auto-fixable
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"auto-fixable"'* ]]
  [[ "$output" == *'"proposed_paths":[".gaia/cli/x.ts"]'* ]]
}

# ---------------------------------------------------------------------------
# non-issue / needs-human verdicts ignore proposed_paths existence — only
# auto-fixable requires them.
# ---------------------------------------------------------------------------

@test "non-issue verdict does not require proposed_paths" {
  body_file="$BATS_TEST_TMPDIR/non-issue-nopaths.txt"
  cat > "$body_file" <<'EOF'
Not a defect.

GAIA-VERDICT: non-issue
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"non-issue"'* ]]
  [[ "$output" == *'"proposed_paths":[]'* ]]
}

@test "needs-human verdict does not require proposed_paths" {
  body_file="$BATS_TEST_TMPDIR/needs-human-nopaths.txt"
  cat > "$body_file" <<'EOF'
Out of scope.

GAIA-VERDICT: needs-human
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict":"needs-human"'* ]]
  [[ "$output" == *'"proposed_paths":[]'* ]]
}

# ---------------------------------------------------------------------------
# Reasoning extraction — everything before the verdict line, with one
# trailing blank line trimmed.
# ---------------------------------------------------------------------------

@test "reasoning captures content before verdict line" {
  body_file="$BATS_TEST_TMPDIR/reasoning.txt"
  cat > "$body_file" <<'EOF'
This is the analysis paragraph that the maintainer reads.

GAIA-VERDICT: non-issue
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"reasoning":"This is the analysis paragraph that the maintainer reads."'* ]]
}

# ---------------------------------------------------------------------------
# CLI contract.
# ---------------------------------------------------------------------------

@test "no args prints usage and exits 2" {
  run "$PARSER"
  [ "$status" -eq 2 ]
}

@test "missing input file exits 2" {
  run "$PARSER" "$BATS_TEST_TMPDIR/does-not-exist.txt"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Determinism — same input twice yields byte-identical output.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# SPEC-003 UAT-006 — pipefail + internal-error JSON envelope. When awk
# fails, the script must NOT fall through to a default verdict:ambiguous;
# it must emit `{"internal_error":true,...}` so the workflow can
# distinguish infrastructure failure from a non-conformant classifier
# response.
# ---------------------------------------------------------------------------

@test "pipefail preamble is declared" {
  grep -qE '^set -uo pipefail' "$PARSER"
}

@test "awk failure emits internal-error JSON envelope (not verdict:ambiguous)" {
  body_file="$BATS_TEST_TMPDIR/internal-error-input.txt"
  cat > "$body_file" <<'EOF'
Reasoning.

GAIA-VERDICT: non-issue
EOF

  # Shadow `awk` with a stub that always exits non-zero. Exit-code check
  # on the first awk call (verdict-count) fires immediately.
  fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/awk" <<'STUB'
#!/usr/bin/env bash
exit 9
STUB
  chmod +x "$fake_bin/awk"

  run env PATH="$fake_bin:$PATH" "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"internal_error":true'* ]]
  [[ "$output" == *'"exit_code":9'* ]]
  # Critical: the failure path does NOT pretend to be an ambiguous verdict.
  [[ "$output" != *'"verdict":"ambiguous"'* ]]
}

@test "parser output is byte-identical across two runs" {
  body_file="$BATS_TEST_TMPDIR/det.txt"
  cat > "$body_file" <<'EOF'
Reasoning.

### Proposed paths

```
.gaia/cli/x.ts
```

GAIA-VERDICT: auto-fixable
EOF
  run "$PARSER" "$body_file"
  first="$output"
  run "$PARSER" "$body_file"
  [ "$output" = "$first" ]
}
