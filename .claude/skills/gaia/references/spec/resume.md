# /gaia-spec: resume a draft

The resume branch of `/gaia-spec` step 2: the liveness check on an existing draft, and the Resume / Start new / Discard choice. `spec.md` routes here only when the allocator reported an unfinalized draft id and the run is interactive; auto mode always starts new. Control returns to `spec.md` at step 3 on Start new or a confirmed discard, or at the step the Resume branch picks (4, 6 or 8).

Contents: Session-lock; Resume point; Live-session check; Resume, start new, or discard.

## Session-lock

A per-draft liveness marker at `.gaia/local/cache/spec-session-<spec_id>.lock`, a sibling of the session-shape `spec-session-<spec_id>.json` cache in `spec.md`'s Operational primitives. It records the session-host process authoring this draft: its process id, start time, a nonce, and the hostname. Liveness is decided by an explicit live-process check, never by file mtime: the Socratic clarify loop blocks on human input, so a very-live session parked on a question has a stale draft and lock mtime alike, a recent write can prove a session live, but a stale write can never prove one dormant.

**Acquire points (two).** Fresh allocation (step 3) and resume of a dormant draft (step 2 Resume branch). Both interactive and auto mode acquire at fresh allocation, step 3 has no auto-mode exception for its cache-init block, so a concurrent same-machine session detects an auto run as live from the moment it allocates, and releases it at exit the same as an interactive session.

**Release (two categories).** The holder drops its own lock on its own graceful exits: the canonical save (step 9), the `Save partial and resume later` escape, and the general abandoned-exit primitive, so an aborted-but-surviving-host session drops its lock rather than leaving a false-live marker behind. Separately, a later session releases a dormant-or-ghost lock it does not own: the step-2 discard of a surfaced dormant draft, and the abandoned-empty sweep retiring a genuine ghost row. Each of these two default paths stays off a live lock: the sweep only ever retires a genuine ghost, whose lock is by definition dead, and the default discard path is reached only for a dormant draft (the step-2 branch below covers the unreadable-lock and explicit-override exceptions to that default).

**Save-partial asymmetry.** The `Save partial and resume later` escape releases the lock, so the paused draft reads dormant and stays resumable by a later session, while it retains the session-shape `.json` cache, so that later session keeps counting questions against the same `start_at`. This is a deliberate asymmetry: the two caches are released on different schedules by design, not a contradiction of the session-shape cache's own not-deleted-on-save-partial rule (`spec/clarify-loop.md`, `## Escape option`).

**Check verdicts.** `status` returns `live`, `dormant`, or `error`; the step-2 branch below maps each to a prompt. An absent lock, a dead host pid, or a host-mismatched or stale-pid lock all read `dormant`. Only an unreadable or otherwise uncheckable lock reads `error`.

**Fail-open guarantee.** Any lock-subsystem error degrades to a non-blocking path, the lock never blocks authoring. This is a best-effort availability tradeoff, not a safety guarantee: the fail-open path can re-admit an action on a draft that may in fact still be live. A clean absent lock still reads dormant; only an unreadable lock takes the reopened error path below.

**Crash never blocks.** An ungraceful death of the holder releases nothing and needs to release nothing: the recorded host process is now dead, so the next pre-flight reads the lock as stale and the next `acquire` simply overwrites it.

## Resume point

Before prompting, gather context for an informed choice. The newer of the canonical artifact and the working-draft cache is the actual resume point:

```bash
SPEC_ID="<from allocator>"
MAIN_ROOT="$(bash .gaia/scripts/main-root-lib.sh)"
SPEC_PATH="${MAIN_ROOT}/.gaia/local/specs/${SPEC_ID}/SPEC.md"
DRAFT_PATH=".gaia/local/cache/draft-${SPEC_ID}.md"
if [[ -f "$DRAFT_PATH" && "$DRAFT_PATH" -nt "$SPEC_PATH" ]]; then
  WORKING="$DRAFT_PATH"
else
  WORKING="$SPEC_PATH"
fi
```

