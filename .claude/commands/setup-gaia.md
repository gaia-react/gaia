---
name: setup-gaia
description: Single post-init onboarding command; detects situation, runs only owed phases; safe to re-run. --reconfigure rotates token and re-selects tools.
argument-hint: [--reconfigure]
---

Run this once after `/gaia-init`, and re-run it any time. `/setup-gaia` is the single onboarding command for a GAIA project. It detects the situation and runs only the phases this clone actually owes:

- **Per-machine work** every clone needs (tool installs, plugins, spec-kit runtime, statusline bit, `.env`, mentorship).
- **GitHub repository provisioning** (create / adopt / manual, private by default).
- **CI wiring** when a repo exists and the runner is a repo admin.
- **Your per-developer audit-mode choice** (CI vs local at merge time).

It is safe for **any developer** to run at any time. A plain (no-flag) re-run on a fully provisioned project prints the already-configured line and mutates nothing: it never re-provisions the repo, rotates the token, or changes branch protection. Pass `--reconfigure` to rotate the bot token and re-select which tools run on cron.

The slash command name intentionally does NOT start with `gaia-` so it does not pollute the `/gaia` autocomplete namespace (those are reserved for the four user-invoked GAIA workflows).

## Argument parse

Parse `$ARGUMENTS` for the `--reconfigure` flag. Cache the boolean as `RECONFIGURE`.

## Phase 0: Prerequisites (every invocation, never skipped)

These run on every invocation and record no setup-state step. They sit outside the per-machine skip gate.

### 0a. Self-heal worktree symlinks

If this clone is being set up from a linked worktree (e.g. one created via `git worktree add` outside the Claude Code harness), the shared-state symlinks (`setup-state.json`, `.gaia/local/cache/shared/`, `.gaia/local/audit/`) may not exist yet. Run the self-heal:

```bash
.gaia/cli/gaia setup link-worktree
```

In a main checkout this is a no-op (exits 0 with `not a linked worktree`). In a linked worktree without symlinks it creates them; where pre-existing plain files conflict with the symlink targets, they are backed up to `<path>.bak.<timestamp>` first.

If the command exits non-zero (e.g. Windows symlink permission failure), HALT and surface the error verbatim. The user must fix the underlying issue (typically: enable Windows Developer Mode) and re-run `/setup-gaia`.

### 0b. Ensure pnpm + node_modules

Tell the user: "Checking pnpm + node_modules…"

If `corepack` is available, run `corepack enable pnpm`. Otherwise `npm install -g pnpm`. If `node_modules/` does not exist at the project root, run `pnpm install`. `pnpm install` is fast on a clean clone and fast-no-op when up to date.

### 0c. GitHub CLI prerequisites (advisory)

Advisory only: warnings surface but do not halt setup, because a contributor may legitimately set up GAIA without `gh` wired up yet.

```bash
if ! command -v gh &>/dev/null; then
  echo "Warning: GitHub CLI ('gh') is not installed. The PR merge gate, /gaia-plan, and forensics workflows depend on it. Install: https://cli.github.com/" >&2
elif ! gh auth status &>/dev/null; then
  echo "Warning: GitHub CLI is not authenticated. Run: gh auth login" >&2
elif [ -f .github/workflows/forensics-triage.yml ] && gh repo view &>/dev/null; then
  if ! gh label list --limit 100 --json name 2>/dev/null \
      | jq -e '.[] | select(.name == "gaia-forensics")' >/dev/null; then
    echo "Warning: forensics-triage.yml is enabled but the 'gaia-forensics' label is missing on this repo. Ask a maintainer to run .github/forensics/bootstrap-labels.sh, which creates the 'gaia-forensics' label with the canonical color and description." >&2
  fi
fi
```

Surface every warning verbatim, then continue.

## Phase 1: Detect situation

Classify the clone by reading state, gating on **file existence, not key presence**. Every input is optional; a missing file is a signal, not an error.

```bash
.gaia/cli/gaia setup status --json
.gaia/cli/gaia setup-ci status --json
```

- `.gaia/local/setup-state.json` (per-machine, gitignored). From `setup status --json`, cache `completed_at` and `completed_steps`.
- `.gaia/automation.json` (committed when present). From `setup-ci status --json`, cache `configured`, `setup_complete`, `setup_opted_out`, `nudge_dismissed`, `tools_enabled`.
- `.gaia/audit-ci.yml` (committed when present): gates Phase 5.

Then read the **repo / branch / push / required-check** state, not merely whether an `origin` remote exists:

```bash
.gaia/cli/gaia setup-ci detect-remote --json
```

Cache `found`, `host`, `owner`, `repo`. When `found` and `host == "github.com"`, probe the live repo state (each degrades to "absent" on a non-zero exit):

```bash
gh api "repos/<owner>/<repo>" --jq '.default_branch' 2>/dev/null                                              # repo exists + its default branch
gh api "repos/<owner>/<repo>/branches/<default-branch>" --jq '.name' 2>/dev/null                              # default branch has been pushed
gh api "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null  # GAIA-Audit registered?
```

Classify into one of: **fresh clone**, **first adopter**, **partial re-run**, **provisioned**, or **admin-teammate-on-unwired-clone**.

- A clone with a github `origin` but **no** `.gaia/automation.json` (init predates the CI-intent record, or a non-standard clone) MUST classify from **file existence**. Do NOT print the misleading `GAIA CI is not configured for this repo. Run /gaia-init first.` guidance from `setup-ci status`'s `configured: false` branch: the per-machine and CI-intent work can still proceed. Offer the teammate-clone per-machine + CI-intent path instead.
- Detect an **incomplete provisioning** (repo created, `origin` added, but the default-branch push or the `GAIA-Audit` registration did not complete) from the repo/branch/push/required-check probes above, and complete only the owed steps. Because `gh repo create` adds `origin` **before** the push, `origin`-presence alone would wedge a failed-push state; judge from actual push/registration state.

The classification only routes the phases below; each phase re-checks its own completion and no-ops when already done, so misclassification cannot corrupt state.

## Phase 2: Per-machine setup (skip if setup-state finalized)

If `setup status --json` reports a non-null `completed_at`, this whole phase no-ops **except for the mentorship and sandbox decisions below** (a first adopter finished per-machine work inside `/gaia-init`, so the repo prompt in Phase 3 is their first real interaction, with no tool-install log lines before it, and the recorded per-machine steps are unchanged). Otherwise run Steps 1–6 below in order. Each records itself via `.gaia/cli/gaia setup mark-step <step>` and is skipped when already in `completed_steps`.

**Mentorship decision (runs even when `completed_at` is non-null).** This clause surfaces the mentorship opt-in whenever no decision has been recorded (`mentorship.json` absent or `enabled: null`, the pre-decision default treated as off). It runs even when `completed_at` is non-null because Phase 2 otherwise short-circuits once per-machine setup is complete and would skip the opt-in. So before falling through to Phase 3, always evaluate this:

```bash
DECIDED="null"
if [ -f .gaia/local/mentorship.json ]; then
  DECIDED="$(jq -r 'if .enabled == null then "null" else (.enabled | tostring) end' .gaia/local/mentorship.json 2>/dev/null)"
  # An unreadable/corrupt config yields empty; treat that as undecided so the opt-in re-runs and rewrites a clean file.
  [ -z "$DECIDED" ] && DECIDED="null"
fi
```

