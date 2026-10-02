#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-loop-state-lib.sh: branch keying, state paths,
# schema-1 validation, the lock, atomic writes, the audited-root resolver and
# the grant/accept line grammar.
#
# AUDIT_LOOP_SCRIPTS_DIR points the suite at a scratch copy of the scripts,
# which is how a mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-loop-state-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="${AUDIT_LOOP_SCRIPTS_DIR:-$REPO_ROOT/.gaia/scripts}"
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-state-lib.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  alf_init
}

# stub_git <branch-output>: a `git` on PATH whose `branch --show-current`
# prints <branch-output>.
stub_git() {
  local d="$BATS_TEST_TMPDIR/stub-git"
  mkdir -p "$d"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" >"$d/git"
  chmod +x "$d/git"
  printf '%s\n' "$d"
}

valid_state() {
  jq -n -c --arg t "$(alf_git rev-parse 'HEAD^{tree}')" --arg c "$(alf_git rev-parse HEAD)" \
    '{schema: 1, key: "branch:feat/x", branch: "feat/x", pr: null,
      history: {knobs: {checkpoint_round: 5, grant_rounds: 3},
                rounds: [{round: 1, tree: $t, commit: $c, members: ["code-audit-frontend"], closing: false, snapshot: null}],
                checkpoints: []},
      allowance: {answers: []}}'
}

@test "key: a branch and its worktree spelling normalize to one key" {
  alf_branch debt/42-fix
  run gaia_loop_key "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "debt/42-fix" ]
  alf_git checkout -q -b worktree-debt+42-fix
  run gaia_loop_key "$ALF_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "debt/42-fix" ]
}

@test "key: a detached HEAD is rc 4" {
  alf_git checkout -q --detach
  run gaia_loop_key "$ALF_ROOT"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "key: a name that cannot key a state file is rc 5" {
  local d bad
  d="$(stub_git x)"
  for bad in 'feat/a..b' 'feat//x' '/lead' 'trail/' 'sp ace' "$(printf 'x%.0s' $(seq 1 129))"; do
    d="$(stub_git "$bad")"
    PATH="$d:$PATH" run gaia_loop_key "$ALF_ROOT"
    [ "$status" -eq 5 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "key: git absent from PATH is rc 6" {
  # A fresh shell: this one has git hashed, and bash 3.2 keeps the hash
  # across a command-scoped PATH.
  PATH="$(path_shim_without git)" run bash -c '. "$1"; gaia_loop_key "$2"' _ "$SCRIPTS/audit-loop-state-lib.sh" "$ALF_ROOT"
  [ "$status" -eq 6 ]
}

@test "state path: colliding slugs a/b-c and a-b/c get distinct state files" {
  local p1 p2
  p1="$(gaia_loop_state_file /m a/b-c)"
  p2="$(gaia_loop_state_file /m a-b/c)"
  [ "$p1" = "/m/.gaia/local/audit-loop/a/b-c.json" ]
  [ "$p2" = "/m/.gaia/local/audit-loop/a-b/c.json" ]
  [ "$p1" != "$p2" ]
}

@test "read: a valid file reads back; an absent file is rc 1" {
  local f="$BATS_TEST_TMPDIR/s/x.json"
  run gaia_loop_read_state "$f"
  [ "$status" -eq 1 ]
  gaia_loop_write_state "$f" "$(valid_state)"
  run gaia_loop_read_state "$f"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.history.rounds | length')" = 1 ]
}

@test "read and write: every corrupt shape is rc 5, prints nothing, and never replaces a file" {
  local f="$BATS_TEST_TMPDIR/s/x.json" bad="$BATS_TEST_TMPDIR/bad.json" snap name json n=0
  gaia_loop_write_state "$f" "$(valid_state)"
  snap="$(snapshot_file "$f")"
  while IFS='|' read -r name json; do
    n=$((n + 1))
    printf '%s' "$json" >"$bad"
    run gaia_loop_read_state "$bad"
    [ "$status" -eq 5 ] || { echo "read accepted: $name"; return 1; }
    [ -z "$output" ] || { echo "read printed for: $name"; return 1; }
    run gaia_loop_write_state "$f" "$json"
    [ "$status" -ne 0 ] || { echo "write accepted: $name"; return 1; }
    assert_files_identical "$snap" "$f" || { echo "file changed by: $name"; return 1; }
  done <<EOF
invalid json|{"schema":1,
schema 2|$(valid_state | jq -c '.schema = 2')
missing history.rounds|$(valid_state | jq -c 'del(.history.rounds)')
non-hex tree|$(valid_state | jq -c '.history.rounds[0].tree = "HEAD"')
missing knobs with rounds|$(valid_state | jq -c 'del(.history.knobs)')
pr not an integer|$(valid_state | jq -c '.pr = "12"')
two documents|$(valid_state) $(valid_state)
EOF
  [ "$n" -eq 7 ]
}

@test "lock: two concurrent writers both land" {
  local f="$BATS_TEST_TMPDIR/s/x.json" t1 t2
  gaia_loop_write_state "$f" "$(valid_state)"
  t1="$(printf '1%.0s' $(seq 1 40))"
  t2="$(printf '2%.0s' $(seq 1 40))"
  writer() {
    gaia_loop_lock "$f" $(($(date +%s) + 20)) || return 1
    local s
    s="$(gaia_loop_read_state "$f")"
    sleep 0.3
    gaia_loop_write_state "$f" "$(printf '%s' "$s" | jq -c --arg t "$1" '.history.rounds += [.history.rounds[0] + {tree: $t}]')"
    gaia_loop_unlock "$f"
  }
  writer "$t1" &
  writer "$t2" &
  wait
  run jq -r '[.history.rounds[].tree] | join(",")' "$f"
  [ "$(jq '.history.rounds | length' "$f")" -eq 3 ]
  case "$output" in *"$t1"*) ;; *) return 1 ;; esac
  case "$output" in *"$t2"*) ;; *) return 1 ;; esac
  [ ! -d "$f.lock" ]
}

