# Changelog

All notable changes to GAIA are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- **Major**: breaking changes to skill/command API, Node/React/React Router major bumps.
- **Minor**: new skills, commands, or wiki concept pages; opt-in features, removed or renamed `.claude/` paths.
- **Patch**: bugfixes, docs, and in-range dependency bumps.

## Adopter-action convention

A release change that requires the adopter to act, run a command or hand-migrate, is authored as a `### Removed` or `### Changed` entry carrying an explicit **Action required:** line and/or a literal command to run (for example, `pnpm remove <pkg>`). That exact phrasing is the deterministic anchor GAIA's two CHANGELOG consumers key on: `/update-gaia` cross-references it during a merge to surface a documented, opt-in cleanup suggestion (it never auto-removes a dependency or deletes a file, the adopter decides), and the maintainer-only `release-notes` skill keys on it to tell an agent-automated cleanup (reframe as a benefit or drop) from a human-must-act migration (keep, plainly framed, with a pointer to the steps). Keep the marker and command literal so both consumers match the anchor instead of free-parsing prose. The `react-router-dom` removal below is the worked example. `/update-gaia`'s confirm gate shows the full baseline-to-latest CHANGELOG range, so an adopter several versions behind sees every intervening entry.

## [Unreleased]

### Added

- Claude now asks before editing `.claude/settings.json`, the file that registers every GAIA hook and permission rule, in every permission mode including bypassPermissions, through the edit tools and the common shell write shapes; an unattended run cannot make the change through those routes. A pull request that changes it is now reviewed by the shell audit member, which lists any hook or permission rule the change removes or weakens. `.claude/settings.json` is a shared file, so a customized copy takes a three-way merge on update.

### Security

- **glob:** Storybook's docgen plugin now resolves glob 14.0.3 through a security floor, closing GHSA-3g3m-2fjr-6pw4 (medium). It is a development-time dependency and never reaches the built app (#3204)

## [2.3.1] - 2026-10-29

### Changed

