#!/usr/bin/env bats
# Remote-fixture tests for git-tag SPEC-number allocation (union read, tag
# reservation, retry, degrade paths, provisional marking, renumber-on-
# collision). Companion to spec-allocator-concurrency.bats, which covers the
# same-machine mutex over a no-origin repo; every test here builds a real
# bare-repo origin (and, where needed, a second clone) via
# helpers/tmp-spec-repo.sh --with-origin and helpers/clone-spec-repo.sh so the
# push-is-the-lock mechanics run against an actual git remote, not a stub.
#
# Hermetic: every test builds its own tmp origin (+ clones) and tears them
# down; no reliance on the real project ledger or remote.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  ALLOC=".specify/extensions/gaia/lib/spec-allocator.sh"
  CLEANUP_EXTRA=()
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO" "${REPO}.git"
  fi
  if [ "${#CLEANUP_EXTRA[@]}" -gt 0 ]; then
    for d in "${CLEANUP_EXTRA[@]}"; do
      rm -rf "$d"
    done
  fi
}

# Exact tag-annotation subject (no columnar `tag -n1` parsing / no ls-remote
# peeled-^{}-line ambiguity: a direct field read).
_tag_subject() {
  local origin="$1" tag="$2"
  git -C "$origin" tag -l --format='%(contents:subject)' "$tag"
}

# --- UAT-001: remote governs via union, + negative control ------------------

@test "UAT-001a: remote max N over local max M; next returns SPEC-(N+1), pushes spec/(N+1)" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin --seed-remote-tag spec/010 "seeded ten" --seed-draft SPEC-003)"
  ORIGIN="${REPO}.git"

  run bash -c "bash '$REPO/$ALLOC' next '$REPO' 'uat001 subject'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-011" ]

  # The remote (N=10), not the local ledger (M=3), governed the number.
  [ "$(git -C "$ORIGIN" tag -l 'spec/011')" = "spec/011" ]
  [ "$(jq -r '.specs[-1].reservation' "$REPO/.gaia/local/specs/ledger.json")" = "reserved" ]
}

@test "UAT-001b negative control: same fixture, GAIA_SPEC_FORCE_OFFLINE=1 degrades to provisional (not silently ledger-numbered)" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin --seed-remote-tag spec/010 "seeded ten" --seed-draft SPEC-003)"
  ORIGIN="${REPO}.git"

  run bash -c "GAIA_SPEC_FORCE_OFFLINE=1 bash '$REPO/$ALLOC' next '$REPO' 'uat001 negative control' 2>'$REPO/err'"
  [ "$status" -eq 0 ]
  # Forced offline: the remote's N=10 is unreachable, so the union falls back
  # to the LOCAL-only max (M=3) -> SPEC-004, never SPEC-011. A silent
  # ledger-only-numbered implementation and this provisional-degrade path are
  # observationally identical on id alone, which is exactly what the
  # reservation state + warning must distinguish.
  [ "$output" = "SPEC-004" ]
  [ "$(jq -r '.specs[-1].reservation' "$REPO/.gaia/local/specs/ledger.json")" = "provisional" ]
  grep -q "reserved provisionally" "$REPO/err"
  # No tag was pushed for the offline id; nothing new landed on the origin.
  [ -z "$(git -C "$ORIGIN" tag -l 'spec/004')" ]
}

# --- UAT-002: two clones racing; distinct ids, loser strictly greater -------