@test "lock: a stale lock is broken; a fresh held lock past the deadline is rc 1" {
  local f="$BATS_TEST_TMPDIR/s/x.json"
  mkdir -p "$f.lock"
  touch -t "$(alf_time 0)" "$f.lock"
  run gaia_loop_lock "$f" $(($(date +%s) + 5))
  [ "$status" -eq 0 ]
  [ -d "$f.lock" ]
  run gaia_loop_lock "$f" $(($(date +%s) + 1))
  [ "$status" -eq 1 ]
  gaia_loop_unlock "$f"
  [ ! -d "$f.lock" ]
}

@test "audited root: the prompt's Working root wins over cwd; cwd is the fallback" {
  local wt payload
  alf_branch feat/x
  alf_git worktree add -q -b feat/wt "$BATS_TEST_TMPDIR/wt" main
  wt="$(cd "$BATS_TEST_TMPDIR/wt" && pwd -P)"
  payload="$(jq -n -c --arg c "$ALF_ROOT" --arg p "Audit this. Working root: $wt, the absolute path of the checkout." \
    '{cwd: $c, tool_input: {prompt: $p}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 0 ]
  [ "$output" = "$wt" ]
  payload="$(jq -n -c --arg c "$ALF_ROOT" '{cwd: $c, tool_input: {prompt: "no root named here"}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 0 ]
  [ "$output" = "$ALF_ROOT" ]
}

