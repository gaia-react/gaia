#!/usr/bin/env bash
# inject-probe-fixtures.sh: lay the Claude probe's instrumentation over a
# target-layout tree (a build-fixture-tree.sh output, a scratch clone of the
# finished branch, or a git worktree of either). Never point it at a checkout
# you work in: it rewrites settings files and adds files.
#
# Usage:
#   inject-probe-fixtures.sh <tree_root>
#   inject-probe-fixtures.sh --list-paths
#
# --list-paths prints every repo-relative path the injection may create or
# rewrite, one per line, so run-probe.sh can back them up before injecting and
# restore them afterwards. Keep that list and the writes below in step.
#
# What it lays down:
#   - probe hooks (SessionStart, InstructionsLoaded, PreToolUse, PostToolUse)
#     appended to each settings file, tagged with the file they live in, so a
#     probe line names its source: .claude/settings.json (root-settings),
#     .claude/settings.local.json (root-local), frontend/.claude/settings.json
#     (frontend-settings), frontend/.claude/settings.local.json
#     (frontend-local). A settings.json that is absent stays absent: creating
#     one would hide the defect the hook rows exist to find. The two .local
#     files are created when absent (they are untracked by design) and carry
#     enableAllProjectMcpServers so the MCP rows are not gated on an approval
#     prompt -p cannot show.
#   - a temporary root .mcp.json registering fixtures/mcp-probe-server.mjs.
#   - the claude-mechanics Q2 glob-anchor experiment rules (gaia-probe-a..d),
#     an unscoped frontend rule (gaia-probe-u) whose lazy load is the
#     root-launch "frontend rules load after a Read of frontend/CLAUDE.md"
#     observation, and a frontend agent (gaia-probe-agent) for the Q4 row.
#   - the permission-row targets when absent: root and frontend .env, the
#     audit markers, and a pnpm-lock.yaml stub.
#
# Re-running is idempotent: existing probe hook entries (any command naming
# claude-probe/probe-hooks/) are stripped before the fresh ones are appended.
set -euo pipefail

HARNESS_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROBE_HOOK_MARKER="claude-probe/probe-hooks/"

# tag<TAB>repo-relative settings path<TAB>create-when-absent
settings_targets() {
  printf '%s\t%s\t%s\n' \
    root-settings .claude/settings.json no \
    root-local .claude/settings.local.json yes \
    frontend-settings frontend/.claude/settings.json no \
    frontend-local frontend/.claude/settings.local.json yes
}

probe_files() {
  printf '%s\n' \
    .mcp.json \
    .claude/rules/gaia-probe-a.md \
    .claude/rules/gaia-probe-b.md \
    frontend/.claude/rules/gaia-probe-c.md \
    frontend/.claude/rules/gaia-probe-d.md \
    frontend/.claude/rules/gaia-probe-u.md \
    frontend/.claude/agents/gaia-probe-agent.md
}

permission_targets() {
  printf '%s\n' \
    .env \
    frontend/.env \
    pnpm-lock.yaml \
    .gaia/local/audit/x.ok \
    .gaia/local/audit/x.carried \
    .gaia/local/audit/x.refused
}

if [ "${1:-}" = "--list-paths" ]; then
  settings_targets | cut -f2
  probe_files
  permission_targets
  exit 0
fi

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: inject-probe-fixtures.sh <tree_root> | --list-paths" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

TREE_ROOT="$(cd "$1" && pwd -P)"
case "$HARNESS_DIRECTORY" in
  *\'*)
    # The hook commands single-quote this path; a quote inside it would break
    # out of the quoting.
    echo "ERROR: the harness path contains a single quote: $HARNESS_DIRECTORY" >&2
    exit 2
    ;;
esac

# Settings: strip earlier probe entries, then append one group per event.
# A group with no matcher matches every tool for the tool events.
probe_hook_groups() {
  local tag="$1"
  jq -n \
    --arg session "bash '$HARNESS_DIRECTORY/probe-hooks/session-start.sh' $tag" \
    --arg loaded "bash '$HARNESS_DIRECTORY/probe-hooks/instructions-loaded.sh' $tag" \
    --arg pre "bash '$HARNESS_DIRECTORY/probe-hooks/pre-tool-use.sh' $tag" \
    --arg post "bash '$HARNESS_DIRECTORY/probe-hooks/post-tool-use.sh' $tag" \
    '{
      SessionStart: [{hooks: [{type: "command", command: $session}]}],
      InstructionsLoaded: [{hooks: [{type: "command", command: $loaded}]}],
      PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $pre}]}],
      PostToolUse: [{matcher: "*", hooks: [{type: "command", command: $post}]}]
    }'
}

