#!/usr/bin/env bash
# Provision the linked worktree a session is working in: re-link the shared
# state the registry declares, give the tree its port slot and port file,
# install the dependencies its own lockfiles commit, and regenerate the typed
# routes the worktree's own branch needs.
#
# Provisioning is a property a worktree must HOLD, not an event that happened
# once when it was created. A worktree whose symlinks were broken by hand, one
# made with plain `git worktree add` outside GAIA's own machinery, and one made
# before a newly-shared registry entry existed are all under-provisioned in the
# same way, and none of them is fixed by anything that runs at creation time.
# So this runs on entry instead, is idempotent, and repairs whatever it finds.
#
# Two triggers, because one entry path does not cover the other and each was
# measured rather than assumed:
#
#   SessionStart (startup|resume)   a session that STARTS inside a worktree,
#                                   including `claude --worktree` and any tree
#                                   opened directly.
#   PostToolUse  (EnterWorktree)    a RUNNING session that enters one. Entering
#                                   a worktree continues the session rather than
#                                   starting a new one, so SessionStart does not
#                                   fire for it, and this repository's own
#                                   instructions make EnterWorktree the way to
#                                   resume worktree work -- the common path, not
#                                   the exotic one. The PostToolUse payload is
#                                   emitted after the switch: its `cwd` is
#                                   already the worktree and its tool_response
#                                   names the path outright.
#
# Also callable directly with the worktree path as an argument, for a caller
# that already knows the tree and has no hook payload to synthesize. One
# definition, three callers: SessionStart, PostToolUse/EnterWorktree, and the
# direct call.
#
# The ports stage runs right after the linker and only for a linked worktree,
# so the main checkout pays nothing for it. In order: reclaim ledger entries
# whose tree is gone and retire the entry of a tree recreated at the same path
# (under the ledger lock); stop servers left by removed trees; stop servers
# recorded by ended Claude sessions, behind a stat-only gate; then keep or
# allocate this tree's slot and rewrite its port file from the ledger (under
# the lock again). The lock guards only the ledger, is never held across a
# signal or a wait, and a lock timeout keeps any existing port file and never
# blocks. Inert under GitHub Actions.
#
# Stdout carries what Claude should know and nothing else: one line per server
# stopped, then one context line naming the tree's ports and the ask-first rule.
# SessionStart and a direct call print plain lines; PostToolUse prints one JSON
# object whose additionalContext holds them. Every log stays on stderr, and a
# run with nothing to say prints nothing.
#
# Always exits 0. Provisioning repairs a worktree; failing to provision must
# never block the session that asked for one.
#
# DO NOT add `set -e`: the link step and the typegen step are independent and
# one failing must not skip the other.

log() {
  printf 'provision-worktree: %s\n' "$1" >&2
}

self_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# shellcheck disable=SC1091
source "$self_directory/../../.gaia/scripts/main-root-lib.sh" 2>/dev/null || exit 0

# ---------- which tree ----------
# An explicit argument wins (the direct-call form). Otherwise read the hook
# payload: tool_response.worktreePath is EnterWorktree's own statement of the
# tree it just switched into, and `cwd` is the payload-anchored identity
# several other hooks in this repository use. The process cwd is the last
# fallback.
tree="${1:-}"
payload=""
payload_event=""
if [ -z "$tree" ] && [ ! -t 0 ]; then
  payload="$(cat)"
  if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    tree="$(jq -r '.tool_response.worktreePath // .cwd // empty' <<<"$payload" 2>/dev/null)"
    payload_event="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null)"
  elif [ -n "$payload" ]; then
    # Without jq the flat fields are read with sed, the shape
    # workflow-doctrine-inject.sh uses.
    tree="$(printf '%s\n' "$payload" | sed -n 's/.*"worktreePath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p)"
    [ -n "$tree" ] || tree="$(printf '%s\n' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p)"
    payload_event="$(printf '%s\n' "$payload" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | sed -n 1p)"
  fi
fi
[ -n "$tree" ] || tree="$PWD"

