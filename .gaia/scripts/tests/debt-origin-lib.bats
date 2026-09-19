#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/debt-origin-lib.sh: the one helper every
# tech-debt provenance route calls to build the `gaia-debt-origin` line that
# rides beside `gaia-debt-key` on a filed issue or a waived finding's
# pull-request-body entry.
#
# What it proves, in the section order below:
#   1. source-time purity, no side effects and no root derivation
#   2. the canonical line, byte for byte
#   3. continuous-integration parity, one implementation for both callers
#   4. the empty case, an unresolved branch is `unknown` and never `adhoc`
#   5. worktree normalization, and that the raw branch stays recoverable
#   6. the convention table reaches the line through branch-name-lib.sh
#   7. the two-character encoding, invertible and comment-safe
#   8. the `changed` vocabulary, reported and never computed
#   9. fail-open, every invocation exits 0
#  10. the `session` field, read off the process rather than the checkout
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/debt-origin-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
# Every expected value below is written as a literal: an assertion that
# recomputes the derivation in its own body would be testing its own
# arithmetic.

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-origin-lib.sh"
  # shellcheck disable=SC1090
  source "$LIB"
  CLEANUP_DIRS=()
  # GitHub Actions exports GITHUB_HEAD_REF on a pull_request event, and this
  # suite runs there. Left set, it would outrank every scratch repo's own
  # branch and turn the whole suite green-for-the-wrong-reason. The one test
  # that wants it passes it explicitly through `env`.
  unset GITHUB_HEAD_REF
  # Same reasoning for the session id, and it bites harder: this suite is
  # normally run BY a Claude Code session, which exports it, so every literal
  # line below would carry that session's real id and the two tests that pin
  # the absent case would never see it. The tests that want a value pass one
  # explicitly through `env`.
  unset CLAUDE_CODE_SESSION_ID
}

teardown() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

git_identity() {
  git -C "$1" config user.email gaia-test@example.com
  git -C "$1" config user.name "GAIA Test"
  git -C "$1" config commit.gpgsign false
}

# make_repo [branch]: a fresh repo with one commit, checked out on [branch]
# (default "main"). Sets REPO and HEAD_SHA.
make_repo() {
  local branch="${1:-main}"
  local raw
  raw=$(mktemp -d -t gaia-dol-repo-XXXXXX)
  REPO="$(cd "$raw" && pwd -P)"
  CLEANUP_DIRS+=("$REPO")
  git -C "$REPO" init -q --initial-branch="$branch"
  git_identity "$REPO"
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
}

# field <key> <line>: the value of `<key>=` in an emitted provenance line.
# A parser for the emitted format, deliberately not a second copy of the
# derivation under test.
field() {
  local key="$1" line="$2" rest
  rest="${line#*"$key"=}"
  printf '%s' "${rest%% *}"
}

# ========== 1. source-time purity ==========

@test "sourcing the lib has no side effects: succeeds under set -u with no git repo and no external PATH" {
  scratch="$BATS_TEST_TMPDIR/no-side-effects"
  mkdir -p "$scratch"
  run bash -c "cd '$scratch' && PATH='' && set -u && source '$LIB' && echo sourced-ok"
  [ "$status" -eq 0 ]
  grep -qF "sourced-ok" <<<"$output"
  [ -z "$(ls -A "$scratch")" ]
}

@test "structural: sourcing the lib defines its public functions and the shared classifier" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_debt_origin_encode >/dev/null
    type gaia_debt_origin_line >/dev/null
    type gaia_branch_classify >/dev/null
    echo OK
  ' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ========== 2. the canonical line ==========

@test "canonical line: a drain branch with changed=1 emits exactly the contracted bytes" {
  make_repo "debt/1121-marker-sep"
  run bash "$LIB" --changed 1 --dir "$REPO"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  local re='^<!-- gaia-debt-origin: branch=debt/1121-marker-sep mode=drain unit=1121 changed=1 head=[0-9a-f]{40} session=unknown -->$'
  [[ "$output" =~ $re ]] || return 1
  [ "$(field head "$output")" = "$HEAD_SHA" ]
}