If `DECIDED` is `null` (file absent, `enabled: null`, or an unreadable config), run **Step 6's opt-in body** now, the prompt-through-write sub-block: the privacy explainer, the AskUserQuestion, the chosen `_internal-write-config` branch, and its `mark-step mentorship-decision` (Step 6's lines starting at the user-facing prompt, not its up-front skip guard), regardless of `completed_at` or whether `mentorship-decision` is already in `completed_steps`; `mentorship.json` is the source of truth here. If `DECIDED` is `true` or `false`, the decision stands and this is a no-op. (When `completed_at` is null, this clause fires first; Step 6's own guard then short-circuits its in-sequence run.)

**Sandbox decision (runs even when `completed_at` is non-null).** This clause surfaces the OS-level Bash sandbox enablement decision whenever no per-machine resolution has been recorded. It runs even when `completed_at` is non-null for the same reason as the mentorship clause above: Phase 2 otherwise short-circuits once per-machine setup is complete and would skip the decision. So before falling through to Phase 3, always evaluate this:

```bash
RESOLVED="$(.gaia/cli/gaia sandbox status --json 2>/dev/null | jq -r '.resolved // false')"
```

If `RESOLVED` is `true` and `RECONFIGURE` is NOT set, the decision stands: do NOT re-prompt and do NOT flip the settled value. Skip to the rest of setup. Otherwise (marker absent, or `--reconfigure`), run the decision body below. This clause is gated on the `gaia sandbox status` marker, never on a `SETUP_STEPS` value: no `SETUP_STEPS` entry is added and `gaia setup mark-step` is never called for the sandbox decision; `.gaia/local/sandbox.json` is the only tracking.

1. **Read the recommendation.** Absent file, absent key, or an unreadable config all mean "no recommendation", so the default is off:

   ```bash
   RECOMMENDED="$(jq -r '.sandbox_recommended // false' .gaia/automation.json 2>/dev/null || echo false)"
   ```

2. **Classify capability** via the injectable CLI (falls back to a real host probe when flags are omitted):

   ```bash
   .gaia/cli/gaia sandbox detect --json
   ```

   Cache `capability`, `installCommand`, `reason` from the JSON.

3. **Branch on capability.** Never half-enable: the sandbox is either fully applied or left off.
   - `unsupported` (native Windows or WSL1): do NOT enable. Tell the developer plainly that Claude Code's OS-level sandbox is unavailable on this machine (use `reason`) and point them to WSL2 instead. Record the outcome and skip the prompt:

     ```bash
     .gaia/cli/gaia sandbox record --outcome incapable --capability unsupported
     ```

   - `needs-deps` (Linux/WSL2 missing bubblewrap/socat): do NOT enable, do NOT half-enable. Print the concrete `installCommand` (plus the Fedora form carried in `reason`) and tell the developer the sandbox stays off until those are installed and `/setup-gaia` is re-run. Record the outcome and skip the prompt:

     ```bash
     .gaia/cli/gaia sandbox record --outcome incapable --capability needs-deps
     ```

   - `ready` (macOS Seatbelt, or Linux/WSL2 with both deps present): run the single prompt below.

4. **The single informed prompt** (`ready` only). Use AskUserQuestion exactly once, there is no promptless auto-enable branch anywhere in this file. Its default option tracks `RECOMMENDED`: when `true`, "Enable the sandbox" is Recommended; when `false` (including when nothing was recommended), "Don't enable" is Recommended.

   > Enable Claude Code's OS-level Bash sandbox on this machine? It sandboxes Bash commands and their child processes, but it can break local tools: `docker`, `gh`, `terraform`, and other commands that need network or host access may fail or need allowlisting. Your project owner {recommends / does not recommend} it; each machine decides for itself.
   >
   > - **Enable the sandbox** / **Don't enable** (Recommended tracks the owner's recommendation, default off when none)

   On **enable**:

   ```bash
   REGISTRY="$(npm config get registry 2>/dev/null)"
   DOCKER_PRESENT=false; command -v docker >/dev/null 2>&1 && DOCKER_PRESENT=true
   .gaia/cli/gaia sandbox apply --registry "$REGISTRY" --docker-present "$DOCKER_PRESENT" --capability ready
   ```

   `apply` deep-merges the minimal seed into `.claude/settings.local.json` (gitignored) and writes the `enabled` marker. Then print the honesty message below. Tell the developer the enable takes effect on the NEXT Claude Code session (this setup run stays unsandboxed), matching the existing "restart Claude Code" closing line in Phase 6.

   On **don't enable**:

   ```bash
   .gaia/cli/gaia sandbox record --outcome declined --capability ready
   ```

**Sandbox honesty message.** Print this on the enable path above:

> Note: enabling the sandbox alone does not protect .env. The sandbox's default read policy is permissive (it still reads ~/.aws, ~/.ssh, .env). What protects `.env` is GAIA's existing `Read(.env)` / `Edit(.env)` deny rules merging into the sandbox boundary, which reaches subprocesses spawned by sandboxed Bash. It does NOT cover the `.env.local` / `.env.production` variant family (delivered by a hook, which does not merge), NOT MCP shell execution, and NOT a `docker *`-excluded command that runs outside the sandbox. The same merged deny also blocks the app's own `.env` reads under Claude-run tooling (Vite, tests). And if bubblewrap/socat later goes missing, an enabled machine degrades to unsandboxed by default.
>
> The minimal seed itself only adds the registry host to `allowedDomains` and, when docker is present, a `docker *` exclusion. It still leaves `gh`/git-over-https, `uvx`, `curl`, and claude plugin installs BLOCKED until you allowlist them yourself.

### Step 1: install-tools

Skip if `install-tools` is in `completed_steps`.

