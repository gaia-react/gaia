#!/usr/bin/env bash
# spec-session-lock.sh: per-draft liveness lock for concurrent /gaia-spec draft
# authoring. Lets /gaia-spec's step-2 pre-flight tell a draft that another
# terminal is authoring RIGHT NOW apart from a genuinely dormant one, so the
# live case reframes the prompt (Start new recommended) instead of offering the
# unsafe Resume (last-writer-wins clobber) or Discard (deletes the shared draft
# cache out from under the live session). Advisory and fail-open: no lock path
# ever blocks authoring.
#
# This phase ships ONLY `resolve-host` + `match-host` + the shared preamble.
# `acquire` / `status` / `release` land in a later phase; their full frozen
# contract is documented below so that phase builds against it without
# re-deriving it.
#
# --- The one load-bearing fact (AUDIT RT-001, maintainer guidance item 1) ---
#
# The recorded liveness token MUST be the session-lifetime HOST process (the
# durable `claude` CLI that owns the whole authoring session), never the
# ephemeral per-Bash-call shell. A wrong token ships a SILENT no-op: the feature
# "works" and passes its own tests while every draft reads dormant forever.
# `resolve-host` therefore WALKS process ancestry up to the host; it never
# records a fixed `$PPID`. Ground truth captured live (Warp terminal, from
# inside a Bash tool call), walking `ps -o ppid=,comm=` upward from `$$`:
#
#   level 1: /bin/zsh -c source /Users/.../.claude/shell-snapshots/snapshot-... <- throwaway wrapper
#   level 2: claude --dangerously-skip-permissions                              <- THE HOST (comm=claude)
#   level 3: -zsh                                                               <- login shell
#   level 4: .../Warp.app/.../stable terminal-server ...
#   level 5: .../Warp.app/.../stable --finish-update  (ppid=1)
#
# --- The `.claude/` false-match trap (do NOT "simplify" the pattern) ---
#
# Level 1's command line CONTAINS the substring `.claude/` (the shell-snapshots
# path). A naive "command contains `claude`" match STOPS at that throwaway
# wrapper and records a pid that dies the instant the acquiring shell returns.
# The host-match therefore identifies the Claude CLI as an executable/argv TOKEN,
# never the bare substring `claude`. The pinned default ERE (below) is proven to
# MATCH level 2 (`claude --dangerously-skip-permissions`) and to REJECT level 1
# (`.../.claude/shell-snapshots/...`). Anyone tempted to collapse it back into a
# substring match reintroduces the silent no-op. The two ground-truth strings
# are locked in as bats cases; keep them green.
#
# Pinned default host-match ERE (overridable by GAIA_SPEC_LOCK_HOST_PATTERN):
#   (^|[[:space:]]|/)claude([[:space:]]|$)|(^|[[:space:]]|/)node[[:space:]].*/claude[^/]*/.*(cli|index)\.[cm]?js
# Two alternations, both anchored so `.claude/` (a dot immediately before
# `claude`) can never match:
#   1. a `claude` command word: line start, a space, or a `/` (an absolute-path
#      binary) immediately before, and a space or line end immediately after.
#      `.claude` fails the leading anchor (dot, not /); `claude-code` and
#      `claude.md` fail the trailing anchor (`-`/`.`, not space/end).
#   2. a `node ... /claude<pkg>/....(cli|index).(js|mjs|cjs)` invocation (installs
#      that exec node with the CLI in argv). The `/claude` path anchor requires a
#      literal slash immediately before `claude`, so `/.claude/...index.js` (a
#      config-dir path) can never match, and `node` must be present as a word.
# Matching is against the COMMAND LINE only (maintainer guidance: "match by
# command line"). A hardcoded `comm == claude` OR-branch is deliberately NOT
# used: it would make GAIA_SPEC_LOCK_HOST_PATTERN non-authoritative (a probe's
# own real `claude` ancestor would match through the hardcoded branch even under
# an unmatchable override), so the no-host path could never be proven. The ERE
# already matches the real host's command line, so command-line matching alone
# covers both documented shapes.
#
# --- Snapshot-wrapper hard exclusion (defends the load-bearing risk directly) ---
#
# Level 1 is the Claude Code per-Bash-call wrapper: `zsh -c 'source
# <.claude/shell-snapshots/snapshot-...> && ... && eval <the caller's command>'`.
# Two facts make it dangerous: (a) it is EPHEMERAL -- it dies the instant the
# Bash call returns, so recording its pid as the host is exactly the silent
# no-op this feature exists to prevent; and (b) its argv EMBEDS the caller's
# full command text, so if that text contains a bare `claude` token (a path
# arg, a flag, an incidental word), the host pattern would match the wrapper
# and the walk would stop one level too low. Rejecting `.claude/` in the host
# pattern is necessary but NOT sufficient against (b): a different `claude`
# token elsewhere on the same line still satisfies shape 1. So the wrapper is
# excluded OUTRIGHT by its snapshot signature (`.claude/shell-snapshots/`),
# whatever else its command line contains -- it is never the durable host. The
# real host (`claude ...` / `node .../claude-code/cli.js`) never carries that
# signature, so the exclusion can never hide a genuine host. On environments
# with no snapshot wrapper (Linux CI, SSH without the wrapper), the exclusion
# simply never fires.
#
# --- Frozen subcommand contract (later phase builds acquire/status/release) ---
#
# Executable script, sibling of spec-allocator.sh / spec-abandon-empty.sh.
# Best-effort / fail-open by contract: except for acquire's one meaningful
# non-zero code (3), every path exits 0 and never blocks a caller.
#
# Lock file path: <repo_root>/.gaia/local/cache/spec-session-<spec_id>.lock
#   (the `.lock` extension is load-bearing: it must never false-match the
#   existing spec-session-<spec_id>.json session-shape cache.)
#
# Lock file body (single jq-readable JSON object):
#   {
#     "spec_id":      "SPEC-NNN",
#     "hostname":     "<uname -n>",
#     "host_pid":     63071,
#     "host_lstart":  "Sun Jul 19 21:00:00 2026",
#     "host_nonce":   "<CLAUDE_CODE_SESSION_ID, else a generated token>",
#     "acquired_at":  "2026-07-19T21:00:00Z"
#   }
#   - host_pid     -- the session-host pid found by the ancestor-walk.
#   - host_lstart  -- captured by a DEDICATED standalone `ps -o lstart= -p
#                     <host_pid>` call, the byte-for-byte same call `status`
#                     compares against, stored VERBATIM. NOT parsed out of a
#                     combined `ps -o ppid= -o lstart= -o command=` line. BSD
#                     `ps` right-justifies single-digit days with a double space
#                     (`Jul  9`) AND pads the field with trailing spaces, so a
#                     token-normalized or trimmed value would not byte-match and
#                     a session started on days 1-9 (or any session) would
#                     false-read dormant (DP-003). The pid-reuse guard (RT-008):
#                     a recycled pid whose start-time differs never reads as the
#                     same session.
#   - host_nonce   -- CLAUDE_CODE_SESSION_ID when present, else a generated
#                     token. acquire's OWNERSHIP token only (is-this-lock-mine);
#                     NOT part of the `status` liveness verdict. A probing
#                     session cannot re-derive a FOREIGN session's id, so folding
#                     the nonce into `status` would make every genuinely-live
#                     other session read dormant -- the exact silent no-op this
#                     feature exists to prevent (DP-002). Liveness is hostname +
#                     kill -0 + host_lstart only.
#   - hostname     -- same-machine guard: a lock whose hostname is not this
#                     machine reads dormant (a copied checkout never reads live).
#
# Subcommands (all take <repo_root> <spec_id> unless noted):
#   resolve-host [start_pid]   [THIS PHASE]
#       Walk ancestry from start_pid (default $PPID) up to the Claude-CLI host.
#       On match: print host_pid then host_lstart (two lines; the lstart from a
#       DEDICATED `ps -o lstart= -p <host_pid>` call -- DP-003), exit 0. No host
#       found (reached pid <= 1) or ps error: print nothing, exit 1. The walk is
#       bounded (<= 30 hops) so a cycle or pathological tree can never spin.
#   match-host <command_line>  [THIS PHASE, test/diagnostic seam]
#       Exit 0 if <command_line> matches the effective host pattern, else exit 1.
#       Exercises the exact matcher resolve-host climbs with, against a literal
#       string, so the pinned ERE can be proven in isolation.
#   acquire [--override]       [LATER PHASE]
#       Resolve host; classify any existing lock by the `status` logic below
#       (liveness = hostname + kill -0 + host_lstart, NEVER the nonce). No
#       existing lock -> atomically create-exclusive, exit 0. Live and ours ->
#       idempotent, exit 0 (ownership = same host_pid AND host_nonce; with no
#       stable CLAUDE_CODE_SESSION_ID, fall back to host_pid + host_lstart so a
#       per-call generated nonce never mis-reads our own lock as foreign --
#       DP-005). Live and foreign -> do NOT overwrite, exit 3 (caller falls back
#       to Start new -- RT-004 TOCTOU guard) UNLESS --override (human-consented
#       reclaim: force-remove + create, exit 0). Dormant / stale / error ->
#       reclaim (remove + create), exit 0. Host unresolvable -> warn to stderr,
#       write NO lock, exit 0 (accepted fail-open-to-"always dormant" degrade).
#   status                     [LATER PHASE]
#       Print exactly one verdict word -- live | dormant | error -- exit 0
#       always, empty stderr on normal paths. Does NOT mutate the lock.
#   release                    [LATER PHASE]
#       rm -f the lock path. Best-effort, exit 0.
#
# `status` verdict logic (fail-open):
#   1. lock file absent                                      -> dormant
#   2. present but unreadable / not valid JSON / missing req -> error
#   3. hostname != this machine                              -> dormant
#   4. host_pid not alive (kill -0 fails, ESRCH)             -> dormant (reclaimable)
#   5. host_pid alive but host_lstart mismatch (pid reuse)   -> dormant (RT-008)
#   6. host_pid alive + host_lstart matches                  -> live
#   7. any unexpected probe error                            -> error
#
# Test seams (env knobs, read at call time):
#   GAIA_SPEC_LOCK_START_PID     -- override the walk's starting pid.
#   GAIA_SPEC_LOCK_HOST_PATTERN  -- override the host-match ERE (default = the
#                                   pinned Claude-CLI pattern above).
#   CLAUDE_CODE_SESSION_ID       -- read for host_nonce (later phase).
#
# --- Manual-verification checklist (maintainer runs by hand) ---
#
# A sub-agent cannot launch integrated terminals / SSH / a real Linux CI shell
# interactively. The automated bats suite proves the walk MECHANICS on the dev
# shell + CI; environment coverage is the maintainer's gate. From inside a
# /gaia-spec session in each environment below, run the walk (or
# `ps -o ppid=,comm=,command=` up the tree) and confirm a `claude`-CLI ancestor
# is found AND its pid outlives a Bash tool call:
#   [ ] VS Code integrated terminal
#   [ ] JetBrains integrated terminal
#   [ ] SSH session
#   [ ] Linux CI shell
#
# Usage:
#   spec-session-lock.sh resolve-host [start_pid]
#   spec-session-lock.sh match-host <command_line>
#
# Exit: resolve-host/match-host return non-zero ONLY to signal "no match / no
# host found", never to crash a caller.
set -uo pipefail

