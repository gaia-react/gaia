---
name: setup-gaia-ci
description: Wire up GAIA CI workflows on GitHub. Run after first git push origin main. Idempotent, re-runs short-circuit; --reconfigure rotates tokens and re-selects tools.
---

Wire up GAIA CI on GitHub. Run this once after your first `git push origin main`. The command is idempotent, re-running on a configured repo prints `GAIA CI is already configured` and exits. Pass `--reconfigure` to rotate the bot token or re-select which tools run on cron.

The flow:

- Detect the repo's `origin` remote and confirm it's GitHub.
- Warn if Dependabot or Renovate is configured (GAIA Sharpen overlaps).
- Ask: enable now / not now / opt out for the team.
- If admin: offer to enable `delete_branch_on_merge` (makes stale-branch cleanup redundant).
- Provision the bot-token secret (`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`) **out of band**: you set it yourself via `gh secret set` or the GitHub web UI, and GAIA only verifies it exists by name. The token value never enters the chat. The same secret authenticates the cron workflows and the `code-review-audit.yml` PR gate, the audit honors either token type.
- Generate `.github/workflows/gaia-ci-*.yml` from `.gaia/automation.json` and install `.github/workflows/code-review-audit.yml`.
- Trigger one `workflow_dispatch` run to verify the workflow boots.
- On success, commit the workflow files plus a flip of `setup_complete: true` in a single commit.

The slash command name intentionally does NOT start with `gaia-` so it does not pollute the `/gaia` autocomplete namespace (those are reserved for the four user-invoked GAIA workflows).

## Step 0: Argument parse

Parse `$ARGUMENTS` for the `--reconfigure` flag. Cache the boolean as `RECONFIGURE`.

## Step 1: Detect Phase A

```bash
.gaia/cli/gaia setup-ci status --json
```

Read the JSON. If `configured: false`, print:

```
GAIA CI is not configured for this repo. Run /gaia-init first.
.gaia/automation.json is missing.
```

Exit cleanly. Otherwise cache `setup_complete`, `setup_opted_out`, and `tools_enabled` for later steps.

## Step 2: Idempotent short-circuit (with template-drift escape)

When `setup_complete: false`, fall through to Step 3.

When `setup_complete: true` AND `RECONFIGURE` IS set, fall through to Step 3, the reconfigure path re-runs the rest of the flow. `--reconfigure` does NOT touch `setup_complete`; it stays true.

When `setup_complete: true` AND `RECONFIGURE` is NOT set, probe for template drift:

```bash
.gaia/cli/gaia setup-ci check-drift --json
.gaia/cli/gaia setup-ci check-audit-drift --json
```

Read both JSON responses. `check-drift` returns `{drifted: ToolId[], missing: ToolId[], in_sync: ToolId[]}`. `check-audit-drift` returns `{state: "in_sync" | "drifted" | "missing"}`.

If `drifted.length === 0 && missing.length === 0` AND `check-audit-drift` state is `"in_sync"`, print exactly:

```
GAIA CI is already configured. Pass --reconfigure to rotate tokens or change tool selection.
```

Exit cleanly. Do not modify any file.

Otherwise (drift or missing cron files, or audit workflow drifted/missing), summarize the affected workflows and `AskUserQuestion`:

> The .github/workflows files have drifted from the bundled templates.
>
> Cron workflows, Drifted: <drifted-list-or-(none)> | Missing: <missing-list-or-(none)>
> Audit workflow, <in_sync|drifted|missing>
>
> What would you like to do?
>
> - **Re-render workflows** (Recommended), regenerate only the drifted/missing cron files and re-install the audit workflow from the current templates, then commit + push on a branch + open a PR. Keeps tool selection and token unchanged.
> - **Skip**, leave the workflows as-is. The next `/update-gaia` will not re-offer this prompt unless templates drift again.
> - **Run full reconfigure instead**, same as `/setup-gaia-ci --reconfigure`: re-prompt for tool modes and rotate the bot token.

On "Re-render workflows" → fall through to Step 11.5 (drift-fix path).

On "Skip" → exit cleanly with no changes.

On "Run full reconfigure instead" → set `RECONFIGURE = true` and fall through to Step 3.

## Step 3: Detect remote

```bash
.gaia/cli/gaia setup-ci detect-remote --json
```

Read the JSON. If `found: false`, print:

```
No `origin` remote found. Run `git remote add origin <url>` and `git push origin main` first, then re-run /setup-gaia-ci.
```

Exit cleanly.

If `host != "github.com"`, print:

