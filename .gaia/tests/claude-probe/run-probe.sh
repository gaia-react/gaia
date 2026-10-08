#!/usr/bin/env bash
# run-probe.sh: run the Claude probe (SPEC-092 Phase 0, UAT-001) against a
# target-layout tree and judge it against the committed expectation table.
#
# Usage:
#   run-probe.sh --target <repo_root> --evidence <dir> --max-usd <n>
#                [--reps <n>] [--only <row-id-glob>] [--table-repo <dir>]
#                [--model <model>] [--launches root,frontend,worktree]
#
# Spends tokens and needs Claude auth: a maintainer runs it by hand. The
# target is rewritten while the probe runs (probe hooks in its settings, a
# temporary .mcp.json, probe rules, scripted commits that are rolled back),
# so it must be a scratch tree: a build-fixture-tree.sh output or a scratch
# clone of the branch. It refuses this checkout and any worktree sharing its
# git directory. Files the injection touched are restored on exit.
#
# Exit 0: the comparator found every observation in every repetition matching
# and nothing unlisted. Exit 1: the comparator's verdict was a mismatch.
# Exit 2: refused to start (missing flag, dirty or untracked table, unsafe
# target, non-empty evidence dir). Exit 3: stopped before the comparator,
# because cumulative total_cost_usd passed --max-usd or a stream's cost could
# not be read.
#
# Ordering contract (COV-007): the table must be committed before the first
# run. The script refuses a dirty or untracked expectations.json in the table
# repo, and records expectations_commit and table_sha256 in meta.json before
# its first Claude call.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TABLE_RELATIVE_PATH=".gaia/tests/claude-probe/expectations.json"
CLAUDE_BIN="${GAIA_PROBE_CLAUDE_BIN:-claude}"

usage() {
  echo "usage: run-probe.sh --target <repo_root> --evidence <dir> --max-usd <n> [--reps <n>] [--only <row-id-glob>] [--table-repo <dir>] [--model <model>] [--launches root,frontend,worktree]" >&2
}

refuse() {
  echo "ERROR: $*" >&2
  exit 2
}

TARGET=""
EVIDENCE=""
REPS=3
MAX_USD=""
ONLY=""
TABLE_REPO=""
MODEL="sonnet"
LAUNCHES="root,frontend,worktree"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target | --evidence | --reps | --max-usd | --only | --table-repo | --model | --launches)
      [ "$#" -ge 2 ] || { usage; refuse "$1 needs a value"; }
      case "$1" in
        --target) TARGET="$2" ;;
        --evidence) EVIDENCE="$2" ;;
        --reps) REPS="$2" ;;
        --max-usd) MAX_USD="$2" ;;
        --only) ONLY="$2" ;;
        --table-repo) TABLE_REPO="$2" ;;
        --model) MODEL="$2" ;;
        --launches) LAUNCHES="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      refuse "unknown argument: $1"
      ;;
  esac
done

[ -n "$MAX_USD" ] || { usage; refuse "--max-usd is required: the probe spends tokens and never runs without a cost cap"; }
decimal_pattern='^[0-9]+(\.[0-9]+)?$'
count_pattern='^[1-9][0-9]*$'
[[ $MAX_USD =~ $decimal_pattern ]] || refuse "--max-usd must be a positive number, got: $MAX_USD"
awk -v cap="$MAX_USD" 'BEGIN { exit !(cap > 0) }' || refuse "--max-usd must be greater than zero"
[ -n "$TARGET" ] || { usage; refuse "--target is required"; }
[ -n "$EVIDENCE" ] || { usage; refuse "--evidence is required"; }
[[ $REPS =~ $count_pattern ]] || refuse "--reps must be a positive integer, got: $REPS"
for required_tool in git jq node awk; do
  command -v "$required_tool" >/dev/null 2>&1 || refuse "$required_tool is required"
done
case ",$LAUNCHES," in
  *[!a-z,]* | ,,) refuse "--launches takes a comma list of root, frontend, worktree" ;;
esac