@test "canonical line: --dir defaults to the process working directory" {
  make_repo "debt/1121-marker-sep"
  local out
  out="$(cd "$REPO" && bash "$LIB" --changed 0)"
  [ "$(field branch "$out")" = "debt/1121-marker-sep" ]
  [ "$(field mode "$out")" = "drain" ]
  [ "$(field unit "$out")" = "1121" ]
  [ "$(field changed "$out")" = "0" ]
  [ "$(field head "$out")" = "$HEAD_SHA" ]
}

@test "canonical line: the output is newline terminated" {
  make_repo "debt/1121-marker-sep"
  local raw
  raw="$(bash "$LIB" --dir "$REPO" | od -c | tr -s ' ')"
  grep -qF '\n' <<<"$raw"
}

# ========== 3. continuous-integration parity ==========

@test "CI parity: GITHUB_HEAD_REF at a detached HEAD reproduces the checkout's own line except for head" {
  make_repo "debt/1121-marker-sep"
  local on_branch detached
  on_branch="$(bash "$LIB" --changed 1 --dir "$REPO")"
  git -C "$REPO" checkout -q "$HEAD_SHA"
  detached="$(env GITHUB_HEAD_REF=debt/1121-marker-sep bash "$LIB" --changed 1 --dir "$REPO")"

  # Field by field, so a failure names the field rather than diffing two long
  # lines. `head` is the same here only because the detached checkout is the
  # same commit; the fields that must agree are the other four.
  [ "$(field branch "$detached")" = "$(field branch "$on_branch")" ]
  [ "$(field mode "$detached")" = "$(field mode "$on_branch")" ]
  [ "$(field unit "$detached")" = "$(field unit "$on_branch")" ]
  [ "$(field changed "$detached")" = "$(field changed "$on_branch")" ]
  [ "$(field branch "$detached")" = "debt/1121-marker-sep" ]
  [ "$(field mode "$detached")" = "drain" ]
  [ "$(field unit "$detached")" = "1121" ]
}

@test "CI parity: --branch outranks GITHUB_HEAD_REF" {
  make_repo "debt/1121-marker-sep"
  local out
  out="$(env GITHUB_HEAD_REF=chore/from-the-runner bash "$LIB" --branch "plan/spec-065" --dir "$REPO")"
  [ "$(field branch "$out")" = "plan/spec-065" ]
  [ "$(field mode "$out")" = "plan" ]
  [ "$(field unit "$out")" = "SPEC-065" ]
}

@test "CI parity: GITHUB_HEAD_REF outranks the checkout's own branch" {
  make_repo "debt/1121-marker-sep"
  local out
  out="$(env GITHUB_HEAD_REF=chore/from-the-runner bash "$LIB" --dir "$REPO")"
  [ "$(field branch "$out")" = "chore/from-the-runner" ]
  [ "$(field mode "$out")" = "maintenance" ]
  [ "$(field unit "$out")" = "from-the-runner" ]
}

# ========== 4. the empty case ==========

@test "empty case: a detached HEAD with no branch source yields unknown, never adhoc" {
  make_repo "main"
  git -C "$REPO" checkout -q "$HEAD_SHA"
  run bash "$LIB" --dir "$REPO"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(field branch "$output")" = "unknown" ]
  [ "$(field mode "$output")" = "unknown" ]
  [ "$(field unit "$output")" = "unknown" ]
  [ "$(field head "$output")" = "$HEAD_SHA" ]
  grep -qF -- "mode=adhoc" <<<"$output" && return 1
  return 0
}

@test "empty case: outside a git repository every field is unknown and the line is still printed" {
  local nongit
  nongit=$(mktemp -d -t gaia-dol-nongit-XXXXXX)
  CLEANUP_DIRS+=("$nongit")
  run bash "$LIB" --dir "$nongit"
  [ "$status" -eq 0 ]
  [ "$output" = "<!-- gaia-debt-origin: branch=unknown mode=unknown unit=unknown changed=unknown head=unknown session=unknown -->" ]
}

