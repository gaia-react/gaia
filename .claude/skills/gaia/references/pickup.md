# /gaia-pickup

Rebuild "where did we leave off" at session start and suggest the next action.

## Steps

### 0. Sweep (defensive)

Only one handoff should ever exist. If `ls .gaia/local/handoff/HANDOFF-*.md` returns more than one, keep the newest (`ls -t .gaia/local/handoff/HANDOFF-*.md | head -1`) and delete the rest. This self-heals any pile-up left by a crash between writing a handoff and clearing the prior one.

### 1. Locate

Find the most recent handoff:

- `ls -t .gaia/local/handoff/HANDOFF-*.md | head -1`
- If none exists, fall back to `wiki/hot.md` (already loaded) and report "No handoff found, resuming from hot cache."

### 2. Read

Read the handoff file in full. Also run in parallel:

- `git rev-parse --abbrev-ref HEAD` + `git status --short` + `git log -1 --oneline`

Compare the handoff's stated branch/commit against current git state. Flag drift (new commits, different branch, dirty files), the handoff may be stale.

### 3. Report

Give the user a tight status block (≤15 lines):

```
Branch: {current} {(drift from handoff if any)}
Last handoff: {filename} ({date})
Context: {one-line from handoff}

State:
- {1–3 bullets on what's done / in-flight}

Open:
- {1–3 bullets on gaps or next actions}

Suggested next: {highest-priority action from handoff, or "confirm direction"}
```

Do **not** paste the whole handoff back, the user wrote it, they know the shape. Synthesize.

### 4. Resolve (never archive)

A handoff is consumed once the user acts. It is never moved or archived.

- **Happy path:** the handoff deletes itself. Its Teardown section instructs the working session to `rm` the file once the Next Actions are complete and verified, so there is nothing for pickup to do.
- **Stale re-pickup:** if the located handoff describes work that has already fully landed (its branch merged or deleted, its Next Actions all reflected in `git log`), delete it now with `rm .gaia/local/handoff/HANDOFF-*.md`, report "previous handoff's work has landed, cleared it", and resume from `wiki/hot.md`.
- **Still outstanding:** leave the file in place so an interruption stays recoverable, and resume the unfinished Next Actions.

Be aggressive: a handoff is one-and-done. Only one ever exists, and a finished one is deleted, not kept.

## Rules

- Hot cache (`wiki/hot.md`) auto-loads, don't re-read it unless the handoff is missing.
- If git state has diverged significantly from the handoff, say so explicitly before suggesting next actions.
- One handoff at a time. A new `/gaia-handoff` deletes the prior one; pickup's step 0 keeps at most one.
- Never archive. Deletion is the only terminal state. The handoff owns its happy-path teardown; pickup deletes only a fully-landed stale handoff.
- Leave an in-progress handoff in place so an interruption is recoverable. Do not move it.
