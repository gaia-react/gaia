#!/usr/bin/env bash
# Shared bats fixture for the audit loop suites: a repository with a `main`
# branch and an `origin` remote, a feature branch, findings sidecars with
# controlled mtimes, round stamps, baselines, dispositions files and a seeded
# branch state file. Sourced from a suite's `setup()`:
#
#   . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
#
# Everything lands under $BATS_TEST_TMPDIR; alf_init refuses without it. The
# hook suites read this helper and never edit it.
#
# Times are minutes after a fixed epoch (alf_time), applied with `touch -t`,
# so a sidecar is "newer than the stamp" by a whole minute on every
# filesystem and at every find(1) precision.
#
# Variables set: ALF_ROOT (physical repo root, also the main checkout),
# ALF_ORIGIN, ALF_BRANCH (raw), ALF_B (normalized branch), ALF_SLUG (raw
# branch slug), ALF_COMMIT and ALF_TREE (HEAD after alf_commit), ALF_STATE
# (the branch state file path).

# The jq programs are single-quoted so their `$` variables reach jq.
# shellcheck disable=SC2016
# shellcheck source=/dev/null
. "${BASH_SOURCE[0]%/*}/../../scripts/audit-key-lib.sh"

# alf_git <args...>: git in the fixture repo with a fixed identity.
alf_git() {
  git -C "$ALF_ROOT" -c user.email=gaia-test@example.com -c user.name="GAIA Test" -c commit.gpgsign=false "$@"
}

# alf_init: build origin plus a repo on `main` holding base.txt (20 lines).
alf_init() {
  [ -n "${BATS_TEST_TMPDIR:-}" ] || { printf 'alf_init: BATS_TEST_TMPDIR is unset\n' >&2; return 1; }
  local repo="$BATS_TEST_TMPDIR/repo" i
  ALF_ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare -b main "$ALF_ORIGIN" || return 1
  git init -q -b main "$repo" || return 1
  ALF_ROOT="$(cd "$repo" && pwd -P)" || return 1
  : >"$ALF_ROOT/base.txt"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do printf 'base %s\n' "$i" >>"$ALF_ROOT/base.txt"; done
  printf '.gaia/\n' >"$ALF_ROOT/.gitignore"
  alf_git add -A && alf_git commit -q -m base || return 1
  alf_git remote add origin "$ALF_ORIGIN" && alf_git push -q origin main 2>/dev/null || return 1
  alf_git fetch -q origin && alf_git remote set-head origin main >/dev/null || return 1
  mkdir -p "$ALF_ROOT/.gaia/local/audit"
}

# alf_branch <raw-name>: cut and check out a feature branch from main.
alf_branch() {
  ALF_BRANCH="$1"
  alf_git checkout -q -b "$1" || return 1
  ALF_B="${1#worktree-}"
  ALF_B="${ALF_B//+//}"
  ALF_SLUG="$(gaia_key_slug "$1")"
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/$ALF_B.json"
}

# alf_set_line <path> <line> <text>: set one line, padding the file to it.
alf_set_line() {
  local f="$ALF_ROOT/$1" n="$2" text="$3" have
  mkdir -p "${f%/*}"
  [ -f "$f" ] || : >"$f"
  have="$(wc -l <"$f" | tr -d ' ')"
  while [ "$have" -lt "$n" ]; do
    have=$((have + 1))
    printf 'pad %s\n' "$have" >>"$f"
  done
  awk -v n="$n" -v t="$text" 'NR == n { print t; next } { print }' "$f" >"$f.alf" && mv "$f.alf" "$f"
}

# alf_fill <path> <count> <tag>: write <count> fresh lines `<tag> <i>`.
alf_fill() {
  local f="$ALF_ROOT/$1" i=1
  mkdir -p "${f%/*}"
  : >"$f"
  while [ "$i" -le "$2" ]; do printf '%s %s\n' "$3" "$i" >>"$f"; i=$((i + 1)); done
}

