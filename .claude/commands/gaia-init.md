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

GAIA bundles project-scoped skills at `.claude/skills/` (`eslint-fixes`, `playwright-cli`, `react-code`, `skeleton-loaders`, `tailwind`, `tdd`, `typescript`) — they ship with the clone. Two external tools still need per-machine setup:

- [React Doctor](https://github.com/millionco/react-doctor): `curl -fsSL https://react.doctor/install-skill.sh | bash`
  Installs the `react-doctor` skill to `~/.claude/skills/`. Scans the project for React-specific issues (47+ rules: security, performance, correctness, architecture). Auto-runs after code edits in a `CLAUDECODE` environment and is invoked by the `code-review-audit` agent pre-merge.
- [Playwright CLI](https://github.com/microsoft/playwright-cli) binary: `npm install -g @playwright/cli@latest`
  Installs the global `playwright-cli` binary the bundled skill shells out to. Without it the skill's `allowed-tools: Bash(playwright-cli:*)` directive resolves to nothing. Used for E2E debugging and authoring Playwright specs with minimal token cost — each interaction is one shell call instead of a round-trip through an MCP session.

### Install plugins

- `claude plugin install typescript-lsp@claude-plugins-official`
- `claude plugin marketplace add AgriciDaniel/claude-obsidian`
- `claude plugin install claude-obsidian@claude-obsidian-marketplace`

### Install the GAIA statusline (optional)

The GAIA statusline shows: **project folder | git branch | active model | context window usage**.

Show the user a live preview by running:

```bash
echo '{"workspace":{"current_dir":"'"$(pwd)"'"},"model":{"display_name":"Claude Opus 4.7"},"context_window":{"used_percentage":42}}' \
  | bash .gaia/statusline/preferred-base.sh; echo
```

The Bash output renders with ANSI colors in the chat. Then `AskUserQuestion`:

> Install the GAIA statusline (project | branch | model | context bar)?
>
> - **Globally (Recommended)** — show this statusline in every project on this machine.
> - **Only in this project** — show only when Claude is launched in this GAIA project.
> - **Skip** — keep Claude's default statusline.

Apply the answer:

- **Globally** → copy `.gaia/statusline/preferred-base.sh` to `~/.claude/preferred-base.sh`, `chmod +x ~/.claude/preferred-base.sh`, then write into `~/.claude/settings.json` (insert alphabetically, preserving existing keys):

  ```json
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/preferred-base.sh"
  }
  ```

- **Only in this project** → write into `.claude/settings.json` (insert alphabetically, preserving existing keys):

  ```json
  "statusLine": {
    "type": "command",
    "command": "bash .gaia/statusline/preferred-base.sh"
  }
  ```

- **Skip** → no action.

Before writing either settings file, read its current contents so you merge rather than overwrite. Use jq or manual JSON editing — never truncate the file.

## Step 10: Refresh the wiki

The template ships with a wiki shaped for the upstream GAIA project. Refresh the two files that encode "where we are right now" so the new project starts with a clean context:

### 10a. Overwrite `wiki/hot.md`

Replace the entire file with:

```md
---
type: meta
title: Hot Cache
updated: <TODAY_ISO>
---

# Recent Context

## Last Updated

<TODAY>. Project initialized via `/gaia-init`. Fresh slate.

## Active Threads

- None.
```

### 10b. Overwrite `wiki/log.md`

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

## Step 11: Complete

1. Remove the `/init` interceptor — it protects the template's curated `CLAUDE.md` and is no longer needed once a project has been initialized:
   - Delete `.claude/hooks/intercept-init.sh`
   - Edit `.claude/settings.json`: from `hooks.UserPromptSubmit`, remove only the matcher entry whose inner `hooks[].command` is `.claude/hooks/intercept-init.sh`. Preserve any other entries the user may have added. If removing it leaves `UserPromptSubmit` as an empty array, also remove the `UserPromptSubmit` key itself.
2. Delete this command file so it can't be run again: `rm .claude/commands/gaia-init.md`
3. Output: "<Project Title> is ready for development. Restart Claude to pick up the new plugin and skill state."