# The table must be committed, and unchanged since, before any run.
[ -n "$TABLE_REPO" ] || TABLE_REPO="$SCRIPT_DIRECTORY"
TABLE_REPO="$(git -C "$TABLE_REPO" rev-parse --show-toplevel 2>/dev/null)" || refuse "--table-repo is not inside a git repository"
TABLE_PATH="$TABLE_REPO/$TABLE_RELATIVE_PATH"
[ -f "$TABLE_PATH" ] || refuse "$TABLE_RELATIVE_PATH does not exist in $TABLE_REPO"
table_status="$(git -C "$TABLE_REPO" status --porcelain --untracked-files=all -- "$TABLE_RELATIVE_PATH")"
if [ -n "$table_status" ]; then
  refuse "$TABLE_RELATIVE_PATH is dirty or untracked in $TABLE_REPO; commit the expectation table before the probe run (a table edit after the first run must cite the run that justified it)"
fi
EXPECTATIONS_COMMIT="$(git -C "$TABLE_REPO" log -1 --format=%H -- "$TABLE_RELATIVE_PATH")"
[ -n "$EXPECTATIONS_COMMIT" ] || refuse "$TABLE_RELATIVE_PATH has no commit in $TABLE_REPO"

# The target is rewritten while the probe runs, so it must not share a git
# directory with the table repo (this checkout or any of its worktrees).
[ -d "$TARGET" ] || refuse "--target $TARGET is not a directory"
TARGET="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)" || refuse "--target is not inside a git repository"
TARGET="$(cd "$TARGET" && pwd -P)"
target_common="$(cd "$TARGET" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
table_common="$(cd "$TABLE_REPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
harness_common="$(cd "$SCRIPT_DIRECTORY" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
if [ "$target_common" = "$table_common" ] || [ "$target_common" = "$harness_common" ]; then
  refuse "--target shares a git directory with the table repo or this harness's checkout; probe a build-fixture-tree.sh output or a scratch clone instead"
fi
[ -d "$TARGET/frontend" ] || refuse "--target has no frontend/ directory; it is not a target-layout tree"

# The floor (SPEC-092 Phase 0 step 3) and the root deny set must be covered
# before a token is spent; a table missing a floor row cannot pass UAT-001.
if ! table_check_output="$(node "$SCRIPT_DIRECTORY/compare.mjs" --check-table "$TABLE_PATH" --root-settings "$TARGET/.claude/settings.json" 2>&1)"; then
  refuse "the expectation table failed its check:
$table_check_output"
fi

if [ -e "$EVIDENCE" ] && [ -n "$(ls -A "$EVIDENCE" 2>/dev/null)" ]; then
  refuse "--evidence $EVIDENCE is not empty; each run writes a fresh evidence dir"
fi
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"

printf '%s\n' "$table_check_output" >"$EVIDENCE/table-check.txt"
TABLE_SHA256="$(node -e 'const {createHash}=require("node:crypto");process.stdout.write(createHash("sha256").update(require("node:fs").readFileSync(process.argv[1])).digest("hex"))' "$TABLE_PATH")"
jq -n \
  --arg expectations_commit "$EXPECTATIONS_COMMIT" \
  --arg table_sha256 "$TABLE_SHA256" \
  --arg table_repo "$TABLE_REPO" \
  --arg target "$TARGET" \
  --argjson reps "$REPS" \
  --arg max_usd "$MAX_USD" \
  --arg model "$MODEL" \
  --arg launches "$LAUNCHES" \
  --arg only "$ONLY" \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{expectations_commit: $expectations_commit, table_sha256: $table_sha256, table_repo: $table_repo,
    target: $target, reps: $reps, max_usd: ($max_usd | tonumber), model: $model,
    launches: ($launches | split(",")), only: (if $only == "" then null else $only end),
    started_at: $started_at}' >"$EVIDENCE/meta.json"

compare_only_arguments=()
[ -z "$ONLY" ] || compare_only_arguments=(--only "$ONLY")
PLAN="$(node "$SCRIPT_DIRECTORY/compare.mjs" --plan "$TABLE_PATH" ${compare_only_arguments[@]+"${compare_only_arguments[@]}"})" \
  || refuse "the expectation table failed its schema check (compare.mjs --plan)"
[ -n "$PLAN" ] || refuse "no rows selected (--only ${ONLY:-<none>})"

WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/claude-probe.XXXXXX")"
BACKUP_DIRECTORY="$WORK_DIRECTORY/backup"
WORKTREE_ROOT=""
# The commit scenarios run on this branch, never on the target's own: GAIA's
# commit-to-main PreToolUse guard denies a commit on main before git runs, so
# a target left on main would observe that guard instead of pre-commit and
# the RED gate. ORIGINAL_REFERENCE is what the exit trap switches back to.
PROBE_BRANCH="probe/run"
ORIGINAL_REFERENCE=""
CREATED_FILES_LIST="$WORK_DIRECTORY/created-files"
: >"$CREATED_FILES_LIST"
mkdir -p "$BACKUP_DIRECTORY"

# Back up every path the injection may touch, so the exit trap can put the
# target back however the run ends (comparator verdict, cost cap, error).
while IFS= read -r relative_path; do
  if [ -e "$TARGET/$relative_path" ]; then
    mkdir -p "$(dirname "$BACKUP_DIRECTORY/present/$relative_path")"
    cp -p "$TARGET/$relative_path" "$BACKUP_DIRECTORY/present/$relative_path"
  else
    printf '%s\n' "$relative_path" >>"$BACKUP_DIRECTORY/absent"
  fi
done < <(bash "$SCRIPT_DIRECTORY/inject-probe-fixtures.sh" --list-paths)

# shellcheck disable=SC2329 # invoked through the EXIT trap
restore_target() {
  local relative_path commit_root commit_head
  # A run stopped mid-commit-scenario (cost cap, error) still rolls the
  # scripted commits back before the probe's files are removed.
  if [ -f "$WORK_DIRECTORY/commit-in-flight" ]; then
    IFS="$(printf '\t')" read -r commit_root commit_head <"$WORK_DIRECTORY/commit-in-flight"
    git -C "$commit_root" reset --quiet --soft "$commit_head" 2>/dev/null || true
    # shellcheck disable=SC2086
    git -C "$commit_root" reset --quiet -- $COMMIT_A_PATHS $COMMIT_B_PATHS 2>/dev/null || true
  fi
  while IFS= read -r relative_path; do
    [ -n "$relative_path" ] && rm -f "$TARGET/$relative_path"
  done <"$CREATED_FILES_LIST"
  if [ -f "$BACKUP_DIRECTORY/absent" ]; then
    while IFS= read -r relative_path; do
      rm -f "$TARGET/$relative_path"
    done <"$BACKUP_DIRECTORY/absent"
  fi
  if [ -d "$BACKUP_DIRECTORY/present" ]; then
    (cd "$BACKUP_DIRECTORY/present" && find . -type f -print) | while IFS= read -r relative_path; do
      relative_path="${relative_path#./}"
      mkdir -p "$(dirname "$TARGET/$relative_path")"
      cp -p "$BACKUP_DIRECTORY/present/$relative_path" "$TARGET/$relative_path"
    done
  fi
  # Back to the branch (or detached commit) the target started on. The probe
  # branch sits at the same commit once the scripted commits are rolled back,
  # so the switch carries no content change.
  if [ -n "$ORIGINAL_REFERENCE" ]; then
    case "$ORIGINAL_REFERENCE" in
      branch:*) git -C "$TARGET" checkout --quiet "${ORIGINAL_REFERENCE#branch:}" 2>/dev/null || true ;;
      detached:*) git -C "$TARGET" checkout --quiet --detach "${ORIGINAL_REFERENCE#detached:}" 2>/dev/null || true ;;
    esac
    git -C "$TARGET" branch --quiet -D "$PROBE_BRANCH" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORKTREE_ROOT" ]; then
    git -C "$TARGET" worktree remove --force "$WORKTREE_ROOT" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIRECTORY"
}
trap restore_target EXIT

bash "$SCRIPT_DIRECTORY/inject-probe-fixtures.sh" "$TARGET"
if awk -F '\t' '$2 == "after_task:commit" { found = 1 } END { exit !found }' <<<"$PLAN"; then
  original_branch="$(git -C "$TARGET" symbolic-ref --quiet --short HEAD 2>/dev/null)" || original_branch=""
  if [ "$original_branch" != "$PROBE_BRANCH" ]; then
    if [ -n "$original_branch" ]; then
      ORIGINAL_REFERENCE="branch:$original_branch"
    else
      ORIGINAL_REFERENCE="detached:$(git -C "$TARGET" rev-parse HEAD)"
    fi
    # Same commit, so the injected (uncommitted) files carry over untouched.
    git -C "$TARGET" checkout --quiet -B "$PROBE_BRANCH"
  fi