- **Plainer public release notes (maintainer repo only):** the `release-notes` skill now writes for a visitor skimming the marketing site. Bullets say what changed in plain language and link a docs page for the detail instead of reciting it, and fixes read as the bug going away rather than a new feature (#3178, #3180)
- **1.6.1 routing line on every release (maintainer repo only):** `/gaia-release` now puts the 1.6.1 migration line first in every release body, since a 1.6.1 project meets whichever release is newest. The CHANGELOG no longer carries a copy in each entry, only in 2.0.0's (#3180)
- **Release notes bucketed by what the reader sees (maintainer repo only):** the `release-notes` skill now files each item under New, Improved or Fixed by how an adopter experiences it rather than by its CHANGELOG heading, copies the routing-line preamble only into the file it is writing, and leaves already-approved release files as they are (#3182)
- **Release fast path (maintainer repo only):** a release pull request whose whole change is version bookkeeping, cut from a green main, now runs a one-minute manifest consistency check in place of the full CI suites and needs no Code Audit Team pass, since main already verified the tree. Anything beyond the bookkeeping, a change to the bookkeeping check itself, or a main that is not green, still runs every gate (#3176)

### Fixed

- **Lint, typecheck, tests and shellcheck now block a merge:** `/setup-gaia` required only `GAIA-Audit`, so a pull request with red CI could still merge. It now also registers the `Vitest and Playwright` and `Shellcheck and bats` checks as required, keeping every check you already require; both report green when nothing they cover changed, and `Run Chromatic` stays optional. A repository admin's `/update-gaia` registers them on an existing project; otherwise an admin runs `/setup-gaia`. CI now lints only the frontend files changed since the last green run instead of the whole app, and lints everything when the ESLint config, a tsconfig or a dependency changes. A non-admin's `/setup-gaia` now names the checks it could not register and asks for a repository admin, instead of ending on "You're all set". On a project hosted outside GitHub, `/setup-gaia` records the checks as not applicable instead of naming them as owed by an admin on every run. When `gh` is not signed in or GitHub does not answer the admin check, setup names the settings still undecided and says to sign in and re-run, or ask a repository admin (#3185, #3194, #3197)
- **Telemetry ID is now random per install:** the adoption ping's `projectId` was a hash of the repository path, which a guessable path makes reversible. It is now a random UUID stored in `.gaia/local/.install-id`, and every existing install rotates to a new one once on its next ping, deleting the old `.gaia/local/.project-id`. No action needed (#3188)

## [2.3.0] - 2026-10-28

### Added

- **Shell audit member, bats stack and shell checks in CI:** the new `code-audit-shell` audit member reviews the shell you author and your own edits to shipped shell, not GAIA release updates. Shell files under `frontend/` and composite-action scripts under `.github/actions/` now go to it rather than the frontend member. `bats` is a new devDependency with `pnpm test:shell` (run `pnpm install` after updating). `tests.yml` gains a default-on `Tests / Shellcheck and bats` check that runs on every pull request: it shellchecks the shell the pull request changes (GAIA's own shell is skipped only on a GAIA update) and runs your `tests/shell/` bats suites when shell changed, finishing in seconds when there is nothing to check, so it can be made a required check. Set `"shellcheck": false` in `.gaia/project.json` to turn the lint off. `tests.yml` is a shared file, so a customized copy takes a three-way merge on update. `/update-gaia` removes `unowned:` entries the member makes overbroad and reports them; for a run that skipped it, run `bash .gaia/scripts/roster-prune-overbroad.sh --root . --member code-audit-shell` (#2873)
- **`/update-gaia --local <tarball>`:** syncs a project from a GAIA bundle built from an unreleased, committed checkout through the same merge, conflict and record steps as a release update. The source is labeled local and unverified and only released migration notes run. The project records the build in a committed `.gaia/VERSION-dev`, the next update merges against that build, and the next release update removes the file. The bundle builder is maintainer-only (#2747)
- **Harness file line limit (maintainer repo only):** GAIA's own CI now fails a harness code file over 400 lines unless it is grandfathered at a recorded ceiling, and fails a grandfathered file that grows past its ceiling (#3109)
- **Per-dispatch audit cost (maintainer repo only):** each Code Audit Team member and light reviewer dispatch now records its own tokens, calls, wall time and dollars, with per-role figures for the agents it spawned, and members already cleared for HEAD record that they were not dispatched. A report prints per-member medians over recent branches and counts results with no cost record, so audit spend is measured rather than estimated (#2913, #3117)
- **Tech-debt source record (maintainer repo only):** every tech-debt issue filed in GAIA's own repository now records a digest of the branch that filed it, and a report command reads those records back to show how many issues each pull request's audit files, so whether to batch minor findings can be decided from data (#2170, #3141)
- **`gaia migrate-csf4` command:** converts a project's Storybook stories to CSF Next in one run. It converts every story file, wires the preview and `.storybook/main.ts` to match, inlines any story export built by a factory function into a direct `meta.story({...})` call (Storybook cannot attach `.test()` to a factory-built export), then typechecks, lints and runs the stories, and prints a per-file report with a command that undoes the conversion. `--json` prints the same facts as one object.

### Changed

- **Stories move to CSF Next with test syntax on:** Storybook's `features.experimentalTestSyntax` is on, GAIA's story scaffolds emit CSF Next (`meta.story(...)` with behavior checks as `.test()` calls), and GAIA's readers now refuse an old-format story file with a pointer to the converter. **Action required:** if you update without `/update-gaia`, run `.gaia/cli/gaia migrate-csf4` once from the repository root; `/update-gaia` runs it for you through its 2.3.0 migration note. Converting renames every story test, so the update pull request needs a fresh worthiness verdict for each converted story test.
- **`/gaia-codify` declines are shared with the team:** a decline is now a small committed file in `.gaia/codify-declines/`, published through the codify pull request, so once it merges it suppresses the candidate on every teammate's clone. It lifts on a material rise, a tally-schema change, or once it is older than one tally window, and every `/gaia-codify` run lists team-declined classes where a teammate can override one with an approval. A run that only declines now opens a pull request. Migration: no action needed; existing machine-local declines keep suppressing on their own clone until each is older than one tally window, after which `.gaia/local/codify/declines.json` can be deleted (#2837, #3116)
- **Audit-filed tech-debt is graded by difficulty:** the audit member that found a defect now grades how hard the fix is, and when the audit files the finding as tech-debt that grade becomes its `difficulty:` label, so `/gaia-debt` batch budgets size audit-filed issues from the code instead of treating them all as medium. A finding the member cannot settle still files ungraded (#3159)
- **Readable issue bodies:** every GitHub issue Claude files now follows one writing guide, the new Issue Writing wiki page, so an agent with a fresh context can act on it from the body alone and a human can read it at a glance. Tech-debt issues show their failure mode and fix under `## Problem` and `## Fix` headings, with room for lists, tables and steps, instead of two one-line labels. The dedup key and other parsed lines are unchanged, and existing issues are left as they are (#3158)
- **CI back on ubuntu-latest (maintainer repo only):** GAIA's own test, lint, triage and release workflows run on ubuntu-latest (Ubuntu 26.04) again, so CI exercises the runner adopters are moving to (#3082, #3111)
- **Release dry run (maintainer repo only):** the release workflow can now be run by hand against an existing tag (`gh workflow run release.yml -f tag=vX.Y.Z`). It rebuilds and gates that tag's bundle and composes its release body without publishing anything, so a runner-image change is proven before a real tag meets it. Building now runs with a read-only token; only the publish step, on a tag push, can write (#3111)
- **Distribution harness runs on main (maintainer repo only):** pull requests run the slow distribution scenarios only when a path they cover changes, so most harness pull requests skip about 9 minutes of them, and every push to main runs the full harness. A red main run opens its own `ci-red-main` issue, which `/gaia-release` already refuses on, so a harness break that reaches main holds the release instead of surfacing at tag time (#3157, #3162)
- **Storybook Controls read props through TypeScript:** Storybook's `experimentalDocgenServer` feature is on ahead of becoming the default in Storybook 11, so the Controls panel infers component props from the TypeScript Language Service instead of react-docgen. A component built on a library primitive now lists its full typed props, and a union-typed prop gets a matching control (#3136, #3138)
- **Reuse-first order in the coding guidelines:** Simplicity First now states, in the always-loaded rules, the order to reach for code before writing new code (the project's own code, then the standard library or platform, then an installed dependency, then a new one only when it earns its weight, then the minimum new code), that a shared-code bug is fixed once where it lives with problems in other callers filed as tech debt, and what is never cut to make code smaller. The react-code skill now points to that order instead of keeping its own copy.
- **Tests workflow env no longer reads secrets for plain config:** `tests.yml` sets `API_URL`, `MSW_ENABLED` and `SITE_URL` as plain job env instead of reading them from repository secrets, since they are not credentials and MSW intercepts outbound HTTP in CI. `SESSION_SECRET` still comes from a secret. If you overrode any of the three through a secret, set the value directly in your own `tests.yml` (#3135)
- **Harness test shards share CI capacity on push (maintainer repo only):** a push run of the harness test shards now runs six legs at a time, so the post-merge run no longer holds most of the account's concurrent-job slots while other branches catch up; pull request runs keep full parallelism (#3067)
- **Plan story criterion reads `Story test criterion`:** the planner has each story-routed UAT write a `Story test criterion (<uat_id>)` line in place of `Story play-function criterion`, and `plan-verify.sh` checks for the new marker, so a plan no longer points the UAT's assertion at a play function. A plan written before this update fails `plan-verify.sh` until its criterion lines are renamed (#3147, #3150)

### Fixed

- **Stale and contradictory Claude instructions:** a prompt audit removed dated phrasing and fixed instructions that contradicted the repo or each other. The shadcn audit lens now flags any edit to a vendored component, since GAIA carries no local patches, and the maintainer shell auditor drops or demotes a finding that fails its proof gate like every other audit member, instead of keeping it as a Minor (#3170)
- **Tech-debt dedup reads every closed issue:** filing a tech-debt issue, and the dedup check, now read the open and closed tech-debt lists completely through paginated requests instead of a search that stops at 1000 results. On a repository with more than 1000 closed tech-debt issues, a finding you had already declined could be filed again; a failed or partial read now stops the filing instead (#3140, #3141)
- **Storybook viewport toolbar shows the project's viewports:** `.storybook/viewport.ts` now sets the custom Landscape, Portrait and mobile viewports under `options`, the key Storybook 10 reads, so they appear in the toolbar instead of Storybook's defaults. The unused `controls.hideNoControlsWarning` parameter is removed from the preview, the stories and the component and route scaffolds, which no longer emit it. Existing stories that set it can drop it; nothing reads it (#3137, #3139)
- **Fitness check on project paths with a `home` or `Users` folder:** `gaia fitness check` no longer reads a project path such as `src/pages/home/sections/Hero.tsx`, named in a skill, command, rule or agent, as a machine-specific home directory. The false warning lowered the fitness grade and armed the `/gaia-fitness` statusline nudge. Real home paths (`/Users/<name>/...`, `/home/<name>/...`, `C:\Users\<name>\...`) are still flagged (#3122)
- **Light-routing spend ratio (maintainer repo only):** the light-routing tally compared a light reviewer's final context size against a full member's cumulative spend, overstating the savings about 30x. It now compares deduplicated spend on both sides, from the recorded dispatch costs, falls back to the fixed baseline only when no member cost is recorded and says which it used, and counts light reviews with no cost record apart. The kill rule is unchanged (#3115)
- **Audit round gate under worktree isolation (maintainer repo only):** the audit loop unit no longer stops a passing round as failed when it runs in a worktree. The prescribed background verification command was refused there, and the plain one never wrote the completion line the unit waits on. The verification runner now writes that line itself on every exit, and the unit runs the plain command (#3132, #3134)
- **Tests workflow on a slow Ubuntu mirror:** installing Playwright's system dependencies no longer stalls the Tests job until its timeout. The packages are cached per runner image and install offline once cached; an uncached install is bounded and retried, keeps what each attempt downloaded, and on final failure names the `gh run rerun <id> --failed` command that recovers it. The workflow now uses the new `.github/actions/gaia-apt-cache` action, which `/update-gaia` installs with it (#3039, #3090)
- **`/update-deps` lands an in-range patch you exempted from the release-age window.** When a fresh release was admitted early by a `minimumReleaseAgeExclude` entry, the security phase's in-range refresh and the transitive refresh could finish cleanly having moved nothing, because pnpm answered from metadata it had cached before that release existed. Both refreshes now drop that cached metadata before resolving (#3054)
- **`/update-deps` keeps a revert baseline for the sub-dependency update and security resolutions.** GAIA's shipped settings deny editing `pnpm-lock.yaml`, which also refuses any `cp` of the lockfile, so both snapshots failed on every run. The refresh then rewrote the lockfile with nothing to revert to, and the only way back was a reset that discarded the run's other updates. The snapshot is now a git baseline, and a snapshot that fails stops the run before anything touches the lockfile, reported as `Not run (snapshot failed: <reason>)` (#3155, #3156)
- **`pnpm install` in CI no longer stalls on a slow registry response:** the `gaia-setup-node` action, and the root install in `pr-conventions.yml`, bound each install attempt (3 minutes by default, about three times the slowest normal install), retries once when the bound ends an attempt, and fails the step naming the bound when both attempts stall, so one hung npm registry request costs minutes instead of ten. pnpm's own fetch timeout cannot do this, since it only ends a request that makes no progress. The new `install-attempt-seconds` input raises the bound for a workspace whose install legitimately takes longer (#3163)
- **Wiki drift after a squash-merged wiki PR:** `gaia wiki state` no longer counts main commits the wiki branch already synced through a catch-up merge as drift, so the statusline nudge stays quiet and `/gaia-release` preflight no longer refuses with a false "wiki is N commits behind HEAD" (#3098)
- **Audit findings with an array-wrapped grade or audience are refused at the member:** a `grade` of `["easy"]` or an `audience` of `["adopter"]` passed the findings writer's checks and then failed when the audit filed the finding as tech-debt, after the member that could fix it had returned. The writer now refuses any value that is not one of the allowed strings (#3167)

## [2.2.0] - 2026-10-26

### Added

- **License notice in new projects:** new projects now carry GAIA's license notice at `.gaia/LICENSE`: the MIT License, prefaced by a short statement that it covers every file GAIA provides, wherever it sits in the project, while the project's own license covers everything else. The project root stays free for your own `LICENSE`. GAIA's copyright holder is now named as Steven Sacks rather than "GAIA" (#3065)

### Changed

- **Onboarding finishes in one Claude session.** After `npx create-gaia`, `/gaia-init` continues straight into `/setup-gaia` instead of telling you to exit and restart Claude twice, and setup ends with no restart and no reload: it suggests `/clear` to start your first feature with a fresh context. `/gaia-init` installs the React Doctor skill first, so it is available in that same session; the other per-machine installs (Playwright CLI, the typescript-lsp plugin) run only in `/setup-gaia`, so a first run that stops after init finishes shows `⚙️ /setup-gaia (Required)` until setup finishes.
- **Lint package:** GAIA's lint package is now `@gaia-harness/lint`. `/update-gaia` adds it, swaps the lint config imports, and removes `@gaia-react/lint`, which stays installable (deprecated).
- **query-string 10:** the app's API URL helper now uses query-string 10, whose `stringify()` throws a `TypeError` for a search-param value it cannot represent (a nested object, a function, a `Date`) instead of sending `[object Object]`. Pass such values as strings, or convert them with query-string's `replacer` option (#3093)

### Fixed

- **Locks on Ubuntu 26.04:** GAIA's lock directories now admit one holder at a time on every system. Ubuntu 26.04's `mkdir` (uutils coreutils) can report success to two processes creating the same directory at once, so two writers could both enter a lock and one update was lost: an audit round went uncounted, or a notebook, port-slot or usage write vanished. Ownership is now decided by an exclusive file create inside the lock, which does not depend on `mkdir` (#3084)
- **Fitness grade on new projects:** a freshly created project no longer shows `/gaia-fitness (grade B-)` on the statusline for its first hours. The wiki's citations of the machine-local `frontend/.env` counted as dead paths until setup wrote that file, and the statusline cached the resulting grade; the dead-path check now treats that file as machine-local.
- **`gaia init strip-branding`:** the Storybook sidebar is de-branded again. The step stopped finding the brand declaration after it was renamed in `.storybook/preview.ts`, so new projects kept the GAIA title and link while init reported the step complete. It now rewrites the current declaration and exits 1 with `storybook_brand_missing`, recording nothing, when a preview it cannot de-brand is present (#3058)
- **RED capture no longer installs dependencies:** the test re-run the RED-capture hook makes after a scoped `pnpm test --run <file>` could make pnpm install first when a `package.json` disagreed with `pnpm-lock.yaml`, silently rewriting the lockfile and `node_modules`. The re-run now skips pnpm's pre-run dependency check (#3080)
- **jq 1.8 compatibility:** on jq 1.8 (Homebrew's current jq on macOS, and Ubuntu 26.04), the update check dropped the reason a dependency security-advisory count was unavailable (such as `gh-unauthenticated`), and joining a workflow's usage tracking recorded the join at the wrong time, misattributing that session's spend. jq 1.8 parses an operator before `as` differently from jq 1.7; both programs are now parenthesized to mean the same thing under either version (#3086)

## [2.1.1] - 2026-10-24

### Fixed

- **Worktrees wiki page:** a sentence explaining why `.gaia/local/` has no allowlist was missing from the shipped page, because it shared a line with a maintainer-only marker and the bundle scrub drops that whole line. The release build now refuses any marker line that carries other text, so a scrub can no longer drop adopter content silently (#3049)
- **`/gaia-fitness` grade card:** the CLAUDE.md category is labelled `CLAUDE.md` instead of its internal id `claudemd`, in both its grade row and its findings header. The JSON report and rule ids keep `claudemd`, so nothing that reads them changes (#3047)

### Security

- **body-parser:** the app's server now resolves body-parser 2.4.0, closing GHSA-27r3-jxmh-p828 (high). It reaches the app at runtime through `@react-router/serve` and express

## [2.1.0] - 2026-10-23

### Added

- **Generated-files rule:** a new rule loads when Claude reads `frontend/.claude/settings.json` or `pnpm-lock.yaml` and names the source to change instead: the root settings or the frontend overlay followed by `gaia packages sync-settings`, or pnpm for dependencies. Until now the only signal was a permission deny with no reason (#3023)
- **`/setup-gaia` catches a machine up to 2.0.0.** On a clone that was on GAIA 1.x, `/setup-gaia` now finds the 1.x leftovers the migration only cleared on the machine that ran it (old local files, the notebook move, the root React Doctor copy, Serena, old spec branch names, renamed variables, leftover files) and fixes each, asking before anything is deleted or pushed; a project that was never on 1.x records it as not applicable. Every run also checks that git hooks are active (`core.hooksPath` is `.githooks`) and offers to turn them on, so a clone no longer commits without the pre-commit and commit-msg checks unnoticed (#3014)
- **`/gaia-spec reopen SPEC-NNN`** reopens a saved SPEC whose UAT cannot hold: Claude asks for the reason, records it with the UAT diff, updates the plan routing it affects, and hands back the plan's resume prompt (#3019)
- **Adding a language after setup.** Ask Claude to add a language at any time and it follows the same runbook `/gaia-init` uses, which now stays in the project; removing i18n entirely deletes both runbooks, since neither applies afterwards (#3015)
- **Your own audit finding classes:** register the finding classes and tool prefixes your own Code Audit Team members report in `.gaia/finding-classes.json`, and `/gaia-codify` counts their recurrence like GAIA's built-in classes and `file-tech-debt` files them instead of diverting them as malformed. A finding whose class is in no vocabulary now counts toward the unclassified signal instead of disappearing from the tally. The file ships empty and `/update-gaia` never overwrites it (#3012)
- **Customizing GAIA wiki page:** one map of every adopter customization: where it lives, whether `/update-gaia` will merge against it, the how-to page, and the check Claude runs afterwards. It also documents the fitness suppression file and how to move the base dev and Storybook ports, so "ask Claude to change X" works without reading GAIA's source. The hooks page now gives numbered steps for adding, disabling and overriding a hook, and the backend package playbook adds a CI step, a contract for per-stack quality gates and a closing verify block (#3016, #3017, #3018)

### Changed

- **`/gaia-plan` reads a SPEC from its id or its path only.** The `SPEC-NNN: <description>` prefix, the 1.x hand-off shape, no longer selects the SPEC; pass the bare id `/gaia-spec` hands off (`/gaia-plan SPEC-NNN`) or the SPEC's path (#3034)
- **Claude takes the steps it used to hand you.** A failed `/gaia-init` step resumes once you confirm the cause is fixed; `/setup-gaia` offers your GitHub handle for a placeholder `CODEOWNERS` owner before its first push; an `in-progress` claim is released when Claude closes the pull request unmerged or you drop the work; and after an `/update-gaia` pull request merges, Claude lists the leftover files the update retired and deletes them on your yes, instead of printing a command to run (#3013, #3019)

### Fixed

- **`/gaia-init` with two or more added languages.** Choosing more than one language beyond the primary stopped at the first one's verification, because every chosen language is registered before any of their translation files exist. Init now creates every language's files first and verifies once (#3015)
- **Each language is registered only once its files exist.** `gaia init configure-i18n` no longer registers every chosen language up front, which made a typecheck fail on any language whose translation files were not created yet. The add-language runbook now registers each language as it creates its files, so the project typechecks after every language, at setup or later; a primary language other than English still replaces English once its files exist (#3031)
- **Hard-reset guard:** `git reset --hard` to any other commit is now denied whatever the spelling (`HEAD^`, `@~1`, a SHA, a branch name), not only `HEAD~<n>`, and the denial says why and that the reset is the user's to run. A reset with no target, or to `HEAD`, still discards uncommitted changes as before (#3022)
- **Worthiness gate refusal:** the merge refusal for an emergent test with no worthiness verdict now names one path, running the worthiness evaluator, and no longer offers a direct ledger write that recorded a verdict without the review (#3021)
- **Refusals with a next step:** several guard refusals now say what Claude can do next or that the step is the user's: the pre-commit registry failure, `rm -rf node_modules` (repair with `pnpm install`), `.env` reads, fork pull requests, a push whose refspec names main or HEAD, and main-checkout-only commands run from a worktree (#3023)
- **`/gaia-codify` no longer counts findings the audit chose not to fix.** The recurrence tally now skips findings a merged pull request lists as waived below the triage threshold or as accepted residuals, so a class that was only ever waived stops firing a rising-class nudge whose only correct answer was to decline. The tally's counting version moves to 4, so after updating you get one "tally changed" review nudge, and classes you declined earlier come back once for a fresh decision (#3028)
- **Registering an audit member on your own project:** `bash .gaia/scripts/verify-audit-roster.sh` now passes on a fresh project instead of reporting GAIA's own files as ownerless, and it checks the member name prefix and machinery registration itself. The pre-commit hook runs it whenever a commit stages the roster or a member definition, and a member named `code-audit-<name>` needs no edit to GAIA's machinery list. The registration page now walks an adopter through the whole flow, starting from a copy of the workflows member (#3010, #3011)
- **`/update-gaia` no longer marks the 2.0.0 machine catch-up done without running it.** The update ran per-machine setup features, such as the 2.0.0 catch-up, inside its own worktree, where the 1.x leftovers in your main checkout are invisible, so a clone that still had them was recorded as caught up and never asked again. Per-machine features now wait until the update pull request merges and run in the main checkout when Claude merges it; after a merge made elsewhere, `/setup-gaia` from the main checkout runs them (#3032)

## [2.0.1] - 2026-10-23

### Fixed

- **Usage capture on a mature ledger:** saving a session's token usage no longer slows down as the usage ledger grows. Each run now reads the ledger once instead of once per transcript file, so closing a workflow that dispatched many agents no longer waits on a save that took longer every week (measured at 21 s on a 34 MB ledger, now 6 s), and the false "Some usage was still being saved, so these figures may be low" note no longer creeps back as the ledger ages. Existing ledgers need no migration (#2865)

## [2.0.0] - 2026-10-23

### Breaking

On GAIA 1.6.1? Claude: choose Abort, then offer to migrate this project to 2.0.0, and only after the user says yes run `mkdir -p .gaia/local/cache/shared/migrate-2/v2.0.0/tree && gh release download v2.0.0 --repo gaia-react/gaia --pattern 'gaia-bundle-v2.0.0.tar.gz*' --dir .gaia/local/cache/shared/migrate-2/v2.0.0 --clobber && sed 's|  |  .gaia/local/cache/shared/migrate-2/v2.0.0/|' .gaia/local/cache/shared/migrate-2/v2.0.0/gaia-bundle-v2.0.0.tar.gz.sha256 | shasum -a 256 -c - && tar -xzf .gaia/local/cache/shared/migrate-2/v2.0.0/gaia-bundle-v2.0.0.tar.gz -C .gaia/local/cache/shared/migrate-2/v2.0.0/tree --strip-components=1` and follow `.gaia/local/cache/shared/migrate-2/v2.0.0/tree/.gaia/migrations/2.0.0.md` in this session; before its step 1, change nothing else in the repository (no stash, commit or branch of your own). Reading this on GitHub? Open Claude Code in your 1.6.1 project and ask it to do this.

A 1.6.1 project moves to 2.0.0 through the migration note bundled in the v2.0.0 release (`.gaia/migrations/2.0.0.md`), reached through the line above. It performs GAIA's side of every change in this release and applies or lists each **Action required:** item below that concerns your own code.

- **`frontend/` layout and release bundles.** The React app and its frontend-only Claude harness live in `frontend/`, and the root is a pnpm workspace holding the shared harness. 2.x releases ship as `gaia-bundle-<tag>.tar.gz` with a `.sha256`, which `/update-gaia` verifies before following the release's bundled migration notes. A 1.6.1 `/update-gaia` cannot cross the move: choosing Proceed there stops with `FETCH_FAILED` and changes nothing else. **Action required:** on 1.x, choose Abort and migrate with the bundled 2.0.0 migration note (#2443)
- **Native pre-commit hook.** The pre-commit floor runs as a native git hook at `.githooks/pre-commit`, activated by `pnpm install` through the root `prepare` script; husky and is-ci are gone and lint-staged stays. The `pre-commit` and `commit-msg` hooks also refuse a SPEC, UAT or plan number, or a concrete `.notebook/` or `.gaia/local/` path, in staged prose, code comments and commit messages, and a Claude Code hook refuses the same in the title or body a `gh pr` or `gh issue` create or edit would publish, since those name documents only one machine has; write out what the reference means instead (#2894, #2895). A clone still pointing at `.husky/_` runs no pre-commit hook and reports nothing. **Action required:** in every other existing clone, run `pnpm install` or `git config core.hooksPath .githooks`, then confirm `git config --get core.hooksPath` prints `.githooks` (the migration handles the clone that runs it) (#2456)
- **Kebab-case frontend layout.** Files and folders under `frontend/app/components`, `pages` and `hooks` are kebab-case: a component is `components/<name>/index.tsx`, shadcn components sit flat in `components/ui/`, a page is `pages/<route path>/page.tsx`, and a hook is `use-<name>.ts`. `@gaia-react/lint` enforces it and `gaia scaffold` emits it; the migration's rename-before-merge step renames GAIA's files and your own so the merge keeps your edits (#2482)
- shadcn/ui is now GAIA's component layer. The vendored components live in `frontend/app/components/ui/` (Base UI primitives, `class-variance-authority` variants, `lucide-react` icons), forms compose them with Conform instead of GAIA's form wrappers, and every color comes from a shadcn role token in `frontend/app/styles/theme.css` instead of the old `primary-*` ramp, paired light and dark palette classes, and custom utilities. GAIA's own `Button`, `LinkButton`, `Toast`, the form wrappers and `react-icons` are gone, and `@gaia-react/lint` now fails raw palette classes, arbitrary values, restyled shadcn components and `FC` types. You get one registry to add components from (`pnpm shadcn add <name>`), and a theme you change by editing token values. **Action required:** migrate your own code with the steps below, then run the closing grep until it prints nothing (#2492)
  1. Run `/update-gaia`, then `pnpm add lucide-react @base-ui/react class-variance-authority tw-animate-css`, `pnpm add -D shadcn` and `pnpm remove autosize @types/autosize @tailwindcss/forms` (add `react-icons` to that remove only if none of your own code imports it; you may keep it as your own dependency, GAIA no longer uses it). `@tailwindcss/forms` is gone together with the global form block, so a raw native `<input>`, `<select>`, `<textarea>`, checkbox or radio loses its styling: move each to the `ui` control that replaces it.
  2. Replace every removed utility and `primary-*` step with a role token. `text-secondary` is now `text-muted-foreground` and `bg-secondary` is now `bg-muted`: the names `text-secondary` and `bg-secondary` now mean the shadcn `secondary` role token, so a leftover old-meaning use renders a different color and must be renamed, not just left alone. The `primary-*` steps map by what the element is, not by its shade, so treat the right-hand column as the usual target and check the result in light and dark.

     | Removed class | Use instead |
     | --- | --- |
     | `bg-body` | `bg-background` |
     | `bg-secondary` | `bg-muted` |
     | `text-body` | `text-foreground` |
     | `text-disabled` | `text-muted-foreground`, with `disabled:opacity-50` on the element |
     | `text-secondary` | `text-muted-foreground` |
     | `text-invalid` | `text-destructive` |
     | `text-placeholder` | `placeholder:text-muted-foreground` |
     | `border-strong` | `border-input` |
     | `border-normal` | `border-input` |
     | `border-medium` | `border-border` |
     | `border-light` | `border-border` |
     | `border-disabled` | `border-border` |
     | `border-invalid` | `border-destructive` |
     | `bg-invalid` | `bg-destructive` |
     | `input-invalid` | `aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20` (the `ui` controls already carry it) |
     | `hide-required` | removed with the required pill it hid; delete it |
     | `primary-50` | `primary-foreground` |
     | `primary-100` | `secondary` |
     | `primary-200` | `border` |
     | `primary-300` | `input` |
     | `primary-400` | `ring` |
     | `primary-500` | `muted-foreground` |
     | `primary-600` | `muted-foreground` |
     | `primary-700` | `primary` |
     | `primary-800` | `card` |
     | `primary-900` | `foreground` |
     | `primary-950` | `foreground` |

     Raw palette classes (`bg-gray-900`, `dark:text-white` and the rest) and arbitrary colors (`bg-[#fff]`) go the same way: pick the role token for what the element is.
  3. Replace each removed GAIA component with its shadcn replacement. The `ui` files ship with this release; a replacement marked "add with" does not, so run the command it names.

     | Removed component | Replacement |
     | --- | --- |
     | `Button` | `ui/button` |
     | `Spinner` | `ui/spinner` |
     | `LinkButton` | `<Button render={<Link />}>` (step 6) |
     | `Field` | `ui/field` (`Field`, `FieldGroup`, `FieldSet`) |
     | `FieldLabel` | `ui/field` `FieldLabel` |
     | `FieldDescription` | `ui/field` `FieldDescription` |
     | `FieldError` | `ui/field` `FieldError` |
     | `SpanOrLegend` | `ui/field` `FieldLegend` inside a `FieldSet` |
     | `FieldStatus` | `ui/field` `FieldDescription` and `FieldError` |
     | `InputText` | `ui/input` |
     | `InputEmail` | `ui/input` with `type="email"` |
     | `InputPassword` | `ui/input` with `type="password"` |
     | `TextArea` | `ui/textarea` |
     | `Select` | `ui/native-select` |
     | `Checkbox` | `ui/checkbox` |
     | `Checkboxes` | the composed checkbox group: one `ui/checkbox` per option inside a `FieldSet` |
     | `InputRadio` | `ui/radio-group` |
     | `RadioButtons` | `ui/radio-group` |
     | `BaseRadioButtons` | `ui/radio-group` |
     | `CheckboxRadioGroup` | `ui/radio-group` or the composed checkbox group |
     | `FieldRequiredText` | removed; mark a required field in its label text |
     | `FieldExtra` | removed; put the extra content in `FieldDescription` |
     | `FormActions` | removed; lay the buttons out with your own flex container |
     | `Chain` | `ui/input-group` for an input with attached addons; add with `pnpm shadcn add button-group` for a group of buttons |
     | `Toast` | `ui/toast` (step 7) |
     | `ToastNotification` | `ui/toast` (step 7) |
     | `YearMonthDay` | removed with no replacement |

     Delete `~/components/form/year-month-day` and the `date.day`, `date.month` and `date.year` i18n keys with it.
  4. GAIA's `Button` is replaced by `ui/button`, which takes shadcn's `variant` and `size` props. The exports `SIZES`, `VARIANTS`, `ICON_SIZES`, `ICON_ONLY_SIZES`, `ICON_POSITION`, the `Variant` and `IconUnion` types and the `isLoading` prop are gone, and no GAIA-to-shadcn name map is provided: `pnpm typecheck` reports each call site. For loading, compose `ui/spinner` inside a disabled button.
  5. Compose forms from `ui/field` parts and `ui` controls, wired with Conform's `getInputProps`, `getCollectionProps` and field ids, as shown in `frontend/.claude/skills/react-code/references/conform-forms.md`. A checkbox group posts one name repeated, once per checked option, so read it as an array in the schema.
  6. Replace `LinkButton` with `<Button nativeButton={false} render={<Link to="/path" role="link" />}>`, and the same for `NavLink` and for an external `<a href>`. Keep the explicit `role="link"`: Base UI gives a non-native `render` target `role="button"`, which would announce a link as a button. A disabled action is a disabled `Button`, never a disabled link.
  7. `notify` keeps its call signature (`notify.error`, `notify.info`, `notify.success` and `notify.warning`, each taking a remix-toast payload or a string, and returning the toast id); its import path moves from `~/components/toast` to `~/utils/notify`, and toasts now render through `ui/toast`, shadcn's toast built on Base UI. Render a bare `<Toaster />` from `~/components/ui/toast` where you rendered `<Toaster {...toasterProps} />` (`toasterProps` is removed), delete the `sonner` dependency with `pnpm remove sonner`, and drop the `stackTrace` i18n key: in development a payload's `stack` is logged to the console instead of shown in the toast.
  8. Replace `react-icons` with `lucide-react`: `import {Sun} from 'lucide-react'` in place of the react-icons import. A component that takes an icon as a prop types it `ComponentType<SVGProps<SVGSVGElement>>`, which both lucide and react-icons satisfy, so an app that keeps `react-icons` for its own icons still type-checks.
  9. The `autosize` package is gone: `ui/textarea` grows with the CSS `field-sizing` property, so delete any `autosize(...)` call.
  10. If your `wiki/concepts/Design System.md` says `established: true`, map your existing token values onto shadcn's role tokens in `frontend/app/styles/theme.css` (or `frontend/app/styles/tailwind.css` where `theme.css` is not used) and keep your wiki page; never overwrite either with GAIA's placeholder values.
  11. Bump `@gaia-react/lint` to 3.0.0 with `pnpm add -D @gaia-react/lint@3.0.0`; `/update-gaia` applies it unless you re-pinned the package. It adds the shadcn token rules, a lint exemption for the vendored `ui` files, and a ban on importing `FC` or `FunctionComponent` from `react`: convert `const X: FC<Props> = (...) => ...` to `const X = (...: Props) => ...`. `frontend/eslint.config.mjs` is yours and hook-guarded, so add `...lint.shadcn({ui: '~/components/ui'})` as the last entry of the config array yourself.
  12. Confirm nothing is left. From the repository root this must print nothing (the `ui` folder is excluded because shadcn's own files use `text-secondary` legitimately):

     ```bash
     git grep -nE "(bg|text|border|border-[trblxyse]|ring|ring-offset|outline|divide|placeholder|shadow|decoration|caret|accent|fill|stroke|from|via|to)-((slate|gray|zinc|neutral|stone|mauve|mist|olive|taupe|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-[0-9]|white|black)|-\[(#|rgb|hsl|oklch)|primary-[0-9]|react-icons|(^|[^A-Za-z-])(bg-body|bg-secondary|text-body|text-disabled|text-secondary|text-invalid|text-placeholder|border-strong|border-normal|border-medium|border-light|border-disabled|border-invalid|bg-invalid|input-invalid|hide-required)([^A-Za-z-]|$)|import[^;]*[{, ](FC|FunctionComponent)[,} ][^;]*from 'react'" -- frontend/app ':!frontend/app/components/ui'
     ```
- **React Compiler on by default** in the app build, dev server, Vitest and Storybook, configured in `frontend/react-compiler.config.ts`. It cuts update-phase renders, but code that evades the react-hooks lint rules can behave differently under it. **Action required:** run `pnpm lint` and your full suites; to roll back, set `isReactCompilerEnabled = false` in `frontend/react-compiler.config.ts`, and re-apply it if an update overwrites that file (`wiki/decisions/React Compiler.md`) (#2507)
- **Stories are the component test surface.** Storybook stories with play functions test components, and unit tests run in real Chromium instead of a DOM emulation: React Testing Library, `happy-dom`, `jsdom`, `test/rtl.tsx` and `test/a11y.ts` are gone (`addon-a11y` checks every story), hook tests use `vitest-browser-react`, and the component scaffold no longer accepts `--no-story`. **Action required:** run `pnpm install:browsers` once, then convert each component test to a story with a play function and each hook test to a `vitest-browser-react` test (async `renderHook`); to keep a test on RTL instead, take on `@testing-library/react` (plus jest-dom and user-event if used) as your own dependencies with your own wrapper and setup file (migration step 10a has the steps) (#2519)
- **Chromatic light and dark modes.** Chromatic snapshots every story once in a light mode and once in a dark mode, replacing the decorator that drew both themes side by side, so play functions run against a single render and each story costs two snapshots per build. **Action required:** replace any story's `chromatic: {viewports: [...]}` with mode viewports (`chromatic: {modes: {light: {viewport: 375}, dark: {viewport: 375}}}`), since Chromatic rejects `viewports` alongside modes, and replace `chromatic: {excludeDark: true}` with `chromatic: {modes: {dark: {disable: true}}}` (#2519)
- **One route data layer.** Services are isomorphic Ky and Zod modules whose responses Ky's `.json(schema)` validates; `/gaia-init` asks your backend's field casing and whether to use TanStack Query (off by default); `gaia scaffold route --data <server|client|query> --service <name> --shape <list|detail>` writes the route, page, `HydrateFallback` and an MSW-driven page story; and `@gaia-react/lint` bans imperative Query fetches in favor of `queryClient.query`. To add Query to an existing project, run `./.gaia/cli/gaia init configure-data-layer --query true` and the `next` commands it prints. **Action required:** migrate your own services and stories with the steps below (`wiki/concepts/API Service Pattern.md` and `wiki/concepts/Data Loading.md` have the patterns) (#2527)
  1. Request functions call `api(URL, {schema: envelope(<schema>)})` on a plain `create()` and return the unwrapped value, where `envelope` is exported from your domain layer's `api.ts` (`z.object({data: schema})`): drop the `create<ServerResponse>()` generic and every per-request `schema.parse(result.data)`, and set the casing on that `create()` as the next entry describes.
  2. Mutations send typed JSON through the `json` option instead of a `FormData` body, your MSW handlers read `request.json()` instead of `formData`, and route actions validate with `parseWithZod` from `@conform-to/zod/v4` and pass only `submission.value` to the request function.
  3. `attempt` maps Ky's `SchemaValidationError` to `{status: 500, statusText: 'Response failed schema validation'}`; update any caller that branched on the old error shape.
  4. Register the MSW loader in Storybook: in `frontend/.storybook/preview.ts` add `import {mswLoader} from 'msw-storybook-addon/csf3'` and `loaders: [mswLoader()]`, and in `frontend/.storybook/main.ts` add `'msw-storybook-addon'` to `addons` and `staticDirs: ['../public']`.
- **`create()` defaults to camelCase**, passing keys through unchanged; a snake_case backend opts into conversion with `create({isSnakeCaseEnabled: true})`, and the `useSnakeCase` option is gone. A 1.x layer that relied on the old snake_case default still compiles but stops converting keys, so its responses fail schema validation. **Action required:** on a snake_case backend, pass `{isSnakeCaseEnabled: true}` to your domain layer's `create()` (or run `./.gaia/cli/gaia init configure-data-layer --casing snake`), and delete any `useSnakeCase: false` (#2546)
- **Audit gate v2.** Code Audit Team members only report: the audit loop unit disposes every finding and files out-of-scope ones through the file-tech-debt recipe, and security-class findings stay local instead of becoming public issues. The `GAIA-Audit:` commit trailer is retired (the `GAIA-Audit` status is unchanged and still required), pull requests Claude opens are drafts that flip to ready when the audit posts its status, and `/health-audit` is removed. **Action required:** run Claude Code 2.1.287 or later (`claude update`); leftover `push_fixes` and `selfHealRefuse` keys are ignored, but the roster verifier now fails a dead or unowned glob, so remove any such glob from a customized `.gaia/audit-ci.yml` (#2596)
- **One severity scale and renamed commands.** Every finding GAIA grades is Critical, Major or Minor (labels `severity:major` and `severity:minor`), and no Minor finding withholds a code-audit marker. `/gaia-harden` is now `/gaia-codify` and `/gaia-audit` is now `/gaia-cleanse`, with no aliases; 1.x local state moves itself on first use and the recurrence tally restarts, so each declined candidate re-surfaces once. `gaia labels sync` renames `severity:important` and `severity:suggestion` in place, keeping every issue's label; only where it cannot write to your repository, run `gh label edit severity:important --name severity:major` and `gh label edit severity:suggestion --name severity:minor` (#2608)

### Added

- **`/gaia-fitness` statusline nudge.** The statusline now suggests `/gaia-fitness` when the fitness check grades a file your project owns, when an update blended your team's edits into harness files, or after enough of your team's harness commits since the last run. Set the commit count with `fitness_commit_threshold` in `.gaia/project.json` (default 15).
- **Code Audit Team.** The pre-merge audit is a team of specialist members (`code-audit-frontend` by default, plus `code-audit-github-workflows` for workflow YAML), each owning the files its globs claim in the `auditors:` roster in `.gaia/audit-ci.yml`. A diff dispatches only the members whose files it touches, every dispatched member must clear before the single required `GAIA-Audit` status posts, and the `gh pr merge` hook fails closed on anything unaudited; the roster verifier refuses a file no member owns and no `unowned:` entry declares, and a config without an `auditors:` block fails closed instead of falling back to a built-in list. See `wiki/concepts/Registering a Code Audit Team Member.md` (#626, #2308)
- **Content-keyed audit clearances.** Each member's clearance is keyed to a digest of the files it owns plus the gate machinery, so members run in parallel in any order, a commit outside a member's files (a CHANGELOG line, a wiki page) never re-dispatches it, and a re-dispatched member reviews only the change since its own last clearance or refusal plus its open findings. A member refuses files with uncommitted changes, a withheld clearance leaves complete findings and a carry-forward ledger, and a silent member gets one retry before its work is done inline, never read as "found nothing" (#800, #2552)
- **Self-running audit loop.** An `audit-loop-unit` sub-agent runs the pre-merge audit rounds a few at a time, with a fixer making each round's repairs and a deterministic verifier checking them, so your session holds only a short report per unit. It checks in when your context nears its limit or rounds stop converging (continue here, or hand off with a ready-to-paste prompt); typing `audit-grant <n>` or `audit-accept` as the whole prompt continues it, an accept runs one closing round with no fixer, and each pull request body carries an `## Audit rounds` record (#2391, #2432)
- **Light review.** A small change since a member's last full review can route to a cheaper Sonnet reviewer when the member opts in with `light_review: true` in `.gaia/audit-ci.yml` (with `light_line_cap` and `light_hard_full` to bound it), falling back to the full member whenever the route cannot be established; `code-audit-frontend` is opted in by default. A small, purely presentational frontend change also gets a quick blocking-or-clear review on its first audit dispatch instead of the full member, chosen by a deterministic classifier that routes anything unproven to the full audit, and `light_review: false` on the member turns off both light arms (#2539)
- **Audit records in the pull request.** The findings summary posted at merge carries every round's findings from every member, and accepted residuals go in one named `## Accepted residuals (recorded, not fixed)` section where each entry carries a dedup key, so the record is enumerable with one `gh` query (#2044, #1573)
- **Merge wait script.** `bash .gaia/scripts/pr-wait-merge.sh --pr <N>` waits on a queued merge and exits on a verdict (`MERGED`, `CONFLICTING`, `CHECK_FAILED`, `TIMEOUT`, `CLOSED`), stopping as soon as the base conflicts or a required check fails instead of waiting forever; a hook denies hand-rolled polling loops, and the PR Merge Workflow's "Conflict found mid-wait" section covers the repair (#2209, #2144)
- `/gaia-debt` drains the `tech-debt` backlog: with no argument it orders open issues by severity then age and offers the top candidate as a menu, and `/gaia-debt 12 34 56` drains named issues as one size-budgeted batch on one branch and pull request; `use worktree` or `use branch` picks isolation. Each drain claims its issues with `in-progress`, re-checks that each issue still matches your code (comments included) before cutting a branch, carries the fix through the PR Merge Workflow to merge, and stops with a reason on an issue it cannot drain or an argument it does not accept; an issue too large for a drain gets a `/gaia-spec` handoff and is parked under `debt:spec-pending` / `debt:spec-active` (#2520, #2553)
- The `file-tech-debt` skill is the one recipe for filing an out-of-scope finding as a `tech-debt` issue, used by the pre-merge audit and by hand: it builds a dedup key, skips an issue already open or declined (closed as not planned, or labeled `wontfix`), and checks the issue's labels and dedup key offline before creating it, refusing a malformed filing instead of leaving a drainer to trip over it later. Security findings are diverted rather than filed in public (#628, #2827)
- Tech-debt issues carry `difficulty:easy|medium|hard` and `footprint:narrow|wide|spec` labels, and a fourth grade, `severity:investigate`, marks a finding whose severity cannot be judged yet: the issue must name the open question, at most three may be open at once, and `/gaia-debt` lists them separately instead of draining them (#2173)
- `/gaia-residue` drains the audit residue recorded in merged pull-request bodies, triaging each entry into a filed tech-debt issue, a recorded dismissal or a deliberate keep, and never fixing anything itself. It takes no arguments, shows each residual's full description, sweeps every aged residual in batches of 25 (`GAIA_RESIDUE_CAP` sets the size) and lands as one pull request, so one run clears its statusline nudge (#2046, #2801)
- `bash .gaia/scripts/state-registry-lib.sh residue-sweep` lists the `.gaia/local` files retired features left behind, each with the reason it is dead, and `--apply` deletes exactly those; unrecognized paths are listed, never deleted, and `/update-gaia` offers the sweep after every update. **Action required:** after migrating to 2.0.0, run the sweep once; the migration prompt runs it with your approval. (#2610)
- `.gaia/local` no longer grows forever. Every state-registry row declares a `retention` class, checked by `bash .gaia/scripts/state-registry-lint.sh`. Merging a branch now removes that branch's audit, run-folder and PR-cache state as part of cleanup (`bash .gaia/scripts/state-cleanup.sh --branch <name>`). A SessionStart hook also launches a background reaper at most once a day, which prunes entries whose branch, worktree or SPEC is gone and ages out scratch files. It never touches state a live branch or tree still owns, and it never deletes unregistered paths (#2870)
- Every piece of committed work, with or without a skill, follows one lifecycle: a minted branch name, isolation per your isolation policy, a draft pull request, the audit, the merge when you ask for it, and cleanup back to a pulled `main`. Claude claims any GitHub issue it starts with an `in-progress` label and releases the claim automatically when the closing pull request merges, so two agents or people never start the same ticket (#2615)
- One workflow doctrine covers every kind of work: a short context-discipline rule is always loaded, and a hook injects the execution doctrine (roles, run folder and resume) only on a non-default branch or in a linked worktree. Model choice lives in one table on the Workflow Doctrine wiki page (#2389)
- Long sessions get a context checkpoint: at the red, fire or skull context band Claude saves its place and asks, with a recommendation, whether to continue or clear and resume (unattended sessions never ask). Plan executors and the `/gaia-plan` planner hand off to a fresh agent past the red band, and a plan halts for you when one unit yields too often.
- Commands that start new work on a branch or worktree (SPECs, plans, debt drains and the rest) offer to pull and restart while your checkout's GAIA version lags origin; resuming earlier work is never interrupted.
- `/gaia-spec` runs an automatic adversarial SPEC-audit before its final gate, verifying the draft's claims against the repo and folding each finding into the draft or a plan directive, and spots a draft being authored live in another session. `/gaia-plan` runs a three-lens decomposition audit on any non-trivial plan, resumes at the first incomplete phase behind a Resume / Restart / Abandon choice, and on a SPEC-derived plan checks that each Playwright UAT still asserts its contract before audit (#874, #2719)
- **Self-provisioning worktrees.** Claude Code creates and removes worktrees natively under `.claude/worktrees/`, and GAIA renames each branch to its canonical name and provisions the tree on entry, or on the next `/clear` or compaction when entry did not: shared `.gaia/local` state and the main checkout's `.env` files are linked in, typed routes and dependencies install in the background, and each checkout owns stable dev, Storybook and Playwright ports (the main checkout keeps 5173 and 6006, and a server refuses a taken port instead of drifting). A guard denies an edit that resolves into a different worktree than the session's, session start lists merged worktrees with their removal commands, and `bash .gaia/scripts/link-worktree.sh` repairs a tree's links by hand. A worktree created before 2.0.0 gets its port slot when the migration provisions it (#2701, #2471)
- Commit messages and PR titles follow Conventional Commits: a native `commit-msg` hook (commitlint) refuses a non-conforming message and names the page documenting the format, a guard lints a `gh pr create`/`gh pr edit` title (with its squash suffix) before the PR opens, and an advisory `PR Conventions` check runs on pull requests. Run `pnpm install` after updating so the hook can find commitlint (#2453, #2570).
- Two new guards: a `git checkout`/`git switch` that would move the main checkout's HEAD off another session's open-PR branch is denied, and writes to `.gaia/manifest.json` are denied so GAIA's workflows never catalog your own files as GAIA-shipped (the add-locale runbook no longer adds new-locale files to it) (#1807).
- New auto-loading rules shape what Claude writes: `no-abbreviations` (descriptive names in every language, alongside the `naming-conventions` skill), `code-comments` (a comment must say something the file does not; the merge-gate auditor applies the same standard), `working-doc-ids` (no SPEC, plan or audit ids, or your own issue and PR numbers, in code and prose), `guards-must-fail` (a guard and its tests must be shown failing before they are trusted), `ambient-context-resolution` (scripts take repo root, base and commit from input, not cwd or `HEAD`) and `file-placement` (where new hooks go and how they register) (#2455, #2393).
- The `subagent-dispatch` rule has a dispatched agent write its result to a JSON file in the session scratchpad and a no-op detector classify that file, so a reply that never arrives is re-dispatched once instead of being read as "found nothing" (#1409).
- `/gaia-react-perf` measures React render performance in a real browser and presents a ranked diagnosis of components whose memoization is defeated (#442, #443)
- When TanStack Query is installed, the `react-code` skill covers how to use it well, not only where it fits: complete query keys, derived state and `select`, dependent and paged queries, v5 error handling, and optimistic mutations with rollback. Upstream Query advice that conflicts with GAIA's loader rules is named as not applying (#2906)
- The template defines fetcher action paths once in `app/action-paths.ts`, so a route rename fails a test instead of 404ing, and ships `hydration.spec.ts` as the example for asserting no page-load errors across `console.error` and `pageerror` (#1712, #975)
- A monorepo playbook covers adding a package such as a backend beside `frontend/`, including the choice between one shared backend and one per worktree, which Claude asks you to make before running backend work in a worktree (#2636)
- Every model call is recorded to a local usage ledger, so GAIA reports what work cost: `/gaia-spec`, `/gaia-plan` and the maintenance commands end with a labelled cost table, each `gh pr merge` prints a `PR #<N> Cost` box (Execute, Audit, Total), and `bash .gaia/scripts/usage.sh initiative <ref>` totals an idea from first research to merge, including runs continued after `/clear`. Cost readouts show active time beside wall-clock time, so idle gaps no longer read as work time. Pricing uses the shipped rate table for current Claude models plus an optional `.gaia/local/telemetry/token-rates.override.json` for your own prices, and makes no network request. (#2378, #2800)
- A session-start janitor deletes local wiki landing branches whose work is already upstream and, when one is present, makes a single bounded `git fetch` and fast-forwards your base branch if it is checked out and clean, so a wiki landing never leaves base stale. `GAIA_WIKI_FETCH_TIMEOUT_SECONDS=0` turns the fetch off. (#468)
- New shipped wiki pages document GAIA's shell layer (`wiki/concepts/GAIA Scripts.md`, one row per script, kept in step with the tree by a checker), worktree isolation and the refusals a dispatched agent can meet (`wiki/concepts/Worktrees.md`), and machine-local working state (`wiki/concepts/Local Working State.md`). (#2175)
- The Quality Gate's dev smoke test runs through `bash .gaia/scripts/dev-smoke.sh`, which starts this checkout's dev server, checks a route for HTTP 200 and stops only the server it started, so a gate run can no longer kill another session's or worktree's dev server. (#2477)

### Changed

- Code Audit Team dispatches cost less: each audit agent carries only the tools it uses, rule specialists and refuters run as dedicated read-only agents on cheaper pinned models, and specialists and oracles run only when the changed files call for them. Measured round-1 frontend audits cost 40-52% less with no finding lost; see `wiki/concepts/Code Review Audit Agent.md`. Review dimensions and the gate attestation are unchanged. **Action required:** restart Claude Code after updating so the two new agent types load; an older session falls back to reviewing inline and says so in the report (#2916)
- Maintainer branch verification (`verify-harness.sh branch`) runs only the bats tests that carry the whole-tree mark, now set per test with `# bats test_tags=whole-tree` instead of per suite, cutting that step's wall clock and CPU by more than half. The mark guard checks marks per test and accepts a `gaia-lint-ignore whole-tree-mark-guard` waiver; `.claude/rules/bats-assertions.md` describes the marks (#2893)
- **Toolchain majors:** Node 22.22.0 or newer, pnpm 12, React Router 8 (with remix-utils 10 and remix-i18next 8) and Vitest 5, plus React 19.3; pnpm's supply-chain release-age window is now 3 days and strict. Vitest 5 turns on `clearMocks` by default and fails an un-awaited `.resolves` or `.rejects`, so your own tests may need small fixes. **Action required:** raise your local Node to 22.22.0 or newer and run `corepack enable pnpm` (or install pnpm 12 globally) before your next `pnpm install` (#2332, #444)
- The frontend runs msw 3: dev mocking for browser and server rendering goes through msw's Vite plugin, and a test fails when `frontend/public/mockServiceWorker.js` drifts from the installed msw (regenerate it with `pnpm -C frontend msw:init`). **Action required:** migrate your own handlers to msw 3's subpath imports with `npx codemod@latest run @mswjs/v3`, review its diff, and make any `afterAll` that calls `worker.stop()` await it (#2554, #2562)
- **`@gaia-react/lint` 3.0.0** (from 1.5.1) adds type-aware safety, ReDoS regex, Fast Refresh, Effect-misuse and React 19 idiom rules, requires a `-- reason` on every `eslint-disable`, makes `z.enum` an error (use `z.literal([...])`), requires `test.each` for runs of data-only sibling tests, flags bare `@conform-to/zod` imports (use `@conform-to/zod/v4`), drops the Testing Library rules, and lints `.playwright/` and `.storybook/`; React Router rules become an opt-in `...lint.reactRouter` group, and both pnpm workspaces resolve the same plugin versions. **Action required:** confirm `frontend/eslint.config.mjs` spreads `...lint.reactRouter` after `...lint.react` (a project without i18n deletes the `...lint.i18n,` line), delete any `eslint-disable` naming a `testing-library/` rule, then run `pnpm lint` and fix each finding or disable it with a `-- reason` (#2643, #2563)
- Components compose classes with `cn` from the `cn` package instead of tailwind-merge's `twMerge`/`twJoin`, with `cond && 'class'` as the one conditional form (enforced by the `cn-conditional` lint rule); `Button`, `LinkButton`, `InputText` and other form components now let a conflicting caller class win. **Action required:** run `pnpm add cn@0.4.0` and `pnpm remove tailwind-merge`, replace `twMerge(`/`twJoin(` with `cn(` in your own components, and rewrite object conditionals and empty-branch ternaries as `cond && 'class'` (#2441)
- Route discovery moves to React Router's first-party `@react-router/fs-routes`: route files become flat dot-delimited names (`_public+/_layout.tsx` becomes `_public.tsx`), route ids read the flat spelling (`routes/_session`), served URLs are unchanged, and `gaia scaffold route --group` takes `_public` or `_session`. **Action required:** the 2.0.0 migration renames your route files, including routes you wrote; then run `pnpm remove remix-flat-routes @react-router/remix-routes-option-adapter` (#2344)
- `FormError`'s `hide` prop is now `isHidden`; the old `hide` is no longer read, so `<FormError hide />` renders the error again. **Action required:** rename `hide` to `isHidden` on any `FormError` you render (#2487)
- `pnpm install` no longer provisions Playwright browsers, so frozen-lockfile installs never trigger an `apt-get`. **Action required:** run `pnpm install:browsers` once to provision Chromium locally (#456)
- `/gaia-init` and `/setup-gaia` install Chromium for the browser tests, so a new project or a teammate's fresh clone runs its first tests and commit without a manual browser install; the Chromium-only install never asks for `sudo`, and on Linux, when system libraries are missing, they name the `install-deps` command to run (#2878)
- `/gaia-init` no longer updates dependencies: a new project starts on the lockfile GAIA's tests ran against, so onboarding is faster and cannot fail on a bump you never asked for. The statusline shows `/update-deps` when packages are outdated or have security advisories; run it when you are ready. (#2884)
- The vendored playwright-cli moves to 0.1.22 (#2459)
- Onboarding is one `/setup-gaia` command, replacing `/setup-gaia-ci` and `/setup-cloned-gaia-project`: it detects a fresh clone, first adopter, partial run or provisioned project, runs only the phases still owed, and is safe for any teammate to re-run. It provisions the GitHub repository (personal account or an org, private by default), registers `GAIA-Audit` as a required check, offers a repo admin squash-only merges with PR-title commit subjects, and creates `frontend/.env` on a fresh clone (#478, #2468)
- Team settings live in `.gaia/project.json`: the git isolation policy (worktrees by default) and the OS sandbox recommendation (off by default) are recorded once, so `/gaia-init`, `/setup-gaia` and later workflows stop asking per run or per machine. A repo admin changes either with `/setup-gaia --reconfigure`, which asks both questions in the admin's language. (#2764, #2786, #2892)
- `/gaia-init` and `/setup-gaia` share one per-machine setup reference and load one-time phases only when owed, so re-runs load far less, and the React Doctor skill installs under `frontend/`, so it no longer lists in harness-only sessions. **Action required:** on each existing machine, from the project root, when `.claude/skills/react-doctor` exists, run `mkdir -p frontend/.claude/skills && mv .claude/skills/react-doctor frontend/.claude/skills/react-doctor` (the migration does this on the machine that runs it).
- `/update-gaia` verifies the release bundles' checksums, three-way merges each file, follows bundled migration notes, and asks one question per real conflict during the run before a single confirm; answers are kept in the committed `.gaia/update-decisions.json`, and generated blocks are regenerated after the merge. It claims an update with a draft pull request so two teammates never update at once, fast-forwards a lagging main checkout first, and loads a fraction of its former instructions. The `.gaia-merge/` conflict-patch folder is retired (#2420)
- `/gaia-init` detects your GitHub handle for CODEOWNERS, commits its own changes as one chore commit, works without a TTY, and refuses to run outside a GAIA-scaffolded project root. (#454, #2767)
- **Maintenance commands isolate their work.** `/gaia-wiki`, `/gaia-residue`, `/gaia-codify`, `/gaia-fitness`, `/gaia-cleanse`, `/update-deps` and `/update-gaia` put their work on a branch of their own, in a worktree cut from the default branch by default and whatever branch the main checkout holds, then commit, open a pull request and, on a main-branch run, merge it, waiting up to ten minutes for a queued merge. Cleanup keeps a tree with unresolved work and pulls `main` afterwards. `gaia wiki chain begin` and `finish` no longer accept `--branch-aware` (#2803, #2814)
- `/gaia-wiki` takes no arguments and always runs sync, consolidate and lint (lint now fixes what it finds, including broken wikilinks) as one commit and one PR titled `wiki: <date> <time> UTC`, then waits for the merge, pulls main and deletes its branch. The wiki sync filter reports its own health and is configurable via `gaia.wikiClassify` in `package.json`; `--force` and the `gaia wiki sync land` subcommand are gone, and the `run-audit` label does nothing. (#2580, #2696)
- `/gaia-fitness` grades with `gaia fitness check`, a fixed rule catalog over the files your project owns, plus an advisory judgment pass that never moves the grade; findings in GAIA-shipped files are listed under an upstream section for `/update-gaia` to fix. Healing asks per file with a diff, an optional `.claude/gaia-fitness.json` suppresses a finding by rule id and path (each with a reason), and the publish gate offers an "Open PR only" option. (#2628, #2585)
- `/gaia-cleanse` edits only files your project owns, asking per file, reports GAIA-shipped files for `/update-gaia` and shared agent memory without editing either, and no longer proposes edits for conflicts between instruction files (run `/doctor prompt-audit` for those). It covers memory and auto-loaded files and routes duplication inside the wiki to `/gaia-wiki`; a clean zero-action run applies itself. (#2592, #2628)
- **`/gaia-codify`** (formerly `/gaia-harden`) takes no arguments, explains each recurring finding in plain language and asks once to accept the whole plan. It counts a classified finding at any severity, surfaces recurring unclassified findings as their own signal, and weighs whether a prose rule would actually work before recommending one; its statusline nudge clears after a completed review and returns only on a named trigger, and a hook posts the findings block on every local `gh pr merge`. Declines recorded before 2.0.0 no longer apply. **Action required:** on each other machine, run `rm -f .gaia/local/harden/declines.json` (the migration handles the machine that runs it) (#2133, #2591)
- `/gaia-spec` now plans its SPEC in the same session and ends at the plan's KICKOFF prompt, replacing the copy-paste `/gaia-plan` handoff; `/gaia-plan auto` runs non-interactively. Both ask closed-set decisions (gates, clarify questions) as menus with a recommendation and show self-review and audit findings as one list you accept as recommended or revise in a single question, every gate prints what it asks you to approve (each UAT, a short final-gate brief of the SPEC and its audit naming the risks you accept, every finding) so you never need to open the draft, questions and gates use plain language with no ids from the research or audit, the interactive clarify loop allows up to 10 questions with a coverage scan, planning treats Opus and Fable as top-tier models, plan execution sub-agents default to Sonnet, and both load shorter instructions (#2750, #2815, #2877, #2888, #2889)
- **`/gaia-plan` execution.** A SPEC-derived plan renders the SPEC's browser-flow UATs into red Playwright specs before the first phase, blocks each owning phase's commit until its specs pass, and halts on a logical divergence so the SPEC can be reopened; SPEC close runs inside the orchestrator's own lifecycle around the merge. Worktree execution is offered without caveat (cut from `main` when you start off it), plan sub-agents cannot run git that rewrites the shared working tree, and a plan generated before an update keeps the steps it was generated with until you regenerate it (#2564, #1962)
- SPEC numbers allocate from immutable `spec/NNN` git tags on the remote instead of the tracked `.gaia/specs.json` ledger, so teammates no longer collide on a working-tree file; spec-less plans get a `PLAN-NNN` id and a SPEC's plan lives inside its SPEC folder. Spec and plan statuses are `draft`, `ready`, `merged` and `abandoned`, and merged or abandoned SPEC folders are kept for `GAIA_SPEC_RETENTION_DAYS` (default 30) before reaping. The 2.0.0 migration performs the one-time ledger cutover (#606, #609)
- Specs, plans and research move from `.gaia/local/specs`, `.gaia/local/plans` and `.gaia/local/research` into one gitignored `.notebook/` at the main checkout, shared by every worktree; research folders are named `.notebook/research/<date>-<topic>/`, and a reaper offers to delete closed, uncited research only on your confirmation. **Action required:** on each other machine that has those `.gaia/local/` folders, run `bash .gaia/scripts/notebook/move.sh run` once from the main checkout (the migration runs it on its own machine); until then the spec and plan commands stop and print that line (#2818)
- **One branch naming scheme.** Every branch GAIA creates is `<kind>/<rest>`, minted by one library: `debt/<n>-<slug>` for debt drains, a timestamped `deps/`, `update/`, `wiki/`, `cleanse/`, `codify/`, `fitness/` or `residue/` branch for maintenance commands, `<type>/spec-<nnn>-<slug>` or `<type>/plan-<nnn>-<slug>` for plans (the commit type of the change), and `<type>/[<issue>-]<slug>` for ad-hoc work. **Action required:** an unmerged plan branch still named `spec-<nnn>-<slug>` no longer reserves its SPEC number or reconciles on merge; rename it with `git branch -m spec-<nnn>-<slug> feat/spec-<nnn>-<slug>` (any commit type works) and push it, or mark that SPEC merged by hand once it lands (#2159, #2453)
- **Label registry.** GAIA's GitHub labels come from one registry, and `gaia labels sync` (run by `/setup-gaia` and `/update-gaia`) creates and renames labels to match it and reports color drift instead of overwriting your colors (unless you pass `--adopt`). `priority:high` and `priority:critical` fold into the severity labels, `needs-human-review` becomes `needs-human`, severity labels form one red ramp and `bug` moves to magenta. **Action required:** rename any `priority:high`, `priority:critical` or `needs-human-review` in your own workflows or templates to `severity:major`, `severity:critical` and `needs-human`; find them with `git grep -n -E 'priority:(high|critical)|needs-human-review'` (#1436, #2472)
- GAIA's tuning variables spell out their names: `GAIA_LEDGER_LOCK_TIMEOUT_SECS`, `_STALE_SECS` and `_POLL_SECS` end in `_SECONDS`, `GAIA_SPEC_REMOTE_TIMEOUT_SECONDS`, `GAIA_SPEC_ALLOCATION_MAXIMUM_RETRIES`, `GAIA_TITLE_MAXIMUM_LENGTH` and `GAIA_WIKI_FETCH_MINIMUM_INTERVAL_MINUTES` replace their abbreviated forms, and an old name is silently ignored. **Action required:** if you export any of the old names (shell profile, CI, or `.env`), rename it to the new one (#2433, #2434).
- A typical Bash call runs far fewer hook and `jq` processes (advisory hooks carry an `if` filter; deny guards never do), and the dotenv and secret guards consolidate into `block-sensitive-read.sh` (reads, including `Monitor` commands) and `block-secrets-write.sh` (writes, now also scanning `export`/`declare`/`local` declarations, so expect new denies, while `.env.example` is editable again). The migration removes the old `block-env-write.sh` and its registration (#2583)
- The `eslint.config.*` guard now asks you to confirm an edit instead of refusing outright, and explains why it asks, so a sanctioned config migration no longer has to be handed back to you (#1220).
- The Quality Gate rule names the workflows that commit without stopping (the PR merge fix round, `/gaia-debt`, plan phase commits), and its page says how to provide `frontend/.env` for Playwright in a worktree so e2e and the dev smoke test run (#2586, #2372).
- GAIA no longer sets Claude Code's experimental agent-teams flag, which made named subagent dispatches launch as teammates; opt in through your own user or local settings if you want it (#2389).
- Machine-local cache consolidates under `.gaia/local/cache/` (shared artifacts in `.gaia/local/cache/shared/`). **Action required:** in each other clone, delete the dead cache directory with `rm -rf .gaia/cache` (the migration handles the clone that runs it) (#567)
- **Catch-up merges no longer re-audit.** Audit markers are keyed to the branch's own change against the pull request's base, so merging the base in re-audits only when a merge commit carries its own edit or a base edit lands within three lines of the branch's changes. The merge gate and status poster refuse when GitHub cannot be reached or the base tip is not fetched: `git fetch origin` (and `gh auth status`) clears it, and after changing a pull request's base branch on GitHub, `git config --unset branch.<branch>.gaia-audit-base` resets the recorded base
- **Out-of-scope findings.** A non-security out-of-scope finding in a file the pull request already changes, or in the gate machinery, is recorded as a waive in the PR body instead of filed as tech-debt, but only when it clears two disqualifiers (for example, the change itself did not author it); everything else is filed with a root-cause class. Waives are scoped to the PR's real base and branch, so stacked PRs and later merges are unaffected; see `wiki/concepts/Audit Disposition and Debt Fix.md` (#1137, #1441)
- **Root-cause finding classes.** The audit's `finding_class` vocabulary now names recurring root causes (with reviewer criteria and a `holistic/unclassified` catch-all), and those classes feed `/gaia-codify`'s recurrence tally so a repeated class can become a rule (#1645, #1415)
- **Frontend auditor coverage.** `code-audit-frontend` now flags quadratic lookups split across a component or function boundary (recommending a `Map` or `Set` built once), names each lens in full when it dispatches, and ends every reply with a `Files reviewed` count so an early stop is caught rather than read as clean (#2681, #2246)
- Subagents run at your session's effort level: GAIA pins no effort on any agent or dispatch, so a low-effort session audits at low and a high one at high. `CLAUDE_CODE_EFFORT_LEVEL` remains the machine-wide override (#2980)
- Every session loads less GAIA context: always-loaded rules, references and skill instructions are shorter, `/gaia-debt`, `/gaia-plan`, `/gaia-spec`, `/update-deps` and `/update-gaia` list by name only, and user-only commands such as `/gaia-init`, `/setup-gaia` and `/gaia-fitness` set `disable-model-invocation` so Claude no longer starts them on its own. The shipped root `CLAUDE.md` is shorter and asks Claude to announce its next step, update only on real findings, and lead with the outcome. (#2680, #2588)
- Every GAIA skill and command asks a choice question as an `AskUserQuestion` menu with the recommended option first, and prints any prompt or command meant for pasting in a fenced code block; the new `.claude/rules/user-questions.md` applies the same standard to skills you write. (#2817, #2604)
- Shipped wiki pages, skills, rules and agents describe what GAIA ships and state your app's conventions as your project's own rules, instead of describing the GAIA repository or speaking as its maintainers; GAIA no longer ships its own pull request template. (#2395, #2372)
- `/update-deps` resolves security advisories first with the least invasive fix and replaces Dependabot updates (Dependabot alerts are read as data only), refreshes sub-dependencies within range after direct bumps and reverts if the gate fails, honors per-package ceilings committed as `gaia.updateDepsHold`, and on `main` commits as `chore(deps)`, opens the PR and merges it once checks are green (#2474, #2226)
- Claude's frontend guidance is sharper and about 4,500 tokens lighter: the react-code skill applies a platform-first ladder before adding a dependency and a React 19 idiom gate, shared value sets derive from one `as const` array, Zod work defers to Zod's official LLM docs, and TDD gains a deterministic RED gate plus a worthiness review of new tests (#2828, #408)
- A Storybook story that weakens its accessibility check now fails the tests unless it opts out with a stated reason, and the addon-a11y settings live in `frontend/.storybook/a11y.ts` (#2526)
- The shipped Tests and Chromatic workflows share one Node setup action, pin third-party actions to commit SHAs (checkout 7, setup-node 7, Chromatic 18.10.2) and cap each job's run time. Chromatic builds only on `main` and ready-for-review PRs, skipping drafts, and reuses the Storybook build, while Playwright runs one worker per core in CI. (#2842, #1300)
- The statusline fits its nudges to the terminal width (shrinking them to icons with a `+N` for hidden ones, refitting within 15 seconds of a resize), leads each with an emoji icon, and adds nudges for a teammate's in-progress GAIA update and concrete cleanse drift (new memories, days since review, an oversized `CLAUDE.md` or rule), refreshing the debt and residue counts as soon as those commands finish. Inside a linked worktree it shows only a blocking setup prompt, and main-checkout-only commands refuse there and name the main checkout. `/setup-gaia` asks developers with their own global statusline which one draws the left side (`/setup-gaia --reconfigure` asks again) and warns when a project override bypasses GAIA's. (#2794, #2331)
- The adoption ping now covers setup and update as well as init: `/gaia-init`, `/setup-gaia` and `/update-gaia` (and the 2.0.0 migration) each send one fire-and-forget POST to telemetry.gaiareact.com carrying a few low-cardinality categorical fields for that event plus a pseudonymous per-install `projectId`, the GAIA version and a coarse platform, never paths or free text. Set `GAIA_TELEMETRY_PING_DISABLE=1` to turn it off. (#585)
- Statusline nudge colors now follow one documented rule, so every nudge stays readable on light and dark terminal themes: `/gaia-residue` draws in your theme's own text color instead of white, `/gaia-debt` moves from dim blue to bright red, and the `/setup-gaia (Required)` segment matches the setup nudge's bright magenta (#2915).
- How Claude presents text for you to copy and paste (prompts, handoffs, commands) now lives in its own always-loaded rule, `.claude/rules/fenced-copy-paste-blocks.md`: one bare three-backtick block per pasteable item (an info string such as `text` stops the block rendering as code in Claude Code), nothing to paste left in prose, and four backticks only around a nested fence. Skills that print a handoff or re-run command now ask for the same bare fence (#2994)

### Removed

- GAIA CI workflows: Claude no longer runs on GitHub Actions. The CI scheduler, scheduled wiki sync, stale-branches, pnpm-audit and update-deps workflows, the Claude PR-audit workflow, their composite actions and the `gaia setup-ci`, `gaia ci-revert` and `gaia ci-stale-check` commands are gone; the local PR Merge Workflow is the only audit path and posts `GAIA-Audit` itself, and `/update-deps` runs locally. **Action required:** a project that enabled GAIA CI keeps spending Claude credit until you delete those workflows, actions, secrets and any `code-review-audit` required check; the 2.0.0 migration does this (steps 7b and 14). (#2403, #2227)
- GAIA no longer installs GitHub spec-kit: `/gaia-spec` runs one script-driven workflow everywhere, the `speckit-*` skills are gone, and spec-lifecycle files move from `.specify/` into `.gaia/` and `.claude/skills/gaia/`. The 2.0.0 migration removes spec-kit's leftovers (asking before touching a root `specs/` folder) and carries your edits to the moved files onto their new paths (#2540, #2550)
- `/gaia-handoff` and `/gaia-pickup` are removed: resume from the run folder's `STATE.md` or ask Claude for a continuation prompt, and `wiki/hot.md` is no longer injected at session start or shipped. The migration deletes the retired hooks and their registrations. **Action required:** on each other machine, run `rm -rf .gaia/local/handoff` from the repository root (the migration handles the machine that runs it); keep `wiki/hot.md` as an ordinary note or delete it with `rm wiki/hot.md` (#2590)
- A custom fitness category added to `wiki/decisions/Claude Integration Fitness.md` no longer runs: `/gaia-fitness` runs only the CLI rule catalog plus its fixed judgment pass. **Action required:** before `/update-gaia` replaces that page, copy your category out of it and keep the check as a rule under `.claude/rules/` or as a skill. (#2628)
- The wiki auto-commit squash hook and the lockfile, bare-test, vitest-globals-tsconfig, i18n-strings and story-exists hooks are removed: each duplicated a permission rule, a rule or a skill, or guarded something that cannot happen. The migration deletes them and their registrations, and a leftover `.claude/i18n-strings-checked` marker can be deleted (#2459, #2291)
- The always-loaded `dep-audit`, `knip` and `instruction-files` rules are removed, since their guidance already lives where it is used; `/update-gaia` offers to remove them.
- The GAIA-branded `Header`, `Footer`, `GaiaLogo` components and logo asset are no longer shipped: a fresh scaffold starts neutral and brand-free (zero-chroma primary scale, system fonts, a simplified `Layout`), and the 2.0.0 migration keeps your customized copies as your own files (#455, #458)
- The example privacy and terms pages (`/privacy`, `/terms`, the `_legal` layout route and their strings) and the `@tailwindcss/typography` plugin are no longer shipped; the plugin was the only path to a vulnerable `postcss-selector-parser`. **Action required:** keep the pages when the migration asks if you use them; otherwise run `pnpm -C frontend remove @tailwindcss/typography` (#2569)
- The unused `react-router-dom` dependency is dropped (React Router 8 no longer ships it; GAIA imports everything from `react-router`). **Action required:** run `pnpm remove react-router-dom` (#419)
- The opt-in adaptive mentorship layer and the `gaia mentorship enable|disable|status|purge` commands are removed, along with `/setup-gaia`'s privacy question; drop any script that calls them. Leftover mentorship files are inert.
- GAIA no longer enables the claude-obsidian plugin, so Python 3.11 is no longer a prerequisite and each session loads about 2,400 fewer tokens; the wiki stays an Obsidian vault. If you installed it only for GAIA, run `claude plugin uninstall claude-obsidian@agricidaniel-claude-obsidian --scope user`. (#2683)
- GAIA no longer installs or routes to the Serena MCP server: the `code-search` rule, `/gaia-serena-sync` and its statusline nudge are gone, and `uv` is no longer a prerequisite. An evaluation found Claude never called Serena, because its MCP tools stay deferred behind tool search, and the vendor's own remedy replaces Claude Code's system prompt, which GAIA cannot ship. **Action required:** on each machine run `claude mcp remove serena -s user`; in each clone run `git rm -q -r -f -- .serena` (`-f` because Serena may have rewritten `.serena/project.yml`), then `rm -rf .serena`, since `git rm` leaves Serena's ignored `cache/`, `project.local.yml` and `memories/` behind. The 2.0.0 migration does both on the machine that runs it. (#2954, #2874)
- GAIA no longer ships its own GitHub issue templates or `FUNDING.yml`; existing copies stay yours, and deleting `.github/ISSUE_TEMPLATE/` restores GitHub's defaults. (#2398, #2565)
- `/gaia-spec` no longer mirrors SPECs to GitHub issues (#484)
- Modes and leftovers nothing reached any more are gone: `gaia init wire-statusline` takes no `--mode` flag and always wires the project's `.claude/settings.json`, `/gaia-cleanse` drops its unused CI publish path, `wiki_promote_default` accepts only `yes`, `ask` or `no`, and the superseded React Testing Library and composeStory wiki pages fold into the Stories as Tests and Testing pages (#2926)
- The frontend template no longer ships starter code, config entries, dependencies and i18n keys that nothing uses (`FormError`, `MaxLength`, `environment.ts`, the empty service `urls.ts`, `useRequestInfo`, three date helpers, `@epic-web/invariant`, `lru-cache`, `@storybook/addon-docs`, the `lint-all` script, stale knip, coverage and ignore entries, and the seeded auth and dialog strings), so an adopter starts with no code that has no caller. `Document` now links the icon set and web manifest already in `frontend/public/`, the `formatMY` date helper is renamed `formatMonthYear`, and the `RequestInfo` field `userPrefs` is renamed `userPreferences`. The 2.0.0 migration removes each only when your code does not use it, and rewrites your uses of the two renamed names. (#2929, #2939)
- CI checks that guarded nothing and support for pre-2.0 branch names are gone: the port, usage-capture and worktree-provisioning hooks and the usage flusher no longer check `GITHUB_ACTIONS`, since on Actions they only write gitignored local state (the execution-doctrine hook keeps its check, because the forensics triage workflow runs Claude on Actions and must not receive the interactive doctrine), the audit key no longer reads `GAIA_AUDIT_KEY_BRANCH`, a `plan/` branch name is no longer accepted for a new pull request, and `chore/<task>-<timestamp>`, `wiki/sync-*` and `wiki-sync/*` branches are no longer recognized or reaped (an old one is simply left alone). A few internal helpers that only tests used are removed too. Nothing to do. (#2927)

### Fixed

- **Merge gate and audit:** the `gh pr merge` gate binds clearances to the pull request the command names and arms on quoted spellings, counts a moved file's old location, reviews stacked pull requests against their own base, treats a member refusal as blocking even for auto-merge, and audits root tooling files (`.npmrc`, `.nvmrc`, `Dockerfile`). Audit checks no longer pass vacuously on unusual path bytes, degrade instead of dying on a corrupt library (including on macOS bash 3.2), and resolve the review base through the remote-tracking ref. A clearance written from an unprovisioned worktree now refuses and names the provisioning step instead of landing where the merge gate never reads it, and the adopter copy of the merge workflow no longer names a CHANGELOG step it does not define (#1544, #1229, #2908, #2946)
- **Hook guards:** the recursive-remove guard allows scratch paths and denies quoted, chained and dotfile-glob variants it missed; the main-branch, `--no-verify`, merge-gate and PR-poll guards see `git` and `gh` behind env prefixes, global options, command substitutions, heredocs and the `Monitor` tool without tripping on text quoted in a pull request body; the RED-before-GREEN gate no longer blocks `test.each`, catch-up merges or verbatim GAIA tests and records failing runs reliably; hooks find their libraries from their own path and degrade instead of denying every call; and the pre-commit floor runs on test-only, e2e-only and non-ASCII commits (#2152, #2224)
- **`/gaia-spec`, `/gaia-plan` and `/gaia-codify`:** saving a SPEC is one allowlisted command, so it no longer stops on a permission prompt or gets denied in an unattended session (#2902), Ctrl-C releases the SPEC allocator lock, audit and clarify menus fit the four-option form, plan sub-agents check only files they own and can write the progress ledger under worktree isolation, a merged SPEC's outcome reaches the wiki again (consolidation picks the wiki sections from what shipped, where it used to promote nothing, and names each page in Title Case like the rest of the wiki; in-flight SPECs need no change) (#2932, #2937), plan executors are told the test command that records a new test's failing run, so a phase commit that adds tests is no longer refused by the RED-before-GREEN gate (#2948), plan executors are told to lint their own files from the package (`pnpm -C <package dir> exec eslint`), since the root `--config` spelling silently skipped the frontend's shadcn, i18next and file-naming rules and a phase halted at its lint gate (#2960), and `/gaia-codify` carries an approved change to a finished pull request, counts across the full 90-day window, and keeps your declined candidates when a background read fails (#1717, #2134). The SPEC lint now fails a UAT whose text cites a SPEC, UAT or plan id, so `/gaia-spec` rewords it instead of `/gaia-plan` halting at the UAT render and forcing a SPEC reopen (#2944)
- **Frontend template:** keyboard focus and choice fixes in `FormError` and the language switcher (which renders nothing with one language), no stray `0` from form components, `tryCatch` reports falsy throws, no hydration-mismatch logs, router stubs serve the theme and language actions, snapshot stories are deterministic, e2e recovers from the cold dev-server race, and `pnpm format` no longer rewrites ignored files or other worktrees. **Action required:** if your project removed i18n, delete the `LANGUAGES` import and `testIgnore` from `frontend/playwright.config.ts`, or Playwright cannot load its config (#2505, #2532)
- **Worktree ports across projects:** worktrees of different GAIA projects on one machine no longer share a port slot, so one project's dev server can't block another's UAT gate. Each slot is claimed in a machine-wide directory (`~/.local/state/gaia/ports/`, or under `XDG_STATE_HOME`), a tree that already collides moves to a free slot the next time it is entered, and the UAT gate's port error names the tree holding the port (#2949)
- **`/gaia-cleanse` no longer auto-applies a clean report whose duplication and conflict check never ran.** Stage 1 now lists every memory and rules file it compared against the wiki, and a 0-action report that leaves one out is held for your decision instead of finalizing as clean, so a skipped check can no longer hide a rule that contradicts the wiki (#2986).
- **Empty stories in the Storybook scan:** when a story renders nothing, the Playwright failure now names the story and tells you to add its id to `RENDERS_NOTHING_BY_DESIGN` in the spec if it is empty on purpose, so a component that hides itself no longer halts a plan's phase gate with no next step (#2962)
- **Playwright server start:** `pnpm pw` waits up to 45 seconds for the dev and Storybook servers to answer, up from 15, so a worktree's cold dev server on a busy machine no longer fails the run, or a plan's phase gate, before any spec starts (#2964)
- **Locale stories in the built Storybook:** a story set to a non-English locale now renders in that locale before its play function runs, so it no longer passes under Vitest and then fails the built-Storybook scan reading English (#2967)
- **Storybook default locale:** Storybook starts in your app's `DEFAULT_LOCALE` instead of always English, so a project that changes its default language sees its stories in that language (#2977)
- **Storybook specs without a build:** when Storybook hasn't been built, every Storybook spec in `pnpm pw` now fails at once telling you to run `pnpm build-storybook`, so the focus checks no longer sit through 30-second timeouts that look like a flaky machine (#2983)
- **Pre-commit test timeouts:** node tests no longer time out on a busy machine. The `no-imperative-query-fetch` config test checks the resolved config instead of linting, so its cost no longer grows with your app, and node tests get headroom for a file's cold first import, so a commit stops failing on tests it never touched (#2970, #2974)
- **UAT checks before the audit:** a plan's executors keep a UAT's Then-clause assertions in the test body rather than a shared Playwright helper, which the UAT gate and the fidelity judge cannot see. When one does land in a helper, the gate and the judge now say to move it back into the body, instead of telling you to implement the behavior or reopen the SPEC (#2972)
- **Secret-read guard:** TypeScript files whose names mention credentials, such as a rendered `login-rejects-invalid-credentials.spec.ts`, are readable again, through both the hook and the OS sandbox, so a sandboxed Playwright or Vitest run can open them; real credential files, Markdown notes and anything under `secrets/` stay denied, and the deny message now names a next step (#2972, #2976)
- **Code Audit Team:** a branch whose name contains "credential" no longer leaves its audit files unreadable to the members reviewing them, so a member can no longer clear a branch it could not read (#2976)
- **Adding a language:** declaring `LANGUAGES` as an `as const` tuple with a second language no longer fails `pnpm lint` in the Playwright config and the index page story, files the adopter never touched (#2935)
- **Tech-debt filing:** a finding that an existing issue already tracks now reports `matched <n>` instead of `filed <n>`, so a dedup hit is never counted or reported as a new issue (#2966)
- **`/update-deps` and `/update-gaia`:** `/update-deps` keeps security-floor overrides when `pnpm audit` or the registry fails, restores values when the gate fails, attributes only new advisories to the run, and cuts its branch before installing; `/update-gaia` shows its opt-in cleanup suggestions again and accurate remedies when regeneration fails, and the release bundle ships `.githooks/pre-commit` and the statusline script executable (#2760, #2613). Both commands, and `/gaia-wiki`, now end with the run's Cost line like every other maintenance command, and `/gaia-wiki`'s figure includes its merge wait (#2924)
- **Onboarding and CLI:** the project title is written once and survives quotes and dollar signs, `/setup-gaia` no longer reads as done while GitHub setup is unfinished and keeps an existing branch protection rule, the scaffold generators handle real inputs (route gains `--dry-run`), `gaia --help` lists every subcommand, piped output is no longer truncated, invalid arguments exit 2, and cleanup, catch-up merges and `/update-gaia` work when the default branch is not `main` (#2861, #2372)
- **Shipped CI and Dockerfile:** the Tests workflow runs the suites a move-only or e2e-only pull request needs, `chore(deps)` pull requests skip only when every changed file is a dependency manifest, Chromatic TurboSnap traces dependency changes through the pnpm lockfile, the Dockerfile builds again, starts without registry access and pins `node:22.23-alpine`, and the shared Node setup action no longer loses five minutes to a hung registry fetch while installing pnpm, a stall that pushed long jobs past their timeout (#2531, #2333, #2953)
- **Statusline, wiki and health commands:** the statusline drops stale update and dependency counts, counts both Dependabot alerts and `pnpm audit` advisories, and fits the row Claude Code draws; wiki sync handles non-ASCII and renamed pages and reports git failures, consolidate rewrites links to archived pages, and lint works on a fresh clone; `/gaia-fitness` and `/gaia-cleanse` stop reporting false findings (#2849, #2574)
- **`/update-deps` nudge after merge:** the statusline no longer keeps showing `/update-deps (N outdated)` for hours after an update merged. Another command refreshing the statusline cache before the merge could restore the old count; `/update-deps` now clears it again once the merge lands (#2989)
- **Rules that loaded on unrelated edits:** the wiki style rule no longer loads when you edit app code, hooks or spec scripts, the ports rule no longer loads on every app edit, and the design baseline rule no longer loads on route-only edits, saving up to about 3,700 tokens of context per edit. The no-history-in-comments guidance still reaches code through the code comments rule, and the never-stop-another-tree's-server warning still prints whenever a dev or Storybook port is taken (#2991)
- **shadcn registry out of the box:** every component in the shadcn registry now lints clean as `pnpm shadcn add` writes it, so adding one such as `pagination` no longer fails `pnpm lint` on a file you are told never to edit. `@gaia-react/lint` 3.0.2 builds its vendored-file exemptions from the whole registry. The `chart` component now installs: `trustPolicy: no-downgrade` stays on, with a single exact-version exception for the `reselect` release its `recharts` pins. The components that ship a code highlighter now import it from the folder they write it to (#2951, #2957, #2958)
- **Dev server browser launch:** `pnpm dev` opens a browser tab only in an interactive terminal, so a Claude-driven, CI or worktree dev server no longer pops a window (#2399)
- **Removing i18n:** the remove-i18n runbook also strips the i18n tooling config it used to leave behind, so a project without i18n lints and builds clean (#2732)

### Security

- Three ways the guard layer silently stopped guarding are closed: `Write(<glob>)` deny rules never fired (audit sentinels could be forged) and are now `Edit(<glob>)` rules, blocking hooks refuse when `jq` is missing instead of allowing the call, and every hook registration resolves from the repository root so a `cd` no longer leaves them unfindable. If you register hooks of your own, check them with `bash .gaia/scripts/check-hook-command-rooting.sh .` (#783, #1740).
- A read-side hook denies reading dotenv files (including `.env.<env>` variants), keys, certificates and credentials, plus `env`/`printenv` dumps and Bash searches that name them in filter flags such as `rg -g '*.key'`, while `.env.example` stays readable; the sandbox's `denyRead` covers the same classes for subprocesses, and `/gaia-forensics` redacts more secret and identity shapes before filing (#1767, #1765)
- The client environment is built from an allowlist, so server variables such as `SESSION_SECRET` stay server-only: the Storybook preview inlines no environment values, Vitest no longer reads your `.env`, inline env JSON in the document is escaped, and the Chromatic workflow runs with no `GITHUB_TOKEN` scope. **Action required:** if a story of yours reads `window.process.env`, pass the value in as a story arg instead, and if a test of yours depends on a value from your own `.env`, set it in your shell or give it a default in `frontend/test/setup.ts` (#2529, #1210)
- The theme and language actions validate their redirect target as a same-site URL and redirect only to the resolved path, closing an open-redirect gap; `resolveLocalRedirect` and `LocalRedirectSchema` replace `isLocalRedirect`, and the 2.0.0 migration applies the switch
- Toolchain and shipped CLI bundles are re-resolved onto patched releases (js-yaml, babel core, esbuild, tsx, vite and others), security-floor overrides live in `pnpm-workspace.yaml`, and `pnpm audit` is clean (#2110, #1648)
- The codify tally counts only findings blocks posted by accounts with write access to the repository (owner, member or collaborator), so a comment from anyone else cannot change the recurring-finding counts or the decline ledger. The tally schema version moves to 3, which shows one "tally changed" nudge (#2995)

## [1.6.1] - 2026-06-12

### Added

- land the full chain on one branch and one PR (#379)
- prune prior-run artifacts at the start of a confirmed update (#376)
- accept a verbatim audit-workflow re-render as a no-marker bypass (#375)
- auto-render stale audit workflow on update (#371, #372) (#374)

### Changed

- shrink dep-audit.md to a wiki pointer (#380)
- pnpm-workspace.yaml must be copied into Docker pnpm stages (#373)

### Fixed

- exclude .claude-pr/ from the stamp dirty check (#370)

## [1.6.0] - 2026-06-11

### Added

- CI audit progress breadcrumbs: the `code-review-audit` workflow prints a curated per-phase timeline (scope resolved, oracles done, holistic review done, adversarial verify done, report stamped) into the GitHub Actions step summary, giving the otherwise-silent CI run a public-safe signal of progress with no raw tool output or secrets, and a breadcrumb write never blocks the audit (#350)
- `/gaia-harden`, a human-gated Policy-Memory Loop: when `code-review-audit` flags the same finding class across three or more distinct PRs within a rolling 90-day window, the statusline nudges, and running `/gaia-harden` judges the lightest durable enforcement form (a path-scoped rule, a deterministic check, or a skill) and drafts it for approval, committing nothing without your say-so (#321)
- `/update-deps` interactive preview and snooze: updates are grouped (major, minor, patch, non-semver) and you can defer any group before applying; snoozes persist and resurface after 14 days or when a newer version ships, and `CI=true` or `--scope` runs skip the preview (#347)
- a React Router local-docs rule: a path-scoped rule points framework-mode work at the version-exact docs React Router ships as markdown under `node_modules/react-router/docs`, falling back to the online docs only when the local copy is absent

### Changed

- pnpm upgraded from 10.33.0 to 11.5.2, with `packageManager` pinned to `pnpm@11.5.2`; workspace settings (`overrides`, `allowBuilds`, `publicHoistPattern`, `savePrefix`, `strictPeerDependencies`) move from `package.json` and `.npmrc` to `pnpm-workspace.yaml` (#333)
- `/update-gaia` merges `pnpm-workspace.yaml` field by field, keeping adopter-only overrides and build approvals while applying the release delta (#335)
- `/gaia-audit` researches first and presents a single Apply, Discuss, or Decline gate before changing any file, adding a CONFLICT finding class, a resumable report lifecycle with a 72-hour re-apply grace window, post-apply verification, an optional scope-hint argument, and a statusline nudge from drift/budget/draft signals; the apply stage runs on Sonnet (#326)
- `/gaia-fitness` renders its report as a deterministic width-aware ASCII card (#320)
- TypeScript 7 readiness: `tsconfig.json` adopts `stableTypeOrdering` and `noUncheckedSideEffectImports` while still on TypeScript 6 (#331)
- `code-review-audit` runs its holistic review on Opus with a coverage-first pass that surfaces every candidate (tagged with severity and confidence) before adversarial verification filters them (#353, #354)
- `/gaia-plan` and `/gaia-spec` dispatch every subagent from a single depth-1 orchestrator, with per-bucket Haiku and Sonnet model pinning (#363)
- the `/gaia-wiki` maintenance chain moves to the same single depth-1 orchestrator topology (#364)
- skeleton-loaders: static translatable text (labels, headings, button text) must use `t()` or `<Trans>`, and skeleton containers require `role="status" aria-busy="true"` (#360)
- statusline: `/update-gaia` now precedes `/update-deps`, and the harden nudge reads `Run /gaia-harden (N recurring patterns)` (#328)
- dependency refresh: react and react-dom 19.2.7, storybook 10.4.2, axe-core 4.12.0, chromatic 17.2.0, happy-dom 20.10.1, i18next 26.3.1; the `brace-expansion` and `ws` CVE overrides are dropped (resolved natively) and the `qs` override is retained (#332, #348)
- the `react-router` group is bumped to 7.17.0 (`react-router`, `react-router-dom`, and the `@react-router/*` packages), which ships its official docs as markdown under `node_modules/react-router/docs` for local lookup
- `/update-deps` and `/update-gaia` repoint dependency-override management to `pnpm-workspace.yaml` for pnpm 11 (#334)
- react-doctor reads a single `doctor.config.jsonc`; the legacy `react-doctor.config.json` is removed from the template (#327)
- the project `CLAUDE.md` response-style guidance is scoped to conversation, with a coverage carve-out for audits, reviews, plans, and specs, and a coaching register (#358)
- `coding-guidelines` clarifies that the impossible-scenario test ban does not cover real failure modes such as non-zero exits, loop non-convergence, and network errors (#359)
- CLI internals cleanup: several dead or unwired maintainer subcommands are retired, a subcommand reachability guard rejects calls to commands the binary no longer exposes, and the CI audit gains a `--verbose` log mode (#336, #337, #338, #339, #340, #341)
- `/gaia-release` (maintainer-only) wires the `release-notes` skill into the website lockstep, overwrites the GitHub release body with the generated adopter-facing notes, and adds a docs-site version lockstep step (#318, #319)
- load-bearing wiki fetches in the instruction files are marked imperative (must-read) and deep-dive pages are tagged, tightening how the assistant pulls wiki context during a task (#361)

### Fixed

- the bare-test guard no longer false-positives on quoted prose: detection anchors to command position, so a `pnpm test` phrase inside a commit message or a `--body` string is no longer blocked, and the sibling RED-observation gate is anchored the same way (#345)
- type-only tests no longer hit an unsatisfiable TDD RED-verification gate: the signal helper classifies each test runtime vs type-only and the commit check exempts type-only tests, delegating their correctness to the `tsc` quality gate (#344)
- `/update-gaia` defers the VERSION-file bump until after the run summary prints, so an interrupted run resumes at the baseline version instead of dead-ending as already up to date (#362)
- `/update-deps` and `/update-gaia` bound their retry and heal loops to one remediation pass plus a single gate re-run, then revert and log, instead of iterating open-ended (#355)
- the autonomous `/gaia-audit` and `/gaia-fitness` re-run paths require a fresh subagent on every stateful re-run, so a resumed cycle can't silently reuse a stale in-context report (#356)
- `/update-deps` override audit adds a security-floor pin test so a CVE-pinned override is never dropped as obsolete while a live advisory remains (#348)
- maintainer-only source paths no longer leak into adopter-facing surfaces and a stale manifest is regenerated; the `/update-deps` skill drops a maintainer-only path reference absent on adopter clones (#367)
- Playwright retries once on local runs to absorb the cold optimize-cache flake (#349)
- the `.specify` GAIA commands dispatch tools and skills explicitly instead of emitting prose narration (#357)
- the CLI test suite triggers on `code-review-audit.yml` edits, closing a gap where workflow changes shipped without exercising the CLI tests (#317)

## [1.5.0] - 2026-06-05

### Added

- dependency-CVE deterministic-oracle advisory (#299)
- mechanical TDD RED-verification (#297)
- decouple from upstream claude-obsidian, add native checks (#289)
- add maintainer-only release-notes skill (#283)

### Changed

- replace the `/gaia <subcommand>` router with discrete `/gaia-*` slash commands (`/gaia-plan`, `/gaia-spec`, `/gaia-audit`, `/gaia-fitness`, `/gaia-forensics`, `/gaia-wiki`, `/gaia-handoff`, `/gaia-pickup`) so every workflow surfaces in autocomplete; the old space-form `/gaia <sub>` is removed, and sub-arguments are unchanged (#277)
- add /gaia-fitness to commands table (#281)

### Fixed

- repair PR-merge audit gate (specialist dispatch + clean no-change marker) (#313)
- exclude self-referential wiki-sync commits from drift count (#311)
- strip git-quoted paths in inspectWorkingTree (#308)
- run sync on Sonnet and add fabrication guard (#307)
- stop runtime-deps flagging prose path tokens as leaks (#304)
- repair flaky wiki-sync release-gate smoke harness (#303)
- repair two pre-existing release-gate failures (#302)
- close distribution-boundary leak failing the smoke suite (#301)
- guard CI-defer source so missing lib doesn't kill wiki hooks (#298)
- anchor git guards to command position (#296)
- exempt non-blocking residuals from the clean-A+ gate (#293)
- alias-proof bare `gaia` CLI calls to repo-relative `.gaia/cli/gaia` (#291)
- regenerate report fresh each run; never reuse a stale #11 (#286)
- out-of-scope bypass for docs/metadata-only PRs (#276) (#280)
- `/update-gaia` merges `package.json` field-aware instead of as one opaque blob: it never touches adopter identity fields, applies only the real upstream dependency/script delta, and never re-adds a dependency the adopter removed, so a version-only release stops emitting a full-file conflict patch (#275) (#279)
- inline literal sibling-repo paths in gaia-release pushes
- add repo-scope.sh to audit-ci-tests paths filter
- the repo-scope guard strips surrounding quotes from `git -C "<path>"` and `cd '<path>'` captures, so a quoted sibling-repo push is recognized as foreign and allowed instead of denied as a home-repo push to main

## [1.4.0] - 2026-06-02

### Changed

- promote machine-local feedback memories into shared wiki (#270)

### Fixed

- derive wiki playbook dates from the shell clock, not the model (#269)
- /update-gaia: scope the three-way merge to the real release delta; respect adopter-deleted files instead of re-injecting them, and skip owned files the release left unchanged instead of emitting spurious conflict patches (#268)

## [1.3.5] - 2026-06-02

### Added

- install code-review-audit on demand; honor both Claude tokens; key merge decision on workflow presence (#262)
- honor pnpm 11 minimumReleaseAge in version selection (#260)
- stamp GAIA-Audit status on out-of-scope skips (#257)
- gate expensive checks on the since-last-green delta (#254)
- enforce Content-Security-Policy for scripts (#253)
- incremental code-review-audit scope (#252)
- pnpm supply-chain hardening: root `pnpm-workspace.yaml` with `minimumReleaseAge` (7-day quarantine) and `trustPolicy: no-downgrade` (#251)

### Changed

- mark CI code-review-audit as opt-in (#263)
- clarify the gate owns formatting; make PR merge marker-first (#261)
- print kickoff prompt instead of copying to clipboard (#259)
- document useDebounce return semantics (#255)
- enable React Router v8 future flags for early v8 readiness: `v8_passThroughRequests`, `v8_splitRouteModules`, `v8_trailingSlashAwareDataRequests`, `v8_viteEnvironmentApi` (#251)
  - **Migration (`v8_passThroughRequests`):** loaders/actions now receive the raw `request`, so `request.url` keeps the `.data` suffix and `?index`/`?_routes` params on data requests. If you customized `app/root.tsx` (or any loader) and call `new URL(request.url)` for normalized routing, switch to the new normalized `url` arg (a `URL` instance), e.g. `({request, url}) => url.pathname`. `/update-gaia` delivers the updated `app/root.tsx` as a conflict patch for customized files, so apply this by hand when resolving it.

### Fixed

- detect orphaned wiki drift in preflight via suggested_base (#258)
- recover the un-evaluated window on sync re-anchor (#256)
- gaia-release updates softwareVersion
- `Form/Chain` composes `className` with `twMerge` instead of `twJoin`, so a consumer's utilities override the component's defaults (#251)

## [1.3.4] - 2026-05-26

### Added

- bypass audit-marker requirement on chore(deps) PRs (#246)
- skip required workflows on chore(deps) PRs (#245)

### Changed

- reframe dispatched-check rollup ADR around polling architecture

### Fixed

- seed missing files; round-trip GH issues; drop UAT leaks (#247)
- poll dispatched runs and stamp jobs into PR rollup (#243)
- stamp dispatched check runs into PR rollup (#240)
- re-trigger required checks on self-heal HEAD (#238)

## [1.3.3] - 2026-05-22

### Added

- `gaia setup-ci check-drift`: primitive that byte-compares rendered `.github/workflows/gaia-ci-*.yml` against a fresh in-memory render. Reports `{drifted, missing, in_sync}` per tool.
- `/setup-gaia-ci` Step 2 calls `check-drift` on configured repos. On drift, prompts for re-render / skip / full reconfigure instead of unconditionally short-circuiting.
- `/setup-gaia-ci` Step 11.5: lightweight drift-fix branch + commit + PR path. Regenerates only the workflow YAML; tool selection and bot token untouched.

## [1.3.2] - 2026-05-22

### Fixed

- dedupe audit issues, scope pre-run-skip per-tool, set git identity (#233)

## [1.3.1] - 2026-05-22

### Fixed

- `create-worktree.sh`: WorktreeCreate hook that creates the worktree and returns its path (#231)
- `update-gaia`: remove phantom `gaia update merge` CLI call from Step 7 (#231)
- `update-gaia`: Step 9 cache-bust writes the new version instead of preserving stale fields (#231)
- `update-gaia`: open a PR at the end of the run instead of stranding the branch (#231)

## [1.3.0] - 2026-05-22

### Added

- allow `/gaia plan` and `/gaia spec` to run concurrently in separate sessions without clashing; collision-proof atomic writes prevent racing writers from corrupting committed state (#198, #207)
- add axe-core accessibility testing for Vitest and Playwright (#205)

### Changed

- derive controlled counter from value, document latest-ref pattern (#217)
- thread auth and language per request (#194)
- single-pass deepRemoveNil
- note why the NonceContext default is an empty string
- record the unsafe-inline and no-report-uri trade-offs
- rename `/setup-gaia` command to `/setup-cloned-gaia-project`

### Fixed

- add 15_000ms timeout to per_domain_page_counts test (#225)
- macOS sed portability + +types ignore bucket (#221)
- accept GitHub commit status as merge gate signal (#219)
- skip setLocalLength in controlled mode, move latest-ref comment (#218)
- deferred code-review-audit findings from PRs #190-214 (#216)
- a11y/perf follow-ups for Checkboxes, FieldDescription, TextArea (#213)
- a11y for field descriptions, drop nested live region (#212)
- audit small fixes: amended_rate, rollback msg, parseKeyPath, generator dup, a11y (#210)
- revert-ledger lock per-PR scope + stale recovery (#209)
- robust flag derivation in sync-land (#208)
- atomic-write deferred writers + crypto temp-path (#207)
- cover .playwright/ entry points (#206)
- correctness gaps in init/schemas/storage (#204)
- correctness gaps in release/scaffold (#203)
- correctness gaps in automation/telemetry (#202)
- correctness gaps in intent-clarity-gap (#201)
- correctness gaps in setup-ci/ci/setup (#200)
- correctness gaps in wiki/update/update-deps (#199)
- atomic file writes with fsync (#198)
- close correctness gaps in utils and api helpers (#197)
- close XSS vector and error-handling gaps (#196)
- correct edge cases across form components (#195)
- preserve falsy success values
- reject non-local redirect targets
- add GAIA-Audit commit-status fallback to the skip gate
- write GAIA-Audit commit status instead of pushing an empty marker commit
- replace client-hints reload with pre-paint inline script
- implement per-request nonce Content-Security-Policy

## [1.2.3] - 2026-05-20

### Added

- repo-scope main/PR-merge guards + create-gaia release lockstep

### Fixed

- update workflow template snapshots for id-token permission addition
- add json-strip transform to stop maintainer-only package.json keys reaching adopters
- harden block-main against multiple git -C flags
- close multi--C ambiguity in repo-scope; handle --repo= form

## [1.2.2] - 2026-05-19

### Fixed

- drop default id-token: write from pnpm-audit workflow

## [1.2.1] - 2026-05-19

### Added

- RUNNING sentinel + concurrent orchestrator detection (#180)

### Changed

- drop second inline PR ref in Release Workflow prose
- drop inline PR ref in Release Workflow prose
- correct the release PR merge step

### Fixed

- health-audit distribution-boundary remediation (#182)
- Linux WSL compatibility for husky hook and CI workflow permissions (#181)
- atomic mkdir prevents TOCTOU race on concurrent plan creation (#179)

## [1.2.0] - 2026-05-12

### Added

- `/gaia fitness`: Claude-integration health check + auto-heal (#169, #171)
- ai shimmer animation on `gaia-logo.svg` (#168)

### Fixed

- `release preflight` tolerates wiki-sync squash-artifact drift (this release)

## [1.1.1] - 2026-05-11

### Fixed

- gaia release reference to maintainer
- bug fixes from live init run (#165)

## [1.1.0] - 2026-05-10

### Added

- robust a11y tooling stack (#156)
- close slice-4 forward-refs (wiki + update-deps) (#153)
- add Phase A configure-automation step (#148)
- GAIA CI slice 4: /setup-gaia-ci slash command (Phase B) (#147)
- GAIA CI slice 3: workflow YAML generation (#146)
- GAIA CI slice 2: auto-merge + auto-revert workflow shape (#145)
- GAIA CI slice 1: smart-cron + per-tool state files (#144)
- add probe-after verification pass to Step 8 (#139)
- surface GAIA-Audit trailer invalidation count in summary (#140)
- rename /wiki-{sync,consolidate,lint} → /gaia wiki <sub> to resolve plugin collision (#121)
- /gaia spec auto + branch-default plan isolation
- code-review-audit CI gate + GAIA-Audit trailer skip mechanism (#117)
- autonomous triage workflow for gaia-forensics issues (#104)
- /gaia forensics: end-user bug-report bridge (#105)
- bundle-time scrub + runtime-deps primitives (#98)
- telemetry v1: three-stream architecture (#91)
- tree READMEs + inventory audit for the shared-state symlinks
- rule file + port smoke-uat-write + relocate serena
- wire before_implement hook + speckit.gaia.uat-write into manifest
- wiki-sync handoff + revised-contracts §2 amendment
- implement before_implement UAT renderer + templates + slash command
- wiki-promote routing + page render + cross-links
- wiki-promote PR-merge detection + spec-close drain
- add UAT divergence policy rule stub
- manifest entry + wiki-promote command skeleton
- install spec-kit + GAIA extension + GAIA preset during scaffold
- real spec-kit extension + preset for GAIA
- salvage GAIA wrapper scaffold + utilities from PR #84
- Serena MCP server registered by `/gaia-init` for LSP-backed code intelligence (pinned, requires `uv`); a `code-search` rule routes Claude to Serena for TS/TSX symbol queries (#82)
- dead-code detection via [knip](https://knip.dev): run `pnpm knip` after refactors or before release-candidate PRs, with a template-aware config that marks GAIA's library surface as entries so intentional exports aren't flagged (#80)

### Changed

- **BREAKING:** `/wiki-sync`, `/wiki-consolidate`, `/wiki-lint` slash commands are removed. Use `/gaia wiki sync`, `/gaia wiki consolidate`, `/gaia wiki lint` instead, or `/gaia wiki` for the full chain. Motivation: `/wiki-lint` collided with the `claude-obsidian` plugin's skill of the same name. Moving everything under the `/gaia` router namespace eliminates the collision and groups wiki maintenance with the other GAIA workflows. Hooks (`wiki-drift-check`, `wiki-commit-nudge`, `wiki-session-stop`) and statusline now point at the new names. Smoke tests under `.gaia/tests/smoke/wiki-sync/` updated. The playbooks moved from `.claude/commands/wiki-{sync,consolidate,lint}.md` to `.claude/skills/gaia/references/wiki/{sync,consolidate,lint}.md`.
- `/gaia audit` no longer covers intra-wiki duplication or broken-wikilink checks; those overlapped with `/gaia wiki consolidate` and `/gaia wiki lint`. Run `/gaia wiki` separately for wiki-internal audits.
- codify post-merge state verification + --auto vs --admin (#155)
- tighten adopter README template (#138)
- pre-launch gap fixes (CI opt-in, rollback, WSL stance) (#137)
- add manual smoke procedure for before_implement hook
- scrub fictional on_save references from smoke.md

### Fixed

- exclude CLI-Binary-Split ADR; add automation.json sentinel (#163)
- replace rm cache-bust with Write tool to avoid hook conflict (#162)
- bust cache immediately on confirmed updates (#161)
- defer stamp push until after marker write (#158)
- split release CLI into maintainer-only binary (#133)
- push GAIA-Audit empty commit to upstream so CI's audit skips (#130)
- skip audit on workflow self-mod, reword abort message (#125)
- surface code-review-audit aborts as red checks (#123)
- CI source-changes gate, knip binaries, instruction-file paths (#122)
- relocate audit-stamp bats + repair latent path bug in 4 existing bats (#119)
- shared-state symlinks + slash-command worktree guards (#118)
- address remaining audit suggestions from PR #114 (#116)
- audit advisory follow-ups (S-1/S-2/S-3) (#114)
- bootstrap-labels.sh: shorten needs-human desc, add gaia-forensics (#113)
- forensics triage workflow correctness + hardening (#110)
- close sharp edges in setup-state, the pre-merge audit and post-merge cleanup (#109)
- address pre-merge audit findings (#106)
- enforce exclusive ceiling in spec-kit version-check

## [1.0.5] - 2026-05-04

### Added

- v1.0.5 wiki sync system: drift-check, commit-nudge, stop-safety-net hooks plus `/wiki-sync` workhorse for a convergent wiki-update model.

### Changed

- `/gaia-init` i18n setup is now language-aware: asks the user's primary language and optional additional locales, with an opt-out path that strips i18n entirely. Per-locale `add-locale` and `remove-i18n` instructions ship as parameterized runbooks under `.claude/instructions/`.
- Pin docs install command to `npx create-gaia@latest`.

### Fixed

- Restore statusline indicators for `/update-deps` and `/update-gaia`. The prior SessionStart hook approach was invisible to users; system-reminders only reach the model, and a 6h snooze locked in regardless of whether the user ever saw a prompt. Statusline indicators are passive and always visible.
- `/gaia-release` Step 2 gate now allows wiki-prefix-only drift, and `/wiki-sync` Step 7 is branch-aware (branch+PR on `main`, in-place commit elsewhere). Together they make the `/wiki-sync` → `/gaia-release` flow self-consistent.
- `/gaia audit` now chains research and apply by default; `--apply` is the retry escape hatch.
- Wiki sync system: smoke test assertions match the frozen interface.
- `/gaia-release` and `/gaia-init` scrub templates for `wiki/hot.md` (and `/gaia-release` Step 9 for `wiki/log.md`) now include the full frontmatter required by `/wiki-lint` (`status`, `created`, `tags`), eliminating a recurring lint regression on every release.

## [1.0.4] - 2026-05-01

### Fixed

- Handle `git -C <path>` in block-main-destructive-git hook

### Changed

- Wiki lint + audit hygiene sweep

## [1.0.3] - 2026-05-01

### Fixed

- Remove if conditionals from PreToolUse/PostToolUse hooks

## [1.0.2] - 2026-05-01

### Fixed

- Added `pnpm.onlyBuiltDependencies` for `core-js-pure`, `esbuild`, `msw`, and `unrs-resolver` to silence the pnpm build-script warning on fresh installs.

## [1.0.1] - 2026-05-01

### Fixed

- `/init` interceptor now reliably redirects to `/gaia-init`. The previous implementation used `UserPromptSubmit` + `exit 2`, which blocked the turn entirely so the model never ran. Switched to `UserPromptExpansion` (matcher: `init`) with `additionalContext` only; the model receives `/init`'s expansion plus a system-reminder override telling it to invoke `/gaia-init` via the Skill tool. The user-visible "blocked by hook" banner is gone.

## [1.0.0] - 2026-04-30

### Initial release

GAIA v1.0.0 is the inaugural public release of the GAIA React workflow, a Claude-native foundation that ships skills, commands, hooks, a wiki, and a curated React Router 7 app skeleton designed for agentic development from day one.

#### Highlights

- **Claude integration surface.** `.claude/` ships with rules, settings, hooks, an agent skills bundle (`typescript`, `react-code`, `tailwind`, `tdd`, `skeleton-loaders`, `playwright-cli`, `eslint-fixes`, `update-deps`, scaffolders), and an agent commands catalog. `CLAUDE.md` is curated for context economy.
- **GAIA workflows.** `/gaia plan`, `/gaia handoff`, `/gaia pickup`, `/gaia audit` cover task orchestration, session continuity, and knowledge-store hygiene. `/gaia-init` bootstraps new projects from the template.
- **Wiki vault.** Architecture overview, decisions (Quality Gate, pnpm, Dark Mode Modernization, etc.), modules (Routing, Styling, i18n, Form Components), concepts (Agentic Design, API Service Pattern, Component Testing, Task Orchestration), and a hot/log pair for session continuity.
- **App stack.** React Router 7, React 19, Tailwind v4, ESLint 9, Vite 8, Vitest 4, TypeScript 6, pnpm 10, MSW 2 + `@msw/data` 1.x.
- **Form system.** Conform + Zod for type-safe forms with reusable field components.
- **i18n.** `remix-i18next` middleware, English + Japanese language scaffolding, `LanguageSelect` component, Storybook locale switcher.
- **Dark mode.** Cookie-as-truth + `@epic-web/client-hints` + optimistic `useFetchers()` UI.
- **Quality gate.** Mandatory pre-commit pipeline: simplify, localization check, typecheck, lint, unit tests, E2E tests, dev smoke test, build. Zero warnings tolerated.
- **Release tooling.** Tag-triggered `release.yml` builds a scrubbed tarball; `create-gaia` bootstrapper consumes it via `npx create-gaia@latest my-app`.

[Unreleased]: https://github.com/gaia-harness/gaia/compare/v2.3.1...HEAD
[2.3.1]: https://github.com/gaia-harness/gaia/releases/tag/v2.3.1
[2.3.0]: https://github.com/gaia-harness/gaia/releases/tag/v2.3.0
[2.2.0]: https://github.com/gaia-harness/gaia/releases/tag/v2.2.0
[2.1.1]: https://github.com/gaia-react/gaia/releases/tag/v2.1.1
[2.1.0]: https://github.com/gaia-react/gaia/releases/tag/v2.1.0
[2.0.1]: https://github.com/gaia-react/gaia/releases/tag/v2.0.1
[2.0.0]: https://github.com/gaia-react/gaia/releases/tag/v2.0.0
[1.6.1]: https://github.com/gaia-react/gaia/releases/tag/v1.6.1
[1.6.0]: https://github.com/gaia-react/gaia/releases/tag/v1.6.0
[1.5.0]: https://github.com/gaia-react/gaia/releases/tag/v1.5.0
[1.4.0]: https://github.com/gaia-react/gaia/releases/tag/v1.4.0
[1.3.5]: https://github.com/gaia-react/gaia/releases/tag/v1.3.5
[1.3.4]: https://github.com/gaia-react/gaia/releases/tag/v1.3.4
[1.3.3]: https://github.com/gaia-react/gaia/releases/tag/v1.3.3
[1.3.2]: https://github.com/gaia-react/gaia/releases/tag/v1.3.2
[1.3.1]: https://github.com/gaia-react/gaia/releases/tag/v1.3.1
[1.3.0]: https://github.com/gaia-react/gaia/releases/tag/v1.3.0
[1.2.3]: https://github.com/gaia-react/gaia/releases/tag/v1.2.3
[1.2.2]: https://github.com/gaia-react/gaia/releases/tag/v1.2.2
[1.2.1]: https://github.com/gaia-react/gaia/releases/tag/v1.2.1
[1.2.0]: https://github.com/gaia-react/gaia/releases/tag/v1.2.0
[1.1.1]: https://github.com/gaia-react/gaia/releases/tag/v1.1.1
[1.1.0]: https://github.com/gaia-react/gaia/releases/tag/v1.1.0
[1.0.5]: https://github.com/gaia-react/gaia/releases/tag/v1.0.5
[1.0.4]: https://github.com/gaia-react/gaia/releases/tag/v1.0.4
[1.0.3]: https://github.com/gaia-react/gaia/releases/tag/v1.0.3
[1.0.2]: https://github.com/gaia-react/gaia/releases/tag/v1.0.2
[1.0.1]: https://github.com/gaia-react/gaia/releases/tag/v1.0.1
[1.0.0]: https://github.com/gaia-react/gaia/releases/tag/v1.0.0