# An absolute path is required before this value reaches `cd`, which would
# option-parse a leading dash and succeed into the wrong directory.
case "$tree" in
  /*) ;;
  *) exit 0 ;;
esac
[ -d "$tree" ] || exit 0

# Every ledger, marker and port-file call below keys on one physical tree
# root. A symlinked path would otherwise be recorded literally while the ports
# reclaim compares physical worktree paths, and a launch from <tree>/frontend
# would fail the .git marker read. A directory outside any work tree has
# nothing to provision.
tree="$(gaia_resolve_tree_root "$tree" 2>/dev/null)" || exit 0
[ -n "$tree" ] || exit 0

# ---------- carry forward per-tree ledger/report data under the tree key ----------
# The per-tree .gaia/local segments moved one path segment deeper, keyed by
# this tree's own gaia_tree_key, so multiple trees stop shadowing each other's
# data at one shared unkeyed path: red-ledger/observations.jsonl,
# worthiness-ledger/worthiness.jsonl, forensics/<file>.
# Every reader looks at the keyed path only -- this is the one place that
# migrates the old data, so anything left behind here is gone from its own
# reader's point of view.
#
# Runs for EVERY tree, main included, and runs BEFORE the linked-worktree
# gate below on purpose. The move shadows main's own unkeyed data exactly
# the way it shadows a worktree's, and nothing else runs at main's session
# start to rescue it. The gate below is unchanged by this: only the re-link
# and typegen steps after it stay worktree-only.

# carry_forward_file <local_subdirectory> <file>: moves the one old unkeyed file at
# .gaia/local/<local_subdirectory>/<file> to .gaia/local/<local_subdirectory>/<tree_key>/<file>, only when
# the old file exists and the keyed file does not, so a second run, or a
# keyed file a live session already wrote, is left untouched and unkeyed
# content never overwrites keyed content. Nothing to move is a silent
# no-op; a tree key that could not be resolved, or a move that fails, is
# not -- a stranded red-ledger or worthiness-ledger file is exactly the
# condition that silently blocks the next commit gate, so both are logged
# loudly enough to act on.
carry_forward_file() {
  local local_subdirectory="$1"
  local file="$2"
  local old="$tree/.gaia/local/$local_subdirectory/$file"
  [ -f "$old" ] || return 0
  if [ -z "$tree_key" ]; then
    log "CARRY-FORWARD FAILED: $local_subdirectory/$file has no resolvable tree key for $tree -- move it to $local_subdirectory/<tree-key>/$file by hand, or a stranded ledger will silently block the next commit gate"
    return 0
  fi
  local new_directory="$tree/.gaia/local/$local_subdirectory/$tree_key"
  local new="$new_directory/$file"
  [ -e "$new" ] && return 0
  if mkdir -p "$new_directory" 2>/dev/null && mv "$old" "$new" 2>/dev/null; then
    log "carried forward $local_subdirectory/$file -> $local_subdirectory/$tree_key/$file"
  else
    log "CARRY-FORWARD FAILED: $local_subdirectory/$file -> $local_subdirectory/$tree_key/$file -- move it by hand, or a stranded ledger will silently block the next commit gate"
  fi
}

# carry_forward_directory_contents <local_subdirectory>: the forensics/ shape --
# any number of loosely-named files sitting directly in the old unkeyed
# directory, never a subdirectory (which is how an already-migrated keyed
# subdir is left alone). Same existence and never-overwrite rules as
# carry_forward_file, applied file by file.
carry_forward_directory_contents() {
  local local_subdirectory="$1"
  local old_directory="$tree/.gaia/local/$local_subdirectory"
  [ -d "$old_directory" ] || return 0
  local file_path base new new_directory
  while IFS= read -r file_path; do
    base="$(basename "$file_path")"
    if [ -z "$tree_key" ]; then
      log "CARRY-FORWARD FAILED: $local_subdirectory/$base has no resolvable tree key for $tree -- move it to $local_subdirectory/<tree-key>/$base by hand, or a stranded ledger will silently block the next commit gate"
      continue
    fi
    new_directory="$tree/.gaia/local/$local_subdirectory/$tree_key"
    new="$new_directory/$base"
    [ -e "$new" ] && continue
    if mkdir -p "$new_directory" 2>/dev/null && mv "$file_path" "$new" 2>/dev/null; then
      log "carried forward $local_subdirectory/$base -> $local_subdirectory/$tree_key/$base"
    else
      log "CARRY-FORWARD FAILED: $local_subdirectory/$base -> $local_subdirectory/$tree_key/$base -- move it by hand, or a stranded ledger will silently block the next commit gate"
    fi
  done < <(find "$old_directory" -maxdepth 1 -type f 2>/dev/null)
}

# migrate_keyed_subtrees_to_main: the second half of the same migration, and
# the one the cutover itself forces.
#
# A linked worktree still holding a REAL .gaia/local is a tree that predates
# the single-symlink cutover. The linker's next act is to move that whole
# directory aside to .gaia/local.bak.<ts> and put one symlink in its place,
# and its contract is explicit that nothing under the backup is inspected or
# merged. So without this step the four per-tree entries -- including the ones
# the carry-forward above has just keyed correctly -- end up inside a backup
# nobody reads. A stranded RED observation is not a missing file: it silently
# BLOCKS a commit the gate should pass, which is precisely the failure the
# cutover's back-off condition names.
#
# So the keyed subtree moves to main's .gaia/local before the linker runs.
# It is safe to move rather than merge: the destination is keyed by THIS
# tree's key, so it cannot collide with the main checkout's own data or with
# any peer worktree's. A destination that already exists is left alone and
# said out loud rather than merged -- two sources for one tree's ledger is a
# state to be told about, not one to resolve by guessing.
#
# Self-retiring, exactly like the carry-forward above: the moment the linker
# has run once, .gaia/local is a symlink and the whole block is skipped.
migrate_keyed_subtrees_to_main() {
  [ -n "$tree_key" ] || return 0
  gaia_is_linked_worktree "$tree" || return 0

  local main_root
  main_root="$(gaia_resolve_main_root "$tree" 2>/dev/null)" || return 0
  [ -n "$main_root" ] || return 0
  [ "$main_root" = "$tree" ] && return 0

  local local_subdirectory source destination
  for local_subdirectory in red-ledger worthiness-ledger forensics; do
    source="$tree/.gaia/local/$local_subdirectory/$tree_key"
    [ -d "$source" ] || continue
    destination="$main_root/.gaia/local/$local_subdirectory/$tree_key"
    if [ -e "$destination" ]; then
      log "CUTOVER MIGRATION SKIPPED: $local_subdirectory/$tree_key exists in both this worktree and the main checkout -- merge them by hand; the worktree's copy is about to be moved aside to $tree/.gaia/local.bak.* and nothing reads it there"
      continue
    fi
    if mkdir -p "$main_root/.gaia/local/$local_subdirectory" 2>/dev/null && mv "$source" "$destination" 2>/dev/null; then
      log "migrated $local_subdirectory/$tree_key into $main_root/.gaia/local"
    else
      log "CUTOVER MIGRATION FAILED: $local_subdirectory/$tree_key -- move it into $main_root/.gaia/local/$local_subdirectory/ by hand, or a stranded ledger will silently block the next commit gate"
    fi
  done
}

# migrate_audit_artifacts_to_main: the same rescue for audit/, which is not
# tree-keyed. A Code Audit Team member dispatched into a worktree made with
# plain `git worktree add` writes its earned marker, findings sidecar, and
# scope file into the worktree's REAL .gaia/local/audit/. Left there, the
# linker's backup swallows them and the merge gate declines "marker absent"
# with nothing to say why, and the only recoveries are a full re-audit or a
# human moving writer-produced artifacts by hand.
#
# Moved file by file, top level only: that is where the clearance writer puts
# them, and every name is digest- or audit-key-scoped, so a name already in
# main is a collision to report, never one to overwrite or merge.
migrate_audit_artifacts_to_main() {
  local source_directory="$tree/.gaia/local/audit"
  [ -d "$source_directory" ] || return 0
  gaia_is_linked_worktree "$tree" || return 0

  local main_root
  main_root="$(gaia_resolve_main_root "$tree" 2>/dev/null)" || return 0
  [ -n "$main_root" ] || return 0
  [ "$main_root" = "$tree" ] && return 0

  local destination_directory="$main_root/.gaia/local/audit"
  local file_path base destination
  while IFS= read -r file_path; do
    base="$(basename "$file_path")"
    destination="$destination_directory/$base"
    if [ -e "$destination" ]; then
      log "AUDIT MIGRATION SKIPPED: audit/$base exists in both this worktree and the main checkout -- the worktree's copy is about to be moved aside to $tree/.gaia/local.bak.* and nothing reads it there"
      continue
    fi
    if mkdir -p "$destination_directory" 2>/dev/null && mv "$file_path" "$destination" 2>/dev/null; then
      log "migrated audit/$base into $main_root/.gaia/local"
    else
      log "AUDIT MIGRATION FAILED: audit/$base -- move it into $destination_directory/ by hand, or the merge gate will decline its marker as absent"
    fi
  done < <(find "$source_directory" -maxdepth 1 -type f 2>/dev/null)
}

# Skipped outright when .gaia/local is itself a symlink. Once the single-symlink
# cutover has run for this tree, the "old unkeyed path" a worktree sees through
# that symlink IS main's own data, and moving it under the WORKTREE's own key
# would steal main's ledger out from under it. Gating on the symlink keeps both
# steps correct on either side of the cutover, without this hook needing to know
# which state it is in.
if [ ! -L "$tree/.gaia/local" ]; then
  tree_key="$(gaia_tree_key "$tree" 2>/dev/null)" || tree_key=""
  carry_forward_file "red-ledger" "observations.jsonl"
  carry_forward_file "worthiness-ledger" "worthiness.jsonl"
  carry_forward_directory_contents "forensics"
  migrate_keyed_subtrees_to_main
  migrate_audit_artifacts_to_main
fi

# ---------- only a linked worktree is provisioned ----------
# gaia_is_linked_worktree is the one predicate for this question, so the main
# checkout costs a single resolver call and nothing else. It answers "no" for
# an indeterminate tree too, which is the right direction here: provisioning a
# tree whose identity is unknown could write symlinks into a checkout that
# owns its own state.
gaia_is_linked_worktree "$tree" || exit 0

# ---------- re-link the shared state ----------
# link-worktree.sh reads the shared set from the state registry and is
# idempotent per path, so a correct worktree is a no-op and a broken one is
# repaired. It derives the tree it acts on from its own process cwd, so it is
# invoked with cwd at the worktree, in a subshell that cannot disturb ours.
linker="$tree/.gaia/scripts/link-worktree.sh"
if [ -f "$linker" ]; then
  if (cd "$tree" && bash "$linker") 2>/dev/null; then
    log "linked shared state in $tree"
  else
    log "link step failed (non-fatal) for $tree"
  fi
else
  log "no linker found at $linker"
fi

# ---------- slot, port file, and stale servers ----------
# Every step below can fail without the others mattering, and several libraries
# answer a non-zero code for a normal "nothing to do" (a stale-entry retire with
# nothing stale, a reclaim that could not list worktrees), so each call is
# guarded and none can end the hook.
ports_report_lines=""
ports_context_line=""

# add_ports_report <text>: appends text, one report line per input line.
add_ports_report() {
  [ -n "$1" ] || return 0
  ports_report_lines="${ports_report_lines}${1}"$'\n'
}

provision_ports() {
  local state reclaimed slot_number reclaimed_slot reclaimed_tree report write_status

  state="$(gaia_ports_state_directory "$tree" 2>/dev/null)" || state=""
  if [ -z "$state" ]; then
    log "PORTS STATE UNRESOLVABLE (non-fatal) for $tree: the main checkout could not be found, so no port slot was assigned"
    return 0
  fi

  if gaia_ports_lock "$state"; then
    reclaimed="$(gaia_ports_reclaim "$state" "$tree")" || reclaimed=""
    while IFS=$'\t' read -r reclaimed_slot reclaimed_tree; do
      [ -n "$reclaimed_slot" ] || continue
      log "reclaimed port slot $reclaimed_slot from removed tree $reclaimed_tree"
    done <<<"$reclaimed"
    gaia_ports_retire_stale_entry "$state" "$tree" >/dev/null || true
    gaia_ports_unlock "$state"
  else
    log "PORTS LOCK TIMEOUT (non-fatal): kept the existing port file for $tree"
    return 0
  fi

  # A directory listing, not a process probe: a plain re-entry stays cheap.
  local tombstone_file
  for tombstone_file in "$state"/tombstones/*.tsv; do
    if [ -e "$tombstone_file" ]; then
      report="$(gaia_server_reap_tombstones "$state")" || report=""
      add_ports_report "$report"
      break
    fi
  done

  if gaia_server_cleanup_needed "$state"; then
    report="$(gaia_server_reap_dead_sessions "$state")" || report=""
    add_ports_report "$report"
  fi

  if gaia_ports_lock "$state"; then
    if slot_number="$(gaia_ports_assign_slot "$state" "$tree")" && [ -n "$slot_number" ]; then
      write_status=0
      gaia_ports_write_file "$tree" "$slot_number" || write_status=$?
      case "$write_status" in
        0) ;;
        3) log "PORT FILE SKIPPED (non-fatal) for $tree: no package carrying a react-router config was found" ;;
        *) log "PORT FILE WRITE FAILED (non-fatal) for $tree" ;;
      esac
    else
      log "PORT SLOTS EXHAUSTED or unassignable (non-fatal) for $tree: no port file was written"
    fi
    gaia_ports_unlock "$state"
  else
    log "PORTS LOCK TIMEOUT (non-fatal): kept the existing port file for $tree"
  fi
}

# build_ports_context_line: the tree's own port file is the source, so a kept
# file after a lock timeout still tells Claude the truth.
build_ports_context_line() {
  local port_file port_record slot_value storybook_value site_url_value
  port_file="$(gaia_ports_file_path "$tree" 2>/dev/null)" || return 0
  port_record="$(gaia_ports_read_file "$port_file" 2>/dev/null)" || return 0
  IFS=$'\t' read -r slot_value _ storybook_value site_url_value <<<"$port_record"
  ports_context_line="$(gaia_ports_context_line "$slot_value" "$site_url_value" "$storybook_value")"
}

# source_ports_libraries: both libraries, or neither. The process library must be
# defined before a slot is assigned, or the foreign-port skip silently turns off.
source_ports_libraries() {
  # shellcheck disable=SC1091
  source "$self_directory/../../.gaia/scripts/server-process-lib.sh" 2>/dev/null || return 1
  # shellcheck disable=SC1091
  source "$self_directory/../../.gaia/scripts/worktree-ports-lib.sh" 2>/dev/null || return 1
}

if [ -z "${GITHUB_ACTIONS:-}" ]; then
  if source_ports_libraries; then
    provision_ports
    build_ports_context_line
  else
    log "PORTS SKIPPED (non-fatal): .gaia/scripts/server-process-lib.sh or worktree-ports-lib.sh is missing, so $tree gets no port slot"
  fi
fi

# ---------- install the tree's own dependencies ----------
# Runs on EVERY entry, not only when node_modules is missing: a warm re-run
# costs a quarter of a second, and paying that every time is what keeps a tree
# whose branch moved package.json or pnpm-lock.yaml from silently resolving
# the dependency graph it had at last entry instead of the one its branch
# commits now.
#
# --frozen-lockfile is deliberate: a hook the user did not invoke must not
# rewrite a tracked file, and a plain `pnpm install` rewrites pnpm-lock.yaml
# when the manifest disagrees with it. This way the tree gets exactly the
# dependency graph its own branch committed. A disagreement between
# package.json and the lockfile is a state a human resolves deliberately, so
# it is refused out loud (logged below, non-fatal) rather than papered over.
#
# No lockfile means nothing declares a graph to install from, so the tree is
# left alone. A tree with a lockfile but no pnpm on PATH, or an install that
# fails, keeps whatever dependencies it already had; either way typegen below
# still runs.
install_workspace() {
  local workspace_directory="$1"
  [ -f "$workspace_directory/pnpm-lock.yaml" ] || return 0
  if command -v pnpm >/dev/null 2>&1; then
    if (cd "$workspace_directory" && pnpm install --frozen-lockfile) >/dev/null 2>&1; then
      log "installed dependencies in $workspace_directory"
    else
      log "INSTALL FAILED for $workspace_directory (non-fatal): the tree keeps whatever dependencies it already had -- run 'pnpm install' there to see why; a package.json/pnpm-lock.yaml disagreement is refused here by design"
    fi
  else
    log "no pnpm found on PATH -- dependency install skipped for $workspace_directory"
  fi
}

install_workspace "$tree"
# .gaia/cli declares its own pnpm workspace root, so the install above never
# populates its node_modules, and anything resolving a CLI dependency from
# there fails in a fresh worktree while passing in the main checkout. Where
# that directory carries no lockfile of its own the call is a no-op.
install_workspace "$tree/.gaia/cli"

# ---------- regenerate the typed routes ----------
# `.react-router/types` is gitignored, so it exists only where it was generated
# and a worktree never receives it. Without it every app file importing
# `./+types/*` resolves to `error` typed values and a lint run inside the
# worktree reports unsafe-assignment errors against code its branch never
# touched.
#
# Generate rather than share main's copy: the types derive from the worktree's
# OWN route files, so main's would hand a branch that adds or renames a route a
# silently wrong answer in place of a loud one. Regenerating on every entry is
# what keeps them current rather than merely present, which is the property a
# create-time run cannot hold once the branch moves.
#
# Typegen runs once per registered package that carries a react-router config,
# from that package's own directory, since the app's routes and its installed
# CLI live there and not at the repository root.
#
# Prefer the package's OWN installed CLI: the install step above is what gives
# the tree its own `node_modules`, and once it exists that is the copy whose
# resolution matches the app's own imports. Borrowing the main checkout's copy
# of the same package is the fallback for a tree where the install above could
# not run (no lockfile, no pnpm on PATH, or the install itself failed). A CLI
# at the repository root is deliberately never tried: a package that resolves
# nothing of its own is reported FAILED, not silently run from the wrong cwd.
# shellcheck disable=SC1091
if ! source "$self_directory/lib/gaia-packages.sh" 2>/dev/null; then
  log "TYPEGEN FAILED (non-fatal): .claude/hooks/lib/gaia-packages.sh is missing, so the packages to generate routes for are unknown"
else
  packages_status=0
  gaia_packages_load "$tree" || packages_status=$?
  if [ "$packages_status" -ne 0 ]; then
    log "TYPEGEN FAILED (non-fatal): $GAIA_PACKAGES_ERROR"
  else
    main_root="$(gaia_resolve_main_root "$tree" 2>/dev/null)" || main_root=""
    while IFS=$'\t' read -r package_name package_path; do
      [ -n "$package_name" ] || continue
      if [ "$package_path" = "." ]; then
        package_prefix=""
      else
        package_prefix="$package_path/"
      fi
      package_directory="${tree}/${package_prefix%/}"
      has_router_config=0
      for router_config in "$package_directory"/react-router.config.*; do
        [ -e "$router_config" ] && has_router_config=1
      done
      [ "$has_router_config" -eq 1 ] || continue

      cli="$tree/${package_prefix}node_modules/.bin/react-router"
      if [ ! -x "$cli" ] && [ -n "$main_root" ]; then
        cli="$main_root/${package_prefix}node_modules/.bin/react-router"
      fi
      if [ ! -x "$cli" ]; then
        log "TYPEGEN FAILED (non-fatal) for package $package_name: no react-router CLI at ${package_prefix}node_modules/.bin in $tree or the main checkout -- run 'pnpm install' there"
      elif (cd "$package_directory" && "$cli" typegen) >/dev/null; then
        log "generated typed routes for package $package_name in $package_directory"
      else
        log "TYPEGEN FAILED (non-fatal) for package $package_name in $package_directory"
      fi
    done <<<"$(gaia_packages_list)"
  fi
fi

# ---------- tell Claude ----------
# json_escape <text>: the JSON string body for text, for a run without jq.
json_escape() {
  local text="$1" backslash=$'\\' quote='"' newline=$'\n' tab=$'\t'
  text="${text//$backslash/$backslash$backslash}"
  text="${text//$quote/$backslash$quote}"
  text="${text//$newline/${backslash}n}"
  text="${text//$tab/${backslash}t}"
  printf '%s' "$text"
}

emit_ports_output() {
  local output_text="$ports_report_lines"
  [ -n "$ports_context_line" ] && output_text="${output_text}${ports_context_line}"$'\n'
  [ -n "$output_text" ] || return 0
  output_text="${output_text%$'\n'}"
  if [ "$payload_event" = "PostToolUse" ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg context "$output_text" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}'
    else
      printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(json_escape "$output_text")"
    fi
  else
    printf '%s\n' "$output_text"
  fi
}

emit_ports_output
exit 0
