---
name: gaia-init
description: Initialize a new project from the GAIA React template — renames, strips GAIA branding, configures i18n, installs Claude skills/plugins.
---

Initialize a new project from the GAIA React template. The template already ships clean (no example code, no docs site, no auth). This command renames, strips GAIA-specific branding, configures i18n, installs Claude skills/plugins, and hands you a ready-to-build project.

**Language meta-instruction:** Conduct this entire conversation in the language the user has been typing in. Detect it from prior context — no explicit detection step needed. Do not translate source files, rules, skills, or wiki entries — those stay English regardless. Only translate the prompts you show the user.

## Step 0: Ensure pnpm is available

Tell the user: "Checking for pnpm…" then run:

```bash
if command -v corepack &>/dev/null; then
  corepack enable pnpm
else
  npm install -g pnpm
fi
```

If this fails, stop and report the error. `corepack enable pnpm` installs the pnpm version pinned in the `packageManager` field of `package.json`. If corepack is unavailable, fall back to a global npm install.

## Step 1: Install dependencies

The project was just created from the template — `node_modules/` does not exist yet. Install before doing anything else so later steps (typecheck, tests, build) can run.

Tell the user: "Installing dependencies — this may take a minute…" then run:

```bash
pnpm install
```

If install fails, stop and report the error. Do not continue.

Then run `/update-deps` to bring all packages to their latest compatible versions before continuing. If `/update-deps` reports anything as **skipped** with a reason, surface it so the user can investigate, but proceed. Note `/update-deps` runs its own quality gate at the end — if it halts on a quality-gate failure or peer-dep error, stop here and surface the report to the user; do not silently continue.

## Step 2: Gather user input (in the user's language)

This whole conversation has been in the user's language so far. Continue in that language for every prompt below. Do not translate source files, rules, skills, or wiki entries — those stay English regardless. Only translate the prompts you show the user.

Use AskUserQuestion. Ask up to three questions, in this exact order:

### Q1 — Primary app language

