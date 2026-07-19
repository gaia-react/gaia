#!/usr/bin/env bash
# spec-session-lock.sh: per-draft liveness lock for concurrent /gaia-spec draft
# authoring. Lets /gaia-spec's step-2 pre-flight tell a draft that another
# terminal is authoring RIGHT NOW apart from a genuinely dormant one, so the
# live case reframes the prompt (Start new recommended) instead of offering the
# unsafe Resume (last-writer-wins clobber) or Discard (deletes the shared draft
# cache out from under the live session). Advisory and fail-open: no lock path
# ever blocks authoring.
#
# This file implements the full subcommand set: `resolve-host` + `match-host`
# (the ancestor-walk primitive) plus `acquire` / `status` / `release` (the
# liveness-lock helper built on top of it).
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
# --- Subcommand contract ---
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
#   resolve-host [start_pid]
#       Walk ancestry from start_pid (default $PPID) up to the Claude-CLI host.
#       On match: print host_pid then host_lstart (two lines; the lstart from a
#       DEDICATED `ps -o lstart= -p <host_pid>` call -- DP-003), exit 0. No host
#       found (reached pid <= 1) or ps error: print nothing, exit 1. The walk is
#       bounded (<= 30 hops) so a cycle or pathological tree can never spin.
#   match-host <command_line>  (test/diagnostic seam)
#       Exit 0 if <command_line> matches the effective host pattern, else exit 1.
#       Exercises the exact matcher resolve-host climbs with, against a literal
#       string, so the pinned ERE can be proven in isolation.
#   acquire [--override]
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
#   status
#       Print exactly one verdict word -- live | dormant | error -- exit 0
#       always, empty stderr on normal paths. Does NOT mutate the lock.
#   release
#       rm -f the lock path. Best-effort, exit 0.
#
# --- Implementation notes (acquire / status / release) ---
#
# Shared classify helper: `_classify_lock` implements the seven-step verdict
# logic below ONCE; both the `status` subcommand and `acquire`'s pre-write
# existing-lock check call it, so the two paths can never drift apart.
#
# Atomic create-exclusive: `( set -o noclobber; printf '%s\n' "$body" >
# "$lockfile" ) 2>/dev/null`. Bash opens a noclobber redirection target with
# O_EXCL, so this is a real kernel-level single-winner race (RT-004), not a
# check-then-write TOCTOU. Chosen over an `ln`-of-a-tempfile dance because the
# target IS the lock file itself here -- no separate link-target file is
# needed, and the subshell parens scope `set -o noclobber` so it never leaks
# into the rest of the script.
#
# `kill -0` ESRCH vs EPERM: on this same-machine same-user design, a `kill -0`
# failure normally means the pid is dead (ESRCH -- "No such process"). If the
# pid is alive but owned by another user, `kill -0` ALSO fails, but with a
# distinct message ("Operation not permitted" / EPERM) -- that process is
# alive, not dead. `_classify_lock` greps the captured stderr for "permitted"
# to tell the two apart; a same-user host_pid never hits this branch in
# practice, but the check keeps a foreign-owned live process from reading
# dormant.
#
# No extra env seam: `status` bats cases stamp a lock file directly with
# `jq -n` and drive liveness with a plain backgrounded `sleep` (real pid, real
# `ps -o lstart=`) -- no walk involved, so no injection seam is needed there.
# `acquire` cases reuse Phase 1's `_spawn_fake_host` fixture (GAIA_SPEC_LOCK_
# HOST_PATTERN + GAIA_SPEC_LOCK_START_PID) so the walk resolves to a
# controllable process without a real `claude` ancestor.
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
#   CLAUDE_CODE_SESSION_ID       -- read for host_nonce.
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
#   spec-session-lock.sh acquire [--override] <repo_root> <spec_id>
#   spec-session-lock.sh status <repo_root> <spec_id>
#   spec-session-lock.sh release <repo_root> <spec_id>
#
# Exit: resolve-host/match-host return non-zero ONLY to signal "no match / no
# host found". status/release always exit 0. acquire exits 0 on every path
# except a live-foreign lock without --override, which exits 3. No path here
# crashes a caller.
set -uo pipefail

# Resolve own dir (the sibling-lib preamble convention keeps it here; reserved
# for a future sibling-script call, unused by acquire/status/release below).
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

# _lock_path <repo_root> <spec_id>: the frozen lock-file location. The `.lock`
# extension is load-bearing -- see the header note on never false-matching the
# existing spec-session-<spec_id>.json session-shape cache.
_lock_path() {
  printf '%s/.gaia/local/cache/spec-session-%s.lock' "${1%/}" "$2"
}

# _generate_nonce: a per-call fallback host_nonce when no stable
# CLAUDE_CODE_SESSION_ID is set. Never compared against in `status` (DP-002);
# `acquire`'s own-lock ownership check falls back to host_pid + host_lstart in
# this case (DP-005), so the token's exact form only needs to be non-empty.
_generate_nonce() {
  printf '%s-%s-%s' "$$" "$RANDOM" "$(date -u +%s)"
}