The two halves of that comparison live in different trees on purpose: the canonical artifact is main-anchored (state registry `specs-main`), so `SPEC_PATH` resolves main, while the working draft is per-tree and stays in the acting worktree where the authoring session wrote it. The Operational-primitives contract in `spec.md` applies here as everywhere: an empty `MAIN_ROOT` stops this step, because comparing against a relative path would silently make the draft look newer.

## Live-session check

Before presenting the resume choice, check whether the draft is being authored live in another session right now (interactive only; auto mode already skips this entire resume prompt per step 2's auto-mode exception in `spec.md`, so it never computes `LOCK_STATUS`):

```bash
LOCK_STATUS="$(bash .gaia/scripts/spec/spec-session-lock.sh status "$PWD" "$SPEC_ID" 2>/dev/null || echo dormant)"
```

`LOCK_STATUS` branches the pre-flight prompt three ways:

- **`live`.** SPEC-NNN is open in another session, being authored live right now. Present a reframed `AskUserQuestion` instead of the usual Resume-first prompt:
  - question: `"SPEC-NNN is open in another session. Start a new SPEC, or use a guarded override to resume or discard the live draft anyway?"`
  - header: `"Live session"`
  - options:
    - `{ label: "Start new (Recommended)", description: "Begin a fresh SPEC; SPEC-NNN stays open in the other session." }`
    - `{ label: "Override: resume SPEC-NNN anyway", description: "This draft is being authored in another session; proceeding may clobber or delete live work. Force-reclaims the lock and resumes." }`
    - `{ label: "Override: discard SPEC-NNN anyway", description: "This draft is being authored in another session; proceeding may clobber or delete live work. Releases the lock and deletes the draft cache." }`

  Resume and Discard are not offered as unguarded actions for a live draft; the human must explicitly pick a guarded override to touch it. On `Override: resume SPEC-NNN anyway`, run `bash .gaia/scripts/spec/spec-session-lock.sh acquire --override "$PWD" "$SPEC_ID" || true` (force-reclaims the live foreign lock for this human-consented session), then proceed straight into the Resume flow below, **skipping** its TOCTOU re-verify (that guard exists for the default dormant Resume and would bounce this override straight back to Start new, making it a dead button). On `Override: discard SPEC-NNN anyway`, run the discard handler below (which releases the lock) and continue exactly as that handler does.
- **`error`.** The lock could not be read (missing `jq`, invalid JSON, or another lock-subsystem error) and may in fact belong to a live session. Present the existing three-option prompt, Resume / Start new / Discard, but with **Start new as the recommended default** and a warning, in place of the dormant branch's Resume-first default:
  - question: `"SPEC-NNN's session lock could not be read and may belong to a live session. Start new is recommended; resume or discard only if you know it's safe."`
  - header: `"Existing SPEC"`
  - options:
    - `{ label: "Start new (Recommended)", description: "Begin a fresh SPEC; SPEC-NNN remains open." }`
    - `{ label: "Resume SPEC-NNN", description: "Continue from the latest draft. The lock could not be verified, resume only if you know no other session is authoring it." }`
    - `{ label: "Discard SPEC-NNN draft cache", description: "Remove the working-draft cache. The lock could not be verified, discard only if you know no other session is authoring it." }`

  When the lock is unreadable, the pre-flight recommends Start new and warns, without surfacing the raw lock-subsystem error text to the user: an unreadable lock may in fact belong to a live session, so the accepted fail-open tradeoff here is availability over safety, not a promise that the draft is dormant. A clean "no lock file" still reads `dormant` below, and Resume/Discard remain reachable here (unlike the `live` branch above), just no longer the recommended default.
- **`dormant`.** The Resume-first prompt below fires unchanged; the lock does not affect it.

## Resume, start new, or discard

Read `$WORKING` and extract: intent first line, UAT count, frontmatter `updated` timestamp (or filesystem mtime if absent). Surface via `AskUserQuestion`:

- question: `"SPEC-NNN in progress (last touched <updated>, <UAT count> UATs drafted): \"<intent first line>\". Resume, start new, or discard?"`
- header: `"Existing SPEC"`
- options:
  - `{ label: "Resume SPEC-NNN (Recommended)", description: "Continue from the latest draft (working cache preferred over canonical if newer)." }`
  - `{ label: "Start new", description: "Begin a fresh SPEC; SPEC-NNN remains open." }`
  - `{ label: "Discard SPEC-NNN draft cache", description: "Remove the working-draft cache (before step 9 this draft cache is the only authored copy, so discarding it removes the draft). Confirm before deleting." }`

Honor the user's choice. Never silently overwrite, never silently start new.

- **Resume:** load `$WORKING` into the working draft, initialize the session-shape cache per its operational primitive in `spec.md` (write only if absent, the original `start_at` survives across resumes), and pick up at the right step (skip earlier steps that are already done):
  - If `.gaia/local/cache/gate1-<spec_id>.json` does NOT exist → resume at step 4 (gate 1).
  - If gate-1 cache exists AND the draft has any `clarifications.pending[]` entries → resume at step 6.
  - If gate-1 cache exists AND no pending clarifications → resume at step 8 (gate 2).
  - Step 3 (initial draft) is always skipped on resume.
  - Never re-snapshot the gate-1 cache; its purpose is immutable drift detection.

  Before continuing, re-verify the lock: a live foreign lock may have appeared in the window between the pre-flight `status` check above and this Resume selection.

  ```bash
  RECHECK_STATUS="$(bash .gaia/scripts/spec/spec-session-lock.sh status "$PWD" "$SPEC_ID" 2>/dev/null || echo dormant)"
  if [ "$RECHECK_STATUS" != "live" ]; then
    bash .gaia/scripts/spec/spec-session-lock.sh acquire "$PWD" "$SPEC_ID"
    ACQUIRE_STATUS=$?
  else
    ACQUIRE_STATUS=3
  fi
  ```

  If `RECHECK_STATUS` is `live`, or `acquire` exits `3` (a live foreign lock won the race between the recheck and this acquire), warn the user that SPEC-NNN is now open in another session and fall back to Start new below instead of proceeding with Resume. Any other non-zero exit from `acquire` is not a signal to stop, `acquire` only refuses via exit `3`, so Resume proceeds normally on every other outcome. This exclusive-create-plus-re-verify sequence is what closes the TOCTOU window between the pre-flight check and the user's selection.
- **Start new:** continue with a fresh allocation (Step 3 onward). The draft SPEC remains untouched. Initialize the session-shape cache per the operational primitive once the new `spec_id` is known (step 3).
- **Discard SPEC-NNN draft cache:** confirm via a follow-up `AskUserQuestion` (`"Delete the draft cache for SPEC-NNN? (Before the step-9 save this is the only authored copy; after it, the saved SPEC in the main-anchored SPEC folder remains.)"` with options `Yes, delete` / `Cancel`). On confirm, `rm -f "$DRAFT_PATH" .gaia/local/cache/spec-session-${SPEC_ID}.json .gaia/local/cache/gate1-${SPEC_ID}.json .gaia/local/cache/spec-session-${SPEC_ID}.lock` (**Release the session lock (step-2 discard)**, alongside the other draft-cache files) and, separately (an `rm -f` cannot delete a directory), `rm -rf .gaia/local/cache/audit-${SPEC_ID}/`, then continue with a fresh allocation. Note: this deletes only the draft cache; the SPEC's ledger row stays `status: draft`, so the allocator keeps flagging SPEC-NNN for resume until that row reaches a finalized status (out of scope for this step). This default (non-override) discard path is reached on a `dormant` verdict (unguarded) and, per the `error` branch above, on an unreadable lock that may belong to a live session (the accepted fail-open tradeoff described there). It is also reached on the explicit human `Override: discard SPEC-NNN anyway` for a `live` draft (above); "never acts on a live lock" holds only for this default, non-override path, it is not a blanket rule.

Control now returns to `spec.md`: step 3 on Start new or a confirmed discard, or the step the Resume branch picked above.
