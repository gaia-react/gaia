---
name: gaia-init
description: Initialize a new project from the GAIA React template, renames, strips GAIA branding, configures i18n, installs Claude skills/plugins.
---

Initialize a new project from the GAIA React template. The template already ships clean (no example code, no docs site, no auth). This command renames, strips GAIA-specific branding, configures i18n, installs Claude skills/plugins, and hands you a ready-to-build project.

**Language meta-instruction:** Conduct this entire conversation in the language the user has been typing in. Detect it from prior context, no explicit detection step needed. Do not translate source files, rules, skills, or wiki entries, those stay English regardless. Only translate the prompts you show the user.

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

The project was just created from the template, `node_modules/` does not exist yet. Install before doing anything else so later steps (typecheck, tests, build) can run.

Tell the user: "Installing dependencies, this may take a minute…" then run:

```bash
pnpm install --config.confirm-modules-purge=false
```

`--config.confirm-modules-purge=false` keeps the install non-interactive. `/gaia-init` runs with no TTY, so if the clone carries a stale or mismatched `node_modules/`, a bare `pnpm install` aborts with `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` waiting for a purge confirmation it can never receive. The flag suppresses only that prompt and leaves lockfile resolution untouched, so the immediately-following `/update-deps` step can still mutate dependencies. (Do not use `CI=true`: it forces `--frozen-lockfile`, which refuses any lockfile change.)

If install fails, stop and report the error. Do not continue.

Then run `/update-deps` to bring all packages to their latest compatible versions before continuing. If `/update-deps` reports anything as **skipped** with a reason, surface it so the user can investigate, but proceed. Note `/update-deps` runs its own quality gate at the end, if it halts on a quality-gate failure or peer-dep error, stop here and surface the report to the user; do not silently continue.

## Step 2: Gather user input (in the user's language)

This whole conversation has been in the user's language so far. Continue in that language for every prompt below. Do not translate source files, rules, skills, or wiki entries, those stay English regardless. Only translate the prompts you show the user.

Before asking any questions, detect the project folder name:

```bash
basename "$(git rev-parse --show-toplevel)"
```

Use this as the slug default. Derive the title default by replacing hyphens and underscores with spaces and applying title case (e.g. `my-cool-app` → `My Cool App`).