# ========== 5. worktree normalization ==========

@test "worktree normalization: the wrapped and unwrapped spellings classify identically" {
  make_repo "main"
  local wrapped plain
  wrapped="$(bash "$LIB" --branch "worktree-debt+1041-lookup-value-flag-guard" --dir "$REPO")"
  plain="$(bash "$LIB" --branch "debt/1041-lookup-value-flag-guard" --dir "$REPO")"
  [ "$(field mode "$wrapped")" = "drain" ]
  [ "$(field unit "$wrapped")" = "1041" ]
  [ "$(field mode "$plain")" = "drain" ]
  [ "$(field unit "$plain")" = "1041" ]
}

@test "worktree normalization: each spelling records its own raw branch verbatim" {
  make_repo "main"
  local wrapped plain
  wrapped="$(bash "$LIB" --branch "worktree-debt+1041-lookup-value-flag-guard" --dir "$REPO")"
  plain="$(bash "$LIB" --branch "debt/1041-lookup-value-flag-guard" --dir "$REPO")"
  [ "$(field branch "$wrapped")" = "worktree-debt+1041-lookup-value-flag-guard" ]
  [ "$(field branch "$plain")" = "debt/1041-lookup-value-flag-guard" ]
}

# ========== 6. the convention table ==========

@test "table: each mode reaches the line through the shared classifier, inside the closed vocabulary" {
  make_repo "main"
  local row branch want_mode want_unit out got_mode got_unit
  for row in \
    "debt/1041-1055-1098-batch|drain|1041-1055-1098" \
    "debt/1121-marker-sep|drain|1121" \
    "plan/spec-065-provenance-on-debt|plan|SPEC-065" \
    "plan/plan-012-execution|plan|plan-012" \
    "chore/update-deps-2026-09-20-1200|maintenance|update-deps-2026-09-20-1200" \
    "main|adhoc|unknown" \
    "fix/some-thing|adhoc|unknown"; do
    IFS='|' read -r branch want_mode want_unit <<<"$row"
    out="$(bash "$LIB" --branch "$branch" --dir "$REPO")"
    got_mode="$(field mode "$out")"
    got_unit="$(field unit "$out")"
    [ "$got_mode" = "$want_mode" ] || {
      echo "branch '$branch': mode was '$got_mode', want '$want_mode'" >&2
      return 1
    }
    [ "$got_unit" = "$want_unit" ] || {
      echo "branch '$branch': unit was '$got_unit', want '$want_unit'" >&2
      return 1
    }
    case "$got_mode" in
      drain | plan | maintenance | adhoc | unknown) ;;
      *)
        echo "branch '$branch': mode '$got_mode' is outside the closed vocabulary" >&2
        return 1
        ;;
    esac
  done
}

@test "table: a missing branch-name-lib.sh degrades mode and unit to unknown and still exits 0" {
  make_repo "debt/1121-marker-sep"
  local lonely="$BATS_TEST_TMPDIR/lonely"
  mkdir -p "$lonely"
  cp "$LIB" "$lonely/debt-origin-lib.sh"
  run bash "$lonely/debt-origin-lib.sh" --changed 1 --dir "$REPO"
  [ "$status" -eq 0 ]
  [ "$(field branch "$output")" = "debt/1121-marker-sep" ]
  [ "$(field mode "$output")" = "unknown" ]
  [ "$(field unit "$output")" = "unknown" ]
}

# ========== 7. the encoding ==========

@test "encoding: gaia_debt_origin_encode reserves exactly two characters" {
  run gaia_debt_origin_encode "plain-name"
  [ "$output" = "plain-name" ]
  run gaia_debt_origin_encode "a>b"
  [ "$output" = "a%3Eb" ]
  run gaia_debt_origin_encode "a%b"
  [ "$output" = "a%25b" ]
  run gaia_debt_origin_encode "feat/a.b_c-d"
  [ "$output" = "feat/a.b_c-d" ]
}