Three external tools require per-machine setup. The Serena MCP entry needs `uv` (Astral's Python toolchain runner).

- [React Doctor](https://github.com/millionco/react-doctor): `npx -y react-doctor@latest install --yes`
  Installs the `react-doctor` skill for detected agents (Claude Code included). Scans for React-specific issues; auto-runs after code edits in a `CLAUDECODE` environment and is invoked by the `code-audit-frontend` agent pre-merge.

  **Then strip React Doctor's bundled extras** so GAIA stays the sole controller of when react-doctor runs. There is no skill-only install flag, so the installer also adds a standalone GitHub Actions workflow, a commit-hook block (written into husky's generated `.husky/_/pre-commit` because GAIA sets `core.hooksPath=.husky/_`), a `doctor` package script, a pinned `react-doctor` devDependency, and a `.agents/skills/react-doctor/` copy of the skill for any other agents it detects (Copilot, Warp). GAIA triggers react-doctor via the Claude Code skill (auto-run after edits) and the `code-audit-frontend` agent (at `@latest`), so remove the rest, keeping only the Claude Code skill:

  ```bash
  rm -f .github/workflows/react-doctor.yml
  # Remove the non-Claude skill copy (Copilot/Warp); rmdir the now-empty parents but leave
  # any unrelated .agents/ content untouched.
  rm -rf .agents/skills/react-doctor
  rmdir .agents/skills .agents 2>/dev/null || true
  pnpm remove react-doctor --config.ignore-scripts=true 2>/dev/null || true
  # Hyphenated key needs bracket+quote form; a bare scripts.react-doctor throws
  # ERR_PNPM_UNEXPECTED_TOKEN_IN_PROPERTY_PATH and aborts, leaving `doctor` behind too.
  pnpm pkg delete scripts.doctor 'scripts["react-doctor"]'
  pnpm exec husky
  ```

  Each line is idempotent and no-ops when its artifact is absent (including when no non-Claude agent was detected, so no `.agents/` copy was written).

- [Playwright CLI](https://github.com/microsoft/playwright-cli): `npm install -g @playwright/cli@latest`
  Installs the global `playwright-cli` binary the bundled skill shells out to. Without it the skill's `allowed-tools: Bash(playwright-cli:*)` directive resolves to nothing.

- [Serena](https://github.com/oraios/serena) MCP server: ensure `uv` first.

  ```bash
  if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  ```

  Verify with `uv --version`. If verification fails, halt with: `uv is required for GAIA. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh, then re-run /setup-gaia.`

  Then register Serena globally:

  ```bash
  claude mcp add serena -s user -- uvx --from git+https://github.com/oraios/serena@v1.2.0 serena start-mcp-server --context claude-code --project-from-cwd --open-web-dashboard false
  ```

  If the registration already exists (`claude mcp add` exits non-zero with a "name already exists" error), treat as success and continue.

  Serena's tools only win over Opus's built-in Read/Grep/Edit when Claude Code loads Serena's system-prompt override; Opus otherwise defaults to its own tools, a strong built-in-tool bias the Serena maintainers prescribe this override to counter. Tell the user the recommended way to start Claude Code sessions in this project:

  ```bash
  claude --append-system-prompt="$(serena prompts print-cc-system-prompt-override)"
  ```

  This is optional but recommended and adopter-safe: a plainly-launched `claude` still works, and the always-loaded `.claude/rules/serena-cc-override.md` is the durable fallback. Use the append form, never `--system-prompt`, which replaces Claude Code's base prompt.

  Serena picks a single language at first startup and freezes it into `.serena/project.yml`. If the project later grows another language, Serena will not index it until the `languages:` list in `.serena/project.yml` is updated and Serena restarts. To fix this manually, edit the `languages:` list in `.serena/project.yml` directly and restart Serena; `/gaia-serena-sync` automates the same edit on explicit consent.

After all three tools install successfully:

```bash
.gaia/cli/gaia setup mark-step install-tools
```

If any install fails, surface the error verbatim and halt. The user can re-run `/setup-gaia` after addressing the cause; this step resumes.

### Step 2: install-plugins

Skip if `install-plugins` is in `completed_steps`.

```bash
claude plugin install typescript-lsp@claude-plugins-official
claude plugin marketplace add AgriciDaniel/claude-obsidian
claude plugin install claude-obsidian@claude-obsidian-marketplace
```

If any fail, surface the error and halt. Already-installed plugins are a no-op. After all three succeed:

```bash
.gaia/cli/gaia setup mark-step install-plugins
```

### Step 3: init-speckit

Skip if `init-speckit` is in `completed_steps`.

The GAIA `/gaia-spec` Socratic discovery workflow runs on top of [spec-kit](https://github.com/github/spec-kit). The repo already ships the GAIA extension at `.specify/extensions/gaia/` and the GAIA preset at `.specify/presets/gaia/`; they need spec-kit's runtime registered.

Pin spec-kit at the version declared in `.specify/extensions/gaia/extension.yml` `requires.speckit_version` floor.

```bash
SPECKIT_PIN="v0.8.5"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify init --here --ai claude --force
# specify extension/preset add --dev consumes its source dir when source == install
# dest (.specify/extensions|presets/gaia in PROJECT_ROOT). Stage a throwaway copy in a
# unique in-project temp dir so source != dest and the originals in .specify/ survive.
# A trap removes the staging dir on exit (repo-relative rm; absolute /tmp rm is sandbox-blocked).
SPECKIT_STAGE="$(mktemp -d "${PROJECT_ROOT}/.gaia-speckit-stage.XXXXXX")"
trap 'rm -rf "${SPECKIT_STAGE}"' EXIT
cp -r "${PROJECT_ROOT}/.specify/extensions/gaia" "${SPECKIT_STAGE}/extension"
yes | uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify extension add --dev "${SPECKIT_STAGE}/extension"
cp -r "${PROJECT_ROOT}/.specify/presets/gaia" "${SPECKIT_STAGE}/preset"
yes | uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify preset add --dev "${SPECKIT_STAGE}/preset"
rm -rf "${SPECKIT_STAGE}"
trap - EXIT
```

If any step fails, surface verbatim and halt. After all succeed:

```bash
.gaia/cli/gaia setup mark-step init-speckit
```

### Step 4: chmod-statusline

Skip if `chmod-statusline` is in `completed_steps`.

The statusline command in `.claude/settings.json` points at `.gaia/statusline/*.sh`; the executable bit is normally tracked by git but can be lost on cross-platform clones.

```bash
chmod +x .gaia/statusline/*.sh
.gaia/cli/gaia setup mark-step chmod-statusline
```

### Step 5: bootstrap-env

Skip if `bootstrap-env` is in `completed_steps`.

`.env` is gitignored. If `.env` does not exist and `.env.example` does, copy:

```bash
cp .env.example .env
```

If neither exists, that's fine, the project may not use `.env`. After the copy (or no-op):

```bash
.gaia/cli/gaia setup mark-step bootstrap-env
```

### Step 6: mentorship-decision

Skip if `mentorship-decision` is in `completed_steps`.

If `.gaia/local/mentorship.json` already exists with a non-null `enabled` field, the decision was already made (e.g. via a prior `/setup-gaia` run or `gaia mentorship enable`/`disable`). Just record the step and move on:

```bash
if [ -f .gaia/local/mentorship.json ] && [ "$(jq -r 'if .enabled == null then "null" else (.enabled | tostring) end' .gaia/local/mentorship.json 2>/dev/null)" != "null" ]; then
  .gaia/cli/gaia setup mark-step mentorship-decision
  # Continue to Phase 3.
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

**On "Not now":**

```bash
.gaia/cli/gaia mentorship _internal-write-config --enabled false --analytics false --decided-via gaia-init
```

**On "Yes, enable":**

```bash
.gaia/cli/gaia mentorship _internal-write-config --enabled true --analytics true --decided-via gaia-init
.gaia/cli/gaia mentorship _internal-provision-dirs
```

After the chosen branch executes:

```bash
.gaia/cli/gaia setup mark-step mentorship-decision
```

## Phase 3: GitHub repository (skip if provisioning already complete)

Judge this phase from the **repo/branch/push state cached in Phase 1**, not merely `origin` presence. If the repo exists, the default branch is pushed, and no repo mutation is owed, print `GitHub repository already provisioned.` and fall through to Phase 4 without touching GitHub.

Otherwise, this is the **first user-facing interaction for a first adopter**. Ask (AskUserQuestion) with these three options:

> How do you want to connect this project to GitHub?
>
> - **Create the repo on GitHub** (Recommended): I'll create it private, push your default branch, and set the recommended defaults.
> - **Adopt an existing repo**: you already have a github `origin`; I'll skip creation and apply the recommended defaults.
> - **Set one up manually**: I'll print guidance and leave GitHub untouched.

### Option 1: Create the repo on GitHub

**Pre-creation authz check (distinct from the existing-repo admin probe).** `check-admin` needs a repo that already exists, so it cannot gate creation. Confirm an **authenticated gh with repo-creation rights** first:

```bash
gh auth status
```

If `gh` is unauthenticated (or the active token lacks the `repo` scope needed to create a repository), do NOT attempt creation. Print:

```
Creating a GitHub repo needs an authenticated gh with repo-creation rights. Run `gh auth login` (grant the `repo` scope), then re-run /setup-gaia and pick "Create the repo on GitHub". Or choose "Adopt an existing repo" / "Set one up manually".
```

Exit the repo phase without mutating GitHub.

**Choose the owner (personal account or organization).** Before creating, decide *where* the repo lives. Resolve the personal login and enumerate the orgs the user belongs to (the `gh api user` login lookup mirrors Phase 5, line 778):

```bash
gh api user --jq .login                       # personal login
gh api --paginate /user/orgs --jq '.[].login' # org memberships (best-effort; may need the read:org scope)
```

Org enumeration is best-effort: `/user/orgs` only returns orgs the active token can see. A missing org is not fatal; the free-text path below covers it.

**If the user belongs to no orgs, skip the owner question entirely** and create under the personal account (the default create command below).

Otherwise, rank the orgs by the user's own recent commit activity so the most-likely target is offered first. The contributions graph is the precise "committed to" signal (last-year window), one call:

```bash
gh api graphql -f query='
{ viewer { contributionsCollection { commitContributionsByRepository(maxRepositories: 100) {
  repository { owner { login } } contributions { totalCount } } } } }' --jq '
  [.data.viewer.contributionsCollection.commitContributionsByRepository[]
   | {owner: .repository.owner.login, n: .contributions.totalCount}]
  | group_by(.owner) | map({owner: .[0].owner, n: (map(.n) | add)})
  | sort_by(-.n) | .[].owner'
```

Order the org set by this ranking; orgs the ranker omits fall to the end in membership order. If the GraphQL call fails or returns nothing (older gh, missing scope, no recent activity), fall back to plain `/user/orgs` order. Ranking is cosmetic: it only decides which orgs appear as buttons; the final choice is always correct.

Then AskUserQuestion with these options **in this exact order**:

> Where should this repository live?
>
> - **Personal account (@<login>)** (Recommended): create it under your own GitHub account.
> - **<org>**: create it in this organization. (one option per org, ranked; **at most 3**)

If the user belongs to **more than three** orgs, print the full ranked list first, offer the personal account plus the **top 3** ranked orgs as buttons, and add to the question: "If the org you want isn't a button, choose Other and type its exact login from the list above." (AskUserQuestion supplies the free-text Other option automatically.) Record the chosen owner for the create command below.

**Create private by default.** Non-interactive `gh repo create` requires one of `--public` / `--private` / `--internal`; default to `--private`. Create under the owner chosen above: omit the positional for the personal account, or pass `<owner>/<name>` for an org (deriving `<name>` from the project directory):

```bash
# Personal account:
gh repo create --source=. --push --private
# Organization <owner>:
gh repo create "<owner>/$(basename "$PWD")" --source=. --push --private
```

Because the repo is created `--private`, the pushed history lands in a private repo and is never publicly exposed by this push. A **public or internal** repo is created **only** after a separate, explicit confirmation:

> Create this repository **public or internal** instead of private? Its full pushed git history becomes visible to everyone who can see the repo.
>
> - **Keep it private** (Recommended)
> - **Make it public**
> - **Make it internal** (org-visible)

Never flip the repo to public/internal without this second confirmation. Private-by-default is the primary mitigation for exposing historical secrets in the pushed history.

**Secret-scanning push-protection (best-effort).** Immediately after create, enable secret-scanning push-protection so it guards every later push and is in place before any public/internal flip:

```bash
gh api -X PATCH "repos/<owner>/<repo>" --input - <<'JSON'
{"security_and_analysis": {"secret_scanning_push_protection": {"status": "enabled"}}}
JSON
```

If this is unavailable on the plan (e.g. a private repo without GitHub Advanced Security), degrade gracefully: print a one-line note that push-protection could not be enabled and continue. Do not halt.

After creation, cache `owner`/`repo` from the new remote and fall through to **Recommended defaults**.

### Option 2: Adopt an existing repo

The user already has a github `origin` (cached in Phase 1). Skip creation and fall through to **Recommended defaults**.

### Option 3: Set one up manually

Print:

```
Create a repo on your provider, then:
  git remote add origin <url>
  git push -u origin <default-branch>
When it's pushed, re-run /setup-gaia to apply the recommended defaults and (if you're an admin) wire CI.
```

Exit the repo phase without mutating GitHub.

### Recommended defaults (admin-gated)

Reached from Option 1 (after create) or Option 2 (adopt). Run the admin probe for the now-existing repo:

```bash
.gaia/cli/gaia setup-ci check-admin --owner <owner> --repo <repo> --json
```

Cache `admin` and `auth_status`. **If `admin` is not `true` (or `auth_status != "ok"`)**, none of the GitHub mutations below fire; print the admin-note and skip straight to Phase 4 (which will also degrade):

```
GitHub provisioning and CI wiring need repo-admin permission and an authenticated gh (yours: admin=<admin>, auth_status=<auth_status>). Skipping the admin-only steps (branch protection, required-check registration, Dependabot alerts, delete-branch-on-merge, the bot-token secret, and the CI commit). Per-machine setup and your per-developer audit-mode choice still complete. Ask a repo admin to finish the GitHub side, or gain admin access and re-run /setup-gaia.
```

When `admin: true` and `auth_status == "ok"`:

**Default-branch protection.** No CLI verb creates a protection rule, so author the full `protection` PUT payload directly. Create protection **before** the `GAIA-Audit` registration in Phase 4: a bare `required_status_checks` PUT 404s when no protection rule exists. Correct order is create repo → push default branch → enable protection → register `GAIA-Audit`.

```bash
gh api -X PUT "repos/<owner>/<repo>/branches/<default-branch>/protection" --input - <<'JSON'
{
  "required_status_checks": {"strict": true, "contexts": []},
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null
}
JSON
```

`required_status_checks.contexts` starts empty here; Phase 4 unions `GAIA-Audit` (and any sibling contexts) into it.

`required_approving_review_count` is `0` and `enforce_admins` is `false` on purpose. GAIA's merge gate is the `GAIA-Audit` required status check (plus any sibling checks), not a human approval, so a review requirement would wedge a solo adopter: nobody can approve their own PR, and `enforce_admins: true` would block the admin override, leaving them unable to merge anything to the default branch. `enforce_admins: false` also lets the admin push GAIA's own finalize commit **directly onto the default branch** during setup, past this protection: that commit is a known-safe CI install with nothing to audit, so setup-gaia lands it straight to main rather than through a PR + audit (it suspends the local `block-main-destructive-git.sh` hook for the single commit+push via a `.gaia/local/setup-in-progress` sentinel, see Phase 4's Finalize step). Do not tighten these to require approvals or enforce admins without a merge path that a solo repo can actually satisfy.

**delete_branch_on_merge.** Read the current setting:

```bash
gh api "repos/<owner>/<repo>" --jq .delete_branch_on_merge
```

If `false`, AskUserQuestion:

> GitHub is set to NOT delete branches when PRs merge. GAIA's monthly stale-branch cron exists to clean those up. Enabling `delete_branch_on_merge` makes that cron redundant, so we'll mark `stale_branches.mode = "off"` in `.gaia/automation.json`.
>
> - **Enable delete_branch_on_merge** (Recommended; mark stale-branches off)
> - **Skip** (keep the stale-branch cleanup cron active)

On Enable:

```bash
.gaia/cli/gaia setup-ci enable-delete-branch --owner <owner> --repo <repo>
.gaia/cli/gaia setup-ci write-tool-mode stale-branches off
```

If already `true`, print `delete_branch_on_merge is already enabled, stale-branches cron is redundant. Marking stale_branches.mode = "off".` and shell only the mode write:

```bash
.gaia/cli/gaia setup-ci write-tool-mode stale-branches off
```

**Dependabot posture.** Enable Dependabot **alerts** (visibility), keep the PR-producing features **off**. First warn about any existing Dependabot / Renovate config:

```bash
.gaia/cli/gaia setup-ci warn-existing-tools --json
```

If `found` is non-empty, print (substituting the actual tools):

```
A {tool} configuration was detected in this repo. GAIA's /update-deps automation covers the same ecosystems (npm, pnpm), and running both in parallel opens duplicate dependency PRs.

Recommendation: disable {tool} for the ecosystems /update-deps covers before continuing. /setup-gaia will NOT auto-disable {tool}.
```

Then set the posture:

```bash
gh api -X PUT "repos/<owner>/<repo>/vulnerability-alerts"                            # expects HTTP 204: alerts on
gh api "repos/<owner>/<repo>/automated-security-fixes" --jq .enabled                 # assert this is false: PR features stay off
```

Assert `automated-security-fixes` is `false`, and write **no** `.github/dependabot.yml`. **`/update-deps` owns package updates** in GAIA; Dependabot is enabled for alert visibility only, never as a second PR-opening bot.

All Phase-3 GitHub mutations (create, protection, vuln-alerts, delete-branch) are net-new, admin-gated, security-sensitive calls. A non-admin runner degrades gracefully: skip the mutation, print the admin-note above, and continue to Phase 4.

## Phase 4: CI wiring (admin-gated; skip if `setup_complete`)

CI wiring installs the audit gate and cron workflows, provisions the bot-token secret out of band, and registers the `GAIA-Audit` required check. This flow **registers the GAIA-Audit required check** as a branch-protection status.

**Non-admin graceful degrade.** If Phase 3's `check-admin` reported `admin != true` (or `auth_status != "ok"`), do NOT fire any `gh secret set`, branch-protection PUT, required-check PUT, Dependabot-alerts PUT, or `delete_branch_on_merge` PATCH. The admin-note was already printed in Phase 3; skip to Phase 5 (per-developer audit-mode still completes). Both an authenticated non-admin and an unauthenticated `gh` take this path.

### Idempotent short-circuit (with template-drift escape)

When `setup_complete: false`, fall through to **CI enable decision**.

When `setup_complete: true` AND `RECONFIGURE` IS set, fall through to the **`--reconfigure` flow**. `--reconfigure` does NOT touch `setup_complete`; it stays true.

When `setup_complete: true` AND `RECONFIGURE` is NOT set, probe for template drift:

```bash
.gaia/cli/gaia setup-ci check-drift --json
.gaia/cli/gaia setup-ci check-audit-drift --json
```

`check-drift` returns `{drifted: ToolId[], missing: ToolId[], in_sync: ToolId[]}`; `check-audit-drift` returns `{state: "in_sync" | "drifted" | "missing"}`.

If `drifted.length === 0 && missing.length === 0` AND `check-audit-drift` state is `"in_sync"`, print exactly:

```
GAIA CI is already configured. Pass --reconfigure to rotate tokens or change tool selection.
```

Do not modify any file; fall through to Phase 5. Otherwise (drift or missing cron files, or the audit workflow drifted/missing), summarize the affected workflows and AskUserQuestion:

> The .github/workflows files have drifted from the bundled templates.
>
> Cron workflows, Drifted: <drifted-list-or-(none)> | Missing: <missing-list-or-(none)>
> Audit workflow, <in_sync|drifted|missing>
>
> - **Re-render workflows** (Recommended): regenerate only the drifted/missing cron files and re-install the audit workflow from the current templates, then commit on a branch and open a PR. Keeps tool selection and token unchanged.
> - **Skip**: leave the workflows as-is.
> - **Run full reconfigure instead**: re-prompt for tool modes and rotate the bot token.

On "Re-render workflows" → run the **Drift-fix path** below. On "Skip" → fall through to Phase 5 with no changes. On "Run full reconfigure instead" → set `RECONFIGURE = true` and run the **`--reconfigure` flow**.

### CI enable decision

First confirm the remote is GitHub (cached in Phase 1). If `detect-remote` reported `found: false`, print `No github origin yet. Provision the repo (Phase 3) or run git push origin <default-branch> first, then re-run /setup-gaia.` and fall through to Phase 5. If `host != "github.com"`, print `GAIA CI supports GitHub Actions only. Detected host: <host>.` and fall through to Phase 5.

**Re-offer CI exactly once.** A first adopter who declined CI at `/gaia-init` but now has a repo is re-offered the enable decision once. Read `nudge_dismissed` from `setup-ci status --json`. If `nudge_dismissed` is `true` and `RECONFIGURE` is not set, do NOT print the enable prompt (the "not now" dismissal is a per-machine, gitignored flag) and fall through to Phase 5. The init-time decline is a one-time intent, not a permanent opt-out; a first adopter with a repo and `nudge_dismissed: false` is offered the choice.

If `RECONFIGURE` is set, skip this question and use the reconfigure flow. Otherwise AskUserQuestion with these three options in this exact order:

> Enable GAIA CI now? It runs four maintenance jobs on a smart cron (wiki sync, /update-deps, pnpm audit, stale branches), opens labeled PRs, and auto-merges them on green CI.
>
> - **Enable GAIA CI now** (Recommended)
> - **Not now** (you can re-run /setup-gaia anytime)
> - **Don't ask the team again** (admin-only; skips this prompt for everyone)

Branches:

- **Enable now:** fall through to **Audit-mode policy (solo or team)**.
- **Not now:**

  ```bash
  .gaia/cli/gaia setup-ci dismiss-personal
  ```

  Print `Personal dismissal recorded. Re-run /setup-gaia anytime to enable.` and fall through to Phase 5. The prompt is absent on the next plain re-run because `nudge_dismissed` is now set.
- **Don't ask the team again:**
  - If `admin: false` (or `auth_status != "ok"`): print `"Don't ask the team again" requires repo admin permission (yours: admin=<admin>, auth_status=<auth_status>). Falling back to personal dismissal.`, then AskUserQuestion "Apply personal dismissal instead?" (Yes → `.gaia/cli/gaia setup-ci dismiss-personal`; No → cancel). Fall through to Phase 5.
  - If `admin: true`: shell `.gaia/cli/gaia setup-ci opt-out-team`, print `Team opt-out recorded in .gaia/automation.json (setup_opted_out=true). Commit and push to apply for the team.` (do NOT auto-commit), and fall through to Phase 5.

### Audit-mode policy (solo or team)

Reached on "Enable now" or in the reconfigure flow. This sets how `code-audit-frontend` runs at merge time, writing to the committed `.gaia/audit-ci.yml`: `default_mode` (the fallback), `override_label` (the sticky label that forces a CI run regardless of author), and, for a solo repo, the setup author's own `audit_authors` entry.

First print the docs link so the reader can read up on the modes before choosing:

```
Audit-gate modes (local vs CI): https://docs.gaiareact.com/maintenance/gaia-ci/#the-audit-gate
```

Then AskUserQuestion:

> Is this repo just for you, or for a team?
>
> - **Solo engineer.** One-person repo. Your audit runs locally at merge time (streaming, incremental), the better DX. No further audit questions.
> - **A team.** Multiple contributors. You'll pick how the team's audit runs next.

**Solo engineer.** Do NOT ask a second question. Write `default_mode: local` and `override_label: run-audit` into `.gaia/audit-ci.yml` (adding each key if absent, rewriting in place if present, no duplicates). Then record the setup author's own per-author entry so Phase 5's per-developer prompt stays silent for them (Phase 5 skips only when your login already appears in `audit_authors`):

```bash
login=$(gh api user --jq .login)
.gaia/scripts/append-audit-author.sh "$login" "local"
```

Print:

```
Solo setup: your code-audit-frontend runs locally at merge time. CI stays installed as a failsafe, run /setup-gaia --reconfigure to switch to CI audits if you add collaborators.
```

**A team.** AskUserQuestion with these two options in this exact order:

> How should the code-audit-frontend run for your team?
>
> - **Local (Recommended).** Each developer's audit runs on their machine at merge time (streaming, incremental) and CI stands down for them, the best day-to-day DX. The GAIA-Audit required check still guards the branch, and if a developer's local mode can't be confirmed the resolver fails closed to `ci`, so the branch is never left unguarded. Sets `default_mode: local`; each teammate confirms their own mode in the per-developer step.
> - **CI.** Every PR's audit runs on CI as a shared failsafe; contributors wait for the GAIA-Audit check. Simplest to reason about for larger teams. Sets `default_mode: ci`.

Write the chosen `default_mode` (`local` or `ci`) and `override_label: run-audit` into `.gaia/audit-ci.yml`, adding each key if absent and rewriting it in place if present (do not duplicate). Leave `audit_authors` untouched (each teammate, including you, sets their own entry in Phase 5).

Both paths: the file is committed alongside the workflow files in the finalize commit; do NOT auto-commit it here.

### Token type selection and out-of-band secret provisioning

**First, detect an existing usable token, and skip all provisioning when one is found.** GAIA CI needs only that a secret named `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` is reachable by this repo's workflows. The rendered workflows wire **both** env vars unconditionally (`${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}` and `${{ secrets.ANTHROPIC_API_KEY }}`), and an org-level secret whose visibility includes this repo is exposed to its workflows automatically, so no repo-level copy is required. This is the common case for a repo inside an org that sets the token org-wide.

List the secret **names** reachable by this repo, both scopes. This reads names only, never values, so it fully respects the safety rule below. `gh secret list --repo` returns only **repo**-level secrets, so query the API directly to also see org secrets the repo can use:

```bash
# Repo-level secret names (empty on error).
repo_secrets=$(gh api "repos/<owner>/<repo>/actions/secrets" --jq '.secrets[].name' 2>/dev/null)
# Org-level secret names available to THIS repo (respects the org secret's repo visibility).
# Empty for a user-owned repo (the endpoint 404s) or on any error.
org_secrets=$(gh api "repos/<owner>/<repo>/actions/organization-secrets" --jq '.secrets[].name' 2>/dev/null)
existing=$(printf '%s\n%s\n' "$repo_secrets" "$org_secrets" | grep -v '^$' | sort -u)
```

Resolve `<NAME>` with **`CLAUDE_CODE_OAUTH_TOKEN` taking precedence** over `ANTHROPIC_API_KEY`, and note whether it was found at repo or org scope (`org` when it appears in `org_secrets` but not `repo_secrets`):

- If `existing` contains `CLAUDE_CODE_OAUTH_TOKEN` → `<NAME> = CLAUDE_CODE_OAUTH_TOKEN`.
- Else if it contains `ANTHROPIC_API_KEY` → `<NAME> = ANTHROPIC_API_KEY`.
- Else no usable token exists → run the **token-type selection** and **provisioning** flow below.

**When a token is detected**, print `Detected <NAME> already set at the <repo|org> level; GAIA CI will use it. Skipping token setup.` and skip straight to **Generate workflow YAML**: do NOT ask the token-type question and do NOT print any `gh secret set` instructions. Under `--reconfigure`, an org-level detection is not repo-rotatable, so print `<NAME> is managed at the org level; rotate it there, then re-run. Skipping repo-secret rotation.` and skip to **Generate workflow YAML**; a repo-level detection instead runs the **Reconfigure (rotation)** path below.

**When no token is detected**, ask the token type and provision out of band.

AskUserQuestion:

> Which bot token will GAIA CI use to authenticate workflow steps that hit the Anthropic API?
>
> The same repo-scoped secret authenticates all GAIA CI workflows, both the scheduled cron jobs (`gaia-ci-*.yml`) and the `code-review-audit.yml` PR gate. The audit honors either token type.
>
> - **CLAUDE_CODE_OAUTH_TOKEN** (default for Claude Code subscribers)
> - **ANTHROPIC_API_KEY** (default for direct Anthropic API customers)
> - **I don't know** (link to docs and exit)

On "I don't know", print `Open https://gaiareact.com/setup-gaia to read the token-type section, then re-run /setup-gaia.` and fall through to Phase 5.

On a token choice, provision the secret **out of band**. GAIA never handles the token value.

**Non-negotiable safety rule.** The token value MUST NOT enter this conversation or the agent's process at all. Do NOT ask the user to paste it, do NOT read it from a chat message, and do NOT route it into any sink. This includes, but is not limited to, Bash command strings, `Edit` / `Write` / `NotebookEdit`, `AskUserQuestion`, commit messages, memory or scratchpad files, subagent prompts, scheduled tasks, and outbound network or MCP calls. The rule is simpler than any list: the value must never leave the user's own terminal. Anything typed into the chat is recorded in the transcript, sent to the model API, and may be persisted by the harness, piping it to `gh` afterward does not undo that exposure. If the user pastes a secret anyway, STOP: treat the pasted value as compromised, do not use or store it, tell them it is now exposed in the transcript and must be rotated, and continue with the out-of-band steps below.

**The agent prints these commands for the user to run in their own terminal; it never executes `gh secret set` itself.** It requires the token value on stdin or the command line, which the agent must never hold.

**Admin pre-gate.** Managing GitHub Actions secrets requires repo-admin permission. If the `admin` flag cached in Phase 3 is not `true` (or `auth_status != "ok"`), do not print the set instructions. Print:

```
Setting the <NAME> secret requires repo-admin permission and an authenticated gh (yours: admin=<admin>, auth_status=<auth_status>). Ask a repo admin to set it and finish /setup-gaia, or gain admin access (and run `gh auth login` if needed), then re-run /setup-gaia.
```

Fall through to Phase 5.

If `RECONFIGURE` is set, skip the fresh-setup block and go straight to **Reconfigure (rotation)** below.

**Fresh setup.** Substitute the chosen secret name for `<NAME>` and the cached `owner` / `repo` before printing, do not print literal angle brackets. Print these instructions and wait for the user to confirm:

```
Set the <NAME> secret yourself, in your OWN terminal (not here, not through me), so its value never touches this chat. Pick one:

  - Terminal (value stays hidden):
      gh secret set <NAME> --repo <owner>/<repo>
    gh prompts for the value with input hidden, type or paste it THERE, never in this chat. Nothing is echoed or logged. If gh reports an auth error, run `gh auth login` first.

  - GitHub web UI:
      <owner>/<repo> -> Settings -> Secrets and variables -> Actions ->
      New repository secret -> Name: <NAME> -> paste the value in the Secret field -> Add secret.

Tell me once it's set and I'll verify (I only read the secret's NAME, never its value).
```

When the user confirms, run **Verify presence** below.

**Verify presence.** Check that the secret exists by **name only**, matching the name **exactly** (a substring match would wrongly accept a leftover like `<NAME>_OLD`):

```bash
gh secret list --repo <owner>/<repo> --json name --jq '.[] | select(.name == "<NAME>") | .name'
```

`gh secret list` returns names, never values, so this is safe.

- Non-empty output (exact name match): print `Verified: <NAME> is set. Its value never entered this session.` and fall through to **Generate workflow YAML**.
- Empty output (secret absent): AskUserQuestion "Retry verification" / "Abandon". On Retry, re-run the presence check. On Abandon, fall through to Phase 5; `setup_complete` stays `false`.
- If `gh secret list` errors (e.g. HTTP 403), surface the error verbatim, note that managing Actions secrets requires repo-admin permission, and fall through to Phase 5.

**Reconfigure (rotation).** Reached only when `RECONFIGURE` is set. The secret already exists, so the goal is to overwrite it. Print the `gh secret set <NAME> --repo <owner>/<repo>` command from **Fresh setup**, framed as a rotation (running it again overwrites the value silently, and the value still never enters this chat), then AskUserQuestion:

> Rotate the <NAME> secret now?
>
> - **I've rotated it** (verify and continue)
> - **Keep the existing token** (no rotation)

On either answer, run **Verify presence** for `<NAME>` (both paths require the chosen secret to exist; this matters when the token type changed during this reconfigure). Then fall through to **Generate workflow YAML**.

### Generate workflow YAML

```bash
.gaia/cli/gaia automation render-workflows --out-dir .github/workflows
```

Capture the JSON list of written cron-workflow paths. Then install the audit workflow unconditionally:

```bash
.gaia/cli/gaia automation install-audit-workflow --out-dir .github/workflows
```

The audit is the PR gate; it installs regardless of how many cron tools are in CI mode. If `render-workflows` reports no paths written (the config has `mode: "ci"` for zero cron tools), do NOT exit, install the audit and continue with a note:

```
No cron tools are configured for CI mode in .gaia/automation.json. The code-review-audit.yml PR gate is installed. Edit .gaia/automation.json to add cron workflows later.
```

### Register GAIA-Audit as the required check

The audit gate is the `GAIA-Audit` COMMIT STATUS, not the `code-audit-frontend` job name. The audit job reaches a green terminal step on every path (including a local-mode stand-down where no audit ran), so requiring the job name would let an unaudited PR merge through the github.com button. Only the `GAIA-Audit` status is the gate, and the resolver honors `default_mode: local` only when this registration is confirmed present.

Register **after** the default-branch protection rule exists (Phase 3), so the `required_status_checks` PUT returns 2xx, not 404. **GET the current contexts, union `GAIA-Audit` into them, then PUT the union**. A static PUT REPLACES the array and would drop sibling contexts (e.g. `Tests`, `Chromatic`), letting unaudited code merge:

```bash
# GET the current required_status_checks contexts (empty on a fresh protection rule,
# or the repo's existing siblings on an adopted repo).
existing_contexts=$(gh api "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null)

# PUT the UNION: GAIA-Audit plus every existing context (one -f 'contexts[]=<ctx>' each,
# skipping a context already equal to GAIA-Audit so it is not duplicated).
gh api -X PUT "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks" \
  -f strict=true \
  -f 'contexts[]=GAIA-Audit'
  # ...append one `-f 'contexts[]=<ctx>'` for each context in $existing_contexts != GAIA-Audit
```

Substitute `<owner>`/`<repo>` (cached earlier) and `<default-branch>` (typically `main`). This call needs repo-admin permission and the protection rule from Phase 3. If it returns 403 (not admin) or 404 (no protection rule), surface the error verbatim and tell the user:

```
Could not register the GAIA-Audit required check (admin permission and a branch-protection rule on the default branch are required). Run it yourself once you have admin access:
  gh api -X PUT "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks" -f strict=true -f 'contexts[]=GAIA-Audit'
Until GAIA-Audit is a required check, the merge gate falls back to ci mode for every author (the resolver fails closed).
```

Do not halt on a registration failure; the workflow install already succeeded. Continue to the **Claude GitHub App install** gate below.

### Claude GitHub App install (prerequisite for the verification run)

Every GAIA CI workflow (all four) invokes the Claude Code Action, which mints a short-lived **repo installation token** at runtime. The `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` secret authenticates the Anthropic API, but the action **also** needs the **Claude GitHub App** installed on the repo to exchange for that GitHub token. Without it, any workflow that reaches the action step fails with `App token exchange failed: 401 Unauthorized` (surfaced in logs as `Claude Code is not installed on this repository`) even though the Quality Gate and earlier steps pass. Gate the app install **before** the verification run, out of band exactly like the token secret, rather than letting the run fail and asking afterward. The agent cannot install the app (it is an interactive GitHub authorization); only the repo admin / org owner can.

**Best-effort detection (skip the prompt when already installed).** No user-token endpoint reveals a repo's app installations directly: `repos/<owner>/<repo>/installation` needs a GitHub App JWT (401 under a user token) and `/user/installations` needs an app-authorized token (403). The one probe that works under a plain `gh` login is the org installations list, and only for an org-owned repo where you're an org owner. A 403/404 (personal repo, or a repo admin who is not an org owner) means "not confirmed", never treat it as "absent":

```bash
gh api "/orgs/<owner>/installations" --jq '.installations[].app_slug' 2>/dev/null | grep -qx claude
```

If this exits 0 (the exact slug `claude` is present), print `Claude GitHub App already installed on <owner>. Skipping the install prompt.` and fall through to **Verification run**. On any other result (non-zero exit, empty output, or slug absent), do not assume absence, run the instruct-and-wait gate below.

**Instruct and wait.** Substitute the cached `<owner>` / `<repo>` (do not print literal angle brackets), print these instructions, and wait for the user to confirm:

```
GAIA CI's workflows run as the Claude GitHub App, so it must be installed on this repo before the verification run, otherwise the run fails with a 401 at the Claude step:

  1. Open https://github.com/apps/claude
  2. Click Install (or Configure, if it's already installed on your account/org).
  3. Grant it access to <owner>/<repo> (or "All repositories").

If <owner> is an organization and you are not an owner, an org owner must approve or complete the install.

Tell me once it's installed and I'll run the verification.
```

When the user responds, AskUserQuestion:

> Is the Claude GitHub App installed on <owner>/<repo>?
>
> - **I've installed it (Recommended).** Run the verification now.
> - **Skip verification for now.** Install the workflows without a verified run; I'll finish setup, and you can trigger a run from the Actions tab once the app is installed.

- **I've installed it** → fall through to **Verification run**.
- **Skip verification for now** → skip the Verification run entirely, set the same commit-without-verification flag used below (it appends `(unverified)` to the finalize commit), and fall through to **Finalize and commit**. Print `Skipping the verification run. The workflows are installed but unverified, run gaia-ci-wiki from the Actions tab (or 'gh workflow run gaia-ci-wiki.yml') once the Claude GitHub App is installed.`

### Verification run

Pick the FIRST workflow file from the generated list (typically `.github/workflows/gaia-ci-wiki.yml`):

```bash
.gaia/cli/gaia setup-ci verify-run .github/workflows/gaia-ci-wiki.yml --json
```

If `verified: true`, print `Verification run succeeded. Conclusion: success. URL: <url>.` and fall through to **Finalize and commit**.

If `verified: false`, surface the URL and AskUserQuestion "Retry verification" / "Abandon" / "Commit without verification". On Retry, re-shell `verify-run` (one retry permitted). On Abandon, delete every file in the generated paths list and fall through to Phase 5; `setup_complete` stays `false`. On Commit without verification, fall through with a flag that adds `(unverified)` to the commit message.

Because the **Claude GitHub App install** is gated just above, a run that fails at the Claude step with `App token exchange failed: 401 Unauthorized` means the app install did not complete or does not grant this repo access. Tell the user to re-check the install at https://github.com/apps/claude (confirm `<owner>/<repo>` is in scope) before choosing Retry.

### Finalize and commit

```bash
.gaia/cli/gaia setup-ci finalize
```

The finalize commit is GAIA's own known-safe CI install: it adds the workflows and flips `setup_complete`, with nothing to audit. It lands **directly on the default branch**, no PR and no code-audit-frontend, so greenfield setup never waits on an audit run. This is the greenfield happy path; if the adopter pre-created a repo and applied branch protection before `/setup-gaia`, the finalize commit still goes through and the audit simply runs on it, that edge case is accepted.

Right after `gh repo create --push`, HEAD is on the default branch. When that branch is `main` or `master`, the `block-main-destructive-git.sh` PreToolUse hook denies every `git commit` and `git push` there (Git Workflow policy), so the standdown below is load-bearing only in that case: the hook does not recognize a custom default-branch name, so it never blocks one and the sentinel is inert (but harmless) there. Suspend that hook for this one commit+push with a machine-local sentinel. It **must be created in a separate, earlier Bash call** than the commit/push, the hook reads it *before* the command runs, so a `touch` bundled into the same call as `git commit` would not yet exist when the hook checks. The sentinel lives in `.gaia/local/` (gitignored), so it never reaches a teammate's clone:

```bash
mkdir -p .gaia/local
touch .gaia/local/setup-in-progress
```

Stage the generated workflow files plus `.gaia/automation.json` and the audit-policy `.gaia/audit-ci.yml`, commit, and push to the default branch. The admin push clears **classic** branch protection (`enforce_admins: false`, `restrictions: null`), so no reorder is needed. A **repository ruleset** is a separate enforcement layer these settings do not govern: if the org or repo protects the default branch with a ruleset that requires a PR (or restricts direct pushes) and does not list the pushing admin as a bypass actor, the push is rejected (`GH006`) even for an admin. Do not assume the push lands, branch on its result below:

```bash
git add .github/workflows/gaia-ci-*.yml .github/workflows/code-review-audit.yml .gaia/automation.json .gaia/audit-ci.yml
git commit -m "chore(gaia-ci): finalize CI setup, verified workflow_dispatch run

Adds .github/workflows/gaia-ci-*.yml, installs
.github/workflows/code-review-audit.yml PR gate, and flips
.gaia/automation.json:setup_complete to true."
git push origin <default-branch>
```

When the commit-without-verification flag is set, append `(unverified)` to the commit title and add the body line `Verification run did not succeed; user opted to commit anyway.`

Clear the sentinel immediately, in its own Bash call, **even if the commit or push failed** (a lingering sentinel keeps main-branch protection suspended on this machine; the hook also self-heals a stale one after 10 minutes). Phase 6 clears it defensively too:

```bash
rm -f .gaia/local/setup-in-progress
```

**Branch on the push result.** `gaia setup-ci finalize` already flipped `setup_complete` on disk and the commit captured it, so a false "done" here wedges a re-run: Phase 4's `already configured` short-circuit reads that local flag and never retries the push.

- **Push succeeded.** Print:

  ```
  GAIA CI is active on <default-branch>. Workflows: <list>. The first scheduled cron fires at the times encoded in .github/workflows/gaia-ci-*.yml; run any workflow on demand via the Actions tab's "Run workflow" button or `gh workflow run <file>`.
  ```

- **Push rejected** (non-zero exit, e.g. `GH006`, `protected branch`, `pre-receive`). Do NOT print the success line. The finalize commit is on local `<default-branch>` but not on the remote. Surface the error verbatim and print:

  ```
  The finalize commit is built locally but the push to <default-branch> was rejected: <error>. This is typically a repository ruleset (separate from classic branch protection) that requires a PR or blocks direct pushes. To finish setup: add yourself as a bypass actor on the ruleset (or temporarily disable it), then run `git push origin <default-branch>` yourself, from your own terminal. A plain /setup-gaia re-run will NOT retry the push, setup_complete is already set locally, so it short-circuits as "already configured". (To re-drive it through /setup-gaia instead, first `git reset --hard HEAD~1` to drop the local finalize commit, then re-run once the ruleset allows the push.)
  ```

Fall through to Phase 5.

### `--reconfigure` flow

When `RECONFIGURE` is set, the short-circuit above is skipped and the CI flow re-runs with these differences:

- **CI enable decision** is REPLACED with a two-option question:

  > Re-select the tools running on cron. Current selections: <tools_enabled>.
  >
  > - **Re-prompt and rewrite .gaia/automation.json**
  > - **Keep current selections** (only rotate the token)

  On "Re-prompt", AskUserQuestion for each of `wiki`, `update-deps`, `pnpm-audit`, `stale-branches` with mode options `ci` / `local` / `off`, applying each via `.gaia/cli/gaia setup-ci write-tool-mode <tool> <mode>`.

- **Audit-mode policy** re-offers the solo/team gate (and, for a team, the Local vs CI question) and rewrites `default_mode` / `override_label` in `.gaia/audit-ci.yml`.
- **Token provisioning** runs its **Reconfigure (rotation)** path: it asks the user to overwrite the secret out of band (`gh secret set` overwrites silently), never reading the existing or new value, then verifies presence by name.
- **Finalize and commit** uses this message instead:

  ```
  chore(gaia-ci): reconfigure, rotated tokens, regenerated workflows

  Re-runs /setup-gaia's CI verification flow. setup_complete remains true.
  ```

  `setup_complete` is NOT touched on `--reconfigure`; it is already true.

### Drift-fix path (re-render only)

Reached when the drift probe found drift and the adopter picked "Re-render workflows". Lightweight branch + commit + PR that regenerates the workflow YAML without re-prompting for tool selection or rotating the bot token.

```bash
git checkout -b chore/gaia-ci-rerender
.gaia/cli/gaia automation render-workflows --out-dir .github/workflows
.gaia/cli/gaia automation install-audit-workflow --out-dir .github/workflows
git add .github/workflows/gaia-ci-*.yml .github/workflows/code-review-audit.yml
git commit -m "chore(gaia-ci): re-render workflows from updated templates"
git push -u origin chore/gaia-ci-rerender
gh pr create --base <default-branch> --head chore/gaia-ci-rerender \
  --title "chore(gaia-ci): re-render workflows from updated templates" \
  --body "GAIA CI templates drifted from the rendered workflows on disk. Regenerated cron workflows and re-installed the code-review-audit.yml PR gate via /setup-gaia. No tool selection or token changes."
```

Print the PR URL. Do NOT auto-merge; the adopter reviews and merges in their normal flow. `setup_complete` is NOT touched. If either render step fails, surface the structured error and exit; the branch is abandoned (the adopter can delete it and re-run `/setup-gaia` after fixing the cause). Fall through to Phase 5.

## Phase 5: Per-developer audit-mode (needs `audit-ci.yml`)

This step chooses who runs **your** `code-audit-frontend` at merge time, on CI or your local machine. It only applies once the project has CI wired up. The `audit-mode-decision` step is recorded in **every** branch below (absent-file, gh-unauthenticated, already-recorded, and post-choice); recording it unconditionally is load-bearing, a teammate clone that skips it reaches Phase 6 at 6/7 steps and `gaia setup finalize` hard-errors.

- If `.gaia/audit-ci.yml` does not exist (CI not configured yet), skip the choice silently and record the step:

  ```bash
  if [ ! -f .gaia/audit-ci.yml ]; then
    .gaia/cli/gaia setup mark-step audit-mode-decision
    # Continue to Phase 6.
  fi
  ```

- If `gh` is not authenticated (cannot resolve your login), skip with a one-line note and record the step (you can re-decide later after `gh auth login`):

  ```bash
  if ! gh auth status &>/dev/null; then
    echo "Skipping audit-mode choice: gh is not authenticated. Run 'gh auth login' and re-run /setup-gaia to choose." >&2
    .gaia/cli/gaia setup mark-step audit-mode-decision
    # Continue to Phase 6.
  fi
  ```

Otherwise resolve your GitHub login and read the team's `audit_authors` for context:

```bash
gh api user --jq .login
```

The interactive choice is **owed only when your login is absent from `audit_authors`** in `.gaia/audit-ci.yml`. If your `<login>` already has an entry, the decision is already recorded: print `Audit mode already recorded for <login>.`, mark the step, and continue to Phase 6 (this is what keeps a plain re-run silent, and what keeps a solo setup from re-asking). When your login is absent, first print the docs link (a teammate cloning later never saw Phase 4's audit-mode policy):

```
Audit-gate modes (local vs CI): https://docs.gaiareact.com/maintenance/gaia-ci/#the-audit-gate
```

Then AskUserQuestion with these two options in this exact order:

> Who runs your code-audit-frontend at merge time?
>
> - **Local (Recommended).** Your audit runs at merge time when you ask Claude to merge, streaming and incremental. CI stands down for you.
> - **CI.** CI audits your PRs; you wait for the GAIA-Audit check.

On a choice, append your `<login>=<mode>` pair to `audit_authors` via the append helper (it reads the existing value, drops any prior entry for your own login, and rewrites the line in place, so it never clobbers a teammate's entry):

```bash
.gaia/scripts/append-audit-author.sh "<your-login>" "<ci|local>"
```

Then tell the developer **explicitly** (do not paraphrase away these obligations):

- This is a **committed** change to `.gaia/audit-ci.yml`, not machine-local state. Other developers see it.
- It lands via a **one-line PR**: the only change is your `audit_authors` pair.
- That PR clears the merge gate through BOTH the merge-hook out-of-scope bypass AND CI's out-of-scope `GAIA-Audit` success stamp, a `.gaia`-only diff is out of audit scope, so neither producer runs a full audit on it. This is **contingent on an empty `gate_label`** in `.gaia/audit-ci.yml`: a non-empty `gate_label` gates the CI audit off the label instead. If `gate_label` is set, expect the audit to run on your one-line PR per the label rule.

Do NOT auto-commit or auto-open the PR. Guide the developer to review the diff, then commit and open the one-line PR themselves:

```bash
git checkout -b chore/audit-mode-<your-login>
git add .gaia/audit-ci.yml
git commit -m "chore(audit): set <your-login> audit mode to <ci|local>"
git push -u origin chore/audit-mode-<your-login>
gh pr create --fill
```

After the chosen branch executes (or a gated skip):

```bash
.gaia/cli/gaia setup mark-step audit-mode-decision
```

## Phase 6: Finalize

Stamp per-machine setup-state as complete, then report. `setup finalize` refuses to finalize while any step is pending (it returns non-zero without stamping `completed_at`), and a first adopter reaches here with `completed_steps: []` (their `/gaia-init` already set `completed_at` via `gaia setup finalize --force`), so this phase must both **short-circuit when already finalized** and **pass `--force` when any step is still pending**.

First, defensively clear the setup sentinel, unconditionally and before the short-circuit below, so a Phase 4 finalize that aborted between creating and removing it cannot leave main-branch protection suspended on this machine:

```bash
rm -f .gaia/local/setup-in-progress
```

Read `setup status --json`:

- If `completed_at` is non-null, setup-state is already finalized. Short-circuit, do NOT call finalize.
- Otherwise run:

  ```bash
  .gaia/cli/gaia setup finalize
  ```

  If it reports `setup_steps_pending`, re-run with `--force` rather than halting:

  ```bash
  .gaia/cli/gaia setup finalize --force
  ```

  Never leave `completed_at` unstamped because a step was skipped upstream (e.g. Phase 5 skipped under an unauthenticated `gh`).

**Adoption ping.** After finalize completes (or short-circuits above), send a setup adoption ping as the last substantive step of this phase, fire-and-forget.

Compute **`$SETUP_TYPE`** (required) from Phase 1's classification and `RECONFIGURE`:

- `RECONFIGURE` is set: `reconfigure`.
- Else Phase 1 classified this run as **first adopter**: `init`.
- Else Phase 1 classified this run as **fresh clone**, **admin-teammate-on-unwired-clone**, or a **partial re-run** that performed owed work: `clone`.
- Else Phase 1 classified this run as **provisioned**, and the short-circuit above fired because `completed_at` was already non-null before this phase ran, with `RECONFIGURE` not set: this is a plain no-op re-run. **Skip the ping entirely** and go straight to the completion message below. The `init|clone|reconfigure` enum has no value for "nothing happened this run"; firing here would inflate setup counts.

When not skipped, add these optional fields only when this run determined them:

- **`$MENTORSHIP`** (always knowable, always include): read `.gaia/local/mentorship.json` `.enabled`, the same field Phase 2 evaluates. `true` maps to `on`; `false`, `null`, or absent maps to `off`.
- **`$SANDBOX`** (always knowable, always include): read the sandbox decision straight from the marker Phase 2 resolves (or resolved on a prior run), so a plain re-run reports it correctly too. `outcome: enabled` maps to `on`; `declined`, `incapable`, or an absent marker maps to `off`:

  ```bash
  SANDBOX="$(.gaia/cli/gaia sandbox status --json 2>/dev/null | jq -r 'if .outcome == "enabled" then "on" else "off" end')"
  ```
- **`$REPO_CHOICE`**: the branch chosen at Phase 3's connect-to-GitHub question. "Create the repo on GitHub" maps to `create`, "Adopt an existing repo" maps to `adopt`, "Set one up manually" maps to `manual`. Omit when Phase 3 short-circuited because the repo was already provisioned (no choice was made this run).
- **`$CI_CHOICE`**: the Phase 4 CI enable decision. "Enable GAIA CI now" maps to `on`, "Not now" (`dismiss-personal`) maps to `off`, "Don't ask the team again" (`opt-out-team`) or a non-admin graceful-degrade maps to `skip`. Omit when Phase 4 was not reached (no GitHub origin yet, or already `setup_complete` with no drift or reconfigure).
- **`$AUDIT_MODE`**: the resolved audit mode. Use the developer's Phase 5 Local/CI choice when made this run, else the committed `default_mode` from `.gaia/audit-ci.yml` (Phase 4's Audit-mode policy). Values are `local` or `ci`. Omit when `.gaia/audit-ci.yml` does not exist (CI not wired).

Fire the ping with only the flags this run determined:

```bash
.gaia/cli/gaia ping --event setup --type "$SETUP_TYPE" \
  [--mentorship "$MENTORSHIP"] [--sandbox "$SANDBOX"] [--repo "$REPO_CHOICE"] \
  [--ci "$CI_CHOICE"] [--audit "$AUDIT_MODE"] || true
```

Then output (in the user's language): "GAIA setup complete. Restart Claude Code so the new plugin and skill state are picked up. The statusline will surface `/update-deps` and `/update-gaia` indicators when applicable."

## Idempotence / re-run safety

A plain (no-flag) re-run on a fully provisioned project prints the already-configured line and mutates nothing: default-branch protection JSON, `gh secret list` names, and workflow-file content hashes are byte-identical before and after, and no mutating `gh` call fires. Never re-provision the repo, rotate the token, or change branch protection on a plain re-run once `setup_complete` is true, only `--reconfigure` does that.

## On failure: re-run

Every step and CLI primitive is idempotent and safe to re-run on partial state. After fixing any failure cause (auth missing, network error, malformed config), simply re-run `/setup-gaia`, each phase detects its own completion and resumes from the first owed step.
