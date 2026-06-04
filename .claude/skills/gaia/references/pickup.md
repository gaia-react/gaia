# /gaia-pickup

Rebuild "where did we leave off" at session start and suggest the next action.

## Steps

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

### 4. Archive (after user confirms direction)

Once the user commits to a direction (picks an action, starts editing, or says "go"), move the consumed handoff to `.gaia/local/handoff/archive/` so it doesn't pollute future pickups. Create the dir if missing. Do not archive until work has actually begun.

## Rules

- Hot cache (`wiki/hot.md`) auto-loads, don't re-read it unless the handoff is missing.
- If git state has diverged significantly from the handoff, say so explicitly before suggesting next actions.
- Never archive a handoff until the user has acted on it, premature archive loses context on a context-break mid-pickup.
