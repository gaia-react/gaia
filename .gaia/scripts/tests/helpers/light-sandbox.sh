#!/usr/bin/env bash
# Shared bats sandbox for the light-review routing suites: a scratch repository
# carrying copies of this checkout's audit machinery (.gaia/scripts,
# .claude/hooks, .claude/agents, .github/audit, the roster and the version
# file) on `main`, an `origin` remote, and a feature branch, plus builders for
# clearances, route and mark runs, reviewer replies, loop state and the merge
# hook. Sourced from a suite's `setup()`:
#
#   # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
#   . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
#
# Everything lands under $BATS_TEST_TMPDIR; lsb_init refuses without it. No
# function here runs a git command against this checkout: the copies are
# plain file copies, and every git call names the sandbox.
#
# Variables set: LSB_ROOT (physical sandbox root, also its main checkout),
# LSB_ORIGIN, LSB_BRANCH, LSB_SLUG (the branch slug), LSB_HEAD and LSB_TREE
# (after any commit).
#
# `status` and `output` are bats' own, set by `run`, and the LSB_* and ALF_*
# variables set here are read by the suites and the loop fixture, none of which
# the linter can see from here. The jq programs are single-quoted so their `$`
# names reach jq.
# shellcheck disable=SC2154,SC2016,SC2034

LSB_REPO_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../../../.." && pwd)"
LSB_MEMBER_DEFAULT="code-audit-frontend"

# lsb_git <args...>: git in the sandbox with a fixed identity.
lsb_git() {
  git -C "$LSB_ROOT" -c user.email=gaia-test@example.com -c user.name="GAIA Test" -c commit.gpgsign=false "$@"
}

_lsb_set_head() {
  LSB_HEAD="$(lsb_git rev-parse HEAD)" || return 1
  LSB_TREE="$(lsb_git rev-parse 'HEAD^{tree}')" || return 1
}

# lsb_init [--maintainer]: build the sandbox; --maintainer also commits the
# maintainer-repo rule file the telemetry gate tests for.
lsb_init() {
  [ -n "${BATS_TEST_TMPDIR:-}" ] || { printf 'lsb_init: BATS_TEST_TMPDIR is unset\n' >&2; return 1; }
  local repository="$BATS_TEST_TMPDIR/lsb-repo" relative
  LSB_ORIGIN="$BATS_TEST_TMPDIR/lsb-origin.git"
  git init -q --bare -b main "$LSB_ORIGIN" || return 1
  git init -q -b main "$repository" || return 1
  LSB_ROOT="$(cd "$repository" && pwd -P)" || return 1
  mkdir -p "$LSB_ROOT/.gaia" "$LSB_ROOT/.claude" "$LSB_ROOT/.github" || return 1
  for relative in .gaia/scripts .claude/hooks .claude/agents .github/audit; do
    cp -R "$LSB_REPO_ROOT/$relative" "$LSB_ROOT/$relative" || return 1
  done
  # The bats suites and their fixtures are most of .gaia/scripts by file count
  # and nothing under test reads them; every digest walk and commit in the
  # sandbox pays for each file it carries.
  rm -rf "$LSB_ROOT/.gaia/scripts/tests"
  cp "$LSB_REPO_ROOT/.gaia/audit-ci.yml" "$LSB_ROOT/.gaia/audit-ci.yml" || return 1
  cp "$LSB_REPO_ROOT/.gaia/VERSION" "$LSB_ROOT/.gaia/VERSION" || return 1
  printf '.gaia/local/\n' >"$LSB_ROOT/.gitignore"
  mkdir -p "$LSB_ROOT/frontend/app"
  printf 'seed\n' >"$LSB_ROOT/frontend/app/seed.md"
  if [ "${1:-}" = "--maintainer" ]; then
    mkdir -p "$LSB_ROOT/.claude/rules/maintainers"
    printf '# maintainer repository marker\n' >"$LSB_ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  fi
  lsb_git add -A && lsb_git commit -q -m base || return 1
  lsb_git remote add origin "$LSB_ORIGIN" && lsb_git push -q origin main 2>/dev/null || return 1
  lsb_git fetch -q origin || return 1
  LSB_BRANCH="feat/light-sandbox"
  lsb_git checkout -q -b "$LSB_BRANCH" || return 1
  # shellcheck source=/dev/null
  LSB_SLUG="$(. "$LSB_ROOT/.gaia/scripts/audit-key-lib.sh" && gaia_branch_slug "$LSB_ROOT")" || return 1
  mkdir -p "$LSB_ROOT/.gaia/local/audit"
  # One commit on the branch, so a clearance written straight after lsb_init
  # sits on a branch commit: the merge-base itself is outside every walk range
  # and can never anchor.
  lsb_commit frontend/app/branch-start.md "branch start"
}