fi
case ",$LAUNCHES," in
  *,worktree,*)
    WORKTREE_ROOT="$WORK_DIRECTORY/worktree"
    git -C "$TARGET" worktree add --quiet --detach "$WORKTREE_ROOT" HEAD
    WORKTREE_ROOT="$(cd "$WORKTREE_ROOT" && pwd -P)"
    bash "$SCRIPT_DIRECTORY/inject-probe-fixtures.sh" "$WORKTREE_ROOT"
    ;;
esac

launch_root() {
  case "$1" in
    worktree) printf '%s' "$WORKTREE_ROOT" ;;
    *) printf '%s' "$TARGET" ;;
  esac
}
launch_directory() {
  case "$1" in
    frontend) printf '%s/frontend' "$TARGET" ;;
    worktree) printf '%s' "$WORKTREE_ROOT" ;;
    *) printf '%s' "$TARGET" ;;
  esac
}

# Snapshot what the comparator expands rows against: the file list of each
# launch's tree and the settings, MCP, rule, command and skill files as they
# stood for the run (the model-invocation expand suffixes read frontmatter).
snapshot_launch() {
  local launch="$1" root snapshot relative_path
  root="$(launch_root "$launch")"
  snapshot="$EVIDENCE/snapshot/$launch"
  mkdir -p "$snapshot/files"
  git -C "$root" ls-files -z --cached --others --exclude-standard | tr '\0' '\n' >"$snapshot/tree.txt"
  {
    printf '%s\n' .claude/settings.json .claude/settings.local.json frontend/.claude/settings.json frontend/.claude/settings.local.json .mcp.json
    grep -E '(^|/)\.claude/(rules/.+|commands/.+|skills/[^/]+/SKILL)\.md$' "$snapshot/tree.txt" || true
  } | while IFS= read -r relative_path; do
    [ -f "$root/$relative_path" ] || continue
    mkdir -p "$(dirname "$snapshot/files/$relative_path")"
    cp -p "$root/$relative_path" "$snapshot/files/$relative_path"
  done
}
for launch in root frontend worktree; do
  case ",$LAUNCHES," in *,"$launch",*) snapshot_launch "$launch" ;; esac
done

# Claude Code writes the session transcript, the only reliable record of the
# skill listing the model saw, under its config dir. Copy it beside the stream
# when exactly one file carries the session id; with none or several the copy
# is skipped and the observer reports the missing transcript. Never fails the
# run.
copy_transcript() {
  local scenario_directory="$1" turn="$2" session_id candidate
  local matches=()
  session_id="$(jq -rs '[.[] | select(.type == "system" and .subtype == "init") | .session_id][0] // empty' "$scenario_directory/stream-$turn.jsonl" 2>/dev/null)" || return 0
  [ -n "$session_id" ] || return 0
  for candidate in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$session_id".jsonl; do
    [ -f "$candidate" ] && matches+=("$candidate")
  done
  [ "${#matches[@]}" -eq 1 ] || return 0
  cp "${matches[0]}" "$scenario_directory/transcript-$turn.jsonl" 2>/dev/null || true
  return 0
}

SPENT_USD=0
stream_cost() {
  jq -s '[.[] | select(.type == "result") | (.total_cost_usd // 0)] | add // 0' "$1" 2>/dev/null
}