@test "encoding: a reserved character never terminates the comment early" {
  make_repo "main"
  local branch out occurrences
  for branch in 'feat/a>b' 'feat/a%b' 'feat/a>b%c' 'a%3Eb' 'feat/-->early'; do
    out="$(bash "$LIB" --branch "$branch" --dir "$REPO")"
    occurrences="$(printf '%s\n' "$out" | grep -o -- '-->' | grep -c '.')"
    [ "$occurrences" -eq 1 ] || {
      echo "branch '$branch': found $occurrences '-->' sequences in: $out" >&2
      return 1
    }
  done
}

@test "encoding: no emitted value carries a raw > or %, and the branch round-trips exactly" {
  make_repo "main"
  local branch out enc decoded stripped
  # 'a%3Eb' is the case that makes the ORDER provable rather than asserted: it
  # round-trips only when `%` is encoded before `>`.
  for branch in 'feat/a>b' 'feat/a%b' 'feat/a>b%c' 'a%3Eb' 'a%25b' '%>%>'; do
    out="$(bash "$LIB" --branch "$branch" --dir "$REPO")"
    enc="$(field branch "$out")"

    case "$enc" in
      *'>'*)
        echo "branch '$branch': emitted value '$enc' carries a raw >" >&2
        return 1
        ;;
    esac

    # Every surviving `%` must belong to one of the two escapes. Strip both and
    # nothing containing a `%` may remain.
    stripped="${enc//%25/}"
    stripped="${stripped//%3E/}"
    case "$stripped" in
      *'%'*)
        echo "branch '$branch': emitted value '$enc' carries a raw %" >&2
        return 1
        ;;
    esac

    # Decode: `%3E` back to `>`, then `%25` back to `%`.
    decoded="${enc//%3E/>}"
    decoded="${decoded//%25/%}"
    [ "$decoded" = "$branch" ] || {
      echo "branch '$branch': decoded to '$decoded' (encoded '$enc')" >&2
      return 1
    }
  done
}

# ========== 8. the changed vocabulary ==========

@test "changed: 0, 1, and unknown pass through" {
  make_repo "main"
  [ "$(field changed "$(bash "$LIB" --changed 0 --dir "$REPO")")" = "0" ]
  [ "$(field changed "$(bash "$LIB" --changed 1 --dir "$REPO")")" = "1" ]
  [ "$(field changed "$(bash "$LIB" --changed unknown --dir "$REPO")")" = "unknown" ]
}

@test "changed: an absent, empty, or junk value all yield unknown" {
  make_repo "main"
  [ "$(field changed "$(bash "$LIB" --dir "$REPO")")" = "unknown" ]
  [ "$(field changed "$(bash "$LIB" --changed "" --dir "$REPO")")" = "unknown" ]
  [ "$(field changed "$(bash "$LIB" --changed maybe --dir "$REPO")")" = "unknown" ]
  [ "$(field changed "$(bash "$LIB" --changed 2 --dir "$REPO")")" = "unknown" ]
  [ "$(field changed "$(bash "$LIB" --changed 01 --dir "$REPO")")" = "unknown" ]
}

@test "structural: the helper resolves no diff base and no repository root" {
  grep -nE 'merge-base|--name-only|symbolic-ref|--show-toplevel|--git-common-dir' "$LIB" && return 1
  return 0
}

# ========== 9. fail-open ==========

@test "fail-open: every degenerate invocation still exits 0 and prints one line" {
  make_repo "main"
  local nongit
  nongit=$(mktemp -d -t gaia-dol-nongit-XXXXXX)
  CLEANUP_DIRS+=("$nongit")

  run bash "$LIB" --dir "$nongit"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]

  run bash "$LIB" --dir "$REPO" --changed maybe
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]

  run bash "$LIB" --dir "$REPO" --not-a-flag
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]

  # A trailing flag with no value must not hang the argument loop.
  run bash "$LIB" --dir "$REPO" --changed
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]

  run bash "$LIB" --dir "$REPO/does-not-exist"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]

  run bash "$LIB" --dir ""
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "fail-open: the public functions each return 0 on degenerate input" {
  run gaia_debt_origin_encode ""
  [ "$status" -eq 0 ]
  run gaia_debt_origin_line --changed
  [ "$status" -eq 0 ]
}