# alf_commit [message]: commit everything; sets ALF_COMMIT and ALF_TREE.
alf_commit() {
  alf_git add -A && alf_git commit -q -m "${1:-change}" || return 1
  ALF_COMMIT="$(alf_git rev-parse HEAD)"
  ALF_TREE="$(alf_git rev-parse 'HEAD^{tree}')"
}

# alf_upstream_change <path> <line> <text>: land a change on origin's main,
# fetch it and merge it into the feature branch; sets ALF_COMMIT, ALF_TREE.
alf_upstream_change() {
  alf_git checkout -q main || return 1
  alf_set_line "$1" "$2" "$3"
  alf_git add -A && alf_git commit -q -m upstream && alf_git push -q origin main 2>/dev/null || return 1
  alf_git checkout -q "$ALF_BRANCH" && alf_git fetch -q origin || return 1
  alf_git merge -q --no-edit origin/main >/dev/null || return 1
  ALF_COMMIT="$(alf_git rev-parse HEAD)"
  ALF_TREE="$(alf_git rev-parse 'HEAD^{tree}')"
}

# alf_time <minutes>: a `touch -t` stamp that many minutes after the epoch.
alf_time() {
  printf '20260101%02d%02d\n' $(($1 / 60)) $(($1 % 60))
}

# alf_sidecar <member> <entries-json> <minutes> [base]: write a findings
# sidecar for the current branch; entries default finding_class and severity.
alf_sidecar() {
  local base="${4:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" f
  f="$ALF_ROOT/.gaia/local/audit/$base.$ALF_SLUG.$1.findings.json"
  jq -n -c --arg m "$1" --argjson e "$2" '{schema: 1, member: $m,
    findings: ($e | map({finding_class: "rule/x", severity: "warning", title: "t", failure_mode: "f",
                         verified_by: "v", suggested_fix: "s"} + .))}' >"$f" || return 1
  touch -t "$(alf_time "$3")" "$f"
}

# alf_stamp <r> <minutes>: write round r's dispatch stamp.
alf_stamp() {
  local f="$ALF_ROOT/.gaia/local/audit-loop/$ALF_B.d/round-$1.stamp"
  mkdir -p "${f%/*}" && : >"$f" && touch -t "$(alf_time "$2")" "$f"
}

# alf_baseline <r> <minutes>: write round r's verifier baseline file.
alf_baseline() {
  local f="$ALF_ROOT/.gaia/local/runs/$ALF_B/baseline-$1.json"
  mkdir -p "${f%/*}" && printf '{"schema":1,"round":%s}\n' "$1" >"$f" && touch -t "$(alf_time "$2")" "$f"
}

# alf_dispositions <k> <entries-json>: write dispositions-<k>.json.
alf_dispositions() {
  local f="$ALF_ROOT/.gaia/local/runs/$ALF_B/dispositions-$1.json"
  mkdir -p "${f%/*}" && jq -n -c --argjson k "$1" --argjson e "$2" '{schema: 1, round: $k, entries: $e}' >"$f"
}

