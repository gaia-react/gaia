---
name: setup-gaia
description: Single post-init onboarding command; detects situation, runs only owed phases; safe to re-run. --reconfigure re-asks the sandbox, isolation-policy, Dependabot, and statusline decisions.
---

Run this once after `/gaia-init`, and re-run it any time. `/setup-gaia` is the single onboarding command for a GAIA project. It detects the situation and runs only the phases this clone actually owes:

- **Per-machine work** every clone needs (tool installs, plugins, spec-kit runtime, statusline bit, `.env`, the sandbox decision, and, for a developer with a global statusline, which statusline draws the left side).
- **GitHub repository provisioning** (create / adopt / manual, private by default), plus branch protection and the `GAIA-Audit` required-check registration when the runner is a repo admin.
- **Team settings** a repo admin records once in `.gaia/project.json`: the git isolation policy and the Dependabot security-updates decision.

It is safe for **any developer** to run at any time. A plain (no-flag) re-run on a fully provisioned project prints the already-provisioned line and mutates nothing: it never re-provisions the repo or changes branch protection. The one exception is a repo admin re-running it on a repo whose required checks still lack `GAIA-Audit` (or still carry the stale `code-review-audit` context): that run owes the registration and makes it. Pass `--reconfigure` to re-ask the sandbox decision (Phase 2), the team git isolation policy (Phase 3.5), the Dependabot security-updates decision (Phase 3.6), and the statusline left-side choice (Phase 4.6).

The slash command name intentionally does NOT start with `gaia-` so it does not pollute the `/gaia` autocomplete namespace (those are reserved for the four user-invoked GAIA workflows).

## Pre-flight: Worktree check

This command does per-machine and per-clone provisioning, writes `.gaia/local/setup-state.json`, and provisions the GitHub repository. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/setup-gaia" || exit 1
```

If the detection does not fire, fall through to `## Argument parse` below.

## Argument parse

Parse `$ARGUMENTS` for the `--reconfigure` flag. Cache the boolean as `RECONFIGURE`. It re-opens four settled decisions and nothing else: the sandbox decision in Phase 2, the isolation policy in Phase 3.5, Dependabot security updates in Phase 3.6, and the statusline left-side choice in Phase 4.6.

## Phase 0: Prerequisites (every invocation, never skipped)

These run on every invocation and record no setup-state step. They sit outside the per-machine skip gate.

### 0a. Self-heal worktree symlinks

If this clone is being set up from a linked worktree (e.g. one created via `git worktree add` outside the Claude Code harness), the shared-state links that `.gaia/scripts/link-worktree.sh` creates may not exist yet: one symlink at `.gaia/local` pointing at the main checkout's, plus a link for each gitignored root `.env` file the main checkout holds. Run the self-heal:

```bash
bash .gaia/scripts/link-worktree.sh
```

In a main checkout this is a no-op (prints `not a linked worktree`). In a linked worktree that lacks them it creates them; where a real file or directory already sits at one of those paths, it is backed up to `<path>.bak.<timestamp>` first, so nothing is clobbered.

The script always exits 0, so read its output: if it prints a `failed:` line (e.g. Windows symlink permission failure), HALT and surface that line verbatim. The user must fix the underlying issue (typically: enable Windows Developer Mode) and re-run `/setup-gaia`.

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
  .gaia/cli/gaia labels sync