```
GAIA CI v1 supports GitHub Actions only. Detected host: <host>. Support for GitLab / Bitbucket / Circle is out of scope for this release.
```

Exit cleanly. Otherwise cache `owner` and `repo`.

## Step 4: Warn about existing Dependabot / Renovate

```bash
.gaia/cli/gaia setup-ci warn-existing-tools --json
```

If `found` is non-empty, print the warning text (substituting the actual tools):

```
A {tool} configuration was detected in this repo. GAIA Sharpen covers the same ecosystems, and running both tools in parallel will open duplicate dependency PRs.

Recommendation: disable {tool} for the ecosystems GAIA Sharpen covers (npm, pnpm) before continuing. /setup-gaia-ci will NOT auto-disable {tool}.
```

Then `AskUserQuestion`:

> Continue with /setup-gaia-ci? You can disable {tool} now in another terminal and come back to confirm.
>
> - **Continue (I've decided how to handle the overlap)** (Recommended)
> - **Cancel (I'll address {tool} first and re-run /setup-gaia-ci)**

On Cancel, exit cleanly. On Continue, fall through.

When `found` is empty, skip the warning and the question.

## Step 5: Three-option enable / not now / opt out

First, run the admin probe:

```bash
.gaia/cli/gaia setup-ci check-admin --owner <owner> --repo <repo> --json
```

Cache `admin` and `auth_status`. Treat `auth_status != "ok"` as personal-dismiss-only, never offer team opt-out unless `auth_status == "ok"`.

If `RECONFIGURE` is set, skip this question entirely and use the reconfigure flow described in Step 11.

Otherwise `AskUserQuestion` with these three options in this exact order:

> Enable GAIA CI now? It runs four maintenance jobs on a smart cron (wiki sync, /update-deps, pnpm audit, stale branches), opens labeled PRs, and auto-merges them on green CI.
>
> - **Enable GAIA CI now** (Recommended)
> - **Not now** (you can re-run /setup-gaia-ci anytime)
> - **Don't ask the team again** (admin-only; skips this prompt for everyone)

Branches:

- **Enable now:** fall through to Step 6.
- **Not now:**

  ```bash
  .gaia/cli/gaia setup-ci dismiss-personal
  ```

  Print `Personal dismissal recorded. Re-run /setup-gaia-ci anytime to enable.` and exit.

- **Don't ask the team again:**
  - If `admin: false` (or `auth_status != "ok"`): print

    ```
    "Don't ask the team again" requires repo admin permission. Your permission level is admin: <admin>, auth_status: <auth_status>. Falling back to personal dismissal.
    ```

    Then `AskUserQuestion`:

    > Apply personal dismissal instead?
    >
    > - **Yes** (Recommended)
    > - **No** (cancel, neither team opt-out nor personal dismissal is recorded)

    On Yes: shell `gaia setup-ci dismiss-personal` and exit. On No: exit cleanly.

  - If `admin: true`: shell

    ```bash
    .gaia/cli/gaia setup-ci opt-out-team
    ```

    Print `Team opt-out recorded in .gaia/automation.json (setup_opted_out=true). Commit and push to apply for the team.` and exit. The slash command does NOT auto-commit the team opt-out write, review the diff and commit yourself.

## Step 6: Repo hygiene check

Only reached when the user picked "Enable now" in Step 5 (or is in the reconfigure flow).

Read the current `delete_branch_on_merge` setting:

```bash
gh api "repos/<owner>/<repo>" --jq .delete_branch_on_merge
```

Cache the boolean.

If `false` AND `admin: true`, `AskUserQuestion`:

> GitHub is set to NOT delete branches when PRs merge. GAIA's monthly stale-branch cron exists to clean those up. If we enable `delete_branch_on_merge` now, the cron becomes redundant and we'll mark `stale_branches.mode = "off"` in `.gaia/automation.json`.
>
> - **Enable delete_branch_on_merge** (Recommended; mark stale-branches off)
> - **Skip** (keep stale-branch cleanup cron active)

On Enable:

```bash
.gaia/cli/gaia setup-ci enable-delete-branch --owner <owner> --repo <repo>
.gaia/cli/gaia setup-ci write-tool-mode stale-branches off
```

If `false` AND `admin: false`, skip the question and print:

```
Note: delete_branch_on_merge is disabled on the repo. An admin running /setup-gaia-ci can offer to enable it.
```

If already `true`, skip the question. Print:

```
delete_branch_on_merge is already enabled, stale-branches cron is redundant. Marking stale_branches.mode = "off".
```

Then shell the `bump-state` call directly:

```bash
.gaia/cli/gaia setup-ci write-tool-mode stale-branches off
```

## Step 6.5: Team audit-mode policy

Only reached when the user picked "Enable now" in Step 5 (or is in the reconfigure flow). This sets the team baseline for how the `code-review-audit` runs at merge time. It writes two keys to the committed `.gaia/audit-ci.yml`: `default_mode` (the team fallback) and `override_label` (the sticky label that forces a CI run regardless of author).

`AskUserQuestion`:

> How should the code-review-audit run for your team?
>
> - **CI audits every PR (Recommended).** Sets `default_mode: ci`. Every PR's audit runs on CI; this is today's behavior.
> - **Local-first.** Sets `default_mode: local`. Developers who run GAIA locally have the audit run at merge time; CI stands down for them. Each developer still opts in per-person via /setup-cloned-gaia-project; the team default is the fallback. Local-first relies on the GAIA-Audit required check being registered on the default branch (this same /setup-gaia-ci flow registers it). If that check is ever unconfirmable, the resolver fails closed to `ci`, so a local stand-down can never leave the branch unguarded.

Cache the chosen mode (`ci` or `local`), then write both keys to `.gaia/audit-ci.yml`. Set `default_mode:` to the chosen value and `override_label: run-audit`, adding each key if absent and rewriting it in place if present (do not duplicate). Leave `audit_authors` untouched, individual developers append to it via /setup-cloned-gaia-project.

The file is committed alongside the workflow files in Step 10's existing commit; do NOT auto-commit it here.

## Step 7: Token type selection and out-of-band secret provisioning

`AskUserQuestion`:

> Which bot token will GAIA CI use to authenticate workflow steps that hit the Anthropic API?
>
> The same repo-scoped secret authenticates all GAIA CI workflows, both the scheduled cron jobs (`gaia-ci-*.yml`) and the `code-review-audit.yml` PR gate. The audit honors either token type; whichever you set here is the one the audit uses.
>
> - **CLAUDE_CODE_OAUTH_TOKEN** (default for Claude Code subscribers)
> - **ANTHROPIC_API_KEY** (default for direct Anthropic API customers)
> - **I don't know** (link to docs and exit)

On "I don't know", print:

```
Open https://gaiareact.com/setup-gaia-ci to read the token-type section, then re-run /setup-gaia-ci.
```

Exit cleanly.

On a token choice, provision the secret **out of band**. GAIA never handles the token value.

**Non-negotiable safety rule.** The token value MUST NOT enter this conversation or the agent's process at all. Do NOT ask the user to paste it, do NOT read it from a chat message, and do NOT route it into any sink. This includes, but is not limited to, Bash command strings, `Edit` / `Write` / `NotebookEdit`, `AskUserQuestion`, commit messages, memory or scratchpad files, subagent prompts, scheduled tasks, and outbound network or MCP calls. The rule is simpler than any list: the value must never leave the user's own terminal. Anything typed into the chat is recorded in the transcript, sent to the model API, and may be persisted by the harness, piping it to `gh` afterward does not undo that exposure. If the user pastes a secret anyway, STOP: treat the pasted value as compromised, do not use or store it, tell them it is now exposed in the transcript and must be rotated, and continue with the out-of-band steps below.

**The agent prints these commands for the user to run in their own terminal; it never executes `gh secret set` (or `.gaia/cli/gaia setup-ci set-secret`) itself.** Both require the token value on stdin or the command line, which the agent must never hold.

**Admin pre-gate.** Managing GitHub Actions secrets requires repo-admin permission. If the `admin` flag cached in Step 5 is not `true` (or `auth_status != "ok"`), do not print the set instructions. Print:

```
Setting the <NAME> secret requires repo-admin permission and an authenticated gh (yours: admin=<admin>, auth_status=<auth_status>). Ask a repo admin to set it and finish /setup-gaia-ci, or gain admin access (and run `gh auth login` if needed), then re-run /setup-gaia-ci.
```

Exit cleanly.

If `RECONFIGURE` is set, skip the fresh-setup block and go straight to **Reconfigure (rotation)** below.

**Fresh setup.** Substitute the chosen secret name for `<NAME>` and the cached `owner` / `repo` (Step 3) before printing, do not print literal angle brackets. Print these instructions and wait for the user to confirm:

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

- Non-empty output (exact name match), print `Verified: <NAME> is set. Its value never entered this session.` and fall through to Step 8.
- Empty output (secret absent), `AskUserQuestion`:

  > `<NAME>` is not set on `<owner>/<repo>` yet.
  >
  > - **Retry verification** (I've set it, check again)
  > - **Abandon** (exit; re-run /setup-gaia-ci later)

  On "Retry verification", re-run the presence check. On "Abandon", exit cleanly, `setup_complete` stays `false`.
- If `gh secret list` errors (e.g. HTTP 403), surface the error verbatim, note that managing Actions secrets requires repo-admin permission, and exit cleanly.

**Reconfigure (rotation).** Reached only when `RECONFIGURE` is set. The secret already exists, so the goal is to overwrite it. Print the `gh secret set <NAME> --repo <owner>/<repo>` command from **Fresh setup**, framed as a rotation (running it again overwrites the value silently, and the value still never enters this chat), then `AskUserQuestion`:

> Rotate the <NAME> secret now?
>
> - **I've rotated it** (verify and continue)
> - **Keep the existing token** (no rotation)

On either answer, run **Verify presence** for `<NAME>`, both paths require the chosen secret to exist (this matters when the token type changed during this reconfigure). Then fall through to Step 8.

## Step 8: Generate workflow YAML

Shell the workflow generator:

```bash
.gaia/cli/gaia automation render-workflows --out-dir .github/workflows
```

Capture the JSON list of written cron-workflow paths.

Then install the audit workflow unconditionally:

```bash
.gaia/cli/gaia automation install-audit-workflow --out-dir .github/workflows
```

The audit is the PR gate, it installs regardless of how many cron tools are in CI mode. Even if zero cron tools are configured for CI, the audit alone is a valid CI posture; proceed to Step 9 using the audit workflow path as the verification target.

If `render-workflows` reports no paths written (the config has `mode: "ci"` for zero cron tools), do NOT exit, install the audit and continue. Print a note:

```
No cron tools are configured for CI mode in .gaia/automation.json. The code-review-audit.yml PR gate is installed. Edit .gaia/automation.json to add cron workflows later.
```

### Register GAIA-Audit as the required check

The audit gate is the `GAIA-Audit` COMMIT STATUS, not the `code-review-audit` job name. The audit job reaches a green terminal step on every path (including a local-mode stand-down where no audit ran), so requiring the job name would let an unaudited PR merge through the github.com button. Only the `GAIA-Audit` status (`success` == cleared for HEAD's tree) is the gate. The resolver honors `default_mode: local` only when this registration is confirmed present, so registering it is what makes local-mode safe.

Register `GAIA-Audit` as a `required_status_checks` context on the default branch:

```bash
gh api -X PUT "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks" \
  -f strict=true -f 'contexts[]=GAIA-Audit'
```

Substitute `<owner>` and `<repo>` (cached in Step 3) and `<default-branch>` (typically `main`). A full `required_status_checks` PUT REPLACES the contexts array; if the repo already requires sibling contexts (e.g. `Tests`, `Chromatic`), include them in the SAME PUT (`-f 'contexts[]=GAIA-Audit' -f 'contexts[]=Tests' -f 'contexts[]=Chromatic'`) so they persist.

This call needs repo-admin permission and a branch-protection rule on the default branch. If it returns 403 (not admin) or 404 (no protection rule yet), surface the error verbatim and tell the user:

```
Could not register the GAIA-Audit required check (admin permission and a branch-protection rule on the default branch are required). Run the registration yourself once you have admin access:
  gh api -X PUT "repos/<owner>/<repo>/branches/<default-branch>/protection/required_status_checks" -f strict=true -f 'contexts[]=GAIA-Audit'
Until GAIA-Audit is a required check, the merge gate falls back to ci mode for every author (the resolver fails closed).
```

Do not halt setup on a registration failure, the workflow install already succeeded; continue to Step 9.

## Step 9: Trigger verification run

Pick the FIRST workflow file from the generated list (typically `.github/workflows/gaia-ci-wiki.yml`):

```bash
.gaia/cli/gaia setup-ci verify-run .github/workflows/gaia-ci-wiki.yml --json
```

Read the JSON.

If `verified: true`, print `Verification run succeeded. Conclusion: success. URL: <url>.` and fall through to Step 10.

If `verified: false`, surface the URL and `AskUserQuestion`:

> Verification run did not succeed. Conclusion: <conclusion>. URL: <url>.
>
> - **Retry verification** (re-run gh workflow run on the same workflow)
> - **Abandon** (delete the generated workflow files; commit nothing)
> - **Commit without verification** (use only if you've already inspected the failed run and confirmed it's a transient infrastructure issue)

On Retry: re-shell `verify-run`. (One retry permitted, second failure prompts the same three options again with Retry removed.)

On Abandon: delete every file in the generated paths list, then exit. The `setup_complete` flag stays `false`.

On Commit without verification: fall through to Step 10 with a flag that adds `(unverified)` to the commit message.

## Step 10: Finalize and commit

```bash
.gaia/cli/gaia setup-ci finalize
```

Stage the generated workflow files plus `.gaia/automation.json` and the audit-policy `.gaia/audit-ci.yml`:

```bash
git add .github/workflows/gaia-ci-*.yml .github/workflows/code-review-audit.yml .gaia/automation.json .gaia/audit-ci.yml
```

Commit with this exact message (when verified):

```
chore(gaia-ci): finalize Phase B setup, verified workflow_dispatch run

Adds .github/workflows/gaia-ci-*.yml, installs
.github/workflows/code-review-audit.yml PR gate, and flips
.gaia/automation.json:setup_complete to true.
```

When the commit-without-verification flag is set, append `(unverified)` to the title and add a body line: `Verification run did not succeed; user opted to commit anyway.`

Push:

```bash
git push origin <current-branch>
```

Print:

```
GAIA CI is configured. Workflows: <list>. Status: setup_complete=true. The first scheduled cron will fire at the times encoded in .github/workflows/gaia-ci-*.yml; you can run any workflow on demand via the Actions tab's "Run workflow" button or `gh workflow run <file>`.
```

## Step 11: --reconfigure flow

When `RECONFIGURE` is set, the short-circuit at Step 2 is skipped and the flow re-runs Steps 3–10 with two differences:

- **Step 5** is REPLACED with this two-option question:

  > Re-select the tools running on cron. Current selections: <tools_enabled>.
  >
  > - **Re-prompt and rewrite .gaia/automation.json**
  > - **Keep current selections** (only rotate the token)

  On "Re-prompt", `AskUserQuestion` for each of `wiki`, `update-deps`, `pnpm-audit`, `stale-branches` with mode options `ci` / `local` / `off`. Apply each via `.gaia/cli/gaia setup-ci write-tool-mode <tool> <mode>`.

- **Step 6.5** re-offers the team audit-mode policy question (CI-every-PR vs local-first) and rewrites `default_mode` / `override_label` in `.gaia/audit-ci.yml` from the answer. The audit-policy file is already in Step 10's `git add` set, so a changed default lands in the reconfigure commit.
- **Step 7** runs its reconfigure (rotation) path: it asks the user to overwrite the secret out of band (`gh secret set` overwrites silently), never reading the existing or new value, then verifies presence by name.
- **Step 10's** commit message changes to:

  ```
  chore(gaia-ci): reconfigure, rotated tokens, regenerated workflows

  Re-runs /setup-gaia-ci's verification flow. setup_complete remains
  true.
  ```

  `setup_complete` is NOT touched on `--reconfigure`, it's already true.

## Step 11.5: Drift-fix path (re-render only)

Reached when Step 2 detected template drift and the adopter picked "Re-render workflows". Lightweight branch + commit + PR flow that regenerates the workflow YAML without re-prompting for tool selection or rotating the bot token.

Cut a working branch from the current HEAD:

```bash
git checkout -b chore/gaia-ci-rerender
```

Render the cron workflows and re-install the audit workflow:

```bash
.gaia/cli/gaia automation render-workflows --out-dir .github/workflows
.gaia/cli/gaia automation install-audit-workflow --out-dir .github/workflows
```

Stage and commit:

```bash
git add .github/workflows/gaia-ci-*.yml .github/workflows/code-review-audit.yml
git commit -m "chore(gaia-ci): re-render workflows from updated templates"
```

Push and open a PR:

```bash
git push -u origin chore/gaia-ci-rerender
gh pr create --base <default-branch> --head chore/gaia-ci-rerender \
  --title "chore(gaia-ci): re-render workflows from updated templates" \
  --body "GAIA CI templates drifted from the rendered workflows on disk. Regenerated cron workflows and re-installed the code-review-audit.yml PR gate via /setup-gaia-ci. No tool selection or token changes."
```

Print the PR URL and exit cleanly. Do NOT auto-merge, the adopter reviews and merges in their normal flow. `setup_complete` is NOT touched.

If `render-workflows` or `install-audit-workflow` fails for any reason, surface the structured error and exit; the branch is abandoned. The adopter can delete it (`git branch -D chore/gaia-ci-rerender`) and re-run `/setup-gaia-ci` after fixing the cause.

## On failure: re-run

The CLI primitives are idempotent and safe to re-run on partial state. After fixing any failure cause (auth missing, network error, malformed config), simply re-run `/setup-gaia-ci`, the idempotent short-circuit in Step 2 catches the already-finalized case and the rest of the flow recovers naturally.
