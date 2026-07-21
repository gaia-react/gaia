#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit + Bash hook: deny a Code Audit Team
# member's attempt to repair a path outside its self-heal boundary.
#
# This is the LOCAL producer's enforcement point. The CI producer's
# equivalent is the "Commit and push self-heal" step's push gate in
# .github/workflows/code-review-audit.yml, which reads the whole self-heal
# diff at push time. Phase 1 of this SPEC makes `local` the default
# resolved mode, and the CI push gate binds only forks and the override
# label, so a local-mode member had no deterministic boundary at all until
# this hook. Both enforcement points source the SAME refusal set from
# .claude/hooks/lib/audit-selfheal-paths.sh; neither carries a second copy.
#
# THE GATE BINDS MEMBERS, NOT THE TREE. A PreToolUse payload carries
# `agent_type` only when the hook fires inside a subagent call; it is
# absent for the main session / orchestrator. This hook no-ops immediately
# whenever `agent_type` is absent or does not carry the `code-audit-`
# prefix, so the orchestrator (trusted by the SPEC's own design, and which
# this very plan's execution requires to repair .gaia/**, test/**, and
# .github/workflows/** on nearly every phase) is never touched. Only a
# dispatched Code Audit Team member (`code-audit-frontend`,
# `code-audit-github-workflows`, etc.) is bound, including advisory members:
# an advisory member returns a byte-identical tree anyway, so refusing it
# costs nothing, and a future self-healing member is bound the day it lands
# rather than the day someone remembers to add it.
#
# Membership is a NAME-PREFIX match, not a roster lookup: the hook fires on
# every edit in every session, so it stays off the classifier's parse path
# and carries no dependency on the roster's record contract. A member named
# off the `code-audit-` convention escapes this hook; that convention is
# already load-bearing in the roster glob, the machinery lists, and the
# release scrub's leak-check, so this adds no new coupling.
#
# HONEST ABOUT THE BASH VECTOR: this is a best-effort, defense-in-depth
# guard, not an airtight one, mirroring block-manifest-write.sh's own stated
# posture. Bash vectors are unbounded; this covers the well-known write
# shapes (output redirect, tee, sed -i with or without a macOS '' backup
# suffix, sponge, cp/mv as destination) and no more. CI's gate reads the
# whole diff at push time and cannot be evaded by the shape of the write;
# this hook reads one attempted edit at a time and can be. That asymmetry is
# real and accepted: under local mode a human watches every turn.
#
# The Bash branch also carries one EXECUTION-shape refusal, not a write
# shape: a dispatched member may not invoke
# .gaia/scripts/write-audit-remits.sh at all, since running it edits
# .claude/agents/code-audit-*.md and rotates every member's clearance
# digest. That literal lives here, not in the shared
# AUDIT_SELFHEAL_REFUSE_ERE, because that ERE is a path matcher the CI push
# gate applies to a diff, and a script invocation is not a path in a diff.
set -euo pipefail

payload=$(cat)

# Cheapest possible filter first: the common case is "no agent_type at all"
# (the main session). Read it before anything else and exit before sourcing
# the refusal-set lib or resolving the repo root.
agent_type=$(jq -r '.agent_type // empty' <<<"$payload")
case "$agent_type" in
  code-audit-*) ;;
  *) exit 0 ;;
esac

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Source the refusal-set lib from THIS hook's own on-disk location, never
# cwd, mirroring .gaia/scripts/audit-machinery-complete.sh. A missing lib
# means the refusal set cannot be determined for a member that IS bound, so
# fail loudly and deny rather than silently allowing the edit through.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SELF_DIR/lib/audit-selfheal-paths.sh"
if [ ! -f "$LIB" ]; then
  printf 'block-selfheal-paths.sh: refusal-set library unavailable: %s\n' "$LIB" >&2
  deny "BLOCKED: the self-heal repair-boundary library ($LIB) is unavailable, so this edit cannot be checked against it. Fail-loud, not fail-open -- restore the library before retrying."
fi
# shellcheck source=/dev/null
. "$LIB"

# Repo root, resolved the same way .claude/hooks/lib/repo-scope.sh resolves
# the home repo (`git rev-parse --show-toplevel`), not a second way. The
# refusal set is repo-relative; an absolute `tool_input.file_path` (or a
# Bash-command absolute path) must be relativized against this before it is
# tested, or every check silently misses.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

MATCHED_PATH=""

# Strip one matching pair of surrounding quotes from a token.
strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
    \'*\') s=${s#\'}; s=${s%\'} ;;
  esac
  printf '%s' "$s"
}