# ========== 10. the session field ==========
#
# `session` is the one field here read off the PROCESS rather than the
# checkout, which is the whole reason it exists: `branch`, `mode` and `unit`
# describe the tree a filing was made from, and that is the wrong fact
# whenever two sessions share one checkout. The tests below pin that
# independence directly rather than trusting the derivation to stay separate.

@test "session: a live CLAUDE_CODE_SESSION_ID is recorded verbatim" {
  make_repo "debt/1121-marker-sep"
  local out
  out="$(env CLAUDE_CODE_SESSION_ID=00000000-0000-4000-8000-000000000000 bash "$LIB" --dir "$REPO")"
  [ "$(field session "$out")" = "00000000-0000-4000-8000-000000000000" ]
}

@test "session: an absent CLAUDE_CODE_SESSION_ID is unknown, never empty" {
  # The empty spelling would emit a bare `session=` and give a reader a field
  # that parses but says nothing; `unknown` is the convention every other
  # field on this line already uses for exactly this case.
  make_repo "debt/1121-marker-sep"
  local out
  out="$(bash "$LIB" --dir "$REPO")"
  [ "$(field session "$out")" = "unknown" ]
  grep -qF -- "session= " <<<"$out" && return 1
  return 0
}

@test "session: an empty CLAUDE_CODE_SESSION_ID is unknown, the same as absent" {
  # Set-but-empty is a distinct state from unset and reaches the same answer:
  # a variable exported with no value carries no identity either.
  make_repo "debt/1121-marker-sep"
  local out
  out="$(env CLAUDE_CODE_SESSION_ID= bash "$LIB" --dir "$REPO")"
  [ "$(field session "$out")" = "unknown" ]
}

@test "session: a value carrying whitespace is unknown, so it cannot split the line" {
  # The line is space-delimited `key=value` pairs and every documented reader
  # matches a field that way, so a space inside a value would present as two
  # fields and corrupt every pair after it. No encoding fixes that, because
  # the space is not a reserved character of the encoder: the only correct
  # answer for a value this shape is to decline it.
  make_repo "debt/1121-marker-sep"
  local out
  out="$(env CLAUDE_CODE_SESSION_ID='not a session id' bash "$LIB" --dir "$REPO")"
  [ "$(field session "$out")" = "unknown" ]
  grep -qF -- "not a session id" <<<"$out" && return 1
  return 0
}

@test "session: a tab-carrying value is unknown too, not only a space-carrying one" {
  make_repo "debt/1121-marker-sep"
  local out
  out="$(env CLAUDE_CODE_SESSION_ID="$(printf 'a\tb')" bash "$LIB" --dir "$REPO")"
  [ "$(field session "$out")" = "unknown" ]
}

@test "session: the field is independent of the branch, which is the point of it" {
  # The defect this field answers, stated as a test: one session filing from
  # two different checkouts records ONE session and two branches. Under
  # branch-derived provenance alone the two filings look like different
  # actors, which is what misattributed #1777 to the #1759 drain.
  make_repo "debt/1121-marker-sep"
  local first second
  first="$(env CLAUDE_CODE_SESSION_ID=same-session bash "$LIB" --dir "$REPO")"
  git -C "$REPO" checkout -q -b "debt/1759-scratch-dir-worktree-tool"
  second="$(env CLAUDE_CODE_SESSION_ID=same-session bash "$LIB" --dir "$REPO")"

  [ "$(field branch "$first")" = "debt/1121-marker-sep" ]
  [ "$(field branch "$second")" = "debt/1759-scratch-dir-worktree-tool" ]
  [ "$(field unit "$first")" = "1121" ]
  [ "$(field unit "$second")" = "1759" ]
  [ "$(field session "$first")" = "same-session" ]
  [ "$(field session "$second")" = "same-session" ]
}