> What should be the primary language for this app's UI?
>
> - {detected user language} (default — what you've been typing in)
> - English
> - Other (you'll specify the ISO 639-1 code and English name in a follow-up free-text prompt)

If the user picks "Other", follow up with a free-text question:

> Enter the ISO 639-1 code (e.g. `pl`) and the English name (e.g. `Polish`).

### Q2 — Additional languages

> Any additional languages to support?
>
> - None
> - Comma-separated list of ISO 639-1 codes (free-text, e.g. `es, de, ar`)

### Q3 — Localize later? (only ask if Q1 + Q2 collapses to a single language)

Compute `LOCALES = unique(Q1 code, Q2 codes)`. If `len(LOCALES) > 1`, skip Q3.

Otherwise, ask:

> You've picked one language. Plan to localize later?
>
> - Yes — keep i18n scaffolding wired up; translations will be English-only for now.
> - No — strip i18n out entirely. Less infrastructure, smaller bundle, easier to remove than to add later.

Default: Yes.

### Other questions still asked here

After the language questions, also ask (single AskUserQuestion is fine):

- GitHub username for CODEOWNERS (suggest @username format)
- The title of their project (default: "GAIA React App")
- The kebab-case slug derived from the title (default: kebab-case of title)
- Statusline mode: `global` (write to `~/.claude/settings.json`), `project` (write to `.claude/settings.json` only), or `skip` (no statusline change)

## Step 3: Run the init CLI

The deterministic surface lives behind `gaia init`. Each subcommand is idempotent and records its own state in `.gaia/init-state.json`, so a failed step can be resumed via `gaia init resume`.

Compute the boolean `STRIP_I18N`: `true` when `len(LOCALES) == 1` AND the user picked "No" in Q3, otherwise `false`.

Run sequentially, stopping at the first non-zero exit:

```bash
.gaia/cli/gaia init strip-branding --title "<Project Title>"
.gaia/cli/gaia init configure-i18n --locales "<comma-separated locale list>" --strip <STRIP_I18N>
.gaia/cli/gaia init rename --title "<Project Title>" --kebab "<kebab-slug>"
.gaia/cli/gaia init wire-statusline --mode <global|project|skip>
```

If any of these exit non-zero, surface the structured error verbatim (the CLI prints a JSON line to stderr) and stop. The user can re-run the failing command manually after addressing the cause, then resume with `.gaia/cli/gaia init resume` — completed steps are skipped automatically.

## Step 4: Locale-specific scaffolding (when not stripping i18n)

If `STRIP_I18N == false`, also run the prose locale instructions for every non-`en` locale in `LOCALES`:

For each locale in `LOCALES` where the locale is NOT `en`:

1. Resolve the locale's English display name (e.g. `Polish`), native display name (e.g. `Polski`), and RTL flag (`true` for `ar`/`he`/`fa`/`ur`, otherwise `false`).
2. Read `.claude/instructions/add-locale.md`.
3. Substitute the four template variables: `{{LOCALE_CODE}}`, `{{LANGUAGE_NAME_EN}}`, `{{LANGUAGE_NAME_NATIVE}}`, `{{IS_RTL}}`.
4. Execute every step in the substituted instruction. Stop on any failure.

If `STRIP_I18N == true`, read `.claude/instructions/remove-i18n.md` and execute every step. Stop on any failure.

## Step 5: Replace the logo + update CODEOWNERS

- Replace `app/assets/images/gaia-logo.svg` with the project's own logo SVG. The Storybook brand logo imports it directly — no `preview.ts` edits needed.
- Replace `.github/CODEOWNERS` contents with just the user's GitHub username (the whole file becomes a single line like `* @username`).

## Step 6: Check `.env`

Run the CLI — it copies `.env.example` to `.env` when `.env` is absent, no-op otherwise. Routing through the CLI subprocess bypasses the project's `Write(.env)` deny rule, which guards against Claude writing secrets, not against init seeding from the example file.

```bash
.gaia/cli/gaia init bootstrap-env
```

If this exits non-zero, surface the structured error verbatim and stop.

## Step 7: Verify the build

Run sequentially, stopping at the first failure:

```bash
pnpm typecheck && pnpm lint && pnpm test:ci && pnpm build
```

Fix any issues before moving on.

## Step 8: Claude configuration

If any install step fails, print the command so the user can run it manually.

### Install tools

GAIA bundles project-scoped skills at `.claude/skills/` (`eslint-fixes`, `playwright-cli`, `react-code`, `skeleton-loaders`, `tailwind`, `tdd`, `typescript`) — they ship with the clone. Three external tools still need per-machine setup. The Serena MCP entry below requires `uv` (Astral's Python toolchain runner) on the host — GAIA precheck-installs it just like Step 0 precheck-installs pnpm.

- [React Doctor](https://github.com/millionco/react-doctor): `curl -fsSL https://react.doctor/install-skill.sh | bash`
  Installs the `react-doctor` skill to `~/.claude/skills/`. Scans the project for React-specific issues (47+ rules: security, performance, correctness, architecture). Auto-runs after code edits in a `CLAUDECODE` environment and is invoked by the `code-review-audit` agent pre-merge.
- [Playwright CLI](https://github.com/microsoft/playwright-cli) binary: `npm install -g @playwright/cli@latest`
  Installs the global `playwright-cli` binary the bundled skill shells out to. Without it the skill's `allowed-tools: Bash(playwright-cli:*)` directive resolves to nothing. Used for E2E debugging and authoring Playwright specs with minimal token cost — each interaction is one shell call instead of a round-trip through an MCP session.
- [Serena](https://github.com/oraios/serena) MCP server: semantic code-search and editing tools (find symbol, find references, replace symbol body) backed by language servers — pulls Claude away from grep-the-world toward symbol-aware operations. First, ensure `uv` is available — tell the user: "Checking for uv…" then run:

  ```bash
  if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  ```

  After install, source the shell rc the installer modifies (or add `~/.local/bin` to `PATH` for this session) and verify with `uv --version`. If the verification fails, halt `/gaia-init` with: `uv is required for GAIA. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh — then re-run /gaia-init.` Once `uv` is confirmed present, register Serena with:

  ```bash
  claude mcp add serena -s user -- uvx --from git+https://github.com/oraios/serena@v1.2.0 serena start-mcp-server --open-web-dashboard false
  ```

  `-s user` registers Serena globally for the user's Claude Code; `--open-web-dashboard false` keeps it headless. The pinned ref keeps every GAIA install on the same Serena baseline. If the `claude mcp add` invocation itself fails (network, registry change, etc.), surface the error verbatim and halt `/gaia-init` so the user can retry the command manually after addressing the cause.

### Install plugins

- `claude plugin install typescript-lsp@claude-plugins-official`
- `claude plugin marketplace add AgriciDaniel/claude-obsidian`
- `claude plugin install claude-obsidian@claude-obsidian-marketplace`

### Initialize spec-kit and install the GAIA extension + preset

The GAIA `/gaia spec` Socratic discovery workflow runs on top of [spec-kit](https://github.com/github/spec-kit). The template already ships the GAIA extension at `.specify/extensions/gaia/` and the GAIA preset at `.specify/presets/gaia/` — they need spec-kit's runtime registered around them.

Pin spec-kit at the version declared in `.specify/extensions/gaia/extension.yml` `requires.speckit_version` (currently `>=0.8.5,<0.10.0`; the floor is the runtime pin). Tell the user: "Initializing spec-kit and registering the GAIA extension + preset…" then run:

```bash
SPECKIT_PIN="v0.8.5"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify init --here --ai claude --force
# specify extension/preset add --dev deletes the source dir when source == dest;
# copy to /tmp first so the originals in the project tree survive.
cp -r "${PROJECT_ROOT}/.specify/extensions/gaia" /tmp/gaia-ext-tmp
yes | uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify extension add --dev /tmp/gaia-ext-tmp
rm -rf /tmp/gaia-ext-tmp
cp -r "${PROJECT_ROOT}/.specify/presets/gaia" /tmp/gaia-preset-tmp
yes | uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify preset add --dev /tmp/gaia-preset-tmp
rm -rf /tmp/gaia-preset-tmp
```

`specify init --here --ai claude --force` writes `.specify/{extensions.yml, integration.json, integrations/, memory/constitution.md, scripts/, templates/, workflows/}` and `.claude/skills/speckit-*` plus `CLAUDE.md`. The `--force` flag is required because the GAIA template ships some `.specify/` paths already; `specify init` refuses without it.

After install, `.specify/extensions/.registry` lists the `gaia` extension with all four registered commands (`speckit.gaia.spec`, `speckit.gaia.constitution-check`, `speckit.gaia.lint`, `speckit.gaia.self-review`); `.specify/presets/.registry` lists the `gaia` preset (priority 10, replaces `speckit.specify` and `spec-template`); `.claude/skills/speckit-gaia-*/SKILL.md` exist for each GAIA hook target; and `.claude/skills/speckit-specify/SKILL.md` is the GAIA preset wrap (core body spliced in via `{CORE_TEMPLATE}` substitution under `strategy: wrap`).

If any step fails, surface the error verbatim and halt — do not silently continue. The user can re-run the failing command manually and resume `/gaia-init` once spec-kit is in place.

### Configure CI integrations

Two GitHub Actions workflows ship with GAIA:

- `.github/workflows/code-review-audit.yml` — pre-merge gate that runs the `code-review-audit` agent against every PR.
- `.github/workflows/forensics-triage.yml` — autonomous triage for issues labeled `gaia-forensics`.

Both invoke Claude via `claude-code-action` and require the repo secret `CLAUDE_CODE_OAUTH_TOKEN`. If the project isn't pushed to GitHub yet, or the maintainer doesn't want CI Claude billing yet, opt out — the workflow files move to `.gaia/templates/workflows/`, and `/update-gaia` respects the deletion as adopter intent (per the file-class decision table on the Update Workflow concept page).

Use AskUserQuestion (in the user's language; this configuration block stays in English):

> Enable GAIA's GitHub Actions workflows now?
>
> - **Yes — enable now** (Recommended). I'll print the `gh` commands you run yourself with maintainer credentials, and ensure the `gaia-forensics` issue label exists.
> - **Skip — disable for now.** I'll move both workflow files to `.gaia/templates/workflows/`. Copy them back to `.github/workflows/` whenever you decide to enable.

**On "Yes":**

1. Verify gh CLI is authenticated:

   ```bash
   gh auth status
   ```

   If `gh auth status` exits non-zero, halt `/gaia-init` with: `GitHub CLI is not authenticated. Run 'gh auth login' and re-run /gaia-init.`

2. Print the copy-pasteable enable recipe verbatim — the user runs these themselves on the maintainer's machine once the project is on GitHub:

   ```bash
   # 1. Mint an OAuth token from a Claude Code-authenticated machine, then store it as a repo secret.
   claude setup-token
   gh secret set CLAUDE_CODE_OAUTH_TOKEN

   # 2. Make code-review-audit a required check on main (run after the workflow's first successful PR run).
   gh api -X PUT "repos/{owner}/{repo}/branches/main/protection/required_status_checks" \
     -f strict=true -f 'contexts[]=code-review-audit'
   ```

3. Ensure the `gaia-forensics` label exists, but only if the project already has a GitHub remote that gh can read:

   ```bash
   if gh repo view &>/dev/null && ! gh label list --limit 100 --json name 2>/dev/null \
       | jq -e '.[] | select(.name == "gaia-forensics")' >/dev/null; then
     gh label create gaia-forensics --color D93F0B --description "Triggers autonomous forensics triage"
   fi
   ```

   If `gh repo view` returns non-zero (no remote configured yet), skip the label creation and tell the user: `Create the gaia-forensics label after pushing the project to GitHub: gh label create gaia-forensics --color D93F0B --description "Triggers autonomous forensics triage"`.

**On "Skip":**

```bash
mkdir -p .gaia/templates/workflows
git mv .github/workflows/code-review-audit.yml .gaia/templates/workflows/code-review-audit.yml 2>/dev/null \
  || mv .github/workflows/code-review-audit.yml .gaia/templates/workflows/code-review-audit.yml
git mv .github/workflows/forensics-triage.yml .gaia/templates/workflows/forensics-triage.yml 2>/dev/null \
  || mv .github/workflows/forensics-triage.yml .gaia/templates/workflows/forensics-triage.yml
```

To re-enable later: `cp .gaia/templates/workflows/*.yml .github/workflows/`, then run the "Yes" recipe above. `/update-gaia` reads `.gaia/manifest.json` and treats deleted-from-adopter files as intentional, so the opt-out persists across updates.

### Make the statusline executable

The CLI in Step 3 wired the statusline command into Claude settings; the wrapper still needs the executable bit:

```bash
chmod +x .gaia/statusline/*.sh
```

(Idempotent — safe to run regardless.)

### Verify installs

After all installs and plugin registrations above, run a probe-after pass to confirm each component landed. For each component below, run the probe and emit one line:

| Component | Probe |
|---|---|
| React Doctor | `[ -d ~/.claude/skills/react-doctor ]` |
| Playwright CLI | `command -v playwright-cli && playwright-cli --version >/dev/null 2>&1` |
| Serena | `claude mcp list 2>/dev/null \| grep -q '^serena '` |
| typescript-lsp | `claude plugin list 2>/dev/null \| grep -q 'typescript-lsp'` |
| claude-obsidian | `claude plugin list 2>/dev/null \| grep -q 'claude-obsidian'` |
| spec-kit | `[ -f .specify/integration.json ] && grep -q 'gaia' .specify/extensions/.registry 2>/dev/null && grep -q 'gaia' .specify/presets/.registry 2>/dev/null` |

Emit one line per component: `[ok] <component>` if the probe exits 0, `[FAIL] <component>` if it exits non-zero.

After all probes run: if any component shows `[FAIL]`, print the full table, then halt `/gaia-init` with:

> "One or more components failed verification. Retry the failed install commands above, then resume with `.gaia/cli/gaia init resume`."

If all probes pass, print the full table and continue to Step 9.

The same probe set applies when setting up from an existing clone — `/setup-gaia` runs it after registering external tools.

## Step 9: Configure GAIA CI (Phase A)

GAIA CI is an optional automated maintenance system that runs four jobs on a smart schedule (wiki sync, dep refresh via `/update-deps`, `pnpm audit`, stale-branch cleanup), opens labeled PRs, and auto-merges on green CI. Phase A — this step — is local-only: it writes `.gaia/automation.json` with your tool selections and `setup_complete: false`. No GitHub repo or workflow files are involved here. After you push to GitHub for the first time, you'll run `/setup-gaia-ci` to wire up tokens and activate CI (Phase B).

Tell the user (in their language; the table headers stay English):

> Configure GAIA's automated maintenance jobs. Recommended: enable all four in CI mode so they run unattended. You can pick a different mode per tool.

Use AskUserQuestion to confirm the recommendation OR open per-tool overrides:

> How should GAIA CI's tools run?
>
> - **Enable all four in CI mode (Recommended).** Sets `wiki`, `update_deps`, `pnpm_audit`, and `stale_branches` to `ci`. Phase B (`/setup-gaia-ci`) activates them.
> - **Customize per tool.** Show the table below and ask for each tool's mode.

If the user picks "Customize per tool", show this table and use AskUserQuestion once per row (or one combined free-text prompt; the prose is the contract, the prompt shape is at the assistant's discretion):

| Tool | Default | What it does | Modes |
|---|---|---|---|
| `wiki` | `ci` | Smart-cron wiki sync against `app/**` changes. | `ci` / `local` / `off` |
| `update_deps` | `ci` | Weekly dependency refresh, auto-merging patch/minor. | `ci` / `local` / `off` |
| `pnpm_audit` | `ci` | Daily security audit; targeted PR for high/critical. | `ci` / `local` / `off` |
| `stale_branches` | `ci` | Monthly cleanup of branches merged >30 days ago. | `ci` / `local` / `off` |

Mode meanings:

- `ci` — runs in GitHub Actions on the documented cadence; PRs auto-merge on green CI.
- `local` — does not run in CI; only the adopter's local invocation runs the tool.
- `off` — never runs (neither in CI nor locally via the smart entrypoints).

The fifth config key, `update_gaia.mode`, is fixed to `local` and not surfaced as a question — `/update-gaia` is a per-machine command by design.

### Apply the answer

Once you have a value for each of the four tools, run:

```bash
.gaia/cli/gaia init configure-automation \
  --wiki <wiki-mode> \
  --update-deps <update-deps-mode> \
  --pnpm-audit <pnpm-audit-mode> \
  --stale-branches <stale-branches-mode>
```

Substitute each `<*-mode>` with the user's selection (`ci`, `local`, or `off`).

If the CLI exits non-zero, surface the structured-error JSON verbatim and stop. The user can re-run the failing command manually after addressing the cause, then resume `/gaia-init` with `.gaia/cli/gaia init resume`.

End of Step 9.

## Step 10: Mentorship opt-in

Tell the user (in their language): "GAIA includes an optional mentorship layer that learns how you work and adapts in-session — fully on your machine, never sent off it. Let's set the default."

Then show the privacy explainer (this block stays English regardless of UI language — it's the canonical contract):

> **GAIA's mentorship layer (experimental, optional)**
>
> GAIA can quietly learn how you work — which kinds of specs you find easy or hard, where you tend to need more context — and adapt in-session to help you ship better specs and code over time.
>
> **What it observes:** which kinds of specs you find easy or hard, where you need more context, when you amend specs after closing.
>
> **What it never observes:** when you work, how fast you type, what you read, your mood, your behavior outside GAIA's workflow.
>
> **Where it lives:** on your machine only, in your Claude project folder. Never in your project's git. Never sent to a server unless you opt into anonymous fine-tuning analytics (which comes with mentorship).
>
> **Read more:** https://gaiareact.com/mentorship/

Use AskUserQuestion. The question text must include the link: "Would you like to enable GAIA's mentorship layer? https://gaiareact.com/mentorship/". Three options in this exact order:

- **Not now (you can enable later if you like)** — `mentorship.enabled = false`, `analytics.enabled = false`. Init proceeds.
- **Yes, enable mentorship + anonymous analytics** — `mentorship.enabled = true`, `analytics.enabled = true`. Provision mentorship tree with `chmod 700/600`. Init proceeds.
- **Tell me more before I decide** — short description only (e.g. "Claude will explain how mentorship works before you decide"). When selected, Claude outputs the full privacy explainer, then drops into a free-form Q&A loop; on user signal of completion, re-present the same three-option AskUserQuestion. Init does not proceed until either "Not now" or "Yes, enable" is selected.

### Apply the answer

**On "Not now":**

```bash
.gaia/cli/gaia mentorship _internal-write-config --enabled false --analytics false --decided-via gaia-init
```

(Internal subcommand — see notes.)

**On "Yes, enable":**

```bash
.gaia/cli/gaia mentorship _internal-write-config --enabled true --analytics true --decided-via gaia-init
.gaia/cli/gaia mentorship _internal-provision-dirs
```

`_internal-provision-dirs` calls `ensureMentorshipDirs(roots)` from the storage-paths module and exits 0 silently. The chmod 700/600 is applied at create time.

**On "Tell me more":**

Output the full privacy explainer (what it observes, what it never observes, where it lives), ending with "Learn more: https://gaiareact.com/mentorship/". Then drop into Q&A. When the user signals they're done (e.g. "ok ready to decide"), re-present the same AskUserQuestion. Loop until the user picks Not now or Yes.

End of Step 10.

## Step 11: Refresh the wiki

The template ships with a wiki shaped for the upstream GAIA project. Refresh the two files that encode "where we are right now" so the new project starts with a clean context:

### 11a. Overwrite `wiki/hot.md`

Read `wiki/hot.md` first (required before Write can overwrite an existing file), then replace the entire file with:

```md
---
type: meta
title: Hot Cache
status: active
created: <TODAY_ISO>
updated: <TODAY_ISO>
tags: [meta, cache]
---

# Recent Context

## Last Updated

<TODAY>. Project initialized via `/gaia-init`. Fresh slate.

## Active Threads

- None.
```

### 11b. Overwrite `wiki/log.md`

Read `wiki/log.md` first, then replace the entire file with the following content (the GAIA development log is irrelevant to the new project):

```md
---
type: meta
title: Log
status: active
created: <TODAY_ISO>
updated: <TODAY_ISO>
tags: [meta, log]
---

# Log

Append-only. New entries at the TOP.

## [<TODAY>] /gaia-init | project initialized

- Project name: <PROJECT_TITLE>
- Languages: en + <OTHER_LANGS>
- Removed: GAIA branding (FUNDING.yml, GaiaLogo component); replaced gaia-logo.svg with project logo
- Installed: React Doctor, TDD, Playwright CLI skills; typescript-lsp, claude-obsidian plugins
```

## Step 12: Finalize

Mark per-machine setup as complete so the statusline does not show "Run /setup-gaia (Required)". `/gaia-init` performs all the same per-machine work as `/setup-gaia` (tools, plugins, spec-kit, statusline chmod, .env, mentorship), but it does not call `gaia setup mark-step` as it goes — so stamp the state file with `--force` now that everything is done:

```bash
.gaia/cli/gaia setup finalize --force
```

Then run the CLI's init finalize step — it removes the `/init` interceptor hook, prunes the matching entry from `.claude/settings.json`, and deletes this command file:

```bash
.gaia/cli/gaia init finalize
```

Then output:

> <Project Title> is ready for development. Restart Claude to pick up the new plugin and skill state.
>
> After you create your GitHub repo and push, run `/setup-gaia-ci` to wire up tokens and enable CI.

## On failure: resume

If any `gaia init <step>` invocation exits non-zero, the structured-error JSON on stderr explains the cause. After fixing the cause, re-run with:

```bash
.gaia/cli/gaia init resume
```

Resume reads `.gaia/init-state.json`, skips already-complete steps, and replays remaining steps using the saved arguments. Use `--from-step <N>` to force restart from a specific step (1-indexed: 1=strip-branding, 2=configure-i18n, 3=rename, 4=wire-statusline, 5=configure-automation, 6=finalize).
