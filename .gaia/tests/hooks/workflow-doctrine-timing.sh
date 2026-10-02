#!/usr/bin/env bash
# Local measurement tool for the workflow-doctrine injection hook and the
# always-loaded context-discipline rule. Not a bats suite and not run in CI.
#
# Purpose: the hook runs on every Bash tool call and on four SessionStart
# sources, and the rule sits in every session's context, so both costs are
# paid constantly. This tool measures the hook's wall time per path and the
# byte size of the injected payload and the rule.
#
# Method: builds a scratch fixture repo (git init, one commit, a feat/9-sample
# branch) holding copies of the real hook, its libraries, the doctrine source,
# and the real settings.json. The hook's command string is read from the copied
# settings.json (the SessionStart group matching startup|resume|clear|compact)
# and that exact string is executed by /bin/sh -c with the fixture as cwd, so
# the registered rooting step is part of the measurement. The hook runs under
# macOS bash 3.2 when /bin/bash is that version (a PATH shim makes
# `#!/usr/bin/env bash` resolve to it); elsewhere a warning is printed and the
# resolved bash is used. Each of four inputs runs N times with a fresh
# session_id per run, so the dedupe marker never short-circuits the inject
# path. Wall time is taken around the child process only, with perl
# Time::HiRes.
#
# Inputs: sessionstart_default (startup on main), sessionstart_branch (startup
# on feat/9-sample), posttooluse_bash_nonarming (Bash `ls -la` on the branch),
# posttooluse_bash_arming (Bash `git switch feat/9-sample` on the branch).
#
# Usage: bash .gaia/tests/hooks/workflow-doctrine-timing.sh [--runs N] [--json]
# Run it from the repo root. Default N is 20.
#
# Reading the output: p50 and p90 are milliseconds per input. injected_bytes
# is the decoded additionalContext length on the branch path (key line plus
# doctrine); payload_max_bytes_128char_branch is the same with a 128-character
# branch name, the longest key line; rule_bytes is the rule file size. Token
# figures are bytes divided by 4. A zero injected_bytes means the registered
# command produced no context, which is a failure, not a fast result.
#
# Budgets: p50 at most 50 ms per path, injected payload at most 4096 bytes,
# rule at most 1200 bytes. This tool reports; it never tunes or enforces.
#
# --json prints the measurement rows this tool computes itself as an array of
# {metric, value, unit, budget} objects. Fixture and temp files are removed on
# exit.

set -uo pipefail

runs=20
json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runs)
      runs="${2:-}"
      shift 2 || { echo "--runs needs a value" >&2; exit 2; }
      ;;
    --json) json=1; shift ;;
    *) echo "usage: $0 [--runs N] [--json]" >&2; exit 2 ;;
  esac
done
case "$runs" in '' | *[!0-9]* | 0) echo "--runs must be a positive integer" >&2; exit 2 ;; esac

for tool in jq perl git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 2; }
done

repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "run from inside the repo" >&2; exit 2; }
for required_file in .claude/hooks/workflow-doctrine-inject.sh .claude/doctrine/execution.md \
  .claude/settings.json .claude/rules/context-discipline.md; do
  [ -f "$repo/$required_file" ] || { echo "missing $required_file" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture="$work/fixture"
long_branch="feat/$(printf 'a%.0s' $(seq 1 123))"

# Fixture: real hook, libs, doctrine, settings.
mkdir -p "$fixture/.claude/hooks" "$fixture/.claude/doctrine" "$fixture/.gaia/scripts"
cp "$repo/.claude/hooks/workflow-doctrine-inject.sh" "$fixture/.claude/hooks/"
cp -R "$repo/.claude/hooks/lib" "$fixture/.claude/hooks/lib"
cp "$repo/.claude/doctrine/execution.md" "$fixture/.claude/doctrine/"
cp "$repo/.claude/settings.json" "$fixture/.claude/settings.json"
for library_file in usage-lib.sh branch-name-lib.sh main-root-lib.sh; do
  cp "$repo/.gaia/scripts/$library_file" "$fixture/.gaia/scripts/"
done
git -C "$fixture" init -q -b main
git -C "$fixture" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
  commit -q --allow-empty -m init
git -C "$fixture" branch feat/9-sample
git -C "$fixture" branch "$long_branch"

# The registered command string, read from the copied settings.
registered_command=$(jq -r '.hooks.SessionStart[] | select(.matcher == "startup|resume|clear|compact")
  | .hooks[] | .command | select(contains("workflow-doctrine-inject.sh"))' "$fixture/.claude/settings.json" | sed -n 1p)
[ -n "$registered_command" ] || { echo "no registered doctrine hook command in settings.json" >&2; exit 2; }

# Bash 3.2 shim.
shim="$work/shim"
mkdir -p "$shim"
sys_bash_version=""
[ -x /bin/bash ] && sys_bash_version=$(/bin/bash --version 2>/dev/null)
if grep -q 'version 3\.2' <<<"${sys_bash_version%%$'\n'*}"; then
  ln -s /bin/bash "$shim/bash"
  hook_path="$shim:$PATH"
else
  echo "warning: /bin/bash is not 3.2 here; using whatever bash resolves" >&2
  hook_path="$PATH"
fi
bash_used=$(PATH="$hook_path" bash --version | sed -n 1p)
[ "$json" = 1 ] || echo "bash used for the hook: $bash_used"

# Sets $session_id in the caller shell; RANDOM keeps ids unique across the subshells that run each input.
now_tag=0
session_id=""
next_session_id() { now_tag=$((now_tag + 1)); session_id="sess-$$-$RANDOM$RANDOM-$now_tag"; }

session_start_payload() { jq -nc --arg session_id "$1" --arg working_directory "$fixture" '{hook_event_name:"SessionStart",session_id:$session_id,source:"startup",cwd:$working_directory}'; }
bash_payload() { jq -nc --arg session_id "$1" --arg working_directory "$fixture" --arg command_text "$2" \
  '{hook_event_name:"PostToolUse",session_id:$session_id,tool_name:"Bash",tool_input:{command:$command_text},cwd:$working_directory}'; }

# time_one <payload file> <stdout file>: wall ms of the registered command.
time_one() {
  (cd "$fixture" && PATH="$hook_path" perl -MTime::HiRes=time -e '
    my ($in, $out, $registered_command) = @ARGV;
    open(STDIN, "<", $in) or die; open(STDOUT, ">", $out) or die;
    open(STDERR, ">", "/dev/null") or die;
    my $start = time; system("/bin/sh", "-c", $registered_command); my $elapsed = (time - $start) * 1000;
    open(my $milliseconds_file, ">", "$out.ms") or die; printf $milliseconds_file "%.3f\n", $elapsed;' "$1" "$2" "$registered_command")
}

# measure <name> <builder> <branch> <arg>: prints "p50 p90".
measure() {
  local iteration_count=0 builder="$2" branch="$3" argument="$4" milliseconds times=""
  git -C "$fixture" checkout -q "$branch"
  while [ "$((iteration_count += 1))" -le "$runs" ]; do
    next_session_id
    "$builder" "$session_id" "$argument" >"$work/in.json"
    time_one "$work/in.json" "$work/out.json"
    milliseconds=$(cat "$work/out.json.ms")
    times="$times$milliseconds
"
  done
  printf '%s' "$times" | sed '/^$/d' | sort -n | awk -v run_count="$runs" '
    { sorted_milliseconds[NR] = $1 } END { p50 = sorted_milliseconds[int((NR + 1) / 2)]; p90_index = int(NR * 0.9); if (p90_index < 1) p90_index = 1;
      printf "%.1f %.1f\n", p50, sorted_milliseconds[p90_index] }'
}

# payload_length <branch>: decoded additionalContext byte length for one startup run.
payload_length() {
  local branch="$1"
  git -C "$fixture" checkout -q "$branch"
  next_session_id
  session_start_payload "$session_id" >"$work/in.json"
  time_one "$work/in.json" "$work/out.json"
  jq -j '.hookSpecificOutput.additionalContext // ""' "$work/out.json" 2>/dev/null | wc -c | tr -d ' '
}

read -r sessionstart_default_p50 sessionstart_default_p90 < <(measure sessionstart_default session_start_payload main "")
read -r sessionstart_branch_p50 sessionstart_branch_p90 < <(measure sessionstart_branch session_start_payload feat/9-sample "")
read -r posttooluse_bash_nonarming_p50 posttooluse_bash_nonarming_p90 < <(measure posttooluse_bash_nonarming bash_payload feat/9-sample "ls -la")
read -r posttooluse_bash_arming_p50 posttooluse_bash_arming_p90 < <(measure posttooluse_bash_arming bash_payload feat/9-sample "git switch feat/9-sample")

injected=$(payload_length feat/9-sample)
maximum_payload_bytes=$(payload_length "$long_branch")
rule=$(wc -c <"$repo/.claude/rules/context-discipline.md" | tr -d ' ')
injected_tokens=$((injected / 4))
rule_tokens=$((rule / 4))

if [ "$json" = 1 ]; then
  jq -n \
    --argjson sessionstart_default_p50 "$sessionstart_default_p50" --argjson sessionstart_branch_p50 "$sessionstart_branch_p50" --argjson posttooluse_bash_nonarming_p50 "$posttooluse_bash_nonarming_p50" --argjson posttooluse_bash_arming_p50 "$posttooluse_bash_arming_p50" \
    --argjson injected_bytes "$injected" --argjson injected_tokens "$injected_tokens" --argjson maximum_payload_bytes "$maximum_payload_bytes" \
    --argjson rule "$rule" --argjson rule_tokens "$rule_tokens" '
    [ {metric:"p50_sessionstart_default_ms",value:$sessionstart_default_p50,unit:"ms",budget:50},
      {metric:"p50_sessionstart_branch_ms",value:$sessionstart_branch_p50,unit:"ms",budget:50},
      {metric:"p50_posttooluse_bash_nonarming_ms",value:$posttooluse_bash_nonarming_p50,unit:"ms",budget:50},
      {metric:"p50_posttooluse_bash_arming_ms",value:$posttooluse_bash_arming_p50,unit:"ms",budget:50},
      {metric:"injected_bytes",value:$injected_bytes,unit:"bytes",budget:4096},
      {metric:"injected_tokens_est",value:$injected_tokens,unit:"tokens",budget:null},
      {metric:"payload_max_bytes_128char_branch",value:$maximum_payload_bytes,unit:"bytes",budget:4096},
      {metric:"rule_bytes",value:$rule,unit:"bytes",budget:1200},
      {metric:"rule_tokens_est",value:$rule_tokens,unit:"tokens",budget:null} ]'
else
  echo "runs per input: $runs"
  printf '%-30s p50 %7s ms   p90 %7s ms\n' sessionstart_default "$sessionstart_default_p50" "$sessionstart_default_p90"
  printf '%-30s p50 %7s ms   p90 %7s ms\n' sessionstart_branch "$sessionstart_branch_p50" "$sessionstart_branch_p90"
  printf '%-30s p50 %7s ms   p90 %7s ms\n' posttooluse_bash_nonarming "$posttooluse_bash_nonarming_p50" "$posttooluse_bash_nonarming_p90"
  printf '%-30s p50 %7s ms   p90 %7s ms\n' posttooluse_bash_arming "$posttooluse_bash_arming_p50" "$posttooluse_bash_arming_p90"
  echo "injected_bytes: $injected (tokens est $injected_tokens)"
  echo "payload_max_bytes_128char_branch: $maximum_payload_bytes"
  echo "rule_bytes: $rule (tokens est $rule_tokens)"
  [ "$injected" -gt 0 ] || echo "FAIL: the registered command injected nothing on the branch path"
fi
