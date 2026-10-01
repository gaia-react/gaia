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
for f in .claude/hooks/workflow-doctrine-inject.sh .claude/doctrine/execution.md \
  .claude/settings.json .claude/rules/context-discipline.md; do
  [ -f "$repo/$f" ] || { echo "missing $f" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fx="$work/fx"
long_branch="feat/$(printf 'a%.0s' $(seq 1 123))"

# Fixture: real hook, libs, doctrine, settings.
mkdir -p "$fx/.claude/hooks" "$fx/.claude/doctrine" "$fx/.gaia/scripts"
cp "$repo/.claude/hooks/workflow-doctrine-inject.sh" "$fx/.claude/hooks/"
cp -R "$repo/.claude/hooks/lib" "$fx/.claude/hooks/lib"
cp "$repo/.claude/doctrine/execution.md" "$fx/.claude/doctrine/"
cp "$repo/.claude/settings.json" "$fx/.claude/settings.json"
for lib in usage-lib.sh branch-name-lib.sh main-root-lib.sh; do
  cp "$repo/.gaia/scripts/$lib" "$fx/.gaia/scripts/"
done
git -C "$fx" init -q -b main
git -C "$fx" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
  commit -q --allow-empty -m init
git -C "$fx" branch feat/9-sample
git -C "$fx" branch "$long_branch"

# The registered command string, read from the copied settings.
cmd=$(jq -r '.hooks.SessionStart[] | select(.matcher == "startup|resume|clear|compact")
  | .hooks[] | .command | select(contains("workflow-doctrine-inject.sh"))' "$fx/.claude/settings.json" | sed -n 1p)
[ -n "$cmd" ] || { echo "no registered doctrine hook command in settings.json" >&2; exit 2; }

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

# Sets $sid in the caller shell; RANDOM keeps ids unique across the subshells that run each input.
now_tag=0
sid=""
next_sid() { now_tag=$((now_tag + 1)); sid="sess-$$-$RANDOM$RANDOM-$now_tag"; }

ss_payload() { jq -nc --arg s "$1" --arg c "$fx" '{hook_event_name:"SessionStart",session_id:$s,source:"startup",cwd:$c}'; }
bash_payload() { jq -nc --arg s "$1" --arg c "$fx" --arg k "$2" \
  '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$k},cwd:$c}'; }

# time_one <payload file> <stdout file>: wall ms of the registered command.
time_one() {
  (cd "$fx" && PATH="$hook_path" perl -MTime::HiRes=time -e '
    my ($in, $out, $cmd) = @ARGV;
    open(STDIN, "<", $in) or die; open(STDOUT, ">", $out) or die;
    open(STDERR, ">", "/dev/null") or die;
    my $t = time; system("/bin/sh", "-c", $cmd); my $e = (time - $t) * 1000;
    open(my $res, ">", "$out.ms") or die; printf $res "%.3f\n", $e;' "$1" "$2" "$cmd")
}

# measure <name> <builder> <branch> <arg>: prints "p50 p90".
measure() {
  local n=0 builder="$2" branch="$3" arg="$4" ms times=""
  git -C "$fx" checkout -q "$branch"
  while [ "$((n += 1))" -le "$runs" ]; do
    next_sid
    "$builder" "$sid" "$arg" >"$work/in.json"
    time_one "$work/in.json" "$work/out.json"
    ms=$(cat "$work/out.json.ms")
    times="$times$ms
"
  done
  printf '%s' "$times" | sed '/^$/d' | sort -n | awk -v n="$runs" '
    { a[NR] = $1 } END { p50 = a[int((NR + 1) / 2)]; i90 = int(NR * 0.9); if (i90 < 1) i90 = 1;
      printf "%.1f %.1f\n", p50, a[i90] }'
}

# payload_len <branch>: decoded additionalContext byte length for one startup run.
payload_len() {
  local branch="$1"
  git -C "$fx" checkout -q "$branch"
  next_sid
  ss_payload "$sid" >"$work/in.json"
  time_one "$work/in.json" "$work/out.json"
  jq -j '.hookSpecificOutput.additionalContext // ""' "$work/out.json" 2>/dev/null | wc -c | tr -d ' '
}

read -r d50 d90 < <(measure sessionstart_default ss_payload main "")
read -r b50 b90 < <(measure sessionstart_branch ss_payload feat/9-sample "")
read -r n50 n90 < <(measure posttooluse_bash_nonarming bash_payload feat/9-sample "ls -la")
read -r a50 a90 < <(measure posttooluse_bash_arming bash_payload feat/9-sample "git switch feat/9-sample")

injected=$(payload_len feat/9-sample)
maxpay=$(payload_len "$long_branch")
rule=$(wc -c <"$repo/.claude/rules/context-discipline.md" | tr -d ' ')
inj_tok=$((injected / 4))
rule_tok=$((rule / 4))

if [ "$json" = 1 ]; then
  jq -n \
    --argjson d "$d50" --argjson b "$b50" --argjson n "$n50" --argjson a "$a50" \
    --argjson inj "$injected" --argjson itok "$inj_tok" --argjson mx "$maxpay" \
    --argjson rule "$rule" --argjson rtok "$rule_tok" '
    [ {metric:"p50_sessionstart_default_ms",value:$d,unit:"ms",budget:50},
      {metric:"p50_sessionstart_branch_ms",value:$b,unit:"ms",budget:50},
      {metric:"p50_posttooluse_bash_nonarming_ms",value:$n,unit:"ms",budget:50},
      {metric:"p50_posttooluse_bash_arming_ms",value:$a,unit:"ms",budget:50},
      {metric:"injected_bytes",value:$inj,unit:"bytes",budget:4096},
      {metric:"injected_tokens_est",value:$itok,unit:"tokens",budget:null},
      {metric:"payload_max_bytes_128char_branch",value:$mx,unit:"bytes",budget:4096},
      {metric:"rule_bytes",value:$rule,unit:"bytes",budget:1200},
      {metric:"rule_tokens_est",value:$rtok,unit:"tokens",budget:null} ]'
else
  echo "runs per input: $runs"
  printf '%-30s p50 %7s ms   p90 %7s ms\n' sessionstart_default "$d50" "$d90"
  printf '%-30s p50 %7s ms   p90 %7s ms\n' sessionstart_branch "$b50" "$b90"
  printf '%-30s p50 %7s ms   p90 %7s ms\n' posttooluse_bash_nonarming "$n50" "$n90"
  printf '%-30s p50 %7s ms   p90 %7s ms\n' posttooluse_bash_arming "$a50" "$a90"
  echo "injected_bytes: $injected (tokens est $inj_tok)"
  echo "payload_max_bytes_128char_branch: $maxpay"
  echo "rule_bytes: $rule (tokens est $rule_tok)"
  [ "$injected" -gt 0 ] || echo "FAIL: the registered command injected nothing on the branch path"
fi
