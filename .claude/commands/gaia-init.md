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

## Step 3: Strip GAIA-specific branding

Run in one shell:

```bash
rm -rf .github/FUNDING.yml app/components/GaiaLogo
```

Replace the root `README.md` with the project-agnostic template and substitute the project title (use the value collected in Step 2; use Title Case):

```bash
cp .gaia/templates/README.md README.md
sed -i.bak 's/{{PROJECT_TITLE}}/<Project Title>/g' README.md && rm README.md.bak
```

The `{{PROJECT_TITLE}}` placeholder is the exact token in the template; the `sed -i.bak … && rm …bak` form is BSD/macOS-compatible and works on GNU sed as well.

Then edit `app/components/Header/index.tsx`:

- Remove the `GaiaLogo` import
- Replace `<GaiaLogo className="h-6 sm:h-7" />` with a text wordmark: `<span className="text-body text-xl font-bold">{t('meta.siteName')}</span>`

Then replace `app/assets/images/gaia-logo.svg` with the project's own logo SVG. The Storybook brand logo imports it directly — no `preview.ts` edits needed.

## Step 4: Update CODEOWNERS

Replace `.github/CODEOWNERS` contents with just the user's GitHub username (the whole file becomes a single line like `* @username`).

## Step 5: Configure i18n based on Step 2 answers

Branch on the answers from Step 2:

### Branch A — Multiple locales (`len(LOCALES) > 1`)

For each locale in `LOCALES` where the locale is NOT `en`:

1. Resolve the locale's English display name (e.g. `Polish`), native display name (e.g. `Polski`), and RTL flag (`true` for `ar`/`he`/`fa`/`ur`, otherwise `false`).
2. Read `.claude/instructions/add-locale.md`.
3. Substitute the four template variables: `{{LOCALE_CODE}}`, `{{LANGUAGE_NAME_EN}}`, `{{LANGUAGE_NAME_NATIVE}}`, `{{IS_RTL}}`.
4. Execute every step in the substituted instruction. Stop on any failure.

(English is already seeded — no add-locale invocation needed for `en`.)

### Branch B — Single locale, keep i18n (`len(LOCALES) == 1` and Q3 == Yes)

Two sub-cases:

- If the single locale is `en`: nothing to do (already seeded).
- If the single locale is NOT `en`: run `add-locale.md` for that locale (as in Branch A), then edit `app/languages/index.ts` to make that locale the default fallback (swap `fallbackLng: 'en'` in `app/i18n.ts` if the project wants the new locale as default — confirm with the user before flipping this).

### Branch C — Single locale, strip i18n (`len(LOCALES) == 1` and Q3 == No)

Read `.claude/instructions/remove-i18n.md` and execute every step. Stop on any failure.

## Step 6: Rename the project

Use the project title from Step 2.

- `package.json` `"name"` field → kebab-case of project title (e.g. `"hello-world"`)
- `CLAUDE.md` — replace the `# GAIA React` heading with `# <Project Title>` (Title Case, e.g. `# Hello World`)

**If i18n is still present (Branch A or B from Step 5):**

- `app/languages/en/pages/_index.ts` — update `meta.title`, `title`, and `heroTitle` to the project title
- `app/languages/en/common.ts` — update `meta.siteName` to the project title
- Do the same for every other `app/languages/<lang>/pages/_index.ts` and `common.ts` file that exists after Step 5 (translate the title if appropriate, otherwise use the English project title). Only loop over locales that actually exist — do not reference any locale that was not added in Step 5.

**If i18n was stripped (Branch C from Step 5):**