# Resolve own dir (consumed by acquire/status/release in a later phase for
# sibling-script calls; the sibling-lib preamble convention keeps it here).
# shellcheck disable=SC2034
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pinned default Claude-CLI host-match ERE. See the header for the anchor
# rationale and the `.claude/` false-match trap. Single-quoted on purpose: the
# `$` end-anchors and every ERE metacharacter must reach grep verbatim, not
# expand in the shell.
# shellcheck disable=SC2016
DEFAULT_HOST_PATTERN='(^|[[:space:]]|/)claude([[:space:]]|$)|(^|[[:space:]]|/)node[[:space:]].*/claude[^/]*/.*(cli|index)\.[cm]?js'
HOST_PATTERN="${GAIA_SPEC_LOCK_HOST_PATTERN:-$DEFAULT_HOST_PATTERN}"

# The Claude Code per-Bash-call snapshot wrapper's signature. A command line
# carrying it is the ephemeral wrapper (never the durable host) and is excluded
# outright -- see the header's snapshot-wrapper exclusion note. Not overridable:
# it is a fixed Claude Code artifact, independent of the host-match seam.
SNAPSHOT_WRAPPER_PATTERN='\.claude/shell-snapshots/'

# Bound the ancestor walk so a cycle or a pathological tree can never spin.
MAX_HOPS=30