# lsb_strip_maintainer_only: remove every maintainer-only region from the
# sandbox's tracked files, the release-excluded telemetry script and the
# maintainer rule directory, as a release would, and commit the result. Call it
# before writing any clearance: it rewrites machinery files.
lsb_strip_maintainer_only() {
  # The marker name is assembled from two halves so this file never carries a
  # marker line of its own for a marker scanner to pair up.
  local file marker="gaia:""maintainer-only"
  while IFS= read -r -d '' file; do
    grep -q "$marker:start" "$LSB_ROOT/$file" 2>/dev/null || continue
    awk -v marker="$marker" '
      function opens(line) { return index(line, "# " marker ":start") || index(line, "<!-- " marker ":start -->") }
      function closes(line) { return index(line, "# " marker ":end") || index(line, "<!-- " marker ":end -->") }
      !inside && opens($0) && closes($0) { next }
      !inside && opens($0) { inside = 1; next }
      inside && closes($0) { inside = 0; next }
      !inside { print }
    ' "$LSB_ROOT/$file" >"$LSB_ROOT/$file.lsb" && cat "$LSB_ROOT/$file.lsb" >"$LSB_ROOT/$file" && rm -f "$LSB_ROOT/$file.lsb" || return 1
  done < <(lsb_git ls-files -z)
  rm -f "$LSB_ROOT/.gaia/scripts/audit-light-telemetry.sh"
  rm -rf "$LSB_ROOT/.claude/rules/maintainers"
  lsb_git add -A && lsb_git commit -q -m "strip maintainer-only" || return 1
  _lsb_set_head
}

# lsb_commit <path> <text>: write <text> as the whole file and commit it.
lsb_commit() {
  mkdir -p "$(dirname "$LSB_ROOT/$1")" || return 1
  printf '%s\n' "$2" >"$LSB_ROOT/$1" || return 1
  lsb_git add -- "$1" && lsb_git commit -q -m "change $1" || return 1
  _lsb_set_head
}

# lsb_commit_lines <path> <count> <tag>: replace the file with <count> lines
# `<tag> <i>` and commit it.
lsb_commit_lines() {
  local file_path="$LSB_ROOT/$1" line_number=1
  mkdir -p "$(dirname "$file_path")" || return 1
  : >"$file_path"
  while [ "$line_number" -le "$2" ]; do
    printf '%s %s\n' "$3" "$line_number" >>"$file_path"
    line_number=$((line_number + 1))
  done
  lsb_git add -- "$1" && lsb_git commit -q -m "lines $1" || return 1
  _lsb_set_head
}

# lsb_member_digest <member>: the member's digest at the sandbox HEAD.
lsb_member_digest() {
  bash "$LSB_ROOT/.gaia/scripts/audit-member-digest.sh" --root "$LSB_ROOT" --member "$1"
}

# lsb_full_clearance <member>: an earned `review: full` marker for HEAD,
# written by the sandbox's real clearance writer.
lsb_full_clearance() {
  local digest
  digest="$(lsb_member_digest "$1")" || return 1
  bash "$LSB_ROOT/.gaia/scripts/audit-write-clearance.sh" --root "$LSB_ROOT" --member "$1" \
    --provenance earned --scope-digest "$digest" >/dev/null
}

# lsb_marker_json <member> <provenance> <review-or-empty> <tree> <version> [digest]:
# hand-write a writer-shaped body into the marker store and print its path. For
# the legacy (empty review), stale-version and refusal fixtures only. The
# digest defaults to one derived from the other arguments, so two fixtures
# never share a file name; pass the current digest for a refusal keyed to it.
lsb_marker_json() {
  local member="$1" provenance="$2" review="$3" tree="$4" version="$5" digest="${6:-}" extension infix path
  if [ -z "$digest" ]; then
    digest="$(printf 'lsb:%s:%s:%s:%s:%s' "$member" "$provenance" "$review" "$tree" "$version" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{ print $1 }')"
  fi
  case "$provenance" in earned) extension="ok" ;; *) extension="refused" ;; esac
  infix=""
  [ "$member" = "$LSB_MEMBER_DEFAULT" ] || infix=".$member"
  path="$LSB_ROOT/.gaia/local/audit/$digest$infix.$extension"
  mkdir -p "$LSB_ROOT/.gaia/local/audit" || return 1
  jq -n -c --arg version "$version" --arg member "$member" --arg provenance "$provenance" \
    --arg digest "$digest" --arg tree "$tree" --arg review "$review" '
    {version: $version, schema: 4, member: $member, provenance: $provenance, digest: $digest,
     tree: $tree, sha: "", audited_at: "2026-01-01T00:00:00Z", sidecar: true}
    + (if $review == "" then {} else {review: $review} end)' >"$path" || return 1
  printf '%s\n' "$path"
}