@test "UAT-002: two clones racing next; distinct ids, loser id > winner id (retry fired)" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin)"
  ORIGIN="${REPO}.git"
  CLONE1="$("$HELPERS/clone-spec-repo.sh" "$ORIGIN")"
  CLONE2="$("$HELPERS/clone-spec-repo.sh" "$ORIGIN")"
  CLEANUP_EXTRA=("$CLONE1" "$CLONE2")

  rm -f "$ORIGIN/.race-start"
  (
    until [ -f "$ORIGIN/.race-start" ]; do :; done
    bash "$CLONE1/$ALLOC" next "$CLONE1" "clone1 subject" > "$CLONE1/out" 2>"$CLONE1/err"
  ) &
  pid1=$!
  (
    until [ -f "$ORIGIN/.race-start" ]; do :; done
    bash "$CLONE2/$ALLOC" next "$CLONE2" "clone2 subject" > "$CLONE2/out" 2>"$CLONE2/err"
  ) &
  pid2=$!
  touch "$ORIGIN/.race-start"
  wait "$pid1"
  wait "$pid2"

  id1="$(cat "$CLONE1/out")"
  id2="$(cat "$CLONE2/out")"
  [[ "$id1" =~ ^SPEC-[0-9]{3}$ ]]
  [[ "$id2" =~ ^SPEC-[0-9]{3}$ ]]
  [ "$id1" != "$id2" ]

  n1=$((10#${id1#SPEC-}))
  n2=$((10#${id2#SPEC-}))
  winner=$(( n1 < n2 ? n1 : n2 ))
  loser=$(( n1 < n2 ? n2 : n1 ))
  # The two clones started from the SAME barrier-released state (a fresh
  # origin, no prior spec/* tags), so both independently computed the SAME
  # first candidate number. A duplicate id is impossible; the ONLY way the
  # loser ends up with a strictly higher number is that its first push was
  # rejected (ref already existed) and the retry loop re-read the union and
  # tried again higher, i.e. this inequality is only possible via a fired
  # client-side retry, not merely distinct remote refs by chance.
  [ "$loser" -gt "$winner" ]

  # Both reservations actually landed on the remote.
  [ "$(git -C "$ORIGIN" tag -l "spec/$(printf '%03d' "$winner")")" = "spec/$(printf '%03d' "$winner")" ]
  [ "$(git -C "$ORIGIN" tag -l "spec/$(printf '%03d' "$loser")")" = "spec/$(printf '%03d' "$loser")" ]
}

# --- UAT-003: empty-tree tag fetch propagation, annotated, immutable -------

@test "UAT-003: reservation tag survives a full sync, annotation equals the passed subject exactly" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin)"
  ORIGIN="${REPO}.git"
  # Cloned BEFORE any reservation exists, mirroring "another machine" that
  # already has a working tree and later needs to see a fresh reservation.
  CLONE2="$("$HELPERS/clone-spec-repo.sh" "$ORIGIN")"
  CLEANUP_EXTRA=("$CLONE2")

  subject="a KNOWN distinctive subject for UAT-003"
  run bash -c "bash '$REPO/$ALLOC' next '$REPO' '$subject'"
  [ "$status" -eq 0 ]
  id="$output"
  num=$((10#${id#SPEC-}))
  tag="spec/$(printf '%03d' "$num")"

  # The annotation on the origin equals the EXACT passed subject, not merely
  # a non-empty placeholder (the allocator's id-fallback would also be
  # non-empty, so equality is the load-bearing assertion here).
  [ "$(_tag_subject "$ORIGIN" "$tag")" = "$subject" ]

  # A genuinely "plain" `git fetch` (no --tags) does NOT sync a spec/NNN
  # reservation into an EXISTING clone. git's tag auto-follow only pulls a
  # tag whose peeled target object is materialized in the fetcher's local
  # object store; the reservation targets the empty-tree object, which a
  # normal working repo has never stored -- git special-cases *producing*
  # the empty tree (so `cat-file -e` succeeds), but auto-follow's has-object
  # check needs it actually present, and it is not. Verified empirically on
  # this toolchain. So a plain fetch leaves the reservation unsynced:
  run bash -c "git -C '$CLONE2' fetch --quiet origin"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$CLONE2" tag -l "$tag")" ]
  # What DOES sync it: a fresh `git clone` (fetches every ref unconditionally
  # -- the load-bearing "registry survives a fresh clone" guarantee) or an
  # explicit `git fetch --tags` (used here). Collision-avoidance never
  # depends on any of this: the allocator reads the remote live via
  # `git ls-remote`, never via locally-fetched tag refs.
  run bash -c "git -C '$CLONE2' fetch --quiet --tags origin"
  [ "$status" -eq 0 ]
  [ "$(_tag_subject "$CLONE2" "$tag")" = "$subject" ]

  # Immutability: the allocator's push path never issues --force (grep the
  # frozen source), and a second allocation cycle leaves the first
  # reservation's annotation untouched.
  run bash -c "grep -nE 'push[^|]*(--force|-f[[:space:]])' '$REPO/$ALLOC'"
  [ "$status" -ne 0 ]

  run bash -c "bash '$REPO/$ALLOC' next '$REPO' 'a second, different subject'"
  [ "$status" -eq 0 ]
  [ "$output" != "$id" ]
  [ "$(_tag_subject "$ORIGIN" "$tag")" = "$subject" ]
}

# --- UAT-004: bounded remote read, provisional, observably marked ----------

@test "UAT-004a: configured-but-unreachable origin; next returns fast, provisional + warning" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin)"
  # Simulate an unreachable remote: the configured origin path no longer
  # resolves (bare repo removed out from under the remote config).
  rm -rf "${REPO}.git"

  start="$(date +%s)"
  run bash -c "GAIA_SPEC_REMOTE_TIMEOUT_SECS=2 bash '$REPO/$ALLOC' next '$REPO' 'uat004a subject' 2>'$REPO/err'"
  end="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-001" ]
  # Bounded: nowhere close to hanging (generous ceiling well above the 2s
  # remote timeout to absorb CI slowness without flaking).
  [ "$((end - start))" -le 10 ]
  [ "$(jq -r '.specs[-1].reservation' "$REPO/.gaia/local/specs/ledger.json")" = "provisional" ]
  grep -q "reserved provisionally" "$REPO/err"
}