# One `claude -p` turn. Observations come from the probe-hook log and the
# stream's structured events; the assistant's text is never read.
run_claude() {
  local launch="$1" scenario_directory="$2" turn="$3" prompt="$4"
  shift 4
  local remaining cost
  remaining="$(awk -v cap="$MAX_USD" -v spent="$SPENT_USD" 'BEGIN { printf "%.4f", cap - spent }')"
  if ! awk -v remaining="$remaining" 'BEGIN { exit !(remaining > 0) }'; then
    echo "ERROR: cost cap reached: spent \$$SPENT_USD of --max-usd \$$MAX_USD; stopping before the comparator" >&2
    exit 3
  fi
  local trace_arguments=()
  [ "$(jq -r '.trigger' "$scenario_directory/scenario.json")" != "after_task:commit" ] \
    || trace_arguments=("GIT_TRACE2_EVENT=$scenario_directory/trace2.jsonl")
  (
    cd "$(launch_directory "$launch")"
    exec env -u CLAUDE_PROJECT_DIR -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT \
      GAIA_PROBE_LOG="$scenario_directory/probe.jsonl" ${trace_arguments[@]+"${trace_arguments[@]}"} \
      "$CLAUDE_BIN" -p "$prompt" --output-format stream-json --verbose --include-hook-events \
      --model "$MODEL" --permission-mode acceptEdits --max-budget-usd "$remaining" "$@"
  ) >"$scenario_directory/stream-$turn.jsonl" 2>"$scenario_directory/stderr-$turn.log" </dev/null || true
  copy_transcript "$scenario_directory" "$turn"
  if ! cost="$(stream_cost "$scenario_directory/stream-$turn.jsonl")" || [ -z "$cost" ] || [ "$cost" = null ]; then
    echo "ERROR: cannot read total_cost_usd from $scenario_directory/stream-$turn.jsonl; stopping before the comparator (cost cannot be capped blind)" >&2
    exit 3
  fi
  SPENT_USD="$(awk -v spent="$SPENT_USD" -v cost="$cost" 'BEGIN { printf "%.6f", spent + cost }')"
  printf '%s\n' "$SPENT_USD" >"$EVIDENCE/spent-usd"
  if awk -v spent="$SPENT_USD" -v cap="$MAX_USD" 'BEGIN { exit !(spent > cap) }'; then
    echo "ERROR: cost cap exceeded: cumulative total_cost_usd \$$SPENT_USD > --max-usd \$$MAX_USD; stopping before the comparator" >&2
    exit 3
  fi
}

ONE_WORD="Reply with the single word OK. Do not use any tools."
COMPONENT_PATH="frontend/app/components/probe-x/index.tsx"
COMMIT_A_PATHS="frontend/app/components/probe-commit/index.tsx"
COMMIT_B_PATHS="frontend/app/utils/probeSum.ts frontend/app/utils/probeSum.test.ts"

table_subjects() {
  jq -r --arg launch "$1" --arg trigger "$2" --arg kind "$3" \
    '.rows[] | select(.launch == $launch and .trigger == $trigger and .kind == $kind) | .subject' "$TABLE_PATH" | sort -u
}

# The generated frontend settings file is the one Edit target that must stay
# in place: a frontend launch reads its own deny from it, so holding it aside
# would remove the rule under test. Its Edit uses a real old_string instead of
# the create-a-file form, and the file is copied aside and put back after.
LIVE_PERMISSION_TARGET="frontend/.claude/settings.json"

numbered_calls() {
  local root="$1" launch="$2" trigger="$3" index=0 tool relative_path
  while IFS=' ' read -r tool relative_path; do
    [ -n "$tool" ] || continue
    index=$((index + 1))
    case "$tool" in
      Read) printf '%s. Use the Read tool on %s\n' "$index" "$root/$relative_path" ;;
      Edit)
        if [ "$relative_path" = "$LIVE_PERMISSION_TARGET" ]; then
          printf '%s. Use the Edit tool on %s with old_string set to permissions and new_string set to permissionz\n' "$index" "$root/$relative_path"
        else
          printf '%s. Use the Edit tool on %s with old_string set to the empty string and new_string set to PROBE=2 (this creates the file)\n' "$index" "$root/$relative_path"
        fi
        ;;
    esac
  done < <(table_subjects "$launch" "$trigger" permission)
}

record_files_after() {
  local root="$1" scenario_directory="$2"
  shift 2
  local relative_path json='{}'
  for relative_path in "$@"; do
    if [ -f "$root/$relative_path" ]; then
      json="$(jq --arg path "$relative_path" '.[$path] = true' <<<"$json")"
    else
      json="$(jq --arg path "$relative_path" '.[$path] = false' <<<"$json")"
    fi
  done
  printf '%s\n' "$json" >"$scenario_directory/files-after.json"
}