# alf_seed_state <spec-json>: write the state file from a compact spec
# {pr, knobs, rounds, checkpoints, answers}; omitted parts take defaults.
alf_seed_state() {
  mkdir -p "${ALF_STATE%/*}"
  jq -n --arg b "$ALF_B" --argjson s "$1" '{schema: 1, key: ("branch:" + $b), branch: $b,
    pr: ($s.pr // null), created_at: "2026-01-01T00:00:00Z",
    history: ({rounds: ($s.rounds // []), checkpoints: ($s.checkpoints // [])}
              + (if (($s.rounds // []) | length) > 0 or $s.knobs != null
                 then {knobs: ($s.knobs // {checkpoint_round: 5, grant_rounds: 3})} else {} end)),
    allowance: {answers: ($s.answers // [])}}' >"$ALF_STATE"
}

# alf_state_edit <jq-filter> [jq-args...]: rewrite the state file in place.
alf_state_edit() {
  local f="$1"
  shift
  jq "$@" "$f" "$ALF_STATE" >"$ALF_STATE.alf" && mv "$ALF_STATE.alf" "$ALF_STATE"
}

# alf_add_round <members-json> [closing]: record HEAD as the next round.
alf_add_round() {
  [ -f "$ALF_STATE" ] || alf_seed_state '{}'
  alf_state_edit '.history.knobs //= {checkpoint_round: 5, grant_rounds: 3}
    | .history.rounds += [{round: ((.history.rounds | length) + 1), tree: $t, commit: $c, raw_branch_slug: $s,
        dispatched_at: "2026-01-01T00:00:00Z", members: $m, closing: $cl, snapshot: null}]' \
    --arg t "$ALF_TREE" --arg c "$ALF_COMMIT" --arg s "$ALF_SLUG" --argjson m "$1" --argjson cl "${2:-false}"
}

# alf_set_snapshot <r> <snapshot-json>: store round r's snapshot.
alf_set_snapshot() {
  alf_state_edit '.history.rounds[$r - 1].snapshot = $s' --argjson r "$1" --argjson s "$2"
}

# alf_add_checkpoint <at-round> <reason>: append a checkpoint.
alf_add_checkpoint() {
  alf_state_edit '.history.checkpoints += [{index: ((.history.checkpoints | length) + 1), at_round: $a,
    reason: $why, recorded_at: "2026-01-01T00:00:00Z", session_id: "s1", audited_root: "/x"}]' \
    --argjson a "$1" --arg why "$2"
}

# alf_add_answer <checkpoint-index> grant <n> | accept: append an answer.
alf_add_answer() {
  if [ "$2" = grant ]; then
    alf_state_edit '.allowance.answers += [{checkpoint: $i, kind: "grant", n: $n, at: "2026-01-01T00:00:00Z", session_id: "s1"}]' \
      --argjson i "$1" --argjson n "$3"
  else
    alf_state_edit '.allowance.answers += [{checkpoint: $i, kind: "accept", at: "2026-01-01T00:00:00Z", session_id: "s1"}]' \
      --argjson i "$1"
  fi
}

# alf_entries <path> <first> <last> [class]: entries on lines first..last.
alf_entries() {
  jq -n -c --arg p "$1" --argjson a "$2" --argjson b "$3" --arg c "${4:-rule/x}" \
    '[range($a; $b + 1) | {path: $p, line: ., finding_class: $c}]'
}

# alf_store_snapshot <r>: evaluate round r and store it, as the bound hook
# does at the next new-tree dispatch (needs audit-loop-eval.sh sourced).
alf_store_snapshot() {
  local snap
  snap="$(gaia_loop_evaluate_round "$ALF_ROOT" "$(cat "$ALF_STATE")" "$1")" || return 1
  alf_set_snapshot "$1" "$snap"
}

# alf_round <r> <member> <entries-json>: one round on the current HEAD:
# store round r-1's snapshot, record round r, stamp it, write the sidecar.
alf_round() {
  if [ "$1" -gt 1 ]; then alf_store_snapshot $(($1 - 1)) || return 1; fi
  alf_add_round "[\"$2\"]" && alf_stamp "$1" $((10 * $1)) && alf_sidecar "$2" "$3" $((10 * $1 + 1))
}

# alf_sequence <A1> <A2> ...: a branch whose round r reports A_r stable keys
# on branch-added f.txt lines 1..A_r; every round's commit touches only
# other.txt, so no entry ever sits on a repaired line.
alf_sequence() {
  local r=1 a
  alf_fill f.txt 12 feature
  for a in "$@"; do
    alf_set_line other.txt "$r" "round $r"
    alf_commit "round $r" || return 1
    alf_round "$r" code-audit-frontend "$(alf_entries f.txt 1 "$a")" || return 1
    r=$((r + 1))
  done
}
