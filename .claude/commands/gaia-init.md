---
name: gaia-init
description: Initialize a new project from the GAIA React template, renames, strips GAIA branding, configures i18n, installs Claude skills/plugins.
---

Initialize a new project from the GAIA React template. The template already ships clean (no example code, no docs site, no auth). This command renames, strips GAIA-specific branding, configures i18n, installs Claude skills/plugins, and hands you a ready-to-build project.

**Language meta-instruction:** Conduct this entire conversation in the language the user has been typing in. Detect it from prior context, no explicit detection step needed. Do not translate source files, rules, skills, or wiki entries, those stay English regardless. Only translate the prompts you show the user.

## Interactive gates: run mode and non-response policy

`/gaia-init` asks the user a series of questions ("gates"). This section governs how **every** gate behaves and overrides any harness default. Read it before the first gate and apply it to each one.

### Harness timeout note, override

After a gate sits unanswered for a while, the harness injects a stock note like "the user may be away from keyboard, proceed using your best judgment, you can re-ask later." That note is generic, it does not describe this command, and it keeps firing on gate after gate. **Do not act on it literally.** Inside `/gaia-init` it means only "apply the non-response policy below", never "the user is gone, auto-answer everything."

### No cascade

Evaluate each gate independently. A non-response on one gate is **never** evidence the user is away for any other gate. A timeout on the language question tells you nothing about the title, the CODEOWNERS handle, or the CI question. Never carry an "away" inference forward, re-ask the next gate normally.

### Tone

Never narrate "since you're away" or otherwise assert the user is absent. Non-response is not proof of absence, the user may be reading, thinking, or opening a docs link. State what you are doing plainly, without diagnosing why the user paused.

### Run mode, the first gate

Before Step 0's pnpm check, ask this as the **very first** AskUserQuestion (in the user's language):

> How do you want to handle the setup questions?
>
> - **Interactive** (Recommended). GAIA asks about language, project name, CODEOWNERS, and CI one at a time and waits for your answer on the consequential ones.
> - **Automatic.** GAIA selects the recommended default for every question for you, without stopping to ask. It shows you the full list of chosen defaults first, and you can change anything afterward.

List **Interactive** first (the recommended option) and **Automatic** second. This gate is itself HARD-BLOCK: on non-response, re-ask, never assume a mode.

- **Interactive**: apply the per-tier non-response rules below to every later gate.
- **Automatic**: the user has pre-consented to defaults. First show the Automatic defaults table (see "Automatic defaults, per gate" below), then apply each gate's recommended default and continue without asking. One exception, free-text identity values are still never fabricated: CODEOWNERS gets the loud placeholder, never a guess.

### Gate tiers

Every gate is one of two tiers. The tier is fixed here, do not reclassify by judgment.

**HARD-BLOCK** (consequential / irreversible / identity). On non-response in interactive mode: re-ask and wait for an explicit answer. Never apply a default and move on, never guess.

