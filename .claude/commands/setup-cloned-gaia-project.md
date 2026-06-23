---
name: setup-cloned-gaia-project
description: One-shot per-machine setup for a cloned GAIA project. Installs tools, plugins, spec-kit; bootstraps .env; opts into mentorship. Idempotent, safe to re-run.
---

Run this once per clone of a GAIA project. The maintainer who created the project ran `/gaia-init`, but per-machine state (Claude tool installs, plugin registrations, spec-kit runtime, mentorship opt-in, `.env`, statusline executable bit) does not travel with the repo, every developer who clones it needs their own pass.

The slash command name intentionally does NOT start with `gaia-` so it does not pollute the `/gaia` autocomplete namespace (those are reserved for the four user-invoked GAIA workflows).

## How to know if this needs to run

The statusline shows `Run /setup-cloned-gaia-project` when `.gaia/local/setup-state.json` is missing or its `completed_at` is null. The indicator takes precedence over `/update-deps` and `/update-gaia`, those become visible only after setup is finalized.

You can also check on demand: `.gaia/cli/gaia setup status` prints a human-readable summary; `--json` is the machine-readable shape.

## Idempotence contract

Each step records itself in `.gaia/local/setup-state.json` via `gaia setup mark-step <step>`. A step is skipped if already recorded. Re-running this command after a partial run resumes from the first pending step.

`gaia setup status --json` returns:

```json
{
  "complete": false,
  "started_at": "2026-05-07T12:00:00.000Z",
  "completed_at": null,
  "completed_steps": ["install-tools", "install-plugins"],
  "pending_steps": [
    "init-speckit",
    "chmod-statusline",
    "bootstrap-env",
    "mentorship-decision",
    "audit-mode-decision"
  ]
}
```

Read this once at the start. Skip any step in `completed_steps`.

## Step -1: Self-heal worktree symlinks

If this clone is being set up from a linked worktree (e.g. one created via `git worktree add` outside the Claude Code harness), the shared-state symlinks (`setup-state.json`, `.gaia/cache/`, `.gaia/local/audit/`) may not exist yet. Run the self-heal:

```bash
.gaia/cli/gaia setup link-worktree
```

In a main checkout, this command is a no-op (exits 0 with `not a linked worktree`). In a linked worktree without symlinks, it creates them and prints a one-line summary. In a linked worktree where pre-existing plain files conflict with the symlink targets, the plain files are backed up to `<path>.bak.<timestamp>` before the symlinks are created.

If the command exits non-zero (e.g. Windows symlink permission failure), HALT and surface the error to the user verbatim. They need to fix the underlying issue (typically: enable Windows Developer Mode) and re-run `/setup-cloned-gaia-project`.

This step is NOT recorded in `setup-state.json`, it's a prerequisite that runs every invocation. The CLI's own idempotence guarantees the no-op behavior on subsequent runs.

## Step 0: Ensure pnpm + node_modules

Tell the user: "Checking pnpm + node_modules…"

If `corepack` is available, run `corepack enable pnpm`. Otherwise `npm install -g pnpm`. If `node_modules/` does not exist at the project root, run `pnpm install`.

This step is NOT recorded in `setup-state.json`, pnpm + node_modules are baseline prerequisites; `pnpm install` is fast on a clean clone and fast-no-op when up to date.

## Step 0.5: GitHub CLI prerequisites

This step is NOT recorded in `setup-state.json`, it runs every invocation as a precondition. The check is advisory: warnings surface but do not halt setup, because a contributor may legitimately set up GAIA without gh wired up yet.

```bash
if ! command -v gh &>/dev/null; then
  echo "Warning: GitHub CLI ('gh') is not installed. The PR merge gate, /gaia-plan, and forensics workflows depend on it. Install: https://cli.github.com/" >&2
elif ! gh auth status &>/dev/null; then
  echo "Warning: GitHub CLI is not authenticated. Run: gh auth login" >&2
elif [ -f .github/workflows/forensics-triage.yml ] && gh repo view &>/dev/null; then
  if ! gh label list --limit 100 --json name 2>/dev/null \
      | jq -e '.[] | select(.name == "gaia-forensics")' >/dev/null; then
    echo "Warning: forensics-triage.yml is enabled but the 'gaia-forensics' label is missing on this repo. Ask a maintainer: gh label create gaia-forensics --color D93F0B --description 'Triggers autonomous forensics triage'" >&2
  fi
fi
```

Surface every warning to the user verbatim, then continue.

## Step 1: install-tools

Skip if `install-tools` is in `completed_steps`.