Ask the two language questions one at a time (Q2 interpolates Q1's answer), then batch the three project-identity questions.

### Q1, Primary app language (asked alone)

Use AskUserQuestion with this single question:

> What should be the primary language for this app's UI?
>
> - {detected user language} (default, what you've been typing in)
> - English
> - Other (you'll specify the ISO 639-1 code and English name in a follow-up free-text prompt)

If the user picks "Other", follow up with a free-text question:

> Enter the ISO 639-1 code (e.g. `pl`) and the English name (e.g. `Polish`).

Hold the resolved choice as `{primary}` (ISO code + English name); the next batch interpolates it into its labels, which is why Q1 is asked first and alone.

### Q2, Additional languages + i18n scaffolding (asked alone)

The primary is now known, so its name can appear in the labels below. Ask this as its own AskUserQuestion. It folds the old standalone "localize later?" decision into the no-additional-languages branch, so that decision never needs its own round-trip:

> Any additional languages, on top of {primary}?
>
> - Keep i18n scaffolding (Recommended): no additional languages; translations stay {primary}-only for now, and the scaffolding stays wired up so you can localize later with no rework.
> - Strip i18n out entirely: no additional languages, and remove i18n. Smaller bundle, less infrastructure. Two costs to weigh: stripping runs a long teardown step during init (more time and tokens now), and it's **hard to reverse**: re-adding i18n later is substantial manual work (there's no add-i18n runbook; you'd reconstruct the scaffolding and re-wrap every string by hand). Only pick this if you're confident the app stays single-language.
> - To add languages, pick "Other" and enter a comma-separated list of ISO 639-1 codes (e.g. `es, de, ar`); don't repeat {primary}.

Mark "Keep i18n scaffolding" as the recommended/default option.

Resolve two values from the answer:

- `LOCALES = unique({primary} code, any additional codes entered above)`. Either no-additional-languages option leaves `LOCALES` as just `[{primary}]`.
- `STRIP_I18N = true` only when the user chose "Strip i18n out entirely"; otherwise `false`. Adding languages or keeping the scaffolding both leave it `false`.

### Q3–Q5, Project identity (one AskUserQuestion, three questions)

These three go together as a group. Ask them in a single AskUserQuestion call:

**GitHub username for CODEOWNERS** (suggest @username format)

**Project title** (default: title-cased folder name from above)

**kebab-case slug** derived from the title (default: folder name from above)

## Step 3: Run the init CLI

The deterministic surface lives behind `gaia init`. Each subcommand is idempotent and records its own state in `.gaia/init-state.json`, so a failed step can be resumed via `gaia init resume`.

`STRIP_I18N` and `LOCALES` were resolved in Step 2: `STRIP_I18N` is `true` only when the user chose "strip i18n out entirely", otherwise `false`.

Run sequentially, stopping at the first non-zero exit:

```bash
.gaia/cli/gaia init strip-branding --title "<Project Title>"
.gaia/cli/gaia init configure-i18n --locales "<comma-separated locale list>" --strip <STRIP_I18N>
.gaia/cli/gaia init rename --title "<Project Title>" --kebab "<kebab-slug>"
.gaia/cli/gaia init wire-statusline --mode project
```

If any of these exit non-zero, surface the structured error verbatim (the CLI prints a JSON line to stderr) and stop. The user can re-run the failing command manually after addressing the cause, then resume with `.gaia/cli/gaia init resume`, completed steps are skipped automatically.

## Step 4: Locale-specific scaffolding (when not stripping i18n)

If `STRIP_I18N == false`, also run the prose locale instructions for every non-`en` locale in `LOCALES`:

For each locale in `LOCALES` where the locale is NOT `en`:

1. Resolve the locale's English display name (e.g. `Polish`), native display name (e.g. `Polski`), and RTL flag (`true` for `ar`/`he`/`fa`/`ur`, otherwise `false`).
2. Read `.claude/instructions/add-locale.md`.
3. Substitute the four template variables: `{{LOCALE_CODE}}`, `{{LANGUAGE_NAME_EN}}`, `{{LANGUAGE_NAME_NATIVE}}`, `{{IS_RTL}}`.
4. Execute every step in the substituted instruction. Stop on any failure.

If `STRIP_I18N == true`, read `.claude/instructions/remove-i18n.md` and execute every step. Stop on any failure.

## Step 5: Create CODEOWNERS

GAIA branding, the logo included, is stripped automatically by `gaia init strip-branding` in Step 3: FUNDING.yml, the `GaiaLogo` component, `app/assets/images/gaia-logo.svg`, and the Storybook brand are all removed or rewritten to the project title. There is no logo to supply during init.

The GAIA template does not ship a `.github/CODEOWNERS`, so create one: a single line naming the user's GitHub username as the repo-wide code owner.

```bash
printf '* @%s\n' "<github-username>" > .github/CODEOWNERS
```

`<github-username>` is the bare handle (no leading `@`); the `* @` prefix makes that user the default owner for every path.

## Step 6: Check `.env`

Run the CLI, it copies `.env.example` to `.env` when `.env` is absent, no-op otherwise. Routing through the CLI subprocess bypasses the project's `Write(.env)` deny rule, which guards against Claude writing secrets, not against init seeding from the example file.

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

GAIA bundles project-scoped skills at `.claude/skills/` (`eslint-fixes`, `playwright-cli`, `react-code`, `skeleton-loaders`, `tailwind`, `tdd`, `typescript`), they ship with the clone. Three external tools still need per-machine setup. The Serena MCP entry below requires `uv` (Astral's Python toolchain runner) on the host, GAIA precheck-installs it just like Step 0 precheck-installs pnpm.

- [React Doctor](https://github.com/millionco/react-doctor): `npx -y react-doctor@latest install --yes`
  Installs the `react-doctor` skill for detected agents (Claude Code included). Scans the project for React-specific issues (47+ rules: security, performance, correctness, architecture). Auto-runs after code edits in a `CLAUDECODE` environment and is invoked by the `code-review-audit` agent pre-merge.
- [Playwright CLI](https://github.com/microsoft/playwright-cli) binary: `npm install -g @playwright/cli@latest`
  Installs the global `playwright-cli` binary the bundled skill shells out to. Without it the skill's `allowed-tools: Bash(playwright-cli:*)` directive resolves to nothing. Used for E2E debugging and authoring Playwright specs with minimal token cost, each interaction is one shell call instead of a round-trip through an MCP session.
- [Serena](https://github.com/oraios/serena) MCP server: semantic code-search and editing tools (find symbol, find references, replace symbol body) backed by language servers, pulls Claude away from grep-the-world toward symbol-aware operations. First, ensure `uv` is available, tell the user: "Checking for uv…" then run:

  ```bash
  if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  ```

  After install, source the shell rc the installer modifies (or add `~/.local/bin` to `PATH` for this session) and verify with `uv --version`. If the verification fails, halt `/gaia-init` with: `uv is required for GAIA. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh, then re-run /gaia-init.` Once `uv` is confirmed present, register Serena with:

  ```bash
  claude mcp add serena -s user -- uvx --from git+https://github.com/oraios/serena@v1.2.0 serena start-mcp-server --open-web-dashboard false
  ```

  `-s user` registers Serena globally for the user's Claude Code; `--open-web-dashboard false` keeps it headless. The pinned ref keeps every GAIA install on the same Serena baseline. If the `claude mcp add` invocation itself fails (network, registry change, etc.), surface the error verbatim and halt `/gaia-init` so the user can retry the command manually after addressing the cause.

### Install plugins

- `claude plugin install typescript-lsp@claude-plugins-official`
- `claude plugin marketplace add AgriciDaniel/claude-obsidian`
- `claude plugin install claude-obsidian@claude-obsidian-marketplace`

### Initialize spec-kit and install the GAIA extension + preset

The GAIA `/gaia-spec` Socratic discovery workflow runs on top of [spec-kit](https://github.com/github/spec-kit). The template already ships the GAIA extension at `.specify/extensions/gaia/` and the GAIA preset at `.specify/presets/gaia/`, they need spec-kit's runtime registered around them.

Pin spec-kit at the version declared in `.specify/extensions/gaia/extension.yml` `requires.speckit_version` (currently `>=0.8.5,<0.10.0`; the floor is the runtime pin). Tell the user: "Initializing spec-kit and registering the GAIA extension + preset…" then run:

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

`specify init --here --ai claude --force` writes `.specify/{extensions.yml, integration.json, integrations/, memory/constitution.md, scripts/, templates/, workflows/}` and `.claude/skills/speckit-*` plus `CLAUDE.md`. The `--force` flag is required because the GAIA template ships some `.specify/` paths already; `specify init` refuses without it.

After install, `.specify/extensions/.registry` lists the `gaia` extension with all four registered commands (`speckit.gaia.spec`, `speckit.gaia.constitution-check`, `speckit.gaia.lint`, `speckit.gaia.self-review`); `.specify/presets/.registry` lists the `gaia` preset (priority 10, replaces `speckit.specify` and `spec-template`); `.claude/skills/speckit-gaia-*/SKILL.md` exist for each GAIA hook target; and `.claude/skills/speckit-specify/SKILL.md` is the GAIA preset wrap (core body spliced in via `{CORE_TEMPLATE}` substitution under `strategy: wrap`).

If any step fails, surface the error verbatim and halt, do not silently continue. The user can re-run the failing command manually and resume `/gaia-init` once spec-kit is in place.

### Configure CI integrations

GAIA CI has two parts: a pre-merge **audit gate** (the `code-review-audit` agent run against every PR) and four optional **maintenance jobs** on a smart cron (wiki sync, `/update-deps`, `pnpm audit`, stale-branch cleanup).

**No `.github/workflows/` files ship in this project.** They are generated and installed on demand by `/setup-gaia-ci` after your first `git push origin main` (Phase B). This step (Phase A) is local-only: it records your CI intent so Step 9 can offer the right maintenance-tool modes, and it sets the local audit baseline. It does not create, move, or push any workflow file, and it touches nothing on GitHub.

(`forensics-triage.yml` is maintainer-only and never ships to or installs on an adopter project. The adopter-side `/gaia-forensics` command files reports to the upstream GAIA repo, which owns the `gaia-forensics` label; nothing about forensics needs configuring here.)

Use AskUserQuestion (in the user's language; this configuration block stays in English):

> Do you plan to run GAIA CI (GitHub Actions) for this project?
>
> - **Yes, I'll enable CI after pushing** (Recommended). Records the intent; Step 9 then offers `ci` / `local` / `off` per maintenance tool. After your first push, run `/setup-gaia-ci` to install the audit gate and cron workflows, store the bot token, and register the `GAIA-Audit` required check.
> - **No, local only.** GAIA's audit and maintenance tools run only when you invoke them on this machine. Step 9 offers `local` / `off` only.

Record the answer as the **Configure-CI decision** (`enabled` or `declined`); Step 9 reads it. This is held as init-state only; it neither probes nor writes any workflow file.

Then set the audit baseline in `.gaia/audit-ci.yml` regardless of the answer. Until `/setup-gaia-ci` wires CI, the local `code-review-audit` agent is the only producer of the `GAIA-Audit` stamp, so `local` is the only valid baseline. `/setup-gaia-ci`'s team audit-mode step sets `default_mode: ci` later if you choose CI-audits-every-PR. Never set this to `off` or any other disabled value, the audit gate is non-negotiable.

```bash
# Idempotent: rewrite an existing default_mode line, or append the key if absent.
if [ -f .gaia/audit-ci.yml ] && grep -qE '^default_mode:' .gaia/audit-ci.yml; then
  sed -i.bak -E 's/^default_mode:.*/default_mode: local/' .gaia/audit-ci.yml && rm -f .gaia/audit-ci.yml.bak
else
  printf '\n# Team baseline audit mode. Until /setup-gaia-ci wires CI, the local audit\n# agent is the only GAIA-Audit producer; local is the only valid value here.\ndefault_mode: local\n' >> .gaia/audit-ci.yml
fi
```

To enable CI later: push to GitHub, then run `/setup-gaia-ci`. It installs `.github/workflows/code-review-audit.yml` (the PR gate) plus any cron workflows, stores your bot token as a repo secret, registers the `GAIA-Audit` required check, and sets the team audit `default_mode`. `/update-gaia` keeps the installed audit workflow in sync with its template thereafter.

### Make the statusline executable

The CLI in Step 3 wired the statusline command into Claude settings; the wrapper still needs the executable bit:

```bash
chmod +x .gaia/statusline/*.sh
```

(Idempotent, safe to run regardless.)

### Verify installs

After all installs and plugin registrations above, run a probe-after pass to confirm each component landed. For each component below, run the probe and emit one line:

| Component       | Probe                                                                                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| React Doctor    | `[ -d ~/.claude/skills/react-doctor ]`                                                                                                                  |
| Playwright CLI  | `command -v playwright-cli && playwright-cli --version >/dev/null 2>&1`                                                                                 |
| Serena          | `claude mcp list 2>/dev/null \| grep -q '^serena:'`                                                                                                     |
| typescript-lsp  | `claude plugin list 2>/dev/null \| grep -q 'typescript-lsp'`                                                                                            |
| claude-obsidian | `claude plugin list 2>/dev/null \| grep -q 'claude-obsidian'`                                                                                           |
| spec-kit        | `[ -f .specify/integration.json ] && grep -q 'gaia' .specify/extensions/.registry 2>/dev/null && grep -q 'gaia' .specify/presets/.registry 2>/dev/null` |

Emit one line per component: `[ok] <component>` if the probe exits 0, `[FAIL] <component>` if it exits non-zero.

After all probes run: if any component shows `[FAIL]`, print the full table, then halt `/gaia-init` with:

> "One or more components failed verification. Retry the failed install commands above, then resume with `.gaia/cli/gaia init resume`."

If all probes pass, print the full table and continue to Step 9.

The same probe set applies when setting up from an existing clone, `/setup-cloned-gaia-project` runs it after registering external tools.

## Step 9: Configure GAIA CI (Phase A)

GAIA CI is an optional automated maintenance system that runs four jobs on a smart schedule (wiki sync, dep refresh via `/update-deps`, `pnpm audit`, stale-branch cleanup), opens labeled PRs, and auto-merges on green CI. Phase A, this step, is local-only: it writes `.gaia/automation.json` with your tool selections and `setup_complete: false`. No GitHub repo or workflow files are involved here. After you push to GitHub for the first time, you'll run `/setup-gaia-ci` to wire up tokens and activate CI (Phase B).

**Carry the Configure-CI decision forward.** The Configure CI integrations block above already recorded whether the user intends to enable CI (`enabled`) or run local only (`declined`). Hold that decision as init-state for this step, do NOT re-probe the filesystem (no workflow files exist at init time, so there is nothing to detect). Step 9 branches on it: a CI decline means CI is not a valid target for any maintenance tool, so the contradictory "Enable all four in CI mode" recommendation is never shown.

**The unconditional terminal action of Step 9, on every exit path (the enumerated recommendation, a free-text answer, a CI decline, or a resumed run), is a single `gaia init configure-automation` call with all four tool modes set to valid values.** No branch may end Step 9 with a half-written or absent `.gaia/automation.json`. The CLI handler writes a complete, schema-valid config (`setup_complete: false`, `update_gaia.mode: local`, all four tool modes) in one atomic write; the prose's only job is to guarantee that call always runs with derived modes.

### Branch A, CI was enabled

Tell the user (in their language; the table headers stay English):

> Configure GAIA's automated maintenance jobs. Recommended: enable all four in CI mode so they run unattended. You can pick a different mode per tool.

Use AskUserQuestion to confirm the recommendation OR open per-tool overrides:

> How should GAIA CI's tools run?
>
> - **Enable all four in CI mode (Recommended).** Sets `wiki`, `update_deps`, `pnpm_audit`, and `stale_branches` to `ci`. Phase B (`/setup-gaia-ci`) activates them.
> - **Customize per tool.** Show the table below and ask for each tool's mode.

If the user picks "Customize per tool", show this table and use AskUserQuestion once per row (or one combined free-text prompt; the prose is the contract, the prompt shape is at the assistant's discretion):

| Tool             | Default | What it does                                         | Modes                  |
| ---------------- | ------- | ---------------------------------------------------- | ---------------------- |
| `wiki`           | `ci`    | Smart-cron wiki sync against `app/**` changes.       | `ci` / `local` / `off` |
| `update_deps`    | `ci`    | Weekly dependency refresh, auto-merging patch/minor. | `ci` / `local` / `off` |
| `pnpm_audit`     | `ci`    | Daily security audit; targeted PR for high/critical. | `ci` / `local` / `off` |
| `stale_branches` | `ci`    | Monthly cleanup of branches merged >30 days ago.     | `ci` / `local` / `off` |

### Branch B, CI was declined

Do NOT show the "Enable all four in CI mode" recommendation, CI is not a valid target. Auto-derive every tool's mode to `local` (the only producer is the adopter's local invocation) and tell the user (in their language; table headers stay English):

> You declined GAIA CI, so the maintenance tools default to `local`, they run only when you invoke them on this machine. Set any tool to `off` if you don't want it at all.

Use AskUserQuestion to confirm the all-`local` derivation OR open per-tool overrides between `local` and `off` only (never `ci`):

> How should GAIA's maintenance tools run? (CI is unavailable.)
>
> - **All four `local` (Recommended).** Sets `wiki`, `update_deps`, `pnpm_audit`, and `stale_branches` to `local`. Each runs only when you invoke it here.
> - **Customize per tool.** Choose `local` or `off` for each of the four tools.

Mode meanings:

- `ci`, runs in GitHub Actions on the documented cadence; PRs auto-merge on green CI. (Only offered when CI was enabled.)
- `local`, does not run in CI; only the adopter's local invocation runs the tool.
- `off`, never runs (neither in CI nor locally via the smart entrypoints).

The fifth config key, `update_gaia.mode`, is fixed to `local` and not surfaced as a question, `/update-gaia` is a per-machine command by design.

### Apply the answer

Once you have a value for each of the four tools (from Branch A, Branch B, or a resumed run's saved arguments), run, ALWAYS, the terminal write:

```bash
.gaia/cli/gaia init configure-automation \
  --wiki <wiki-mode> \
  --update-deps <update-deps-mode> \
  --pnpm-audit <pnpm-audit-mode> \
  --stale-branches <stale-branches-mode>
```

Substitute each `<*-mode>` with the derived selection (`ci` is only valid on the CI-enabled branch; the CI-declined branch substitutes `local` or `off`). This call is mandatory on every exit path, there is no Step 9 branch that skips it.

If the CLI exits non-zero, surface the structured-error JSON verbatim and stop. The user can re-run the failing command manually after addressing the cause, then resume `/gaia-init` with `.gaia/cli/gaia init resume`.

End of Step 9.

## Step 10: Mentorship opt-in

Tell the user (in their language): "GAIA includes an optional mentorship layer that learns how you work and adapts in-session, fully on your machine, never sent off it. Let's set the default."

Then show the privacy explainer (this block stays English regardless of UI language, it's the canonical contract):

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
> **Read more:** https://gaiareact.com/mentorship/

Use AskUserQuestion. The question text must include the link: "Would you like to enable GAIA's mentorship layer? https://gaiareact.com/mentorship/". Three options in this exact order:

- **Not now (you can enable later if you like)**: `mentorship.enabled = false`, `analytics.enabled = false`. Init proceeds.
- **Yes, enable mentorship + anonymous analytics**: `mentorship.enabled = true`, `analytics.enabled = true`. Provision mentorship tree with `chmod 700/600`. Init proceeds.
- **Tell me more before I decide**: short description only (e.g. "Claude will explain how mentorship works before you decide"). When selected, Claude outputs the full privacy explainer, then drops into a free-form Q&A loop; on user signal of completion, re-present the same three-option AskUserQuestion. Init does not proceed until either "Not now" or "Yes, enable" is selected.

### Apply the answer

**On "Not now":**

```bash
.gaia/cli/gaia mentorship _internal-write-config --enabled false --analytics false --decided-via gaia-init
```

(Internal subcommand, see notes.)

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

Read `wiki/log.md` first, then replace the entire file with the following content (the GAIA development log is irrelevant to the new project). Substitute `<LANGUAGES>` with this run's configured locale codes, comma-separated (e.g. `en` or `en, es, de`); if i18n was stripped, write `single-language (i18n removed)`.

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
- Languages: <LANGUAGES>
- Removed: GAIA branding (FUNDING.yml, GaiaLogo component, README, Storybook brand, gaia-logo.svg)
- Installed: React Doctor, TDD, Playwright CLI skills; typescript-lsp, claude-obsidian plugins
```

## Step 12: Finalize

Mark per-machine setup as complete so the statusline does not show "Run /setup-cloned-gaia-project (Required)". `/gaia-init` performs all the same per-machine work as `/setup-cloned-gaia-project` (tools, plugins, spec-kit, statusline chmod, .env, mentorship), but it does not call `gaia setup mark-step` as it goes, so stamp the state file with `--force` now that everything is done:

```bash
.gaia/cli/gaia setup finalize --force
```

Then run the CLI's init finalize step, it removes the `/init` interceptor hook, prunes the matching entry from `.claude/settings.json`, and deletes this command file:

```bash
.gaia/cli/gaia init finalize
```

Then output the message below verbatim. Output the `cd` line exactly as written, even though Claude is currently running inside the project folder: when the user exits Claude back to the terminal, their shell returns to the directory they launched from (the parent), not the project folder. Do not tell the user they are "already inside" the folder or that they can skip the `cd`.

> <Project Title> is ready for development. To pick up the new plugin and skill state, exit Claude, then from your terminal:
>
> ```
> cd <project-folder-name>
> ```
>
> Then start Claude again.
>
> After you create your GitHub repo and push, run `/setup-gaia-ci` to wire up tokens and enable CI.

## On failure: resume

If any `gaia init <step>` invocation exits non-zero, the structured-error JSON on stderr explains the cause. After fixing the cause, re-run with:

```bash
.gaia/cli/gaia init resume
```

Resume reads `.gaia/init-state.json`, skips already-complete steps, and replays remaining steps using the saved arguments. Use `--from-step <N>` to force restart from a specific step (1-indexed: 1=strip-branding, 2=configure-i18n, 3=rename, 4=wire-statusline, 5=configure-automation, 6=finalize).