@test "UAT-004b: GAIA_SPEC_FORCE_OFFLINE=1 (credential-prompt analogue); provisional + warning, distinguishable from the no-remote 'local' case" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin)"

  start="$(date +%s)"
  run bash -c "GAIA_SPEC_FORCE_OFFLINE=1 bash '$REPO/$ALLOC' next '$REPO' 'uat004b subject' 2>'$REPO/err'"
  end="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-001" ]
  [ "$((end - start))" -le 10 ]
  [ "$(jq -r '.specs[-1].reservation' "$REPO/.gaia/local/specs/ledger.json")" = "provisional" ]
  grep -q "reserved provisionally" "$REPO/err"

  # Companion no-remote fixture: same allocation, no origin configured at
  # all. Distinguishable by BOTH reservation state and the absence of a
  # warning, so a future implementation cannot collapse "never wired the
  # remote" and "wired but currently unreachable" into the same signature.
  NOREMOTE="$("$HELPERS/tmp-spec-repo.sh")"
  CLEANUP_EXTRA=("$NOREMOTE")
  run bash -c "bash '$NOREMOTE/$ALLOC' next '$NOREMOTE' 'no remote subject' 2>'$NOREMOTE/err'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.specs[-1].reservation' "$NOREMOTE/.gaia/local/specs/ledger.json")" = "local" ]
  [ ! -s "$NOREMOTE/err" ]
}

# --- UAT-005: offline-provisional collision -> renumber ---------------------