run_scenario() {
  local rep="$1" launch="$2" trigger="$3" slug="$4" needs_listing="$5"
  local scenario_directory="$EVIDENCE/rep-$rep/$launch/$slug"
  local root
  root="$(launch_root "$launch")"
  if [ -z "$root" ]; then
    echo "WARN: launch $launch not enabled (--launches $LAUNCHES); skipping $trigger" >&2
    return 0
  fi
  mkdir -p "$scenario_directory"
  # commit_paths lets the comparator tie a RED-gate deny reason, which names
  # the offending staged files, to the scripted commit it blocked.
  jq -n --arg launch "$launch" --arg trigger "$trigger" --arg root "$root" --arg directory "$(launch_directory "$launch")" \
    --arg commit_a "$COMMIT_A_PATHS" --arg commit_b "$COMMIT_B_PATHS" \
    '{launch: $launch, trigger: $trigger, launch_root: $root, launch_directory: $directory}
     + (if $trigger == "after_task:commit"
        then {commit_paths: {a: ($commit_a | split(" ")), b: ($commit_b | split(" "))}} else {} end)' >"$scenario_directory/scenario.json"
  : >"$scenario_directory/probe.jsonl"
  echo "--> rep $rep: $launch $trigger" >&2

  case "$trigger" in
    session_start)
      run_claude "$launch" "$scenario_directory" 1 "$ONE_WORD"
      ;;
    after_read:*)
      local read_path="${trigger#after_read:}"
      run_claude "$launch" "$scenario_directory" 1 \
        "Use the Read tool exactly once to read the file $root/$read_path. Do not use any other tool. Then reply with the single word OK."
      if [ "$needs_listing" = 1 ]; then
        # The listing turn runs only after a PostToolUse line proves the Read
        # happened; otherwise the comparator records read_not_verified.
        if jq -e --arg path "$root/$read_path" 'select(.event == "PostToolUse" and .tool_name == "Read" and .file_path == $path)' \
          "$scenario_directory/probe.jsonl" >/dev/null 2>&1; then
          local session_id
          session_id="$(jq -rs '[.[] | select(.type == "system" and .subtype == "init") | .session_id][0] // empty' "$scenario_directory/stream-1.jsonl" 2>/dev/null)" || session_id=""
          [ -z "$session_id" ] || run_claude "$launch" "$scenario_directory" 2 "$ONE_WORD" --resume "$session_id"
        fi
      fi
      ;;
    after_task:component-write)
      rm -f "$root/$COMPONENT_PATH"
      printf '%s\n' "$COMPONENT_PATH" >>"$CREATED_FILES_LIST"
      run_claude "$launch" "$scenario_directory" 1 \
        "Use the Write tool exactly once to create the file $root/$COMPONENT_PATH with exactly this content: export const ProbeX = () => <div>probe</div>; Do not read any file first and do not use any other tool. Then reply with the single word DONE."
      record_files_after "$root" "$scenario_directory" "$COMPONENT_PATH"
      rm -f "$root/$COMPONENT_PATH"
      rmdir "$(dirname "$root/$COMPONENT_PATH")" 2>/dev/null || true
      ;;
    after_task:permissions-read | after_task:permissions-edit)
      local hold_directory="$WORK_DIRECTORY/hold-$rep-$launch" relative_path tool calls
      calls="$(numbered_calls "$root" "$launch" "$trigger")"
      if [ "$trigger" = after_task:permissions-edit ]; then
        # Edit with an empty old_string creates a file, which passes the
        # Edit tool's own input validation so the permission layer decides.
        # That needs every target absent, so each is held aside meanwhile.
        mkdir -p "$hold_directory"
        while IFS=' ' read -r tool relative_path; do
          [ -e "$root/$relative_path" ] || continue
          mkdir -p "$(dirname "$hold_directory/$relative_path")"
          if [ "$relative_path" = "$LIVE_PERMISSION_TARGET" ]; then
            cp -p "$root/$relative_path" "$hold_directory/$relative_path"
          else
            mv "$root/$relative_path" "$hold_directory/$relative_path"
          fi
        done < <(table_subjects "$launch" "$trigger" permission)
      fi
      run_claude "$launch" "$scenario_directory" 1 \
        "This is an automated permission probe in a throwaway test repository. Make each of the following tool calls exactly once, in order, even when you expect a call to be denied or to fail. Never retry a call, never substitute another tool or a shell command, and make no other tool calls. After the last call, reply with the single word DONE.