# lsb_route <member> [--check]: run the sandbox's router through bats' `run`.
lsb_route() {
  if [ "${2:-}" = "--check" ]; then
    run bash "$LSB_ROOT/.gaia/scripts/audit-light-route.sh" --root "$LSB_ROOT" --member "$1" --check
  else
    run bash "$LSB_ROOT/.gaia/scripts/audit-light-route.sh" --root "$LSB_ROOT" --member "$1"
  fi
}

# lsb_mark <member> <reply-file-or-empty>: run the sandbox's light-marker
# script with the reply on stdin, or with empty stdin.
lsb_mark() {
  local reply_file="${2:-}"
  [ -n "$reply_file" ] || reply_file=/dev/null
  run bash -c 'bash "$1" --root "$2" --member "$3" --verdict - <"$4"' _ \
    "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$LSB_ROOT" "$1" "$reply_file"
}

_lsb_reply() {
  local member="$1" verdict="$2" digest record
  digest="$(lsb_member_digest "$member")" || return 1
  record="$LSB_ROOT/.gaia/local/audit/light/$digest.$member.route.json"
  [ -f "$record" ] || { printf 'lsb reply: no route record at %s\n' "$record" >&2; return 1; }
  jq -c --arg verdict "$verdict" '
    {schema: 1, member: .member, digest: .digest, tree: .tree, verdict: $verdict,
     reason: (if $verdict == "clear" then "delta reviewed, nothing found" else "needs the full member" end),
     files: [.files[] | {path: .path, verdict: $verdict, note: "reviewed"}]}' "$record"
}

# lsb_clear_reply <member> / lsb_escalate_reply <member>: a well-formed verdict
# built from the current route record.
lsb_clear_reply() {
  _lsb_reply "$1" clear
}

lsb_escalate_reply() {
  _lsb_reply "$1" escalate
}

# lsb_merge_payload <pr-number>: a PreToolUse Bash payload for
# `gh pr merge <pr-number>`, the shape the merge-gate suite builds.
lsb_merge_payload() {
  jq -n -c --arg command_line "gh pr merge $1 --squash --delete-branch" --arg cwd "$LSB_ROOT" \
    '{tool_name: "Bash", tool_input: {command: $command_line}, cwd: $cwd}'
}

# lsb_seed_loop_state <member>: one recorded audit-loop round for <member> at
# HEAD, standing in for the bound hook's record of the full round that earned
# the anchor.
lsb_seed_loop_state() {
  # shellcheck source=.gaia/tests/helpers/audit-loop-fixture.sh
  . "$LSB_REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh" || return 1
  ALF_ROOT="$LSB_ROOT"
  ALF_BRANCH="$LSB_BRANCH"
  ALF_NORMALIZED_BRANCH="${LSB_BRANCH#worktree-}"
  ALF_NORMALIZED_BRANCH="${ALF_NORMALIZED_BRANCH//+//}"
  ALF_SLUG="$(gaia_key_slug "$LSB_BRANCH")" || return 1
  ALF_STATE="$LSB_ROOT/.gaia/local/protected/audit-loop/$ALF_NORMALIZED_BRANCH.json"
  ALF_COMMIT="$(lsb_git rev-parse HEAD)" || return 1
  ALF_TREE="$(lsb_git rev-parse 'HEAD^{tree}')" || return 1
  [ -f "$ALF_STATE" ] || alf_seed_state '{}' || return 1
  alf_add_round "[\"$1\"]"
}

# lsb_run_merge_hook <pr-number>: run the sandbox's merge gate on that payload
# from the sandbox root, with a gh stub on PATH for this one run, through
# bats' `run`.
lsb_run_merge_hook() {
  local stub_directory="$BATS_TEST_TMPDIR/lsb-gh-bin"
  mkdir -p "$stub_directory" || return 1
  cat >"$stub_directory/gh" <<EOF
#!/usr/bin/env bash
pull_request_number="$1"
EOF
  cat >>"$stub_directory/gh" <<'EOF'
case "$*" in *isCrossRepository*) printf 'false\n'; exit 0 ;; esac
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) printf '{"title":"","baseRefName":"","number":"%s"}\n' "$pull_request_number"; exit 0 ;;
  issue) printf '[]\n'; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$stub_directory/gh"
  run env PATH="$stub_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ \
    "$LSB_ROOT" "$(lsb_merge_payload "$1")" "$LSB_ROOT/.claude/hooks/pr-merge-audit-check.sh"
}
