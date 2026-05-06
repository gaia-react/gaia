# /gaia plan

Plan a complex feature using the task orchestration pattern. Do not implement anything.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `plan`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want me to orchestrate?"** and wait for the response before continuing.

### 2. Check model

Check your current model from session context.

- If you are on Opus, skip to step 3.
- If not, call `AskUserQuestion` with:
  - question: `"You're on [model name]. Use Opus for planning?"`
  - header: `"Model"`
  - options:
    - `{ label: "Use Opus (Recommended)", description: "Spawn the planning agent on Opus 4.7 for higher-quality plans." }`
    - `{ label: "Use [model name]", description: "Keep the current model." }`
  - If user picks option 1: spawn the agent with `model: opus`.
  - If user picks option 2: spawn without a model override (inherit current).

### 3. Spawn planning agent

Launch a `general-purpose` Agent with the model determined above and this prompt:

---

You are planning a feature using task orchestration. Do not implement anything.

**You cannot Write files.** The Claude Code harness blocks Write for research-classified subagents. Do not attempt Write — it will fail and waste tokens. Investigate, then return your output as structured text. The parent will write the files verbatim.

**Output format (required):**

    ## File: /absolute/path/to/file.md

    ```markdown
    <verbatim file content>
    ```

Repeat the `## File:` heading + fenced block for each file. Use the language tag matching the file extension (`markdown` for `.md`).

**Feature:** {feature description from step 1}

First, read `wiki/concepts/Task Orchestration.md`.

Then specify the following files for the parent to write under `.gaia/local/plans/{slug}/` where `{slug}` is a short kebab-case slug derived from the feature description:

1. **One task doc per parallel workstream** — name each `task-{name}.md`. Each must be fully self-contained for a fresh-context sub-agent and include:
   - Context and motivation
   - Interface contracts (types, function signatures, file exports)
   - Files to touch (with line-range hints where possible)
   - Acceptance criteria (concrete and testable)
   - Dependencies on other tasks in this plan

2. **`README.md`** — task graph showing phases, which tasks run in parallel within each phase, and the frozen interface contracts shared across tasks.

3. **`ORCHESTRATOR.md`** — instructions for running the plan. Must cover:
   - **Pre-flight branch policy.** Check the current branch. If HEAD is on `main`/`master`, the orchestrator ASKS the user whether to (a) create a feature branch in place or (b) create a git worktree, then acts on the answer. If HEAD is on any other branch, assume it is the work branch and proceed.
   - **Phase order** with per-phase quality gates (`pnpm typecheck && pnpm lint`).
   - **Sub-agent invocation:** the verbatim prompt template for each task sub-agent. Sub-agents do NOT commit, push, or open/update the PR — they only edit files and report. The orchestrator owns all git operations.
   - **Orchestrator-owned git flow.** After each phase that produces changes (and only once the quality gate is clean), the orchestrator stages, commits with a meaningful message, and pushes. The orchestrator opens the PR after the first phase's commit lands on the remote (using `gh pr create`) and updates it with subsequent commits. Never commit a broken state.
   - **Stop conditions.** On any sub-agent failure or quality-gate failure: STOP and surface to the user. Do not "fix and continue", do not commit, do not push.
   - **Final summary.** After all implementation phases pass and the final commit is pushed, before awaiting merge confirmation, print a brief summary to the user: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, and quality-gate status. Keep it tight — a few lines, not a recap of every change.
   - **Final self-cleanup phase (last step before merge).** After all implementation phases pass and the user has reviewed the PR and confirmed it is ready to merge, the orchestrator deletes its own plan folder (`rm -rf .gaia/local/plans/{slug}/`, absolute path) so scaffolding does not persist locally. Then check `git check-ignore .gaia/local/plans/{slug}/` — if `.gaia/local/plans/` is gitignored (the GAIA default), the deletion is invisible to git: skip the commit and report "plan folder removed locally; gitignored, no commit needed." If the path is tracked, commit and push the deletion as the final commit on the PR. If the user explicitly asks to keep the plan folder for archival, the orchestrator skips the deletion and reports.

4. **`KICKOFF.md`** — the orchestrator's kickoff prompt itself, ready to be read and executed verbatim. The file is the prompt — no preamble, no "copy and paste below" instruction, no surrounding commentary, no `---` separators framing the prompt as a quoted block. The opening line addresses the orchestrator directly (e.g. "You are the orchestrator for the {feature} plan…"). Must be fully self-contained with no assumed context: absolute paths to `README.md` and `ORCHESTRATOR.md`, the goal, hard rules, and the execution outline.

Return all file specifications using the output format above. End with the absolute path to `KICKOFF.md` so the parent knows which path to surface to the user.

---

### 3.5. Write the plan files

Parse the agent's structured output. For each `## File: <absolute path>` heading followed by a fenced block, Write the fenced content verbatim to that path. Create the parent directory first via `mkdir -p` if needed.

Use the Write tool directly — the permission scope (`Write(.gaia/local/plans/**)`) covers it. Verify all files exist before proceeding to step 4.

### 4. Report to user

Output a short summary of what's in `.gaia/local/plans/{slug}/`, then emit the copy-paste prompt the user drops into a fresh Claude Code session to start the orchestrator cold.

The prompt is a single line, exactly:

```
Read /Users/.../absolute/path/to/.gaia/local/plans/{slug}/KICKOFF.md and execute it.
```

Use the absolute path to the `KICKOFF.md` you just created. Do not include any other instruction — the orchestrator's behavior lives in `KICKOFF.md`.

**Try to copy the prompt to the system clipboard** with the first available tool. Probe in this order — the first match wins; if none exist, skip silently:

```bash
PROMPT='Read {absolute path to KICKOFF.md} and execute it.'
COPIED=0
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | pbcopy && COPIED=1
elif command -v wl-copy >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | wl-copy && COPIED=1
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | xclip -selection clipboard && COPIED=1
elif command -v xsel >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | xsel --clipboard --input && COPIED=1
elif command -v clip.exe >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | clip.exe && COPIED=1
elif command -v clip >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | clip && COPIED=1
fi
```

**Always print the prompt as a fenced code block**, regardless of whether the copy succeeded — the user may want to verify or copy manually.

Then print one trailing line, conditional on `$COPIED`:

- Copy succeeded (`COPIED=1`): `Prompt copied to clipboard. Type /clear then paste.`
- No tool found (`COPIED=0`): `Type /clear and paste the prompt above.`