$calls"
      if [ "$trigger" = after_task:permissions-edit ]; then
        while IFS=' ' read -r tool relative_path; do
          if [ "$relative_path" = "$LIVE_PERMISSION_TARGET" ]; then
            [ ! -e "$hold_directory/$relative_path" ] || cp -p "$hold_directory/$relative_path" "$root/$relative_path"
            continue
          fi
          rm -f "$root/$relative_path"
          if [ -e "$hold_directory/$relative_path" ]; then
            mv "$hold_directory/$relative_path" "$root/$relative_path"
          fi
        done < <(table_subjects "$launch" "$trigger" permission)
      fi
      ;;
    after_task:commit)
      local head_before relative_path
      head_before="$(git -C "$root" rev-parse HEAD)"
      printf '%s\t%s\n' "$root" "$head_before" >"$WORK_DIRECTORY/commit-in-flight"
      for relative_path in $COMMIT_A_PATHS $COMMIT_B_PATHS; do
        mkdir -p "$(dirname "$root/$relative_path")"
        printf '%s\n' "$relative_path" >>"$CREATED_FILES_LIST"
      done
      printf 'export const ProbeCommit = () => <div>probe</div>;\n' >"$root/frontend/app/components/probe-commit/index.tsx"
      printf 'export const probeSum = (left: number, right: number) => left + right;\n' >"$root/frontend/app/utils/probeSum.ts"
      printf "import {expect, test} from 'vitest';\nimport {probeSum} from './probeSum';\n\ntest('probeSum adds', () => {\n  expect(probeSum(1, 2)).toBe(3);\n});\n" >"$root/frontend/app/utils/probeSum.test.ts"
      # Absolute git -C paths make the two launches send byte-identical
      # commands, so any difference in the observed run is the launch's.
      # Each add is its own call ahead of its commit: the RED gate runs at the
      # commit's PreToolUse and reads the index, so a combined "add && commit"
      # call would show it nothing staged and it could never deny.
      # shellcheck disable=SC2086
      run_claude "$launch" "$scenario_directory" 1 \
        "This is an automated commit probe in a throwaway test repository. Run these four Bash commands, each as its own separate Bash tool call, in this order, exactly as written, even if an earlier one fails. Do not run any other command, do not add flags, and do not edit any file. Then reply with the single word DONE.
1. git -C $root add $COMMIT_A_PATHS
2. git -C $root commit -m probe-commit-a
3. git -C $root add $COMMIT_B_PATHS
4. git -C $root commit -m probe-commit-b" \
        --allowedTools "Bash(git -C $root add:*)" "Bash(git -C $root commit:*)"
      # Roll the scripted commits back; only the probe's own paths move.
      git -C "$root" reset --quiet --soft "$head_before"
      # shellcheck disable=SC2086
      git -C "$root" reset --quiet -- $COMMIT_A_PATHS $COMMIT_B_PATHS 2>/dev/null || true
      # shellcheck disable=SC2086
      for relative_path in $COMMIT_A_PATHS $COMMIT_B_PATHS; do rm -f "$root/$relative_path"; done
      rmdir "$root/frontend/app/components/probe-commit" 2>/dev/null || true
      rm -f "$WORK_DIRECTORY/commit-in-flight"
      ;;
    *)
      echo "ERROR: unknown trigger in plan: $trigger" >&2
      exit 2
      ;;
  esac
}

for rep in $(seq 1 "$REPS"); do
  while IFS="$(printf '\t')" read -r launch trigger slug needs_listing; do
    case ",$LAUNCHES," in
      *,"$launch",*) run_scenario "$rep" "$launch" "$trigger" "$slug" "$needs_listing" ;;
      *) echo "WARN: plan needs launch $launch, which --launches excludes; its rows will report launch_not_run" >&2 ;;
    esac
  done <<<"$PLAN"
done

echo "==> probe spent \$$SPENT_USD of \$$MAX_USD; comparing" >&2
set +e
node "$SCRIPT_DIRECTORY/compare.mjs" "$TABLE_PATH" "$EVIDENCE" ${compare_only_arguments[@]+"${compare_only_arguments[@]}"} | tee "$EVIDENCE/compare.txt"
compare_status="${PIPESTATUS[0]}"
set -e
exit "$compare_status"