inject_settings() {
  local tag="$1" relative_path="$2" create_when_absent="$3"
  local settings_path="$TREE_ROOT/$relative_path"
  if [ ! -f "$settings_path" ]; then
    [ "$create_when_absent" = yes ] || return 0
    mkdir -p "$(dirname "$settings_path")"
    printf '{}\n' >"$settings_path"
  fi
  local groups updated
  groups="$(probe_hook_groups "$tag")"
  updated="$(jq --argjson groups "$groups" --arg marker "$PROBE_HOOK_MARKER" --arg local_file "$create_when_absent" '
    .hooks = ((.hooks // {})
      | with_entries(.value |= (map(.hooks |= map(select((.command // "") | contains($marker) | not)))
                               | map(select((.hooks | length) > 0)))))
    | reduce ($groups | to_entries[]) as $entry (.;
        .hooks[$entry.key] = ((.hooks[$entry.key] // []) + $entry.value))
    | if $local_file == "yes" then .enableAllProjectMcpServers = true else . end
  ' "$settings_path")"
  printf '%s\n' "$updated" >"$settings_path"
}

while IFS="$(printf '\t')" read -r tag relative_path create_when_absent; do
  inject_settings "$tag" "$relative_path" "$create_when_absent"
done < <(settings_targets)

# Temporary root .mcp.json, merged so an adopter-shaped tree keeps its own
# servers beside the probe one.
mcp_path="$TREE_ROOT/.mcp.json"
[ -f "$mcp_path" ] || printf '{}\n' >"$mcp_path"
mcp_updated="$(jq --arg server "$HARNESS_DIRECTORY/fixtures/mcp-probe-server.mjs" '
  .mcpServers = ((.mcpServers // {}) + {"gaia-probe": {type: "stdio", command: "node", args: [$server]}})
' "$mcp_path")"
printf '%s\n' "$mcp_updated" >"$mcp_path"

write_rule() {
  local relative_path="$1" globs="$2" body="$3"
  mkdir -p "$(dirname "$TREE_ROOT/$relative_path")"
  {
    if [ -n "$globs" ]; then
      printf -- '---\npaths:\n  - %s\n---\n\n' "$globs"
    fi
    printf '# Claude probe rule\n\n%s\n' "$body"
  } >"$TREE_ROOT/$relative_path"
}

# The Q2 glob-anchor experiment: the same target file, frontend/app/..., read
# from each launch dir, against four anchorings of the glob.
write_rule .claude/rules/gaia-probe-a.md "'frontend/app/**'" "Root rule, repo-root-anchored glob. Probe fixture; carries no instruction."
write_rule .claude/rules/gaia-probe-b.md "'**/app/**'" "Root rule, depth-agnostic glob. Probe fixture; carries no instruction."
write_rule frontend/.claude/rules/gaia-probe-c.md "'app/**'" "Frontend rule, package-relative glob. Probe fixture; carries no instruction."
write_rule frontend/.claude/rules/gaia-probe-d.md "'frontend/app/**'" "Frontend rule, repo-root-anchored glob. Probe fixture; carries no instruction."
write_rule frontend/.claude/rules/gaia-probe-u.md "" "Frontend rule with no paths. Probe fixture; carries no instruction."

mkdir -p "$TREE_ROOT/frontend/.claude/agents"
cat >"$TREE_ROOT/frontend/.claude/agents/gaia-probe-agent.md" <<'AGENT'
---
name: gaia-probe-agent
description: Claude probe fixture agent. Never dispatch it; it exists only so the probe can observe whether frontend/.claude/agents is listed.
---

Reply with the single word OK.
AGENT

# Permission-row targets. Existing files are left alone: in a real tree the
# lockfile is the real one.
while IFS= read -r relative_path; do
  target_path="$TREE_ROOT/$relative_path"
  [ -e "$target_path" ] && continue
  mkdir -p "$(dirname "$target_path")"
  printf 'PROBE=1\n' >"$target_path"
done < <(permission_targets)

exit 0