@test "UAT-005: offline-provisional SPEC-K collides on reconnect; renumbered, folder + ledger + caches re-keyed, new tag reserved" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" \
    --with-origin \
    --seed-provisional SPEC-005 "renumber test subject" \
    --seed-folder SPEC-005 \
    --seed-remote-tag spec/005 "taken by another machine while offline")"
  ORIGIN="${REPO}.git"

  # Gate1/draft/session/audit caches the renumber must re-key alongside the
  # folder + ledger row.
  printf '{"spec_id":"SPEC-005","intent_hash":"abc123"}\n' > "$REPO/.gaia/local/cache/gate1-SPEC-005.json"
  mkdir -p "$REPO/.gaia/local/cache/audit-SPEC-005"
  echo "draft body" > "$REPO/.gaia/local/cache/draft-SPEC-005.md"
  printf '{"spec_id":"SPEC-005","phase":"discover"}\n' > "$REPO/.gaia/local/cache/spec-session-SPEC-005.json"
  echo "audit note" > "$REPO/.gaia/local/cache/audit-SPEC-005/notes.md"

  run bash -c "bash '$REPO/$ALLOC' reserve_pending '$REPO'"
  [ "$status" -eq 0 ]

  # Renumbered to the next free number over the union (5 was taken; 6 is
  # free), not kept at the collided 5.
  [ "$(jq -r '.specs | length' "$REPO/.gaia/local/specs/ledger.json")" -eq 1 ]
  [ "$(jq -r '.specs[0].id' "$REPO/.gaia/local/specs/ledger.json")" = "SPEC-006" ]
  [ "$(jq -r '.specs[0].renamed_from' "$REPO/.gaia/local/specs/ledger.json")" = "SPEC-005" ]
  [ "$(jq -r '.specs[0].reservation' "$REPO/.gaia/local/specs/ledger.json")" = "reserved" ]

  # Folder renamed; frontmatter re-keyed.
  [ ! -e "$REPO/.gaia/local/specs/SPEC-005" ]
  [ -f "$REPO/.gaia/local/specs/SPEC-006/SPEC.md" ]
  grep -q "^spec_id: SPEC-006$" "$REPO/.gaia/local/specs/SPEC-006/SPEC.md"

  # Caches re-keyed.
  [ ! -e "$REPO/.gaia/local/cache/gate1-SPEC-005.json" ]
  [ -f "$REPO/.gaia/local/cache/gate1-SPEC-006.json" ]
  [ "$(jq -r '.spec_id' "$REPO/.gaia/local/cache/gate1-SPEC-006.json")" = "SPEC-005" ]
  [ ! -e "$REPO/.gaia/local/cache/draft-SPEC-005.md" ]
  [ -f "$REPO/.gaia/local/cache/draft-SPEC-006.md" ]
  [ ! -e "$REPO/.gaia/local/cache/spec-session-SPEC-005.json" ]
  [ -f "$REPO/.gaia/local/cache/spec-session-SPEC-006.json" ]
  [ "$(jq -r '.spec_id' "$REPO/.gaia/local/cache/spec-session-SPEC-006.json")" = "SPEC-006" ]
  [ ! -e "$REPO/.gaia/local/cache/audit-SPEC-005" ]
  [ -f "$REPO/.gaia/local/cache/audit-SPEC-006/notes.md" ]

  # The new number's tag is reserved; the collided number is not reclaimed.
  [ "$(git -C "$ORIGIN" tag -l 'spec/006')" = "spec/006" ]
  [ "$(git -C "$ORIGIN" tag -l 'spec/005')" = "spec/005" ]
  [ "$(_tag_subject "$ORIGIN" "spec/005")" = "taken by another machine while offline" ]
}

# --- UAT-006: gaps below N, sparse/empty ledger -> N+1 ----------------------

@test "UAT-006: remote tags with gaps below N, empty local ledger; next returns SPEC-(N+1), never a gap or SPEC-001" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin --seed-remote-tag spec/003 "sub three" --seed-remote-tag spec/007 "sub seven")"
  ORIGIN="${REPO}.git"

  run bash -c "bash '$REPO/$ALLOC' next '$REPO' 'uat006 subject'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-008" ]
  [ "$(git -C "$ORIGIN" tag -l 'spec/008')" = "spec/008" ]
}

# --- success_criteria b2: reachable-but-UNSEEDED remote (SPEC-001 blocker) -

@test "reachable-but-unseeded origin, non-empty local ledger; next returns SPEC-(M+1), never SPEC-001" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin --seed-draft SPEC-004)"
  ORIGIN="${REPO}.git"
  # Sanity: the origin is reachable and writable, but genuinely has zero
  # spec/* tags (this is the distinguishing fixture vs UAT-006, which seeds
  # the remote, and vs UAT-001, where the remote max exceeds local).
  [ -z "$(git -C "$ORIGIN" tag -l 'spec/*')" ]

  run bash -c "bash '$REPO/$ALLOC' next '$REPO' 'reachable unseeded subject'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-005" ]
  [ "$(git -C "$ORIGIN" tag -l 'spec/005')" = "spec/005" ]
}

# --- UAT-007: non-writable tag namespace -> local numbering + warning ------

@test "UAT-007: origin rejects refs/tags/spec/* pushes; next returns the id, marks unavailable, warns, never blocks" {
  REPO="$("$HELPERS/tmp-spec-repo.sh" --with-origin --origin-reject-spec-tags)"
  ORIGIN="${REPO}.git"

  run bash -c "bash '$REPO/$ALLOC' next '$REPO' 'uat007 subject' 2>'$REPO/err'"
  [ "$status" -eq 0 ]
  [ "$output" = "SPEC-001" ]
  [ "$(jq -r '.specs[-1].reservation' "$REPO/.gaia/local/specs/ledger.json")" = "unavailable" ]
  grep -q "cross-team collision-safety unavailable" "$REPO/err"

  # The reject hook actually fired (this machine's global core.hooksPath
  # would otherwise silently no-op it): the tag never landed on the origin.
  [ -z "$(git -C "$ORIGIN" tag -l 'spec/001')" ]
}
