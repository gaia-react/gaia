#!/usr/bin/env bats
#
# Conformance suite for the two background refreshers' root derivation
# (`.gaia/scripts/check-updates.sh` and `.gaia/scripts/debt-count-refresh.sh`).
#
# Both write machine-local state the state registry classifies `shared`:
# cache/shared/update-check.json and debt/count.json are one physical copy per
# clone, and the statusline reads them by resolving the main checkout. Until
# this suite existed each refresher derived every path it writes from its own
# location on disk, so a copy running inside a worktree wrote a per-tree copy
# and the nudge it feeds went quiet.
#
# The fixture deliberately gives the worktree a REAL .gaia/local directory
# rather than the symlink to main that provisioning installs. That is the whole
# point: with the symlink in place a per-tree path resolves to main's copy
# anyway, so a suite built on a provisioned worktree would pass whether or not
# the script asks the resolver. Removing the symlink is what makes these
# assertions measure the derivation instead of the cutover.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/refresher-roots.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVER="$SCRIPTS_DIR/main-root-lib.sh"
  [ -f "$RESOLVER" ] || skip "main-root-lib.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"
}

# make_pair <script> [--no-resolver]
#
# Builds a committed main checkout holding the named refresher plus the
# resolver, adds a linked worktree at the real .claude/worktrees/<name> layout,
# and gives that worktree its own REAL .gaia/local (see the header note).
# Sets MAIN and WT. With --no-resolver the resolver is never copied in, which
# is the degrade-to-local path the shipped idiom must still honour.
make_pair() {
  local script="$1"
  local with_resolver=1
  [ "${2:-}" = "--no-resolver" ] && with_resolver=0

  MAIN="$(mktemp -d "$BATS_TEST_TMPDIR/main.XXXXXX")"
  MAIN="$(cd "$MAIN" && pwd -P)"

  mkdir -p "$MAIN/.gaia/scripts" "$MAIN/.gaia/local" "$MAIN/bin"
  cp "$SCRIPTS_DIR/$script" "$MAIN/.gaia/scripts/$script"
  chmod +x "$MAIN/.gaia/scripts/$script"
  if [ "$with_resolver" -eq 1 ]; then
    cp "$RESOLVER" "$MAIN/.gaia/scripts/main-root-lib.sh"
  fi
  printf '1.0.0\n' > "$MAIN/.gaia/VERSION"

  git -C "$MAIN" init -q
  git -C "$MAIN" config user.email t@t.t
  git -C "$MAIN" config user.name t
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -qm fixture

  git -C "$MAIN" worktree add -q "$MAIN/.claude/worktrees/wt" -b wt
  WT="$MAIN/.claude/worktrees/wt"

  # The worktree owns a real state directory, not main's symlink.
  mkdir -p "$WT/.gaia/local"
}

# stub_gh <count>: a `gh` whose `issue list` reports <count> open issues and
# whose every other subcommand is a silent success.
stub_gh() {
  cat > "$MAIN/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  printf '%s\n' "$1"
fi
exit 0
STUB
  chmod +x "$MAIN/bin/gh"
}

# ---------- debt-count-refresh.sh ----------

@test "debt refresher run from a worktree writes the MAIN checkout's count cache" {
  make_pair debt-count-refresh.sh
  stub_gh 7
  mkdir -p "$WT/.gaia/local/debt"
  touch "$WT/.gaia/local/debt/refresh-requested"

  PATH="$MAIN/bin:$PATH" run bash "$WT/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ]

  # The one physical copy the statusline reads lives under main.
  [ -f "$MAIN/.gaia/local/debt/count.json" ]

  # And nothing forked a per-tree copy beside it.
  if [ -f "$WT/.gaia/local/debt/count.json" ]; then
    printf 'forked a per-tree count cache at %s\n' "$WT/.gaia/local/debt/count.json" >&2
    return 1
  fi
}

@test "debt refresher with no resolver present degrades to its own root" {
  make_pair debt-count-refresh.sh --no-resolver
  stub_gh 3
  mkdir -p "$WT/.gaia/local/debt"
  touch "$WT/.gaia/local/debt/refresh-requested"

  PATH="$MAIN/bin:$PATH" run bash "$WT/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ]

  # No resolver to ask, so the local root is the honest answer rather than a
  # failure: the refresher still refreshes something.
  [ -f "$WT/.gaia/local/debt/count.json" ]
}

# ---------- check-updates.sh ----------

@test "update refresher run from a worktree writes the MAIN checkout's shared cache" {
  make_pair check-updates.sh

  PATH="$MAIN/bin:$PATH" run bash "$WT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]

  [ -f "$MAIN/.gaia/local/cache/shared/update-check.json" ]

  if [ -f "$WT/.gaia/local/cache/shared/update-check.json" ]; then
    printf 'forked a per-tree update cache at %s\n' "$WT/.gaia/local/cache/shared/update-check.json" >&2
    return 1
  fi
}

@test "update refresher counts the MAIN checkout's memory dir, not the worktree's" {
  make_pair check-updates.sh

  # The memory dir is machine-local state keyed by the tree's own path
  # spelling, so it is NOT covered by the .gaia/local symlink. Main's slug gets
  # three entries; the worktree's gets one, which is the realistic shape (a
  # freshly created worktree path has almost no memory history). A count of 1
  # here means the shared cache is stating a fact about the worktree, and the
  # audit nudge silently stops tracking the clone.
  main_slug="${MAIN//\//-}"
  wt_slug="${WT//\//-}"
  mkdir -p "$BATS_TEST_TMPDIR/home/.claude/projects/$main_slug/memory"
  mkdir -p "$BATS_TEST_TMPDIR/home/.claude/projects/$wt_slug/memory"
  touch "$BATS_TEST_TMPDIR/home/.claude/projects/$main_slug/memory/"{a,b,c}.md
  touch "$BATS_TEST_TMPDIR/home/.claude/projects/$wt_slug/memory/only.md"

  HOME="$BATS_TEST_TMPDIR/home" PATH="$MAIN/bin:$PATH" \
    run bash "$WT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]

  count="$(jq -r '.auditMemoryCount' "$MAIN/.gaia/local/cache/shared/update-check.json")"
  [ "$count" = "3" ]
}

@test "update refresher with no resolver present degrades to its own root" {
  make_pair check-updates.sh --no-resolver

  PATH="$MAIN/bin:$PATH" run bash "$WT/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ]

  [ -f "$WT/.gaia/local/cache/shared/update-check.json" ]
}