@test "session: two sessions on one branch are distinguishable, the converse case" {
  # The #1284-#1287 shape: one checkout, two concurrent sessions. `branch`,
  # `mode` and `unit` agree because they describe the tree; only `session`
  # tells the two filers apart.
  make_repo "debt/1121-marker-sep"
  local a b
  a="$(env CLAUDE_CODE_SESSION_ID=session-a bash "$LIB" --dir "$REPO")"
  b="$(env CLAUDE_CODE_SESSION_ID=session-b bash "$LIB" --dir "$REPO")"
  [ "$(field branch "$a")" = "$(field branch "$b")" ]
  [ "$(field unit "$a")" = "$(field unit "$b")" ]
  [ "$(field session "$a")" = "session-a" ]
  [ "$(field session "$b")" = "session-b" ]
}

@test "session: --branch does not reach it, so an overridden branch still names the real filer" {
  # `--branch` and GITHUB_HEAD_REF are branch-source overrides. Neither is a
  # session source, and a caller supplying one must not be able to silently
  # restamp authorship along with it.
  make_repo "main"
  local out
  out="$(env CLAUDE_CODE_SESSION_ID=real-filer GITHUB_HEAD_REF=chore/from-the-runner \
    bash "$LIB" --branch "plan/spec-065" --dir "$REPO")"
  [ "$(field branch "$out")" = "plan/spec-065" ]
  [ "$(field session "$out")" = "real-filer" ]
}

@test "session: a reserved character in the value is encoded, not emitted raw" {
  # The encoder runs over every value on the line, this one included. A raw
  # `>` would terminate the HTML comment early; the contract says every
  # emitted value is encoded, and this proves the new field is not an
  # exception carved out of that rule.
  make_repo "debt/1121-marker-sep"
  local out
  out="$(env CLAUDE_CODE_SESSION_ID='a>b%c' bash "$LIB" --dir "$REPO")"
  [ "$(field session "$out")" = "a%3Eb%25c" ]
}

@test "session: outside a git repository the field still resolves from the process" {
  # Every other field goes `unknown` outside a repository because every other
  # field is derived from one. This one is not, so it must survive there: a
  # filing made outside a checkout still has a filer.
  local nongit out
  nongit=$(mktemp -d -t gaia-dol-nongit-XXXXXX)
  CLEANUP_DIRS+=("$nongit")
  out="$(env CLAUDE_CODE_SESSION_ID=still-a-session bash "$LIB" --dir "$nongit")"
  [ "$(field branch "$out")" = "unknown" ]
  [ "$(field head "$out")" = "unknown" ]
  [ "$(field session "$out")" = "still-a-session" ]
}

# ========== structural hygiene ==========

@test "structural: no hardcoded /Users or /home paths" {
  grep -E '/Users/|/home/' "$LIB" && return 1
  return 0
}

@test "structural: never invokes cd, per .claude/rules/shell-cwd.md" {
  local code_lines
  code_lines="$(grep -vE '^[[:space:]]*#' "$LIB")"
  grep -qE '(^|[^[:alnum:]_])cd([^[:alnum:]_]|$)' <<<"$code_lines" && return 1
  return 0
}

@test "structural: shellcheck is clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  shellcheck "$LIB"
}

@test "portability: the emitted line is byte-identical under zsh, where zsh exists" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
  make_repo "debt/1121-marker-sep"
  local from_bash from_zsh
  from_bash="$(bash "$LIB" --changed 1 --dir "$REPO")"
  from_zsh="$(zsh -c "source '$LIB'; gaia_debt_origin_line --changed 1 --dir '$REPO'")"
  [ -n "$from_bash" ]
  [ "$from_zsh" = "$from_bash" ]
}
