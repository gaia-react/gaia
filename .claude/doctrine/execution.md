# Execution doctrine

This session is on a working branch or in a linked worktree, so it executes. The reasons behind each line, and the model table, live in `wiki/concepts/Workflow Doctrine.md`. When a running command defines its own contract (a plan orchestrator's per-phase commits and ledger, a debt fix's inline flow), its own contract governs where the two differ.

## Roles and git

- Read-only advisors investigate and write plan JSON; the main thread decides; executors edit files; a verifier checks executor output against the plan JSON before the Quality Gate.
- Only the main thread runs git that changes state: stage, commit, push, branch. Executors and advisors never run git that changes state; read-only queries such as `git rev-parse` are allowed.
- The main thread runs the Quality Gate (`wiki/decisions/Quality Gate.md`) once per commit: after that commit's executors finish and the verifier passes, and before the commit.

## Inline floor

Stay on the main thread when the work is small, tightly iterative (edit-run-fix), or needs the user. Sub-agents cannot prompt the user. Keep dispatch depth-1. The one exception is `audit-loop-unit`, which the main thread dispatches during the pre-merge audit: it is the sanctioned depth-2 orchestrator allowed to run state-changing git and the Quality Gate for its own rounds.

## Run folder

One per normalized branch key, `branch:` prefix dropped, slashes nesting: `branch:feat/9-sample` uses `.gaia/local/runs/feat/9-sample/`; a detached HEAD uses `.gaia/local/runs/session-<session id>/`. `runs/` is registered in `.gaia/state-registry.json`. It holds:

- `STATE.md`: Facts, a Status checklist recording each dispatch's expected artifact count, and one `NEXT:` line. At most 4 KB, rewritten in place.
- One JSON artifact per dispatch, named `<role>-<round>-<slug>.json`.
- `log.md`, append-only. Append only with Bash (`printf '...\n' >> <abs path>/log.md`), never Edit or Write, so appending never loads it.

In a linked worktree, `.gaia/local` resolves into the shared main checkout: write the run-folder files, and append `log.md`, with Bash at the main checkout's absolute path, then read them back; never through Edit or Write there.

## Resume

Read `STATE.md` and list the artifacts. Never read `log.md`. Re-dispatch any dispatch whose artifact is missing. If `STATE.md` is over 4 KB, compact it before continuing.

## Initiative linking and research

Once per branch, unless the branch name already derives the issue edge, link the initiative: `bash .gaia/scripts/usage.sh link branch:<normalized> research:<topic>-<date>` (or `issue:<n>`). The key line above this doctrine carries the concrete command for the current key.

Every worktree shares one `.gaia/local`, so run folders are keyed by branch and never shared. A research Write binds only when made with the Write tool to the main checkout's absolute `.gaia/local/research/<topic>-<date>/...` path; a worktree-relative or symlinked path does not bind. Research done with Edit or Bash binds with `bash .gaia/scripts/usage.sh declare research:<topic>-<date>`. A binding re-keys only `session:` spend.
