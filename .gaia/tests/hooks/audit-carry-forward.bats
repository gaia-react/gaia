#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-carry-forward.sh, the carry-forward
# predicate (cf_enabled / cf_select_anchor / cf_may_carry).
#
# The lib is sourced in setup(); it resolves its own sibling libs (audit-scope,
# audit-machinery, audit-clearance) from its real on-disk location, so calls run
# against a scratch sandbox root while the classifier still parses the built-in
# roster. Each test builds distinct real trees by committing files, seeds
# writer-shaped schema-2 earned markers into the pool, and calls the predicate.
#
# The predicate is PURE: it reads, it never writes. It raises no security bar,
# the machinery guard cannot defeat an actor who rewrites the working tree.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS bash 3.2 does not
# fail a @test on a false bare `[[ ]]` that is not the last command, so
# assertions use `grep -q` / `[ ]` / explicit `return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  CF_LIB="$REPO_ROOT/.claude/hooks/lib/audit-carry-forward.sh"
  [ -f "$CF_LIB" ] || skip "audit-carry-forward.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # shellcheck source=/dev/null
  . "$CF_LIB"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/.gaia"
  printf '1.6.1\n' > "$R/.gaia/VERSION"
  git -C "$R" init --quiet --initial-branch=main
  git -C "$R" config user.email "test@example.com"
  git -C "$R" config user.name "Test"
  git -C "$R" config commit.gpgsign false
  echo "# readme" > "$R/README.md"
  git -C "$R" add .gaia/VERSION README.md
  git -C "$R" commit --quiet -m "init"
  mkdir -p "$R/.gaia/local/audit"
  AUDIT="$R/.gaia/local/audit"
}

# commit_file PATH CONTENT: commit one file, echo the new HEAD tree sha.
commit_file() {
  mkdir -p "$R/$(dirname "$1")"
  printf '%s\n' "$2" > "$R/$1"
  git -C "$R" add "$1"
  git -C "$R" commit --quiet -m "change $1"
  git -C "$R" rev-parse "HEAD^{tree}"
}

head_tree() { git -C "$R" rev-parse "HEAD^{tree}"; }
head_sha() { git -C "$R" rev-parse HEAD; }

# seed_earned TREE SHA MEMBER AAT [FINDINGS_JSON]: write a writer-shaped earned
# marker for MEMBER (frontend is sidecar:true and gets a sidecar file).
seed_earned() {
  local tree="$1" sha="$2" member="$3" aat="$4" findings="${5:-[]}" infix sidecar
  if [ "$member" = "code-audit-frontend" ]; then infix=""; sidecar="true"; else infix=".$member"; sidecar="false"; fi
  printf '{"version":"1.6.1","schema":2,"member":"%s","provenance":"earned","sha":"%s","tree":"%s","audited_at":"%s","sidecar":%s}\n' \
    "$member" "$sha" "$tree" "$aat" "$sidecar" > "$AUDIT/${tree}${infix}.ok"
  if [ "$sidecar" = "true" ]; then
    printf '{"schema":1,"backend":"absent","findings":%s}\n' "$findings" > "$AUDIT/${sha}.dispositions.json"
  fi
}

# ---------------------------------------------------------------------------
# UAT-005: ownerless-in-scope path refuses the DEFAULT member.
# ---------------------------------------------------------------------------

@test "UAT-005: ownerless-in-scope path refuses the default member (Dockerfile)" {
  anchor="$(commit_file "app/x.ts" "export const x = 1")"
  asha="$(head_sha)"
  seed_earned "$anchor" "$asha" "code-audit-frontend" "2026-07-14T10:00:00Z"
  head="$(commit_file "Dockerfile" "FROM scratch")"

  run cf_may_carry "$R" "code-audit-frontend" "$anchor" "$head"
  [ "$status" -ne 0 ]
  grep -q "carry-forward: declined code-audit-frontend: ownerless-in-scope Dockerfile" <<<"$output" || return 1
  # No clearance minted (the predicate is pure).
  [ ! -e "$AUDIT/${head}.carried" ]
}