- Edit the relevant components and route files directly with raw English strings:
  - Replace `t('meta.siteName')` with the literal project title string wherever it appears (e.g. `app/components/Header/index.tsx` — already handled by Step 3's wordmark, verify)
  - Replace any remaining `t('meta.title')`, `t('title')`, `t('heroTitle')` references in route/page files with the literal project title string

## Step 7: Check `.env`

If a `.env` file does not exist, rename `.env.example` to `.env`. If `.env` already exists, leave it.

## Step 8: Verify the build

Run sequentially, stopping at the first failure:

```bash
pnpm typecheck && pnpm lint && pnpm test:ci && pnpm build
```

Fix any issues before moving on.

## Step 9: Claude configuration

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
uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify init --here --ai claude --force
yes | uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify extension add --dev .specify/extensions/gaia
yes | uvx --from "git+https://github.com/github/spec-kit.git@${SPECKIT_PIN}" specify preset add --dev .specify/presets/gaia
```

`specify init --here --ai claude --force` writes `.specify/{extensions.yml, integration.json, integrations/, memory/constitution.md, scripts/, templates/, workflows/}` and `.claude/skills/speckit-*` plus `CLAUDE.md`. The `--force` flag is required because the GAIA template ships some `.specify/` paths already; `specify init` refuses without it.

After install, `.specify/extensions/.registry` lists the `gaia` extension with all four registered commands (`speckit.gaia.spec`, `speckit.gaia.constitution-check`, `speckit.gaia.lint`, `speckit.gaia.self-review`); `.specify/presets/.registry` lists the `gaia` preset (priority 10, replaces `speckit.specify` and `spec-template`); `.claude/skills/speckit-gaia-*/SKILL.md` exist for each GAIA hook target; and `.claude/skills/speckit-specify/SKILL.md` is the GAIA preset wrap (core body spliced in via `{CORE_TEMPLATE}` substitution under `strategy: wrap`).

If any step fails, surface the error verbatim and halt — do not silently continue. The user can re-run the failing command manually and resume `/gaia-init` once spec-kit is in place.

### Wire the GAIA statusline

Add the project-scoped GAIA statusline to **project** `.claude/settings.json` so the user gets `/update-deps` and `/update-gaia` hints automatically. The wrapper at `.gaia/statusline/gaia-statusline.sh` delegates the left-side render and only appends GAIA addons inside this project.

Make `.gaia/statusline/*.sh` executable: `chmod +x .gaia/statusline/*.sh` (idempotent — safe to run regardless).

Inspect `~/.claude/settings.json` for a top-level `statusLine` key, then branch:

#### Branch A — adopter has a custom global statusline (`statusLine` exists in `~/.claude/settings.json`)

Show the user a colored preview of the wrapped result by running:

```bash
GAIA_PREVIEW_TMP="$(mktemp -d)/gaia-example"
mkdir -p "$GAIA_PREVIEW_TMP" && git -C "$GAIA_PREVIEW_TMP" init -q -b feat/example-name \
  && git -C "$GAIA_PREVIEW_TMP" -c user.email=x@x -c user.name=x commit -q --allow-empty -m preview
mkdir -p .gaia/cache
cat > .gaia/cache/update-check.json <<'JSON'
{"checkedAt":9999999999,"outdatedCount":3,"gaiaCurrent":"1.0.0","gaiaLatest":"1.2.0","gaiaHasUpdate":true}
JSON
echo '{"workspace":{"current_dir":"'"$GAIA_PREVIEW_TMP"'"},"model":{"display_name":"Claude Opus 4.7"},"context_window":{"used_percentage":42}}' \
  | bash .gaia/statusline/gaia-statusline.sh; echo
rm -rf "$(dirname "$GAIA_PREVIEW_TMP")"
rm -f .gaia/cache/update-check.json
```

The Bash output renders with ANSI colors in the chat. The `gaia-example` / `feat/example-name` placeholders keep the preview stable regardless of the adopter's real cwd or branch — once wired, the live statusline reflects their actual project + branch. Tell the user: "GAIA addons will append to your existing global statusline only when Claude is launched in this project." Then write the project-level wrapper into `.claude/settings.json` (insert alphabetically):

```json
"statusLine": {
  "type": "command",
  "command": "bash .gaia/statusline/gaia-statusline.sh"
}
```

#### Branch B — adopter is on the default Claude statusline (no global `statusLine`)

Render the same colored preview as Branch A. Then `AskUserQuestion`:

> Install GAIA's recommended statusline (project + branch + model + context bar)?
>
> - **Globally** — show this layout in every project, plus GAIA addons inside GAIA projects (Recommended).
> - **Only in this GAIA project** — show only when Claude is launched here.
> - **Skip** — keep Claude's default; GAIA addons still append in this project.

Apply the answer:

- **Globally** → copy `.gaia/statusline/preferred-base.sh` to `~/.claude/preferred-base.sh`, `chmod +x` it, and write into `~/.claude/settings.json`:

  ```json
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/preferred-base.sh"
  }
  ```

  (Insert alphabetically into the user-level JSON. Preserve any existing keys.)

- **Only in this GAIA project** → `touch .gaia/statusline/.use-vendored-base`. The sentinel is gitignored; the wrapper detects it and routes to the vendored base.

- **Skip** → no extra action.

In all three sub-cases, write the project-level wrapper into `.claude/settings.json` exactly as in Branch A.

Before writing either settings file, read its current contents so you merge rather than overwrite. Use jq or manual JSON editing — never truncate the file.

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
> **Read more:** https://gaiareact.com/mentorship

Use AskUserQuestion with these three options in this exact order:

- **Not now (you can enable later if you like)** (Recommended) — `mentorship.enabled = false`, `analytics.enabled = false`. Init proceeds.
- **Yes, enable mentorship + anonymous analytics** — `mentorship.enabled = true`, `analytics.enabled = true`. Provision mentorship tree with `chmod 700/600`. Init proceeds.
- **Tell me more before I decide** — drop into a free-form Q&A loop where Claude answers questions about mentorship; on user signal of completion, re-present the same three-option AskUserQuestion. Init does not proceed until either "Not now" or "Yes, enable" is selected.

### Apply the answer

**On "Not now":**

```bash
bin/gaia mentorship _internal-write-config --enabled false --analytics false --decided-via gaia-init
```

(Internal subcommand — see notes.)

**On "Yes, enable":**

```bash
bin/gaia mentorship _internal-write-config --enabled true --analytics true --decided-via gaia-init
bin/gaia mentorship _internal-provision-dirs
```

`_internal-provision-dirs` calls `ensureMentorshipDirs(roots)` from the storage-paths module and exits 0 silently. The chmod 700/600 is applied at create time.

**On "Tell me more":**

Drop into Q&A. Claude has the design notes available in context (the explainer above + `studio/decisions/telemetry-v1-design.md` and `studio/decisions/local-adaptive-mentorship.md` if needed for deeper questions). See `.claude/rules/mentorship-display.md` for the project-wide contract on what Claude does with mentorship data. When the user signals they're done (e.g. "ok ready to decide"), re-present the same AskUserQuestion. Loop until the user picks Not now or Yes.

End of Step 10.

## Step 11: Refresh the wiki

The template ships with a wiki shaped for the upstream GAIA project. Refresh the two files that encode "where we are right now" so the new project starts with a clean context:

### 11a. Overwrite `wiki/hot.md`

Replace the entire file with:

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

Replace the entire `wiki/log.md` file with the following content (the GAIA development log is irrelevant to the new project):

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

## Step 12: Complete

1. Remove the `/init` interceptor — it protects the template's curated `CLAUDE.md` and is no longer needed once a project has been initialized:
   - Delete `.claude/hooks/intercept-init.sh`
   - Edit `.claude/settings.json`: from `hooks.UserPromptSubmit`, remove only the matcher entry whose inner `hooks[].command` is `.claude/hooks/intercept-init.sh`. Preserve any other entries the user may have added. If removing it leaves `UserPromptSubmit` as an empty array, also remove the `UserPromptSubmit` key itself.
2. Delete this command file so it can't be run again: `rm .claude/commands/gaia-init.md`
3. Output: "<Project Title> is ready for development. Restart Claude to pick up the new plugin and skill state."