# _compose_lock_body <spec_id> <hostname> <host_pid> <host_lstart> <host_nonce>:
# echoes the single JSON lock object, built entirely with jq -n so no field
# is ever string-interpolated into the JSON literal (injection-safe).
_compose_lock_body() {
  local spec_id="$1" this_hostname="$2" host_pid="$3" host_lstart="$4" host_nonce="$5"
  local acquired_at
  acquired_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  jq -n \
    --arg spec_id "$spec_id" \
    --arg hostname "$this_hostname" \
    --argjson host_pid "$host_pid" \
    --arg host_lstart "$host_lstart" \
    --arg host_nonce "$host_nonce" \
    --arg acquired_at "$acquired_at" \
    '{spec_id: $spec_id, hostname: $hostname, host_pid: $host_pid, host_lstart: $host_lstart, host_nonce: $host_nonce, acquired_at: $acquired_at}'
}

# _classify_lock <lockfile>: the shared status-classify helper. This IS the
# `status` verdict logic (steps 1-7 in the header); sets LOCK_VERDICT to
# exactly one word (live|dormant|error). On a `live` verdict also populates
# LOCK_HOST_PID / LOCK_HOST_LSTART / LOCK_HOST_NONCE so `acquire`'s ownership
# check can compare them without re-reading the file. Reports through globals,
# not stdout+`echo`: callers MUST invoke this directly (never via `$(...)`),
# since a command-substitution subshell would silently drop every assignment
# made inside it.
_classify_lock() {
  local lockfile="$1"
  LOCK_VERDICT=""
  LOCK_HOST_PID=""
  LOCK_HOST_LSTART=""
  LOCK_HOST_NONCE=""

  # 1. lock file absent -> dormant.
  if [ ! -f "$lockfile" ]; then
    LOCK_VERDICT=dormant
    return 0
  fi

  # jq missing with a lock file present is an unreadable-lock situation, same
  # bucket as invalid JSON below.
  if ! command -v jq >/dev/null 2>&1; then
    LOCK_VERDICT=error
    return 0
  fi

  local raw
  raw="$(cat "$lockfile" 2>/dev/null)"
  if [ -z "$raw" ]; then
    LOCK_VERDICT=error
    return 0
  fi

  # 2. present but not valid JSON, or missing a required field -> error. One
  # jq pass validates and extracts in the same step.
  local fields
  fields="$(printf '%s' "$raw" | jq -r '
    if (.hostname // "") == "" or (.host_pid // "") == "" or (.host_lstart // "") == ""
    then empty
    else [.hostname, (.host_pid | tostring), .host_lstart, (.host_nonce // "")] | @tsv
    end
  ' 2>/dev/null)"
  if [ -z "$fields" ]; then
    LOCK_VERDICT=error
    return 0
  fi

  local lock_hostname lock_pid lock_lstart lock_nonce
  IFS=$'\t' read -r lock_hostname lock_pid lock_lstart lock_nonce <<<"$fields"

  # 3. hostname mismatch -> dormant (a copied checkout never reads live here).
  if [ "$lock_hostname" != "$(uname -n)" ]; then
    LOCK_VERDICT=dormant
    return 0
  fi

  # 4. host_pid not alive -> dormant. `kill -0` fails identically for a dead
  # pid (ESRCH) and a live pid owned by another user (EPERM); the same-machine
  # same-user design treats ESRCH as dead and EPERM as alive, distinguished
  # here by grepping the captured stderr text (see the header's implementation
  # note).
  local kill_err kill_status
  kill_err="$(kill -0 "$lock_pid" 2>&1)"
  kill_status=$?
  if [ "$kill_status" -ne 0 ] && ! printf '%s' "$kill_err" | grep -qi 'permitted'; then
    LOCK_VERDICT=dormant
    return 0
  fi

  # 5. host_pid alive but host_lstart mismatch -> dormant (pid reuse; RT-008).
  # Compared against a standalone `ps -o lstart= -p` call, byte-identical to
  # the one resolve-host used to produce the recorded value (DP-003). DP-002:
  # host_nonce is NEVER consulted here.
  local live_lstart
  live_lstart="$(ps -o lstart= -p "$lock_pid" 2>/dev/null)"
  if [ -z "$live_lstart" ]; then
    # 7. kill -0 said alive/permitted but ps could not read it: an unexpected
    # probe error, not a normal absent-process case.
    LOCK_VERDICT=error
    return 0
  fi
  if [ "$live_lstart" != "$lock_lstart" ]; then
    LOCK_VERDICT=dormant
    return 0
  fi

  # 6. alive + host_lstart matches -> live.
  LOCK_HOST_PID="$lock_pid"
  LOCK_HOST_LSTART="$lock_lstart"
  LOCK_HOST_NONCE="$lock_nonce"
  LOCK_VERDICT=live
  return 0
}

# _acquire [--override] <repo_root> <spec_id>: see the header's frozen acquire
# contract. Returns 0 on every path except a live-foreign lock without
# --override (3).
_acquire() {
  local override=0
  if [ "${1:-}" = "--override" ]; then
    override=1
    shift
  fi
  if [ "$#" -lt 2 ]; then
    echo "usage: spec-session-lock.sh acquire [--override] <repo_root> <spec_id>" >&2
    return 0
  fi
  local repo_root="$1" spec_id="$2"
  local lockfile
  lockfile="$(_lock_path "$repo_root" "$spec_id")"

  command -v jq >/dev/null 2>&1 || {
    echo "spec-session-lock: jq not found; skipping acquire (fail-open)" >&2
    return 0
  }

  # Resolve host FIRST: no host means no lock is ever written, by contract.
  local resolved host_pid host_lstart
  if ! resolved="$(_resolve_host)"; then
    echo "spec-session-lock: no session host resolved; skipping acquire (fail-open)" >&2
    return 0
  fi
  host_pid="$(printf '%s\n' "$resolved" | sed -n '1p')"
  host_lstart="$(printf '%s\n' "$resolved" | sed -n '2p')"

  mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true

  local this_hostname nonce have_stable_nonce body
  this_hostname="$(uname -n)"
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    nonce="$CLAUDE_CODE_SESSION_ID"
    have_stable_nonce=1
  else
    nonce="$(_generate_nonce)"
    have_stable_nonce=0
  fi
  body="$(_compose_lock_body "$spec_id" "$this_hostname" "$host_pid" "$host_lstart" "$nonce")"

  if [ "$override" -eq 1 ]; then
    # COV-001 / DP-001: the ONLY path that reclaims a LIVE foreign lock,
    # firing only from the human-consented "Override: resume ... anyway"
    # branch (Phase 3).
    rm -f "$lockfile" 2>/dev/null || true
    (
      set -o noclobber
      printf '%s\n' "$body" > "$lockfile"
    ) 2>/dev/null
    return 0
  fi

  # Atomic create-exclusive: bash opens a noclobber redirection target with
  # O_EXCL, so this is a real single-winner race (RT-004), not a
  # check-then-write TOCTOU. See the header's implementation note for why this
  # idiom was chosen over an `ln`-of-a-tempfile dance.
  if (
    set -o noclobber
    printf '%s\n' "$body" > "$lockfile"
  ) 2>/dev/null; then
    return 0
  fi

  # Create failed: a lock already exists. Classify it with the SAME logic
  # `status` uses (DP-002: never the nonce for liveness). Called directly
  # (not via `$(...)`) so LOCK_HOST_PID/LOCK_HOST_LSTART/LOCK_HOST_NONCE reach
  # this shell rather than dying in a substitution subshell.
  _classify_lock "$lockfile"

  case "$LOCK_VERDICT" in
    live)
      # Ownership: same host_pid AND host_nonce; when no stable
      # CLAUDE_CODE_SESSION_ID exists, fall back to host_pid + host_lstart so
      # a per-call generated nonce never mis-reads our own lock as foreign
      # (DP-005).
      if [ "$LOCK_HOST_PID" = "$host_pid" ]; then
        if [ "$have_stable_nonce" -eq 1 ] && [ "$LOCK_HOST_NONCE" = "$nonce" ]; then
          return 0
        fi
        if [ "$have_stable_nonce" -eq 0 ] && [ "$LOCK_HOST_LSTART" = "$host_lstart" ]; then
          return 0
        fi
      fi
      echo "spec-session-lock: live foreign lock exists for $spec_id" >&2
      return 3
      ;;
    dormant | error)
      # Reclaim: rm + re-create exclusively. COV-005 -- a crash never blocks a
      # draft.
      rm -f "$lockfile" 2>/dev/null || true
      (
        set -o noclobber
        printf '%s\n' "$body" > "$lockfile"
      ) 2>/dev/null
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

# _status <repo_root> <spec_id>: print exactly one verdict word, exit 0
# always. Never mutates the lock file.
_status() {
  if [ "$#" -lt 2 ]; then
    echo "usage: spec-session-lock.sh status <repo_root> <spec_id>" >&2
    echo error
    return 0
  fi
  _classify_lock "$(_lock_path "$1" "$2")"
  echo "$LOCK_VERDICT"
  return 0
}

# _release <repo_root> <spec_id>: rm -f the lock path. Best-effort, exit 0.
# Verdict-blind by design -- whether a caller should reach it is the call
# site's responsibility, not this helper's.
_release() {
  if [ "$#" -lt 2 ]; then
    echo "usage: spec-session-lock.sh release <repo_root> <spec_id>" >&2
    return 0
  fi
  rm -f "$(_lock_path "$1" "$2")" 2>/dev/null || true
  return 0
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
  acquire)
    shift
    _acquire "$@"
    exit $?
    ;;
  status)
    shift
    _status "$@"
    exit $?
    ;;
  release)
    shift
    _release "$@"
    exit $?
    ;;
  *)
    printf 'usage: spec-session-lock.sh <resolve-host [start_pid]|match-host <command_line>|acquire [--override] <repo_root> <spec_id>|status <repo_root> <spec_id>|release <repo_root> <spec_id>>\n' >&2
    exit 1
    ;;
esac