Three external tools require per-machine setup. The Serena MCP entry needs `uv` (Astral's Python toolchain runner).

- [React Doctor](https://github.com/millionco/react-doctor): `npx -y react-doctor@latest install --yes`
  Installs the `react-doctor` skill for detected agents (Claude Code included). Scans for React-specific issues; auto-runs after code edits in a `CLAUDECODE` environment and is invoked by the `code-review-audit` agent pre-merge.

- [Playwright CLI](https://github.com/microsoft/playwright-cli): `npm install -g @playwright/cli@latest`
  Installs the global `playwright-cli` binary the bundled skill shells out to. Without it the skill's `allowed-tools: Bash(playwright-cli:*)` directive resolves to nothing.

- [Serena](https://github.com/oraios/serena) MCP server: ensure `uv` first.

  ```bash
  if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  ```

  Verify with `uv --version`. If verification fails, halt with: `uv is required for GAIA. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh, then re-run /setup-cloned-gaia-project.`

  Then register Serena globally:

  ```bash
  claude mcp add serena -s user -- uvx --from git+https://github.com/oraios/serena@v1.2.0 serena start-mcp-server --open-web-dashboard false
  ```

  If the registration already exists (`claude mcp add` exits non-zero with a "name already exists" error), treat as success and continue.

After all three tools install successfully, run:

```bash
.gaia/cli/gaia setup mark-step install-tools
```

If any install fails, surface the error verbatim and halt. The user can re-run `/setup-cloned-gaia-project` after addressing the cause; this step will resume.

## Step 2: install-plugins

Skip if `install-plugins` is in `completed_steps`.

```bash
claude plugin install typescript-lsp@claude-plugins-official
claude plugin marketplace add AgriciDaniel/claude-obsidian
claude plugin install claude-obsidian@claude-obsidian-marketplace
```

If any of these fail, surface the error and halt. Already-installed plugins should be a no-op (the `claude plugin install` command treats this case gracefully).

After all three commands succeed, run:

```bash
.gaia/cli/gaia setup mark-step install-plugins
```

## Step 3: init-speckit

Skip if `init-speckit` is in `completed_steps`.

The GAIA `/gaia-spec` Socratic discovery workflow runs on top of [spec-kit](https://github.com/github/spec-kit). The repo already ships the GAIA extension at `.specify/extensions/gaia/` and the GAIA preset at `.specify/presets/gaia/`; they need spec-kit's runtime registered.

Pin spec-kit at the version declared in `.specify/extensions/gaia/extension.yml` `requires.speckit_version` floor.

```bash
SPECKIT_PIN="v0.8.5"
uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify init --here --ai claude --force
yes | uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify extension add --dev .specify/extensions/gaia
yes | uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify preset add --dev .specify/presets/gaia
```

If any step fails, surface verbatim and halt. After all three succeed:

```bash
.gaia/cli/gaia setup mark-step init-speckit
```

## Step 4: chmod-statusline

Skip if `chmod-statusline` is in `completed_steps`.

The statusline command in `.claude/settings.json` points at `.gaia/statusline/*.sh`; the executable bit is normally tracked by git but can be lost on cross-platform clones.

```bash
chmod +x .gaia/statusline/*.sh
.gaia/cli/gaia setup mark-step chmod-statusline
```

## Step 5: bootstrap-env

Skip if `bootstrap-env` is in `completed_steps`.

`.env` is gitignored. If `.env` does not exist and `.env.example` does, copy:

```bash
cp .env.example .env
```

If neither exists, that's fine, the project may not use `.env`. After the copy (or no-op):

```bash
.gaia/cli/gaia setup mark-step bootstrap-env
```

## Step 6: mentorship-decision

Skip if `mentorship-decision` is in `completed_steps`.

If `.gaia/local/mentorship.json` already exists with a non-null `enabled` field, the user has already made a decision (e.g. via `/gaia-init` on a clone the maintainer set up, or via `gaia mentorship enable`/`disable` directly). Just record the step and move on:

```bash
if [ -f .gaia/local/mentorship.json ] && [ "$(jq -r '.enabled // "null"' .gaia/local/mentorship.json 2>/dev/null)" != "null" ]; then
  .gaia/cli/gaia setup mark-step mentorship-decision
  # Continue to Step 7.
fi
```

Otherwise, tell the user (in their language, detected from earlier context): "GAIA includes an optional mentorship layer that learns how you work and adapts in-session, fully on your machine, never sent off it. Let's set the default."

Show the privacy explainer (this block stays English regardless of UI language, it's the canonical contract):

> **GAIA's mentorship layer (experimental, optional)**
>
> GAIA can quietly learn how you work, which kinds of specs you find easy or hard, where you tend to need more context, and adapt in-session to help you ship better specs and code over time.
>
> **What it observes:** which kinds of specs you find easy or hard, where you need more context, when you amend specs after closing.
>
> **What it never observes:** when you work, how fast you type, what you read, your mood, your behavior outside GAIA's workflow.
>
> **Where it lives:** on your machine only, in your Claude project folder. Never in your project's git. Never sent to a server unless you opt into anonymous fine-tuning analytics (which comes with mentorship).
>
> **Read more:** https://gaiareact.com/mentorship

Use AskUserQuestion with these three options in this exact order:

- **Not now (you can enable later if you like)** (Recommended), `mentorship.enabled = false`, `analytics.enabled = false`.
- **Yes, enable mentorship + anonymous analytics**: `mentorship.enabled = true`, `analytics.enabled = true`. Provision the mentorship tree.
- **Tell me more before I decide**: Q&A loop until the user picks one of the first two.

### Apply the answer

**On "Not now":**

```bash
.gaia/cli/gaia mentorship _internal-write-config --enabled false --analytics false --decided-via gaia-init
```

**On "Yes, enable":**

```bash
.gaia/cli/gaia mentorship _internal-write-config --enabled true --analytics true --decided-via gaia-init
.gaia/cli/gaia mentorship _internal-provision-dirs
```

`_internal-write-config` applies the chosen settings; per-machine state follows from the flags.

After the chosen branch executes:

```bash
.gaia/cli/gaia setup mark-step mentorship-decision
```

## Step 6.5: audit-mode-decision

Skip if `audit-mode-decision` is in `completed_steps`.

This step lets you choose who runs your `code-review-audit` at merge time, CI (the default) or your local machine. It only applies once the project has CI wired up. Gate it:

- If `.gaia/audit-ci.yml` does not exist (CI not configured yet), skip silently and record the step:

  ```bash
  if [ ! -f .gaia/audit-ci.yml ]; then
    .gaia/cli/gaia setup mark-step audit-mode-decision
    # Continue to Step 7.
  fi
  ```

- If `gh` is not authenticated (cannot resolve your login), skip with a one-line note and record the step, you can re-decide later by re-running this command after `gh auth login`:

  ```bash
  if ! gh auth status &>/dev/null; then
    echo "Skipping audit-mode choice: gh is not authenticated. Run 'gh auth login' and re-run /setup-cloned-gaia-project to choose." >&2
    .gaia/cli/gaia setup mark-step audit-mode-decision
    # Continue to Step 7.
  fi
  ```

Otherwise, resolve your GitHub login and read the team default for context:

```bash
gh api user --jq .login
```

Use AskUserQuestion with these two options in this exact order:

> Who runs your code-review-audit at merge time?
>
> - **CI (default).** CI audits your PRs; you wait for the GAIA-Audit check. Today's behavior.
> - **Locally.** Your audit runs at merge time when you ask Claude to merge, streaming, faster, incremental. CI stands down for you.

### Apply the answer

On a choice, append your `<login>=<mode>` pair to `audit_authors` in `.gaia/audit-ci.yml` via the append helper (it reads the existing value, drops any prior entry for your own login, and rewrites the line in place, so it never clobbers a teammate's entry):

```bash
.gaia/scripts/append-audit-author.sh "<your-login>" "<ci|local>"
```

Then tell the developer **explicitly** (do not paraphrase away these obligations):

- This is a **committed** change to `.gaia/audit-ci.yml`, not machine-local state. Other developers see it.
- It lands via a **one-line PR**: the only change is your `audit_authors` pair.
- That PR clears the merge gate through BOTH the merge-hook out-of-scope bypass AND CI's out-of-scope `GAIA-Audit` success stamp, a `.gaia`-only diff is out of audit scope, so neither producer runs a full audit on it. This is **contingent on an empty `gate_label`** in `.gaia/audit-ci.yml`: a non-empty `gate_label` gates the CI audit off the label instead, which changes the path. If `gate_label` is set, expect the audit to run on your one-line PR per the label rule.

Do NOT auto-commit or auto-open the PR for the developer. Guide them to review the diff, then commit and open the one-line PR themselves:

```bash
git checkout -b chore/audit-mode-<your-login>
git add .gaia/audit-ci.yml
git commit -m "chore(audit): set <your-login> audit mode to <ci|local>"
git push -u origin chore/audit-mode-<your-login>
gh pr create --fill
```

After the chosen branch executes (or the gated skip):

```bash
.gaia/cli/gaia setup mark-step audit-mode-decision
```

## Step 7: Finalize

After every step records as complete, run:

```bash
.gaia/cli/gaia setup finalize
```

The CLI refuses to finalize while any step is pending. If the maintainer initialized this clone manually before `/setup-cloned-gaia-project` existed, they can pass `--force` to mark the state as complete without running through the steps.

Then output (in the user's language): "Per-machine GAIA setup complete. Restart Claude Code so the new plugin and skill state are picked up. The statusline will now surface `/update-deps` and `/update-gaia` indicators when applicable."

## On failure: resume

Every step is idempotent and recorded individually. After fixing any failure, simply re-run `/setup-cloned-gaia-project`, completed steps are detected via `gaia setup status --json` and skipped automatically.