fi
```

Surface every warning and the sync report verbatim, then continue. `gaia labels sync` reconciles this repo's labels against the registry for whichever audience and feature set it resolves to. `gaia-forensics` is a maintainer-audience entry, so an adopter's sync never creates it; an adopter files forensics reports upstream, never locally, regardless of what this step finds.

## Phase 1: Detect situation

Classify the clone by reading state, gating on **file existence, not key presence**. Every input is optional; a missing file is a signal, not an error.

```bash
.gaia/cli/gaia setup status --json
```

From `.gaia/local/setup-state.json` (per-machine, gitignored), cache `completed_at` and `completed_steps`.

Then read the **repo / branch / push / required-check** state, not merely whether an `origin` remote exists:

```bash
.gaia/cli/gaia setup-ci detect-remote --json
```

Cache `found`, `host`, `owner`, `repo`. When `found` and `host == "github.com"`, probe the live repo state (each degrades to "absent" on a non-zero exit):

```bash
gh api "repos/<owner>/<repo>" --jq '.default_branch' 2>/dev/null                                              # repo exists + its default branch
gh api "repos/<owner>/<repo>/branches/<default-branch>" --jq '.name' 2>/dev/null                              # default branch has been pushed
```

When the repo exists, run the admin probe once and cache `admin` and `auth_status` (Phase 3 reuses them):

```bash
.gaia/cli/gaia setup-ci check-admin --owner <owner> --repo <repo> --json
```

When `admin` is `true` and `auth_status == "ok"`, read the default branch's required contexts:

```bash
gh api "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null  # GAIA-Audit registered?
```

The **registration is owed** when that probe fails (no protection rule, or a rule without required status checks), when its output lacks `GAIA-Audit`, or when it still lists `code-review-audit`. Nothing posts a `code-review-audit` context, so a repo that requires it holds every pull request until the context is dropped. For a non-admin runner the probe does not run: branch protection is not theirs to read or change, so nothing on GitHub is owed by them.

Classify into one of these, first match wins:

- **First adopter**: no GitHub repo yet (`detect-remote` reported `found: false`, or the repo probe came back absent).
- **Partial re-run**: the repo exists but its default branch is not pushed, or the runner is an admin and the registration is owed.
- **Fresh clone**: the repo exists with its default branch pushed, nothing on GitHub is owed by this runner, and `completed_at` is null (per-machine work still owed).
- **Provisioned**: the repo exists, its default branch is pushed, `GAIA-Audit` is a required context with no `code-review-audit` beside it (or the runner is a non-admin, for whom nothing on GitHub is owed), and `completed_at` is non-null.

Detect an **incomplete provisioning** (repo created, `origin` added, but the default-branch push or the `GAIA-Audit` registration did not complete) from the repo/branch/push/required-check probes above, and complete only the owed steps. Because `gh repo create` adds `origin` **before** the push, `origin`-presence alone would wedge a failed-push state; judge from actual push/registration state.

The classification only routes the phases below; each phase re-checks its own completion and no-ops when already done, so misclassification cannot corrupt state.

## Phase 2: Per-machine setup (skip if setup-state finalized)

If `setup status --json` reports a non-null `completed_at`, this whole phase no-ops **except for the sandbox decision below** (a first adopter finished per-machine work inside `/gaia-init`, so the repo prompt in Phase 3 is their first real interaction, with no tool-install log lines before it, and the recorded per-machine steps are unchanged). Otherwise run Steps 1–5 below in order. Each records itself via `.gaia/cli/gaia setup mark-step <step>` and is skipped when already in `completed_steps`.

**Sandbox decision (runs even when `completed_at` is non-null).** This clause surfaces the OS-level Bash sandbox enablement decision whenever no per-machine resolution has been recorded. It runs even when `completed_at` is non-null because Phase 2 otherwise short-circuits once per-machine setup is complete and would skip the decision. So before falling through to Phase 3, always evaluate this:

```bash
RESOLVED="$(.gaia/cli/gaia sandbox status --json 2>/dev/null | jq -r '.resolved // false')"
```

If `RESOLVED` is `true` and `RECONFIGURE` is NOT set, the decision stands: do NOT re-prompt and do NOT flip the settled value. Skip to the rest of setup. Otherwise (marker absent, or `--reconfigure`), run the decision body below. This clause is gated on the `gaia sandbox status` marker, never on a `SETUP_STEPS` value: no `SETUP_STEPS` entry is added and `gaia setup mark-step` is never called for the sandbox decision; `.gaia/local/sandbox.json` is the only tracking.

1. **Read the recommendation.** Absent file, absent key, or an unreadable config all mean "no recommendation", so the default is off:

   ```bash
   RECOMMENDED="$(jq -r '.sandbox_recommended // false' .gaia/project.json 2>/dev/null || echo false)"
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

> Note: enabling the sandbox alone does not protect .env. The sandbox's default read policy is permissive (it still reads ~/.aws, ~/.ssh, .env). What protects `.env` is GAIA's committed `sandbox.filesystem.denyRead` entries, which reach subprocesses spawned by sandboxed Bash and cover `.env`, the `.env.local` / `.env.production` variant family, and the key, certificate, credential, and secrets-directory classes, each at any depth in the project rather than at its root only; `.env.example` stays readable. They do NOT cover MCP shell execution, NOT a `docker *`-excluded command that runs outside the sandbox, and NOT `~/.ssh` or `~/.aws`: no entry names either one, and an ordinary private key there (`id_rsa`, `id_ed25519`) carries none of those names or extensions and sits under no `secrets/` directory, so it stays readable. The same denied read also blocks the app's own `.env` reads under Claude-run tooling (Vite, tests). And if bubblewrap/socat later goes missing, an enabled machine degrades to unsandboxed by default, at which point only the `block-env-read.sh` / `block-secrets-read.sh` tool-tier guards remain.
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

## Phase 3: GitHub repository (skip if provisioning already complete)

Judge this phase from the **repo/branch/push/required-check state cached in Phase 1**, not merely `origin` presence. Three cases:

- **The repo exists, the default branch is pushed, and the registration is not owed** (Phase 1's **provisioned** or **fresh clone**): print `GitHub repository already provisioned.` and fall through to Phase 3.5 without touching GitHub.
- **The repo exists, the default branch is pushed, and the registration is owed** (an admin's **partial re-run**): print `GitHub repository already provisioned; registering the GAIA-Audit required check.` and skip the connect question. When the default branch has no protection rule yet (`gh api "repos/<owner>/<repo>/branches/<default-branch>/protection"` exits non-zero), run the **Default-branch protection** PUT below first; never re-PUT an existing rule, because the PUT replaces every setting on it. Then run **Register GAIA-Audit as the required check** below and fall through to Phase 3.5. The other recommended defaults already ran when the repo was provisioned, so this path skips them.
- **Otherwise** (no repo yet, or its default branch is not pushed), this is the **first user-facing interaction for a first adopter**. Ask (AskUserQuestion) with these three options:

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

**Choose the owner (personal account or organization).** Before creating, decide *where* the repo lives. Resolve the personal login and enumerate the orgs the user belongs to:

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
When it's pushed, re-run /setup-gaia to apply the recommended defaults (branch protection and the GAIA-Audit required check need repo admin).
```

Exit the repo phase without mutating GitHub.

### Recommended defaults (admin-gated)

Reached from Option 1 (after create) or Option 2 (adopt). Run the admin probe for the now-existing repo (Option 1's repo did not exist when Phase 1 ran, so its cached values cannot be reused here):

```bash
.gaia/cli/gaia setup-ci check-admin --owner <owner> --repo <repo> --json
```

Cache `admin` and `auth_status`. **If `admin` is not `true` (or `auth_status != "ok"`)**, none of the GitHub mutations below fire; print the admin-note and skip straight to Phase 3.5 (which runs its own admin probe and fails closed the same way):

```
GitHub provisioning needs repo-admin permission and an authenticated gh (yours: admin=<admin>, auth_status=<auth_status>). Skipping the admin-only steps (branch protection, the GAIA-Audit required-check registration, Dependabot alerts, and delete-branch-on-merge). Per-machine setup still completes. Ask a repo admin to finish the GitHub side, or gain admin access and re-run /setup-gaia.
```

When `admin: true` and `auth_status == "ok"`:

**Default-branch protection.** No CLI verb creates a protection rule, so author the full `protection` PUT payload directly. Create protection **before** the `GAIA-Audit` registration below: a bare `required_status_checks` registration 404s when no protection rule exists. Correct order is create repo → push default branch → enable protection → register `GAIA-Audit`.

Probe for an existing rule first and PUT only when there is none. The PUT replaces every setting on a rule, so on an adopted repo that already protects its default branch it would silently drop the adopter's required reviews, other required checks, and push restrictions. An existing rule is kept as it is; the registration below then edits its required contexts alone:

```bash
protection_endpoint="repos/<owner>/<repo>/branches/<default-branch>/protection"
if gh api "$protection_endpoint" >/dev/null 2>&1; then
  echo "<default-branch> already has a protection rule; keeping it and registering GAIA-Audit only."
else
  gh api -X PUT "$protection_endpoint" --input - <<'JSON'
{
  "required_status_checks": {"strict": true, "contexts": []},
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null
}
JSON
fi
```

When the PUT runs, `required_status_checks.contexts` starts empty; the registration below adds `GAIA-Audit` to it and keeps any sibling contexts.

`required_approving_review_count` is `0` and `enforce_admins` is `false` on purpose. GAIA's merge gate is the `GAIA-Audit` required status check (plus any sibling checks), not a human approval, so a review requirement would wedge a solo adopter: nobody can approve their own PR, and `enforce_admins: true` would block the admin override, leaving them unable to merge anything to the default branch. `enforce_admins: false` also lets the admin push the Phase 3.5 and Phase 3.6 team-setting commits **directly onto the default branch**, past this protection: each records one decision in `.gaia/project.json` (plus the Dependabot config when one is written), so setup-gaia lands it straight rather than through a PR + audit (it suspends the local `block-main-destructive-git.sh` hook for the single commit+push via a `.gaia/local/setup-in-progress` sentinel, see Phase 3.5's **The commit**). Do not tighten these to require approvals or enforce admins without a merge path that a solo repo can actually satisfy.

#### Register GAIA-Audit as the required check

The merge gate is the `GAIA-Audit` commit status, which the local PR Merge Workflow posts when an audit clears; requiring it is what stops a pull request merged from the github.com button from skipping the audit. This registration runs for every admin, on every run where it is owed: `GAIA-Audit` is not a required context, or the stale `code-review-audit` context still is one. Nothing posts `code-review-audit`, so a repo that still requires it holds every pull request forever; the registration drops it.

**GET the current contexts, then PUT the full set back to the `/contexts` endpoint with `GAIA-Audit` added and `code-review-audit` removed.** That PUT REPLACES the list, so a static PUT would drop sibling contexts (e.g. `Tests`, `Chromatic`) and let unaudited code merge. Every other context is kept. When the GET shows nothing to change, no PUT is sent:

```bash
required_checks_endpoint="repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks"
# A failed GET sends no PUT: replacing contexts that could not be read would drop the siblings.
if ! current_contexts=$(gh api "$required_checks_endpoint" --jq '.contexts'); then
  echo "Could not read the required status checks on <default-branch>." >&2
elif printf '%s' "$current_contexts" | jq -e 'any(.[]; . == "GAIA-Audit") and all(.[]; . != "code-review-audit")' >/dev/null; then
  echo "GAIA-Audit is already the required check on <default-branch>."
else
  jq -n --argjson current "$current_contexts" \
    '{contexts: ($current | map(select(. != "code-review-audit" and . != "GAIA-Audit")) + ["GAIA-Audit"])}' \
    | gh api -X PUT "$required_checks_endpoint/contexts" --input -
fi
```

Substitute `<owner>`/`<repo>` (cached earlier) and `<default-branch>` (typically `main`). If the GET or the PUT fails (403 when not admin, 404 when the branch has no protection rule or the rule requires no status checks), surface the error verbatim and tell the user:

```
Could not register the GAIA-Audit required check (admin permission and a branch-protection rule with required status checks on the default branch are required). Run it yourself once you have admin access, listing every other required context you keep in the JSON body (leave out code-review-audit):
  printf '%s' '{"contexts":["GAIA-Audit"]}' | gh api -X PUT "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks/contexts" --input -
Until GAIA-Audit is registered, GitHub does not require the audit: a pull request merged from the github.com button skips it. While code-review-audit stays a required context, every pull request on <default-branch> stays blocked, because nothing posts it.
```

Do not halt on a registration failure; continue with **Remaining defaults** below, or, on the registration-only re-run path at the top of Phase 3, fall through to Phase 3.5.

#### Remaining defaults

**delete_branch_on_merge.** Read the current setting:

```bash
gh api "repos/<owner>/<repo>" --jq .delete_branch_on_merge
```

If `false`, AskUserQuestion:

> GitHub is set to NOT delete branches when PRs merge, so every merged branch stays on the remote until someone deletes it by hand. GAIA runs no branch cleanup of its own. Enabling `delete_branch_on_merge` has GitHub delete each pull request's branch as it merges.
>
> - **Enable delete_branch_on_merge** (Recommended)
> - **Skip** (merged branches stay on the remote)

On Enable:

```bash
.gaia/cli/gaia setup-ci enable-delete-branch --owner <owner> --repo <repo>
```

If already `true`, print `delete_branch_on_merge is already enabled.` and continue.

**Dependabot posture.** Enable Dependabot **alerts** (visibility) and keep the PR-producing features **off** here; Phase 3.6 offers security updates as an opt-in. First warn about any existing Dependabot / Renovate config:

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

Assert `automated-security-fixes` is `false` (unless `.gaia/project.json` already records `"dependabot_security_updates": "on"`), and write **no** `.github/dependabot.yml` here. **`/update-deps` owns version updates** in GAIA; Dependabot never opens a version-update pull request. Security-update pull requests are a separate, explicit opt-in offered in Phase 3.6, the only path that turns `automated-security-fixes` on.

All Phase-3 GitHub mutations (create, protection, required-check registration, vuln-alerts, delete-branch) are net-new, admin-gated, security-sensitive calls. A non-admin runner degrades gracefully: skip the mutation, print the admin-note above, and continue to Phase 3.5.

## Phase 3.5: Team git isolation policy (always evaluated)

This is a **committed team setting**, not per-machine state: whether `/gaia-plan` and `/gaia-debt` isolate
their work in a feature branch or a git worktree by default. It sits here, after Phase 3 returns rather than
inside it, because Phase 3 short-circuits entirely once the repo is already provisioned, and an
already-provisioned repo is what every developer after the first one hits. This section always runs, whether
Phase 3 above just created a repo, adopted one, or short-circuited straight through, and it carries its own
commit, because nothing else in this command commits the policy.

### Gate 1: the key's own presence

```bash
HAS_POLICY="$(jq -r 'has("isolation_policy")' .gaia/project.json 2>/dev/null || echo false)"
```

- `HAS_POLICY` is `true` and `RECONFIGURE` is NOT set → the decision stands. **Skip silently**: do not
  re-prompt, do not flip the settled value.
- `HAS_POLICY` is `false`, OR `RECONFIGURE` is set → an answer is owed. Continue to Gate 2.

Answering the question below writes the key, so its presence alone is a sufficient "already asked" signal. No
separate marker file, no `SETUP_STEPS` entry, no `mark-step` call; `.gaia/project.json` is the source of
truth here, the same shape as the sandbox decision's `gaia sandbox status` marker above. A missing
`.gaia/project.json` reads as an absent key (the `|| echo false` tail covers jq's error on a missing file), and
the write below creates the file when it is absent.

### Gate 2: this clause's own `check-admin` probe (fail closed)

Gated behind Gate 1, so the `gh api` round-trip only costs anything on a repo that still owes an answer. Reuse
Phase 1's cached `detect-remote` values (`found`, `host`, `owner`, `repo`):

```bash
.gaia/cli/gaia setup-ci check-admin --owner <owner> --repo <repo> --json
```

Fail closed, silently (skip the question, no error, no output), on any of:

- `detect-remote` reported `found: false` (no GitHub origin at all);
- `host != "github.com"`;
- `admin` is not `true`;
- `auth_status` is not `"ok"`.

A developer who is not a repo admin is never asked for the team policy and sees no error.

### The question

Tell the user (in their language, detected from earlier context): "Let's set your team's default git
isolation policy."

Show the explainer (this block stays English regardless of UI language, it's the canonical contract):

> Worktrees buy you the ability to run a GAIA task without touching your current checkout, so you can keep
> coding, or run a second GAIA task, while it works. They cost:
>
> - a separate checkout per task, whose first quality-gate run installs its own `node_modules` (a one-time
>   install; the real disk cost ranges from tens of megabytes on a copy-on-write filesystem to the full
>   install size elsewhere);
> - your editor indexes that second checkout as well as the main one;
> - a dev server started inside a worktree collides on the same port as one in the main checkout;
> - a crashed session can leave a worktree behind for you to remove by hand.
>
> Scope limit: this policy governs `/gaia-plan` and `/gaia-debt` only. `/gaia-audit`, `/gaia-harden`, and
> `/gaia-wiki` still work in the main checkout. And while a GAIA task holds your session in a worktree,
> `/update-deps` and `/update-gaia` refuse to run there; run them from a separate session on the main
> checkout.

Use `AskUserQuestion`, header **`Isolation policy`**, with these three options in this exact order:

- **Prefer branches (Recommended)**
- **Prefer worktrees**
- **Always use worktrees**

On a choice, run **The write** below with the matching value: `Prefer branches (Recommended)` →
`prefer-branch`, `Prefer worktrees` → `prefer-worktree`, `Always use worktrees` → `always-worktree`.

**Declining** ("Other", or dismissing the question) writes nothing and commits nothing. The key stays absent,
so the question re-fires on a later explicit `/setup-gaia` run, a bounded cost since this is a setup command,
not a per-task prompt.

### The write

```bash
.gaia/cli/gaia setup-ci write-isolation-policy <always-worktree|prefer-worktree|prefer-branch>
```

If this exits non-zero, surface the structured-error JSON verbatim and skip **The commit** below. Do not
retry, do not hand-write the key.

### The commit

This clause carries its own commit, including the main-branch hook standdown. Right after `gh repo create
--push`, HEAD is on the default branch; when that branch is `main` or `master`, the `block-main-destructive-git.sh`
PreToolUse hook denies `git commit` and `git push` there, so a machine-local sentinel in `.gaia/local/`
(gitignored, never reaching a teammate's clone) suspends it for this one commit+push. The hook does not recognize
a custom default-branch name, so on one the sentinel is inert but harmless.

**Separate Bash call, first** (the `block-main-destructive-git.sh` PreToolUse hook reads this sentinel before
the command runs, so bundling it into the same call as `git commit` would not yet exist when the hook checks):

```bash
mkdir -p .gaia/local
touch .gaia/local/setup-in-progress
```

**Then, in its own call:**

```bash
git add .gaia/project.json
git commit -m "chore(gaia): set the team git isolation policy to <value>"
git push origin <current-branch>
```

**Then, in its own call, unconditionally** (even if the commit or push failed, a lingering sentinel keeps
main-branch protection suspended on this machine):

```bash
rm -f .gaia/local/setup-in-progress
```

**Branch on the push result honestly.** A repository ruleset can reject even an admin's direct push (`GH006`).
If the push fails, say so in one line and tell the admin the value is committed locally and needs a push (or
a PR); do not report success on a failed push. The commit itself makes the policy real for this machine's next
run; the push is what makes it real for the team.

Fall through to Phase 3.6.

## Phase 3.6: Dependabot security updates (opt-in, always evaluated)

This is a **committed team setting**, like Phase 3.5's isolation policy, not per-machine state. It sits here,
after Phase 3.5, for the same reason Phase 3.5 sits after Phase 3: Phase 3 short-circuits entirely once the
repo is already provisioned, so this clause always runs and carries its own commit. It closes a gap nothing else in GAIA
covers: between `/update-deps` runs, a vulnerable transitive dependency sits unpatched, Dependabot alerts
alone are advisory and open no pull request.

### Gate 1: the key's own presence

```bash
HAS_DEPENDABOT="$(jq -r 'has("dependabot_security_updates")' .gaia/project.json 2>/dev/null || echo false)"
```

- `HAS_DEPENDABOT` is `true` and `RECONFIGURE` is NOT set → the decision stands. **Skip silently**: do not
  re-prompt, do not flip the settled value.
- `HAS_DEPENDABOT` is `false`, OR `RECONFIGURE` is set → an answer is owed. Continue to Gate 2.

Answering the question below writes the key, so its presence alone is a sufficient "already asked" signal. No
separate marker file, no `SETUP_STEPS` entry, no `mark-step` call; `.gaia/project.json` is the source of
truth here, the same shape as Phase 3.5's isolation-policy decision, and the policy write creates the file when
it is absent.

### Gate 2: `check-admin` probe (fail closed)

Gated behind Gate 1, so the `gh api` round-trip only costs anything on a repo that still owes an answer. Reuse
Phase 1's cached `detect-remote` values (`found`, `host`, `owner`, `repo`):

```bash
.gaia/cli/gaia setup-ci check-admin --owner <owner> --repo <repo> --json
```

Fail closed, silently (skip the question, no error, no output), on any of:

- `detect-remote` reported `found: false` (no GitHub origin at all);
- `host != "github.com"`;
- `admin` is not `true`;
- `auth_status` is not `"ok"`.

A non-admin is not the audience for a repository setting, and Dependabot exists only on GitHub.

### The question

Tell the user (in their language, detected from earlier context): "Dependabot can open a pull request when a
security advisory lands for a package in your lockfile."

Show the explainer (this block stays English regardless of UI language, it's the canonical contract):

> Dependabot security updates open a pull request when GitHub publishes an advisory for a package in your
> lockfile, including transitive dependencies that `/update-deps` reaches only on its next run. Accepting does
> three things:
>
> - Adds an `npm` entry (it covers pnpm) to `.github/dependabot.yml`, merged beside any other ecosystems
>   already there, with version updates disabled (`open-pull-requests-limit: 0`), so it never competes with
>   `/update-deps` for routine upgrades. Security-update pull requests are not subject to that limit.
> - Groups each batch of security fixes into one pull request titled `fix(deps): ...` and labeled
>   `dependencies` and `security` (a label that does not exist in the repository is skipped). The `fix`
>   prefix is deliberate: a `chore(deps)` title takes GAIA's dep-bump bypass, which skips the test suite and
>   the audit, and that bypass is only safe for `/update-deps`, which runs the quality gate locally first.
> - Turns on the repository settings Dependabot alerts and Dependabot security updates. The config file alone
>   opens nothing.
>
> Tradeoffs:
>
> - Dependabot's `cooldown` applies only to version updates, so Dependabot does not hold these pull requests
>   back. pnpm's own `minimumReleaseAge` still applies to the lockfile Dependabot writes: a patched version
>   published inside the window fails the pull request's `pnpm install` in CI (and with
>   `minimumReleaseAgeStrict` can fail the Dependabot job itself) until it ages out or you add a hand-checked
>   exact-version `minimumReleaseAgeExclude` entry, per the policy in `pnpm-workspace.yaml`.
> - Dependabot pull requests, like any pull request merged from the GitHub UI, receive `GAIA-Audit` only when
>   merged through the local PR Merge Workflow in Claude Code, so a repo that requires `GAIA-Audit` holds them
>   until then.
> - GitHub's supported-ecosystems table lists pnpm through v10. If your project pins a newer pnpm and a
>   security-update job fails, the repository's Dependabot tab shows the error, and `/update-deps` remains the
>   path.

Use `AskUserQuestion`, header **`Dependabot`**, with these two options in this exact order:

- **Enable Dependabot security updates**
- **No, keep /update-deps as the only path**

Neither option is marked Recommended; this is an opt-in, not a default. Choosing "Other" or dismissing the
question writes nothing and commits nothing. The key stays absent, so the question re-fires on a later explicit
`/setup-gaia` run. "No" is a recorded decision (see below).

### On "No"

```bash
.gaia/cli/gaia setup-ci write-dependabot-policy off
```

Then **The commit** below with the message `chore(gaia): record the Dependabot security-updates opt-out`.

When `RECONFIGURE` is set and the previous value was `on`, also print: `Dependabot security updates stay
enabled on GitHub until you turn them off: gh api -X DELETE
"repos/<owner>/<repo>/automated-security-fixes". The npm entry in .github/dependabot.yml is left in place.` Do
not auto-disable.

### On "Enable"

1. Render or merge the config:

   ```bash
   .gaia/cli/gaia setup-ci write-dependabot-config --json
   ```

   - `created` or `merged` → stage its `path` for **The commit** below.
   - `npm_entry_exists` → print `An npm entry already exists in <path>; leaving it unchanged. For
     /update-deps to keep owning version updates, it needs open-pull-requests-limit: 0. Security-update pull
     requests use that entry's commit-message settings: if its prefix is chore with include: scope, their
     titles start chore(deps): and skip the test suite and audit, so change the prefix (GAIA renders fix). If
     the entry sets no commit-message, Dependabot copies the repository's existing commit style, and a GAIA
     history full of chore(deps): commits makes that the likely title.` This clause enables nothing on this
     path: after that message, print `Once that entry sets commit-message: prefix: "fix" (or any non-chore
     prefix) and is on <default-branch>, finish with:` followed by the two gh api -X PUT commands from the
     failure block below. Stage nothing from this step.
   - `unmergeable` (nonzero exit) → print `Could not merge the npm entry into <path> (<reason>). Add this
     under updates: by hand, commit it, then re-run /setup-gaia:` followed by the `entry` text in a fenced
     block, then **stop this clause**: write no policy, enable nothing. Enabling without the grouping config
     opens one ungrouped pull request per alert.

2. Write the policy:

   ```bash
   .gaia/cli/gaia setup-ci write-dependabot-policy on
   ```

   If this exits non-zero, surface the structured-error JSON verbatim and stop the clause.

3. **The commit** below with the message `chore(gaia): enable Dependabot security updates for npm`, staging
   `.gaia/project.json` plus the config path from step 1 when one was written. Never use a `chore(deps)`
   subject here.

4. Enable the repository settings only when the config is on the default branch: the push in step 3 succeeded
   AND the current branch is the default branch. Dependabot reads its config from the default branch, and
   turning the setting on first would open one ungrouped pull request per open alert.

   Otherwise print `The Dependabot config is committed on <branch> but not yet on <default-branch>. Once it
   lands there, finish with:` followed by the two `gh api -X PUT` commands from the failure block below, and
   continue (do not treat this as a failure).

   ```bash
   .gaia/cli/gaia setup-ci enable-dependabot-security --owner <owner> --repo <repo> --json
   ```

   On success, print `Dependabot security updates are on for <owner>/<repo> (alerts: enabled, security
   updates: enabled).` If `paused` is `true`, add `GitHub reports security updates as paused for this
   repository; resume them from the repository's Dependabot settings.`

   On failure (nonzero exit), print with no silent skip:

   ```
   Could not enable Dependabot security updates on <owner>/<repo> (failed at <step>). The config is committed; finish with repo-admin access:
     gh api -X PUT "repos/<owner>/<repo>/vulnerability-alerts"
     gh api -X PUT "repos/<owner>/<repo>/automated-security-fixes"
   Then confirm: gh api "repos/<owner>/<repo>/automated-security-fixes" --jq .enabled   (expects true)
   Or turn on Dependabot alerts and Dependabot security updates at https://github.com/<owner>/<repo>/settings/security_analysis
   ```

   An organization policy can block this even for a repo admin.

### The commit

Uses exactly Phase 3.5's **The commit** mechanics: the sentinel `touch` in its own earlier Bash call, the
commit and push in its own call, `rm -f .gaia/local/setup-in-progress` unconditionally in its own call, and
the honest push-failure line. Only the git block differs:

```bash
git add .gaia/project.json <config-path-if-written>
git commit -m "<message from the branch above>"
git push origin <current-branch>
```

Fall through to Phase 4.5.

## Phase 4.5: Label sync (always evaluated)

This runs on every invocation, after Phase 3.6, whichever path Phases 3 through 3.6 took (repo created, adopted, set up manually, already provisioned, or degraded on a non-admin runner), because the feature and audience choices already on disk by then are what the label sync filters on: whether the forensics workflow is present, and whether this repo is adopter- or maintainer-audience.

```bash
.gaia/cli/gaia labels sync
```

Surface its report verbatim: labels created, labels renamed, and any color drift found. Color drift is never applied here, no `--adopt` flag; an operator's own recolor of a label always wins over the registry's suggested color.

This step is advisory, never halting. A token without label-write scope gets the manual `gh label create` / `gh label edit` commands the command itself prints, and setup continues either way; `gaia labels sync` already exits 0 in that case, so this step adds no failure path of its own. It is idempotent and safe to re-run on every plain `/setup-gaia` invocation: a repo already in sync reports zero creates and zero renames.

Fall through to Phase 4.6.

## Phase 4.6: Statusline left side (per-machine, always evaluated)

GAIA's statusline (`.gaia/statusline/gaia-statusline.sh`) always draws GAIA's nudges on the right. For the left side it runs the developer's global `statusLine.command` from `~/.claude/settings.json` when one exists, otherwise GAIA's own bar (project, branch, model and effort, and a context bar colored by the audit checkpoint line). This phase lets a developer with a global statusline choose between the two. It is per-machine state, not a team setting: the answer lives in `.gaia/local/settings.json` (gitignored, GAIA's writable per-machine opt-ins), and it runs even when `completed_at` is non-null, like the sandbox decision, so a clone set up before this phase existed still gets asked.

### The routing warning (every invocation)

Find the statusLine the project actually runs: the first of `.claude/settings.local.json`, `.claude/settings.json` and `~/.claude/settings.json` that sets `statusLine.command`.

```bash
EFFECTIVE_STATUSLINE=""; EFFECTIVE_SOURCE=""
for f in .claude/settings.local.json .claude/settings.json "$HOME/.claude/settings.json"; do
  c="$(jq -r '.statusLine.command // empty' "$f" 2>/dev/null)"
  if [ -n "$c" ]; then EFFECTIVE_STATUSLINE="$c"; EFFECTIVE_SOURCE="$f"; break; fi
done
printf '%s\n%s\n' "$EFFECTIVE_SOURCE" "$EFFECTIVE_STATUSLINE"
```

The command routes through GAIA when its text names `gaia-statusline.sh`, or when it runs a wrapper script whose own text names `gaia-statusline.sh` (read the script the command runs, one level deep). Otherwise print this warning, filling in the source file, and continue; it is advisory and changes nothing:

> Warning: this project's effective statusLine (from `<EFFECTIVE_SOURCE>`) does not run `.gaia/statusline/gaia-statusline.sh`. Without it you get no GAIA nudges, and no context readings are written, so the audit loop's checkpoint falls back to counting rounds. To fix it, remove the `statusLine` key from `<EFFECTIVE_SOURCE>` (when that is `.claude/settings.local.json`), or point it at a wrapper that runs `gaia-statusline.sh`. `/gaia-fitness` reports the same condition.

The choice below still runs after the warning: it takes effect once the statusLine is routed through GAIA again.

### Gate: a global statusline, and no recorded choice

```bash
GLOBAL_STATUSLINE="$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)"
case "$GLOBAL_STATUSLINE" in *gaia-statusline.sh*) GLOBAL_STATUSLINE="" ;; esac
LEFT_CHOICE="$(jq -r 'if type == "object" and .version == 1 and (.statusline | type) == "object" then (.statusline.left // empty) else empty end' .gaia/local/settings.json 2>/dev/null)"
printf 'global=%s\nchoice=%s\n' "$GLOBAL_STATUSLINE" "$LEFT_CHOICE"
```

- `GLOBAL_STATUSLINE` is empty → there is nothing to choose between: GAIA's bar already draws the left side. **Skip silently and write nothing.** A global statusline added later makes this phase owed again on the next run.
- `LEFT_CHOICE` is `gaia` or `user`, and `RECONFIGURE` is NOT set → the choice stands. **Skip silently.**
- Otherwise (no recorded choice, any other value, or `--reconfigure`) → ask.

A missing `statusline.left` key means never asked. The file's presence alone is not the signal, because it holds other opt-ins too.

### The question

Use `AskUserQuestion`, header **`Statusline`**, question "You have your own global statusline. Which one should draw the left side of the statusline in this project?", with these two options in this exact order:

- **Use GAIA's statusline bar (Recommended)**: project, branch, model and effort, and a context bar whose colors match the audit checkpoint line.
- **Keep my own statusline**: your global `statusLine.command` keeps drawing the left side.

Either way GAIA's nudges stay on the right and context readings are still written. Choosing "Other" or dismissing the question writes nothing, so the question re-fires on a later `/setup-gaia` run.

### The write

Write `gaia` for the first option or `user` for the second, keeping any other key already in the file. A file without version 1, or one that does not parse, is replaced, since the statusline reads it as missing anyway:

```bash
LEFT="<gaia|user>"
mkdir -p .gaia/local
tmp="$(mktemp .gaia/local/settings.json.XXXXXX)"
if jq -e 'type == "object" and .version == 1' .gaia/local/settings.json >/dev/null 2>&1; then
  jq --arg left "$LEFT" '.statusline = ((.statusline | if type == "object" then . else {} end) + {left: $left})' .gaia/local/settings.json >"$tmp"
else
  jq -n --arg left "$LEFT" '{version: 1, statusline: {left: $left}}' >"$tmp"
fi && mv -f "$tmp" .gaia/local/settings.json || rm -f "$tmp"
```

The statusline reads the choice on its next render; no restart is needed. Nothing is committed: the file is gitignored. This file is not `.gaia/local/checkpoint-override.json`, the human-only audit checkpoint override, which Claude never writes.

Fall through to Phase 6.

## Phase 6: Finalize

Stamp per-machine setup-state as complete, then report. `setup finalize` refuses to finalize while any step is pending (it returns non-zero without stamping `completed_at`), and a first adopter reaches here with `completed_steps: []` (their `/gaia-init` already set `completed_at` via `gaia setup finalize --force`), so this phase must both **short-circuit when already finalized** and **pass `--force` when any step is still pending**.

First, defensively clear the setup sentinel, unconditionally and before the short-circuit below, so a Phase 3.5 or Phase 3.6 commit that aborted between creating and removing it cannot leave main-branch protection suspended on this machine:

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

  Never leave `completed_at` unstamped because a step was skipped upstream.

**Adoption ping.** After finalize completes (or short-circuits above), send a setup adoption ping as the last substantive step of this phase, fire-and-forget.

Compute **`$SETUP_TYPE`** (required) from Phase 1's classification and `RECONFIGURE`:

- `RECONFIGURE` is set: `reconfigure`.
- Else Phase 1 classified this run as **first adopter**: `init`.
- Else Phase 1 classified this run as **fresh clone** or **partial re-run**: `clone`.
- Else Phase 1 classified this run as **provisioned**, and the short-circuit above fired because `completed_at` was already non-null before this phase ran, with `RECONFIGURE` not set: this is a plain no-op re-run. **Skip the ping entirely** and go straight to the completion message below. The `init|clone|reconfigure` enum has no value for "nothing happened this run"; firing here would inflate setup counts.

When not skipped, add these optional fields only when this run determined them:

- **`$SANDBOX`** (always knowable, always include): read the sandbox decision straight from the marker Phase 2 resolves (or resolved on a prior run), so a plain re-run reports it correctly too. `outcome: enabled` maps to `on`; `declined`, `incapable`, or an absent marker maps to `off`:

  ```bash
  SANDBOX="$(.gaia/cli/gaia sandbox status --json 2>/dev/null | jq -r 'if .outcome == "enabled" then "on" else "off" end')"
  ```
- **`$REPO_CHOICE`**: the branch chosen at Phase 3's connect-to-GitHub question. "Create the repo on GitHub" maps to `create`, "Adopt an existing repo" maps to `adopt`, "Set one up manually" maps to `manual`. Omit when Phase 3 short-circuited because the repo was already provisioned (no choice was made this run).

Fire the ping with only the flags this run determined:

```bash
.gaia/cli/gaia ping --event setup --type "$SETUP_TYPE" \
  [--sandbox "$SANDBOX"] [--repo "$REPO_CHOICE"] || true
```

Then output (in the user's language): "GAIA setup complete. Restart Claude Code so the new plugin and skill state are picked up. The statusline will surface `/update-deps` and `/update-gaia` indicators when applicable."

## Idempotence / re-run safety

A plain (no-flag) re-run on a fully provisioned project prints the already-provisioned line and mutates nothing: default-branch protection JSON and `.gaia/project.json` are byte-identical before and after, and no mutating `gh` call fires. Never re-provision the repo or change branch protection on a plain re-run; the one branch-protection change a re-run makes is the owed `GAIA-Audit` registration (Phase 3) for an admin on a repo whose required contexts lack `GAIA-Audit` or still carry `code-review-audit`. Only `--reconfigure` re-opens the settled sandbox, isolation-policy, Dependabot, and statusline decisions.

## On failure: re-run

Every step and CLI primitive is idempotent and safe to re-run on partial state. After fixing any failure cause (auth missing, network error, malformed config), simply re-run `/setup-gaia`, each phase detects its own completion and resumes from the first owed step.