# is_refused_path <token>: strip quotes and a leading ./, relativize an
# absolute token against REPO_ROOT when it resolves under it, then test the
# result against AUDIT_SELFHEAL_REFUSE_ERE. On a match, sets MATCHED_PATH to
# the relative path (so the caller can name it in the deny reason) and
# returns 0. An absolute token that does not resolve
# under REPO_ROOT is ambiguous (out-of-repo, or the root could not be
# resolved) and is left alone -- the safe direction is to allow.
is_refused_path() {
  local p rel
  p=$(strip_quotes "$1")
  p=${p#./}
  [ -n "$p" ] || return 1
  case "$p" in
    /*)
      if [ -n "$REPO_ROOT" ] && [ "${p#"$REPO_ROOT"/}" != "$p" ]; then
        rel="${p#"$REPO_ROOT"/}"
      else
        return 1
      fi
      ;;
    *) rel="$p" ;;
  esac
  [[ "$rel" =~ $AUDIT_SELFHEAL_REFUSE_ERE ]] || return 1
  MATCHED_PATH="$rel"
  return 0
}

deny_reason() {
  printf 'BLOCKED: self-heal may not edit %s -- off-limits to the repair boundary (tests, the CI pipeline, .gaia/ gate & roster machinery, instruction/convention surfaces, or root build config). This is a defect to report as a finding, not to repair. See .claude/hooks/lib/audit-selfheal-paths.sh.' "$1"
}

tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

case "$tool_name" in
  Edit | Write | MultiEdit)
    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
    [[ -n "$file_path" ]] || exit 0
    is_refused_path "$file_path" && deny "$(deny_reason "$MATCHED_PATH")"
    exit 0
    ;;

  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
    [[ -n "$cmd" ]] || exit 0

    read -r -a toks <<<"$cmd"
    n=${#toks[@]}

    # A dispatched member may not repair its own declared remit. This is an
    # EXECUTION shape, not a write shape: `bash .gaia/scripts/write-audit-remits.sh`
    # presents no redirect, tee, sed -i, sponge, or cp/mv destination, so the
    # write-shape loop below never sees it. The literal lives here rather than in
    # the shared AUDIT_SELFHEAL_REFUSE_ERE because that ERE is a path matcher the
    # CI push gate applies to a diff, and an invocation is not a path in a diff.
    #
    # Matched only at an EXECUTION position: token 0, a token immediately
    # following a `;` / `&&` / `||` / `|` separator, or -- after an
    # interpreter-like token (bash, sh, zsh, env, nohup) -- the first
    # following token that is neither a `-`-prefixed option nor (after `env`)
    # a `VAR=VALUE` assignment, so `sh -x <writer>`, `bash --norc <writer>`,
    # `env FOO=1 <writer>`, and `nohup <writer>` all deny. `-c` is never
    # treated as a skippable option: its argument is a quoted script STRING
    # this whitespace tokenizer cannot safely parse, so `bash -c '<writer>'`
    # is left exactly as it was (a stated, out-of-scope gap; same for any
    # invocation past line 1, since `read -r -a toks` above only tokenizes
    # the first line). A read-only command that merely NAMES the file as an
    # argument (`shellcheck .gaia/scripts/write-audit-remits.sh`, `cat ...`,
    # `git log --grep ...`) is not an invocation of it and must stay allowed.
    prev_sep=1
    after_interp=0
    after_interp_env=0
    k=0
    while [ "$k" -lt "$n" ]; do
      cand=$(strip_quotes "${toks[$k]}")

      exec_pos=0
      [ "$prev_sep" -eq 1 ] && exec_pos=1

      if [ "$after_interp" -eq 1 ]; then
        skip=0
        case "$cand" in
          -c) ;;
          -*) skip=1 ;;
        esac
        if [ "$skip" -eq 0 ] && [ "$after_interp_env" -eq 1 ]; then
          case "$cand" in
            [A-Za-z_]*=*) skip=1 ;;
          esac
        fi
        if [ "$skip" -eq 0 ]; then
          exec_pos=1
          after_interp=0
        fi
      fi

      if [ "$exec_pos" -eq 1 ]; then
        case "${cand##*/}" in
          write-audit-remits.sh)
            deny "BLOCKED: a dispatched Code Audit Team member may not run the remit writer (.gaia/scripts/write-audit-remits.sh). Regenerating a remit region rewrites every code-audit-*.md definition under .claude/agents/, which are audit-machinery paths: it rotates every member's content digest and invalidates every clearance marker on this PR. Reporting the remit drift as a finding is your only correct action here; repairing it is the orchestrator's, never a member's."
            ;;
        esac
        case "$cand" in
          bash | sh | zsh | nohup)
            after_interp=1
            after_interp_env=0
            ;;
          env)
            after_interp=1
            after_interp_env=1
            ;;
        esac
      fi

      case "$cand" in
        ';' | '&&' | '||' | '|') prev_sep=1 ;;
        *) prev_sep=0 ;;
      esac

      k=$((k + 1))
    done

    i=0
    while [ "$i" -lt "$n" ]; do
      tok="${toks[$i]}"
      case "$tok" in
        '>' | '>>')
          next="${toks[$((i + 1))]:-}"
          is_refused_path "$next" && deny "$(deny_reason "$MATCHED_PATH")"
          ;;
        tee | sponge)
          j=$((i + 1))
          while [ "$j" -lt "$n" ]; do
            t2="${toks[$j]}"
            case "$t2" in
              ';' | '&&' | '||' | '|') break ;;
            esac
            is_refused_path "$t2" && deny "$(deny_reason "$MATCHED_PATH")"
            j=$((j + 1))
          done
          ;;
        sed)
          has_i=0
          sed_match=""
          j=$((i + 1))
          while [ "$j" -lt "$n" ]; do
            t2="${toks[$j]}"
            case "$t2" in
              ';' | '&&' | '||' | '|') break ;;
            esac
            [[ "$t2" == "-i" || "$t2" == -i* ]] && has_i=1
            if is_refused_path "$t2"; then sed_match="$MATCHED_PATH"; fi
            j=$((j + 1))
          done
          [ "$has_i" -eq 1 ] && [ -n "$sed_match" ] && deny "$(deny_reason "$sed_match")"
          ;;
        cp | mv)
          dest=""
          j=$((i + 1))
          while [ "$j" -lt "$n" ]; do
            t2="${toks[$j]}"
            case "$t2" in
              ';' | '&&' | '||' | '|') break ;;
            esac
            [[ "$t2" == -* ]] || dest="$t2"
            j=$((j + 1))
          done
          is_refused_path "$dest" && deny "$(deny_reason "$MATCHED_PATH")"
          ;;
      esac
      i=$((i + 1))
    done

    exit 0
    ;;

  *)
    exit 0
    ;;
esac