| Gate | Where |
|---|---|
| Run mode (this section) | before Step 0 |
| pnpm upgrade consent | Step 0c |
| Primary app language (+ "Other" free-text) | Step 2, Q1 |
| Additional languages / i18n teardown, `STRIP_I18N` (+ free-text) | Step 2, Q2 |
| CODEOWNERS GitHub handle (HARD-BLOCK only when `gh` can't detect it) | Step 2, Q3 |
| Project title | Step 2, Q4 |
| kebab-case slug | Step 2, Q5 |
| CI intent (Configure-CI decision) | Step 8, Configure CI integrations |

**SAFE-DEFAULT** (reversible, the recommended default is the safe outcome). On non-response in interactive mode: re-ask once; if still no answer, apply the stated default, name it plainly ("Defaulting the maintenance tools to their recommended run mode, you can reconfigure later"), and continue. Do not claim the user is absent.

| Gate | Default on non-response | Where |
|---|---|---|
| Maintenance-tool run modes | all `ci` (CI enabled) or all `local` (CI declined) | Step 9 |

### Free-text identity values are never fabricated

The CODEOWNERS GitHub handle, and any similar free-text identity field, must come from the user. A guessed handle is a silent correctness bug: a wrong owner ships in `.github/CODEOWNERS`. Never write a plausible-looking guess.

**Detecting the handle is not fabricating it.** The GitHub CLI, when installed and authenticated, reports the user's *own* authenticated login. That is the user's real identity, not a guess, so using it never violates this rule. There is one authoritative detection method, used everywhere `/gaia-init` needs the handle:

```bash
handle=""
if command -v gh >/dev/null 2>&1; then
  handle="$(gh api user --jq .login 2>/dev/null)"
fi
# $handle is the authenticated login, or empty on any failure
```

`gh api user` is the most reliable method: a single call both verifies auth and returns the login. Treat detection as **failed** if `gh` is absent, unauthenticated, or the call returns empty. Do **not** fall back to `git config user.name` (a display name, not a handle) or remote-URL parsing (there is no remote at init time). What stays never-fabricated is any handle that is neither user-typed nor gh-detected: never invent a plausible-looking one.

- Interactive: offer the gh-detected handle as the recommended default; the user can override it. HARD-BLOCK applies only when detection failed (no default to fall back to): re-ask, do not reach Step 5 without a real handle.
- Automatic: use the gh-detected handle when available. Only when detection also fails, write a loud placeholder that fails visibly, never a guess. Use `REPLACE-WITH-YOUR-GITHUB-HANDLE`, GitHub flags it as an unknown owner so the gap is obvious, and surface it in the Step 11 summary as a required follow-up.

### Automatic defaults, per gate

When the user chose Automatic, first detect the project folder name (`basename "$(git rev-parse --show-toplevel)"`), run the GitHub-handle detection from "Free-text identity values are never fabricated" above, and use the already-detected primary language, then show the user this table (substitute the bracketed values, leave everything else verbatim) so they can catch anything before init proceeds:

> **Automatic mode. Applying these defaults:**
>
> | Setting | Value | Reversible? |
> |---|---|---|
> | Primary language | {detected language, e.g. English (en)} | Costly, re-run i18n |
> | Additional languages | None, i18n scaffolding kept | Yes, fully |
> | Project title | {title-cased folder name} | Yes, re-run rename |
> | Slug | {folder name} | Yes, re-run rename |
> | CODEOWNERS handle | {gh-detected handle when available, else `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder} | Placeholder: one-line edit required. Detected handle: none |
> | GAIA CI intent | Enabled, activate later via /setup-gaia | Yes, /setup-gaia --reconfigure |
> | Maintenance tools | All four in `ci` mode | Yes, reconfigure |

Exactly one row per setting. For the CODEOWNERS row, show the gh-detected handle when detection succeeds (it is the user's own authenticated identity, not a guess), otherwise the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder. **Never** put a guessed or git-config-derived handle there: the only non-placeholder value allowed is the gh-detected login.

Then apply the defaults and proceed without stopping (the user chose Automatic; do not block, they can interrupt if they want to change something):

- pnpm upgrade (0c): upgrade (Yes), it is required to continue.
- Primary language (Q1): the detected user language.
- Additional languages / i18n (Q2): primary-only, keep i18n scaffolding (`STRIP_I18N=false`). The teardown is never auto-selected.
- CODEOWNERS (Q3): the gh-detected handle when available; otherwise the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder, flagged as a required Step 11 follow-up. Never a guessed or git-derived handle.
- Project title (Q4): title-cased folder name.
- kebab slug (Q5): folder name.
- CI intent (Step 8): "Yes, I'll enable CI after pushing" (records intent only).
- Maintenance tools (Step 9): all `ci`.

## Step 0: Ensure pnpm is available (and new enough)

**First, ask the run-mode gate** from "Interactive gates: run mode and non-response policy" above, it is the very first thing `/gaia-init` asks. Hold the answer (interactive or automatic) for every later gate. Then continue with the pnpm check.

GAIA needs pnpm 11+. Tell the user: "Checking for pnpm…" then read the currently-resolved version **from the project root** (so corepack's `packageManager` pin applies when it's active):

```bash
pnpm --version 2>/dev/null || echo "absent"
```

Branch on the result:

**a) `absent` (no pnpm on PATH):** auto-install. Prefer corepack (it activates the version pinned in `package.json` `packageManager`, currently `pnpm@11.9.0`); fall back to the latest global when corepack is missing.

```bash
if command -v corepack &>/dev/null; then
  corepack enable pnpm
else
  npm install -g pnpm@latest
fi
```

If this fails, stop and report the error. Then proceed to Step 1.

**b) Major version ≥ 11:** good, proceed to Step 1.

**c) Major version < 11 (a stale pnpm, e.g. 10.x):** do **not** silently proceed. Use the **AskUserQuestion** tool to get consent before touching the user's toolchain, with exactly these two options:

_Non-response: HARD-BLOCK. Re-ask; never auto-upgrade or auto-exit on a timeout. Automatic mode: upgrade (Yes)._

- **Yes (Required)**: "Upgrade pnpm to a supported version (11+). Required to continue with /gaia-init."
- **No**: "Keep the current pnpm and stop /gaia-init. Nothing has been installed or renamed yet, so it's safe to exit and re-run later."

On **No** (or anything that is not an explicit Yes): stop `/gaia-init` immediately with a one-line message. Step 0 runs before any file is installed or renamed, so exiting here leaves the clone untouched.

On **Yes**: upgrade by enabling corepack (its `packageManager` pin makes the in-project version 11.9.0 regardless of any stray global pnpm); fall back to a latest global install when corepack is missing.

```bash
if command -v corepack &>/dev/null; then
  corepack enable pnpm
else
  npm install -g pnpm@latest
fi
```

Then **re-verify from the project root**:

```bash
pnpm --version
```

If the major version is still < 11, a non-corepack pnpm (Homebrew, the standalone installer) is shadowing the upgrade earlier on `PATH`. Do **not** loop or silently continue. Show which binary wins and halt so the user can resolve it:

```bash
command -v pnpm   # e.g. /opt/homebrew/bin/pnpm, the shadowing install
```

Halt with: "pnpm <version> at <path> is older than the required 11+ and takes precedence on your PATH. Upgrade or remove it (e.g. `brew upgrade pnpm`, `pnpm self-update`) so corepack's pinned version wins, then re-run /gaia-init."

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

_Non-response: HARD-BLOCK. Re-ask; never auto-pick. Automatic mode: the detected user language._

Use AskUserQuestion with this single question:

> What should be the primary language for this app's UI?
>
> - {detected user language} (default, what you've been typing in)
> - English
> - Other (you'll specify the ISO 639-1 code and English name in a follow-up free-text prompt)

If the user picks "Other", ask for the value as a plain chat message and wait for the user to type their reply in the prompt. Do **not** use AskUserQuestion here: its preset options can't capture free text, and a hand-added "Other" option is an inert button with no input field.

> What language? Type it however you like, a name or a code, in English or its own script (e.g. `Polish`, `pl`, or `polski`).

Interpret the reply yourself: resolve it to an ISO 639-1 code plus English name. Only ask again if it's genuinely ambiguous or you can't identify the language.

Then echo the resolved choice back as a plain chat message so the user can catch a misread before anything runs, e.g. `Primary language: French (fr). Look right?` Wait for confirmation (or apply their correction and echo again) before continuing.

Hold the resolved choice as `{primary}` (ISO code + English name); the next batch interpolates it into its labels, which is why Q1 is asked first and alone.

### Q2, Additional languages + i18n scaffolding (asked alone)

_Non-response: HARD-BLOCK. Re-ask; the i18n teardown (`STRIP_I18N=true`) is never auto-selected. Automatic mode: primary-only, keep scaffolding (`STRIP_I18N=false`)._

The primary is now known, so its name can appear in the labels below. Ask this as its own AskUserQuestion. It folds the old standalone "localize later?" decision into the no-additional-languages branch, so that decision never needs its own round-trip:

> Primary language is {primary}. Any additional languages?
>
> - {primary} only, keep i18n scaffolding (Recommended): no additional languages; scaffolding stays wired so you can localize later with no rework.
> - Add more languages now: add locales on top of {primary} during init. You can also ask Claude to add languages later if you'd rather skip this for now.
> - {primary} only, remove i18n entirely: no additional languages, remove i18n. Smaller bundle, less infra, but a long teardown now, and hard to reverse (you'd rebuild scaffolding and re-wrap every string by hand). Only do this if you're confident the app will remain single-language.

Mark "{primary} only, keep i18n scaffolding" as the recommended/default option.

If the user picks "Add more languages now", ask for the languages as a plain chat message and wait for the user to type their reply in the prompt. Do **not** use AskUserQuestion here: its preset options can't capture free text, and a hand-added "Other" option is an inert button with no input field.

> Which languages? List them however you like, names or codes, in English or their own script, separated by commas (e.g. `fr, german, 日本語`).

Interpret the reply yourself: resolve each entry to an ISO 639-1 code, dedupe, and drop any that match {primary}. Only ask again about an entry you genuinely can't identify, don't make the user learn code syntax.

Then echo the resolved list back as a plain chat message so the user can catch a misread before anything runs, e.g. `Adding: German (de), Japanese (ja), Spanish (es). Look right?` Wait for confirmation (or apply their corrections and echo again) before moving to Step 3.

Resolve two values from the answer:

- `LOCALES = unique({primary} code, any additional codes entered above)`. Either {primary}-only option leaves `LOCALES` as just `[{primary}]`.
- `STRIP_I18N = true` only when the user chose "{primary} only, remove i18n entirely"; otherwise `false`. Adding languages or keeping the scaffolding both leave it `false`.

### Q3–Q5, Project identity (one AskUserQuestion, three questions)

_Non-response: title and slug are HARD-BLOCK, re-ask, never guess. CODEOWNERS: offer the gh-detected handle as the recommended default; HARD-BLOCK only when detection failed (no default to fall back to), re-ask, never guess. Automatic mode: title-cased folder name (title), folder name (slug), and the gh-detected handle (CODEOWNERS) when available, else the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder flagged as a required Step 11 follow-up._

These three go together as a group. Ask them in a single AskUserQuestion call:

**GitHub username for CODEOWNERS.** First run the GitHub-handle detection from "Free-text identity values are never fabricated" above (reuse the automatic-mode result if it already ran). If it yields a handle, offer it as the recommended default (first option); a gh-detected handle is the user's own authenticated identity, not a guess, so it is safe to default to. The user can still override it with a different handle via free text. If detection fails there is no default, so this stays a free-text identity value that is **never fabricated**: on interactive non-response, HARD-BLOCK and re-ask rather than guessing; in automatic mode, use the loud placeholder so a wrong owner never ships. Suggest `@username` format; store the bare handle.

**Project title** (default: title-cased folder name from above)

**kebab-case slug** derived from the title (default: folder name from above)

## Step 3: Run the init CLI

The deterministic surface lives behind `gaia init`. Each subcommand is idempotent and records its own state in `.gaia/init-state.json`, so a failed step can be resumed via `gaia init resume`.

`STRIP_I18N` and `LOCALES` were resolved in Step 2: `STRIP_I18N` is `true` only when the user chose "remove i18n entirely", otherwise `false`.

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

GAIA branding is stripped automatically by `gaia init strip-branding` in Step 3: FUNDING.yml is removed, the README is regenerated from the template with the project title, and the Storybook brand is rewritten to the project title. The template ships no GAIA logo, so there is nothing to supply during init.

The GAIA template does not ship a `.github/CODEOWNERS`, so create one: a single line naming the user's GitHub username as the repo-wide code owner.

```bash
printf '* @%s\n' "<github-username>" > .github/CODEOWNERS
```

`<github-username>` is the bare handle (no leading `@`); the `* @` prefix makes that user the default owner for every path.

`<github-username>` is the handle Q3 resolved: the user's typed handle, or the gh-detected login when the user accepted (or automatic mode used) that default. Any of these is a real handle, write `* @<handle>` and emit **no** Step 11 follow-up warning.

Only when Q3 obtained no real handle (automatic mode where gh detection also failed) is `<github-username>` the placeholder `REPLACE-WITH-YOUR-GITHUB-HANDLE`. Write it anyway, GitHub flags the unknown owner in its CODEOWNERS validation, so the gap is visible. Add a required follow-up to the Step 11 summary: "Edit `.github/CODEOWNERS`, it holds a placeholder owner, set your real GitHub handle." Never substitute a guessed handle.

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

  **Then strip React Doctor's bundled extras so GAIA stays the sole controller of when react-doctor runs.** The installer adds five things beyond the Claude Code skill: a standalone GitHub Actions workflow, a commit-hook block, a `doctor` package script, a pinned `react-doctor` devDependency, and a `.agents/skills/react-doctor/` copy of the skill for any other agents it detects (GitHub Copilot, Warp). There is no skill-only install flag, so install (above) then remove them. GAIA already triggers react-doctor two ways it owns, the Claude Code skill (auto-run after edits) and the `code-review-audit` agent pre-merge (always at `@latest`), so the bundled trigger points are redundant and they collide with GAIA's husky `pre-commit` hook and GAIA CI. Because GAIA sets `core.hooksPath=.husky/_`, the installer writes its hook into husky's generated (gitignored) stub at `.husky/_/pre-commit`, not GAIA's `.husky/pre-commit`; regenerating the husky stubs wipes it.

  ```bash
  # 1. Drop the standalone workflow (GAIA CI is the only CI surface).
  rm -f .github/workflows/react-doctor.yml
  # 2. Remove the non-Claude skill copy. The installer writes .agents/skills/react-doctor/ for
  #    any other agents it detects (Copilot, Warp); GAIA drives react-doctor through the Claude
  #    Code skill only, so this copy is redundant. rmdir the now-empty parents but leave any
  #    unrelated .agents/ content untouched (rmdir refuses a non-empty dir).
  rm -rf .agents/skills/react-doctor
  rmdir .agents/skills .agents 2>/dev/null || true
  # 3. Uninstall the pinned dep + lockfile entry. --config.ignore-scripts=true skips the
  #    prepare hook (avoids a redundant husky/playwright run); react-doctor runs at @latest on demand.
  pnpm remove react-doctor --config.ignore-scripts=true 2>/dev/null || true
  # 4. Delete the package script it added (named `doctor`, or `react-doctor` if `doctor` was taken).
  #    The hyphenated key needs bracket+quote form; a bare `scripts.react-doctor` throws
  #    ERR_PNPM_UNEXPECTED_TOKEN_IN_PROPERTY_PATH and aborts the whole command, leaving `doctor` behind too.
  pnpm pkg delete scripts.doctor 'scripts["react-doctor"]'
  # 5. Regenerate husky's hook stubs, wiping react-doctor's appended pre-commit block.
  pnpm exec husky
  ```

  Each line is idempotent and no-ops when its artifact is absent (e.g. when React Doctor's dependency install was skipped by a trust policy, or when no non-Claude agent was detected so no `.agents/` copy was written). After this, `git status` shows no React Doctor workflow and no `.agents/` skill copy, and `package.json` carries no `react-doctor` entry; only the Claude Code skill remains. Do not report a lingering workflow, `.agents/` copy, or commit hook to the user; there is none.
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
  claude mcp add serena -s user -- uvx --from git+https://github.com/oraios/serena@v1.2.0 serena start-mcp-server --context claude-code --project-from-cwd --open-web-dashboard false
  ```

  `-s user` registers Serena globally for the user's Claude Code; `--context claude-code` selects Serena's Claude-Code tool context instead of the default desktop-app one; `--project-from-cwd` makes Serena auto-activate the project rooted at the launch directory, so no per-project re-registration is needed; `--open-web-dashboard false` keeps it headless. The pinned ref keeps every GAIA install on the same Serena baseline. If the `claude mcp add` invocation itself fails (network, registry change, etc.), surface the error verbatim and halt `/gaia-init` so the user can retry the command manually after addressing the cause.

  Serena's tools only win over Opus's built-in Read/Grep/Edit when Claude Code loads Serena's system-prompt override; Opus otherwise defaults to its own tools, a strong built-in-tool bias the Serena maintainers prescribe this override to counter. Tell the user the recommended way to start Claude Code sessions in this project:

  ```bash
  claude --append-system-prompt="$(serena prompts print-cc-system-prompt-override)"
  ```

  This is optional but recommended and adopter-safe: a plainly-launched `claude` still works, and the always-loaded `.claude/rules/serena-cc-override.md` is the durable fallback. Use the append form, never `--system-prompt`, which replaces Claude Code's base prompt.

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

**No `.github/workflows/` files ship in this project.** They are generated and installed on demand by `/setup-gaia` after your first `git push origin main` (Phase B). This step (Phase A) is local-only: it records your CI intent so Step 9 can offer the right maintenance-tool modes, and it sets the local audit baseline. It does not create, move, or push any workflow file, and it touches nothing on GitHub.

(`forensics-triage.yml` is maintainer-only and never ships to or installs on an adopter project. The adopter-side `/gaia-forensics` command files reports to the upstream GAIA repo, which owns the `gaia-forensics` label; nothing about forensics needs configuring here.)

_Non-response: HARD-BLOCK. Re-ask; never auto-decide CI intent on a timeout. Automatic mode: "Yes, I'll enable CI after pushing" (records intent only)._

Use AskUserQuestion (in the user's language; this configuration block stays in English). Include the docs link in the question text so the user can Cmd/Ctrl+click to read what GAIA CI is before answering:

> Do you plan to run GAIA CI (GitHub Actions) for this project?
>
> New to GAIA CI? Read https://docs.gaiareact.com/maintenance/gaia-ci/ before deciding (Cmd/Ctrl+click to open).
>
> - **Yes, I'll enable CI after pushing** (Recommended). Records the intent; Step 9 then offers `ci` / `local` / `off` per maintenance tool. After your first push, run `/setup-gaia` to install the audit gate and cron workflows, store the bot token, and register the `GAIA-Audit` required check.
> - **No, local only.** GAIA's audit and maintenance tools run only when you invoke them on this machine. Step 9 offers `local` / `off` only.

Record the answer as the **Configure-CI decision** (`enabled` or `declined`); Step 9 reads it. This is held as init-state only; it neither probes nor writes any workflow file.

Then set the audit baseline in `.gaia/audit-ci.yml` regardless of the answer. Until `/setup-gaia` wires CI, the local `code-review-audit` agent is the only producer of the `GAIA-Audit` stamp, so `local` is the only valid baseline. `/setup-gaia`'s team audit-mode step sets `default_mode: ci` later if you choose CI-audits-every-PR. Never set this to `off` or any other disabled value, the audit gate is non-negotiable.

```bash
# Idempotent: rewrite an existing default_mode line, or append the key if absent.
if [ -f .gaia/audit-ci.yml ] && grep -qE '^default_mode:' .gaia/audit-ci.yml; then
  sed -i.bak -E 's/^default_mode:.*/default_mode: local/' .gaia/audit-ci.yml && rm -f .gaia/audit-ci.yml.bak
else
  printf '\n# Team baseline audit mode. Until /setup-gaia wires CI, the local audit\n# agent is the only GAIA-Audit producer; local is the only valid value here.\ndefault_mode: local\n' >> .gaia/audit-ci.yml
fi
```

To enable CI later: push to GitHub, then run `/setup-gaia`. It installs `.github/workflows/code-review-audit.yml` (the PR gate) plus any cron workflows, stores your bot token as a repo secret, registers the `GAIA-Audit` required check, and sets the team audit `default_mode`. `/update-gaia` keeps the installed audit workflow in sync with its template thereafter.

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
| React Doctor    | `[ -d .claude/skills/react-doctor ]` (installed project-local; gitignored, kept per-machine)                                                            |
| Playwright CLI  | `command -v playwright-cli && playwright-cli --version >/dev/null 2>&1`                                                                                 |
| Serena          | `claude mcp list 2>/dev/null \| grep -q '^serena:'`                                                                                                     |
| typescript-lsp  | `claude plugin list 2>/dev/null \| grep -q 'typescript-lsp'`                                                                                            |
| claude-obsidian | `claude plugin list 2>/dev/null \| grep -q 'claude-obsidian'`                                                                                           |
| spec-kit        | `[ -f .specify/integration.json ] && grep -q 'gaia' .specify/extensions/.registry 2>/dev/null && grep -q 'gaia' .specify/presets/.registry 2>/dev/null` |

Emit one line per component: `[ok] <component>` if the probe exits 0, `[FAIL] <component>` if it exits non-zero.

After all probes run: if any component shows `[FAIL]`, print the full table, then halt `/gaia-init` with:

> "One or more components failed verification. Retry the failed install commands above, then resume with `.gaia/cli/gaia init resume`."

If all probes pass, print the full table and continue to Step 9.

The same probe set applies when setting up from an existing clone, `/setup-gaia` runs it after registering external tools.

## Step 9: Configure GAIA CI (Phase A)

GAIA CI is an optional automated maintenance system that runs four jobs on a smart schedule (wiki sync, dep refresh via `/update-deps`, `pnpm audit`, stale-branch cleanup), opens labeled PRs, and auto-merges on green CI. Phase A, this step, is local-only: it writes `.gaia/automation.json` with your tool selections and `setup_complete: false`. No GitHub repo or workflow files are involved here. After you push to GitHub for the first time, you'll run `/setup-gaia` to wire up tokens and activate CI (Phase B).

_Non-response (the run-mode question in Branch A or B): SAFE-DEFAULT. Re-ask once, then apply the recommended default (all `ci` when CI was enabled, all `local` when CI was declined), name it plainly, and continue to the terminal `configure-automation` write. Automatic mode: same defaults, no re-ask. This never claims the user is absent, and it never skips the mandatory terminal write._

**Carry the Configure-CI decision forward.** The Configure CI integrations block above already recorded whether the user intends to enable CI (`enabled`) or run local only (`declined`). Hold that decision as init-state for this step, do NOT re-probe the filesystem (no workflow files exist at init time, so there is nothing to detect). Step 9 branches on it: a CI decline means CI is not a valid target for any maintenance tool, so the contradictory "Enable all four in CI mode" recommendation is never shown.

**The unconditional terminal action of Step 9, on every exit path (the enumerated recommendation, a free-text answer, a CI decline, or a resumed run), is a single `gaia init configure-automation` call with all four tool modes set to valid values.** No branch may end Step 9 with a half-written or absent `.gaia/automation.json`. The CLI handler writes a complete, schema-valid config (`setup_complete: false`, `update_gaia.mode: local`, all four tool modes) in one atomic write; the prose's only job is to guarantee that call always runs with derived modes.

### Branch A, CI was enabled

Tell the user (in their language; the table headers stay English):

> Configure GAIA's automated maintenance jobs. Recommended: enable all four in CI mode so they run unattended. You can pick a different mode per tool.

Use AskUserQuestion to confirm the recommendation OR open per-tool overrides. Include the run-mode docs link in the question text so the user can Cmd/Ctrl+click to read it before answering:

> How should GAIA CI's tools run?
>
> Run-mode reference: https://docs.gaiareact.com/maintenance/gaia-ci/#run-modes (Cmd/Ctrl+click to open).
>
> - **Enable all four in CI mode (Recommended).** Sets `wiki`, `update_deps`, `pnpm_audit`, and `stale_branches` to `ci`. Phase B (`/setup-gaia`) activates them.
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

Use AskUserQuestion to confirm the all-`local` derivation OR open per-tool overrides between `local` and `off` only (never `ci`). Include the run-mode docs link in the question text so the user can Cmd/Ctrl+click to read it before answering:

> How should GAIA's maintenance tools run? (CI is unavailable.)
>
> Run-mode reference: https://docs.gaiareact.com/maintenance/gaia-ci/#run-modes (Cmd/Ctrl+click to open).
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

## Step 10: Refresh the wiki

The template ships with a wiki shaped for the upstream GAIA project. Refresh the two files that encode "where we are right now" so the new project starts with a clean context:

### 10a. Overwrite `wiki/hot.md`

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

### 10b. Overwrite `wiki/log.md`

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
- Removed: GAIA branding (FUNDING.yml, README, Storybook brand)
- Installed: React Doctor, TDD, Playwright CLI skills; typescript-lsp, claude-obsidian plugins
```

## Step 11: Finalize

Mark per-machine setup as complete so the statusline does not show "Run /setup-gaia (Required)". `/gaia-init` performs all the same per-machine work as `/setup-gaia` (tools, plugins, spec-kit, statusline chmod, .env), but it does not call `gaia setup mark-step` as it goes, so stamp the state file with `--force` now that everything is done:

```bash
.gaia/cli/gaia setup finalize --force
```

If the CLI exits non-zero, it surfaces a structured error whose `code` field explains the cause (e.g. `not_a_git_repo`, `state_malformed`); surface that JSON line verbatim and stop. Do not retry or self-heal.

Then run the CLI's init finalize step, it removes the `/init` interceptor hook, prunes the matching entry from `.claude/settings.json`, and deletes this command file:

```bash
.gaia/cli/gaia init finalize
```

Then output the message below verbatim. Output the `cd` line exactly as written, even though Claude is currently running inside the project folder: when the user exits Claude back to the terminal, their shell returns to the directory they launched from (the parent), not the project folder. Do not tell the user they are "already inside" the folder or that they can skip the `cd`.

**If `.github/CODEOWNERS` holds the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder** (automatic mode where gh detection also failed, or any run where a real handle was never obtained), prepend this required follow-up to the message: "⚠ Required: `.github/CODEOWNERS` has a placeholder owner. Edit it to set your real GitHub handle before you push." A gh-detected or user-typed handle writes a real owner, so this warning does not appear.

> <Project Title> is ready for development. Exit Claude, then from your terminal:
>
> ```
> cd <project-folder-name>
> ```
>
> Then start Claude again, and run `/setup-gaia`.

## On failure: resume

If any `gaia init <step>` invocation exits non-zero, the structured-error JSON on stderr explains the cause. After fixing the cause, re-run with:

```bash
.gaia/cli/gaia init resume
```

Resume reads `.gaia/init-state.json`, skips already-complete steps, and replays remaining steps using the saved arguments. Use `--from-step <N>` to force restart from a specific step (1-indexed: 1=strip-branding, 2=configure-i18n, 3=rename, 4=wire-statusline, 5=configure-automation, 6=finalize).