@test "audited root: a prose-punctuated or quoted Working root resolves to the named checkout" {
  local wt payload p
  alf_branch feat/x
  alf_git worktree add -q -b feat/wt "$BATS_TEST_TMPDIR/wt" main
  wt="$(cd "$BATS_TEST_TMPDIR/wt" && pwd -P)"
  for p in "Working root: $wt. Audit the PR." "Working root: $wt; base main" "Working root: \`$wt\`." \
    "Working root: \"$wt\"" "(Working root: $wt)"; do
    payload="$(jq -n -c --arg c "$ALF_ROOT" --arg p "$p" '{cwd: $c, tool_input: {prompt: $p}}')"
    run gaia_loop_resolve_audited_root "$payload"
    [ "$status" -eq 0 ] || { printf 'prompt %s: status %s\n' "$p" "$status" >&2; return 1; }
    [ "$output" = "$wt" ] || { printf 'prompt %s: output %s\n' "$p" "$output" >&2; return 1; }
  done
}

@test "audited root: a named Working root that does not resolve is rc 2 naming it, never the cwd" {
  local payload
  mkdir -p "$BATS_TEST_TMPDIR/nogit"
  payload="$(jq -n -c --arg c "$ALF_ROOT" --arg p "Working root: $BATS_TEST_TMPDIR/nogit, the path" \
    '{cwd: $c, tool_input: {prompt: $p}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 2 ]
  [ "$output" = "$BATS_TEST_TMPDIR/nogit" ]
  payload="$(jq -n -c --arg c "$ALF_ROOT" '{cwd: $c, tool_input: {prompt: "Working root: rel/path, x"}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 2 ]
  [ "$output" = "rel/path" ]
}

@test "audited root: no Working root and a relative cwd is rc 1" {
  local payload
  payload="$(jq -n -c '{cwd: "rel/dir", tool_input: {prompt: "no root named here"}}')"
  run gaia_loop_resolve_audited_root "$payload"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "parse line: the grammar table, with PATH empty" {
  local text want got raw n=0
  while IFS='|' read -r text want; do
    n=$((n + 1))
    raw="$(printf '%bX' "$text")"
    raw="${raw%X}"
    got="$(PATH='' gaia_loop_parse_line "$raw")"
    [ "$got" = "$want" ] || { echo "'$text' gave '$got', want '$want'"; return 1; }
  done <<'EOF'
audit-grant 2|grant 2
audit-grant 10|grant 10
  audit-accept\n|accept
\t audit-grant 7\r\n|grant 7
audit-grant 0|malformed
audit-grant 11|malformed
audit-grant abc|malformed
audit-grant 02|malformed
audit-grant  2|malformed
audit-grant 2 please|malformed
what does audit-grant 3 do?|malformed
audit-accept now|malformed
audit-grant\t2|malformed
hello|none
|none
EOF
  [ "$n" -eq 15 ]
}

@test "parse line: the library's own lines parse back" {
  [ "$(gaia_loop_parse_line "$(gaia_loop_grant_line 3)")" = "grant 3" ]
  [ "$(gaia_loop_parse_line "$(gaia_loop_accept_line)")" = "accept" ]
  run gaia_loop_grant_line 11
  [ "$status" -ne 0 ]
}

@test "validators: oid, uint and safe relpath" {
  gaia_loop_is_oid "$(printf 'a%.0s' $(seq 1 40))"
  gaia_loop_is_oid "$(printf 'b%.0s' $(seq 1 64))"
  gaia_loop_is_oid "$(printf 'A%.0s' $(seq 1 40))" && return 1
  gaia_loop_is_oid "HEAD" && return 1
  gaia_loop_is_uint 0
  gaia_loop_is_uint 123456789
  gaia_loop_is_uint 01 && return 1
  gaia_loop_is_uint -1 && return 1
  gaia_loop_is_uint 1234567890 && return 1
  gaia_loop_is_safe_relpath a/b.txt
  gaia_loop_is_safe_relpath 'a b/c..d'
  gaia_loop_is_safe_relpath -rf && return 1
  gaia_loop_is_safe_relpath /etc/x && return 1
  gaia_loop_is_safe_relpath a/../b && return 1
  gaia_loop_is_safe_relpath .. && return 1
  gaia_loop_is_safe_relpath "$(printf 'a\nb')" && return 1
  gaia_loop_is_safe_relpath '' && return 1
  true
}