# _match_command <command_line>: 0 if the command line is the Claude-CLI host,
# non-zero otherwise. The single point where host identity is decided: the
# ephemeral snapshot wrapper is rejected first (whatever else its argv embeds),
# then the host pattern is applied.
_match_command() {
  if printf '%s\n' "$1" | grep -qE "$SNAPSHOT_WRAPPER_PATTERN"; then
    return 1
  fi
  printf '%s\n' "$1" | grep -qE "$HOST_PATTERN"
}

# _resolve_host [start_pid]: walk ancestry to the Claude-CLI host. On match,
# print host_pid then host_lstart (two lines) and return 0; otherwise return 1.
_resolve_host() {
  local start_pid pid ppid command host_lstart hops line
  start_pid="${1:-${GAIA_SPEC_LOCK_START_PID:-$PPID}}"
  pid="$start_pid"
  hops=0
  while [ "$hops" -lt "$MAX_HOPS" ]; do
    # Non-numeric / empty pid, or a pid at/above init: no host above here.
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    # One climb-and-match read. ppid is field 1; the fixed 5-token lstart date
    # occupies fields 2-6 (default field-splitting collapses BSD's double-space
    # single-digit day, so it is always 5 tokens); command is the remainder.
    # The lstart parsed here is used ONLY to locate command; the EMITTED
    # host_lstart comes from a dedicated call below (DP-003).
    line="$(ps -o ppid= -o lstart= -o command= -p "$pid" 2>/dev/null)"
    [ -n "$line" ] || return 1
    read -r ppid _ _ _ _ _ command <<<"$line"
    if _match_command "$command"; then
      host_lstart="$(ps -o lstart= -p "$pid" 2>/dev/null)"
      [ -n "$host_lstart" ] || return 1
      printf '%s\n%s\n' "$pid" "$host_lstart"
      return 0
    fi
    pid="$ppid"
    hops=$((hops + 1))
  done
  return 1
}

case "${1:-}" in
  resolve-host)
    shift
    _resolve_host "$@"
    exit $?
    ;;
  match-host)
    shift
    if _match_command "${1:-}"; then exit 0; else exit 1; fi
    ;;
  *)
    printf 'usage: spec-session-lock.sh <resolve-host [start_pid]|match-host <command_line>>\n' >&2
    exit 1
    ;;
esac