@test "UAT-005: nested ownerless-in-scope public asset refuses the default member" {
  anchor="$(commit_file "app/x.ts" "export const x = 1")"
  asha="$(head_sha)"
  seed_earned "$anchor" "$asha" "code-audit-frontend" "2026-07-14T10:00:00Z"
  head="$(commit_file "public/logo.svg" "<svg></svg>")"

  run cf_may_carry "$R" "code-audit-frontend" "$anchor" "$head"
  [ "$status" -ne 0 ]
  grep -q "ownerless-in-scope public/logo.svg" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# UAT-006: the machinery guard, table-driven over AUDIT_MACHINERY_PATHS.
# ---------------------------------------------------------------------------

@test "UAT-006(a): every AUDIT_MACHINERY_PATHS entry in the delta refuses with machinery <path>" {
  anchor="$(head_tree)"
  anchor_sha="$(head_sha)"
  local m="code-audit-maintainer-shell"
  seed_earned "$anchor" "$anchor_sha" "$m" "2026-07-14T10:00:00Z"

  local checked=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    local rep
    case "$entry" in
      *"/**") rep="${entry%\*\*}rep-machinery.sh" ;;
      *) rep="$entry" ;;
    esac
    head="$(commit_file "$rep" "machinery change")"
    run cf_may_carry "$R" "$m" "$anchor" "$head"
    [ "$status" -ne 0 ]
    grep -q "carry-forward: declined ${m}: machinery ${rep}" <<<"$output" || {
      echo "entry=$entry rep=$rep did not refuse with machinery: $output" >&2
      return 1
    }
    checked=$((checked + 1))
    # Reset back to the anchor so each entry's delta is isolated to one file.
    git -C "$R" reset --hard "$anchor_sha" --quiet
  done <<EOF
$AUDIT_MACHINERY_PATHS
EOF
  [ "$checked" -ge 20 ]
}

@test "UAT-006(b): a non-machinery sibling does NOT disable carry for a member that does not own it" {
  # .gaia/scripts/token-tally.sh is deliberately OUTSIDE the machinery set, and
  # the frontend member does not own it (code-audit-maintainer-shell does), so
  # the frontend member carries forward across a delta touching only it.
  anchor="$(commit_file "app/x.ts" "export const x = 1")"
  asha="$(head_sha)"
  seed_earned "$anchor" "$asha" "code-audit-frontend" "2026-07-14T10:00:00Z"
  head="$(commit_file ".gaia/scripts/token-tally.sh" "echo tally")"

  run cf_may_carry "$R" "code-audit-frontend" "$anchor" "$head"
  [ "$status" -eq 0 ]
}

@test "UAT-006(c): a machinery edit already inside the anchor tree lets a wiki-only delta carry" {
  # The machinery file was audited and cleared AT the anchor: it sits inside the
  # anchor tree, so the anchor-to-HEAD delta (wiki only) contains no machinery.
  commit_file ".gaia/audit-ci.yml" "x: 1" >/dev/null
  anchor="$(head_tree)"
  asha="$(head_sha)"
  seed_earned "$anchor" "$asha" "code-audit-maintainer-shell" "2026-07-14T10:00:00Z"
  head="$(commit_file "wiki/note.md" "doc")"

  run cf_may_carry "$R" "code-audit-maintainer-shell" "$anchor" "$head"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Ownership refusal names its first owned path (success criterion 10, COV-008).
# ---------------------------------------------------------------------------

@test "ownership refusal names the first owned path with owns-changed-path" {
  anchor="$(commit_file "wiki/a.md" "doc")"
  asha="$(head_sha)"
  seed_earned "$anchor" "$asha" "code-audit-frontend" "2026-07-14T10:00:00Z"
  head="$(commit_file "app/y.ts" "export const y = 2")"

  run cf_may_carry "$R" "code-audit-frontend" "$anchor" "$head"
  [ "$status" -ne 0 ]
  grep -q "carry-forward: declined code-audit-frontend: owns-changed-path app/y.ts" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# UAT-011: never carry past a live refusal of the EXACT tree being merged.
# ---------------------------------------------------------------------------

@test "UAT-011: a refusal artifact for HEAD's exact tree blocks the carry (refused-tree)" {
  local m="code-audit-maintainer-shell"
  anchor="$(commit_file "wiki/a.md" "doc")"
  asha="$(head_sha)"
  seed_earned "$anchor" "$asha" "$m" "2026-07-14T10:00:00Z"
  # A later wiki-only tree the member neither owns nor finds machinery in.
  head="$(commit_file "wiki/b.md" "more")"
  hsha="$(head_sha)"
  # The member audited THIS tree for real and withheld its clearance.
  printf '{"version":"1.6.1","schema":2,"member":"%s","provenance":"refused","sha":"%s","tree":"%s","audited_at":"2026-07-14T11:00:00Z","sidecar":false}\n' \
    "$m" "$hsha" "$head" > "$AUDIT/${head}.${m}.refused"

  # An anchor still selects (the delta touches nothing the member owns)...
  a="$(cf_select_anchor "$R" "$m" "$head" 2>/dev/null)"
  [ "$a" = "$anchor" ]
  # ...but the live refusal of the exact tree blocks the carry.
  run cf_may_carry "$R" "$m" "$anchor" "$head"
  [ "$status" -ne 0 ]
  grep -q "carry-forward: declined ${m}: refused-tree ${head}" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# UAT-014: anchor selection over a mixed pool. Deterministic, never carried.
# ---------------------------------------------------------------------------

@test "UAT-014: selection drops every unusable candidate, is deterministic, never picks a carried" {
  local m="code-audit-maintainer-shell"
  base_sha="$(head_sha)"
  # Two valid earned anchors as SIBLINGS off the same base, so each one's delta
  # to head is exactly {own unique file, head's unique file} = 2 paths: TIED on
  # changed-path count. Same audited_at, so the tiebreak is the smaller tree sha.
  t1="$(commit_file "wiki/one.md" "1")"
  git -C "$R" reset --hard "$base_sha" --quiet
  t2="$(commit_file "wiki/two.md" "2")"
  git -C "$R" reset --hard "$base_sha" --quiet
  head="$(commit_file "wiki/head.md" "h")"
  hsha="$(head_sha)"
  seed_earned "$t1" "$hsha" "$m" "2026-07-14T10:00:00Z"
  seed_earned "$t2" "$hsha" "$m" "2026-07-14T10:00:00Z"
  # A legacy marker (no version).
  legacy="$(printf '%040d' 5)"
  printf '{"schema":2,"member":"%s","provenance":"earned","tree":"%s","sha":"%s","audited_at":"2026-07-14T12:00:00Z","sidecar":false}\n' \
    "$m" "$legacy" "$hsha" > "$AUDIT/${legacy}.${m}.ok"
  # A tree-mismatch marker (filename key != body tree).
  badkey="$(printf '%040d' 7)"
  printf '{"version":"1.6.1","schema":2,"member":"%s","provenance":"earned","tree":"%s","sha":"%s","audited_at":"2026-07-14T13:00:00Z","sidecar":false}\n' \
    "$m" "$t1" "$hsha" > "$AUDIT/${badkey}.${m}.ok"
  # A marker whose recorded tree object is absent from the object database.
  absent="$(printf '%040d' 3 | tr '0' 'a')"
  printf '{"version":"1.6.1","schema":2,"member":"%s","provenance":"earned","tree":"%s","sha":"%s","audited_at":"2026-07-14T14:00:00Z","sidecar":false}\n' \
    "$m" "$absent" "$hsha" > "$AUDIT/${absent}.${m}.ok"
  # A CARRIED clearance for t1 (must NEVER be selected).
  printf '{"version":"1.6.1","schema":2,"member":"%s","provenance":"carried","tree":"%s","sha":"%s","audited_at":"2026-07-14T15:00:00Z","sidecar":false,"anchor_tree":"%s"}\n' \
    "$m" "$t1" "$hsha" "$t2" > "$AUDIT/${t1}.${m}.carried"

  expected="$(printf '%s\n%s\n' "$t1" "$t2" | LC_ALL=C sort | head -1)"
  a1="$(cf_select_anchor "$R" "$m" "$head" 2>"$BATS_TEST_TMPDIR/drops")"
  a2="$(cf_select_anchor "$R" "$m" "$head" 2>/dev/null)"
  [ "$a1" = "$a2" ]
  [ "$a1" = "$expected" ]
  # Every unusable candidate was dropped with a logged reason.
  grep -q "version-mismatch" "$BATS_TEST_TMPDIR/drops" || return 1
  grep -q "tree-mismatch" "$BATS_TEST_TMPDIR/drops" || return 1
  grep -q "tree-object-absent" "$BATS_TEST_TMPDIR/drops" || return 1
}

@test "an empty pool refuses with no-anchor" {
  head="$(commit_file "wiki/a.md" "doc")"
  run cf_select_anchor "$R" "code-audit-maintainer-shell" "$head"
  [ "$status" -eq 0 ]
  # stdout is empty (the selected anchor); the reason is on stderr.
  grep -q "carry-forward: declined code-audit-maintainer-shell: no-anchor" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# Cost budget: 50 valid candidates -> at most 10 git diff forks; the free
# filters run before any fork.
# ---------------------------------------------------------------------------

shim_git_diff_counter() {
  SHIM_DIR="$BATS_TEST_TMPDIR/shim"
  DIFF_COUNTER="$SHIM_DIR/diff.count"
  mkdir -p "$SHIM_DIR"
  : > "$DIFF_COUNTER"
  local real_git
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = "diff" ]; then echo x >> "$DIFF_COUNTER"; break; fi
done
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
}
git_diff_forks() { wc -l < "$DIFF_COUNTER" | tr -d ' '; }

@test "budget: a pool of 50 valid earned candidates produces at most 10 git diff forks" {
  local m="code-audit-maintainer-shell" hsha i tr
  # 50 real trees, each with a valid earned marker.
  i=0
  while [ "$i" -lt 50 ]; do
    tr="$(commit_file "wiki/c$i.md" "c$i")"
    seed_earned "$tr" "$(head_sha)" "$m" "$(printf '2026-07-14T10:00:%02dZ' "$i")"
    i=$((i + 1))
  done
  head="$(head_tree)"
  shim_git_diff_counter
  PATH="$SHIM_DIR:$PATH" cf_select_anchor "$R" "$m" "$head" >/dev/null 2>&1
  [ "$(git_diff_forks)" -le 10 ]
}

@test "budget: the free filters run before any fork (all-invalid pool costs ZERO git diff forks)" {
  local m="code-audit-maintainer-shell" i tr
  # 20 candidates that all FAIL a free filter (version mismatch): none should
  # ever reach a git diff.
  i=0
  while [ "$i" -lt 20 ]; do
    tr="$(commit_file "wiki/b$i.md" "b$i")"
    printf '{"version":"9.9.9","schema":2,"member":"%s","provenance":"earned","tree":"%s","sha":"%s","audited_at":"2026-07-14T10:00:%02dZ","sidecar":false}\n' \
      "$m" "$tr" "$(head_sha)" "$i" > "$AUDIT/${tr}.${m}.ok"
    i=$((i + 1))
  done
  head="$(head_tree)"
  shim_git_diff_counter
  a="$(PATH="$SHIM_DIR:$PATH" cf_select_anchor "$R" "$m" "$head" 2>/dev/null)"
  [ -z "$a" ]
  [ "$(git_diff_forks)" -eq 0 ]
}
