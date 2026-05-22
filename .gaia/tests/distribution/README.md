# Distribution tests

Maintainer-only validation of the post-scrub GAIA tarball. Excluded from the release bundle via category 3 (`.gaia/tests/`). Audience is the machine — every scenario reports PASS/FAIL with a deterministic exit code. Convention: `.claude/rules/_internal/smoke.md`.

## When to run

- Before cutting a GAIA release (`/gaia-release`).
- When modifying any file that shapes the staged tarball:
  - `.gaia/release-scrub.yml`
  - `.gaia/release-exclude`
  - `.github/workflows/release.yml`
  - `.gaia/manifest.ts`

## Layout

```
.gaia/tests/distribution/
├── run-all.sh                   # top-level driver
├── lib/
│   ├── lib.sh                   # pass/fail/log/require_cmd, PROJECT_ROOT
│   ├── build-staging.sh         # builds staging tarball into $1 (mktemp dir)
│   └── docker.sh                # Layer 2 image build + container run helpers
├── 01-files-present.sh          # manifest/exclude/sentinel presence
├── 02-leak-replay.sh            # re-runs scrub regexes against staged tree
├── 03-marker-strip.sh           # asserts maintainer-only markers gone
├── 04-scaffold-runs.sh          # extract + pnpm install + typecheck/lint/test/build
├── 05-clean-env.sh              # PATH-stripped subshell (Layer 1)
├── 06-claude-runs-staged.sh     # Claude-in-Docker auth + cwd smoke (Layer 2)
├── 07-gaia-init-strip-branding.sh  # Adopter-flow regression: gaia init strip-branding
├── 08-gaia-init-cli-sequence.sh    # Adopter-flow regression: full gaia init CLI sequence
└── diagnostic/
    └── claude-auth-in-docker.md
```

## Running

```bash
bash .gaia/tests/distribution/run-all.sh
```

Walks `*.sh` (excluding `run-all.sh` and anything under `lib/`/`diagnostic/`) in lexicographic order, prints PASS/FAIL per scenario, exits non-zero on any failure.

Individual scenarios are runnable directly:

```bash
bash .gaia/tests/distribution/01-files-present.sh
```

## Prerequisites

- `.gaia/cli/gaia` binary built and present — scenarios shell out to it directly, not to `pnpm -C .gaia/cli`.
- Host has `git`, `tar`, `rsync`, `pnpm` on PATH (Layer 0).

## Layered isolation

Layer 0 — host pnpm available, scenarios run with the maintainer's PATH (default). Layer 1 — PATH-stripped subshell (`05-clean-env.sh`) verifies the bootstrapper extracts cleanly with only `/usr/bin:/bin`. Layer 2 — Docker (`06-claude-runs-staged.sh`) verifies the Claude-in-container plumbing against a staged release tree. Adopter-flow regressions (`07-`+) run on the host or runner without Docker and exercise the bundled CLI against a writable copy of the staged tree.

### Layer 1: clean-env bootstrap (`05-clean-env.sh`)

Covers tarball extraction and the corepack-driven pnpm bootstrap inside a PATH-stripped subshell with an isolated `$HOME`. Reuses `lib/build-staging.sh` to produce a release-shape tree, tars it, and extracts into a scratch scaffold — the same shape `create-gaia` runs on an adopter's machine. The subshell's PATH is reduced to `/usr/bin:/bin` plus symlinks to the outer `node`/`corepack`/`tar`/`git`, so any maintainer-local `pnpm`/`uv`/`claude` becomes invisible. The scenario asserts pnpm is *not* visible before bootstrap, then exercises `corepack enable pnpm` followed by `pnpm install --frozen-lockfile`.

Does not cover `/gaia-init` or `/setup-cloned-gaia-project` execution (no Claude in the subshell — see `diagnostic/claude-auth-in-docker.md`), full filesystem isolation (a true Docker run is the answer), or non-host operating systems. The `npm install -g pnpm` fallback path inside `create-gaia`'s `ensurePnpm()` is intentionally untested here — exercising it would mutate the host's global npm state with no clean rollback.

Skips automatically if `corepack` is not on the host PATH (Node 16.13+ ships corepack, so this is rare). Skip is reported as a soft PASS so `run-all.sh` summaries stay green on hosts where the layer cannot run.

### Layer 2: Claude-in-Docker plumbing (`06-claude-runs-staged.sh`)

Builds a `gaia-dist-claude` image (`node:22-bullseye-slim` + `claude.ai/install.sh`, with `/root/.local/bin` on PATH per the verified pattern in `diagnostic/claude-auth-in-docker.md`), bind-mounts the staged tree at `/work` read-only, and runs `claude --print "Reply with the single word: ok"` with `CLAUDE_CODE_OAUTH_TOKEN` passed through from the host env. The OAuth token attributes to the maintainer's Claude Max subscription, so per-run cost is $0.

What it covers: image build, claude binary on PATH inside the container, OAuth auth from container to Anthropic, staged tree reachable as the container's working directory. What it does NOT cover: adopter flows like `/gaia-init` or `/setup-cloned-gaia-project` — those exercise interactive skills and live in follow-up scenarios; this is the harness smoke that proves Layer 2 is wired.

Skips automatically if Docker is unavailable OR `CLAUDE_CODE_OAUTH_TOKEN` is unset, so contributors without auth can still run Layers 0 + 1 via `run-all.sh`. Both skips report as soft PASS.

### Adopter-flow regressions (`07-`+)

`06-claude-runs-staged.sh` proves the harness wiring (Docker, OAuth auth, claude binary on PATH), but does NOT prove any GAIA-specific flow works in the shipped tarball. Adopter-flow scenarios fill that gap by running the bundled `.gaia/cli/gaia` binary directly against a writable copy of the staged tree.

`07-gaia-init-strip-branding.sh` runs `gaia init strip-branding --title "Test Project"` and asserts the four documented post-conditions: `README.md` is regenerated from `.gaia/templates/README.md` with the title substituted, `app/components/GaiaLogo/` is removed, `app/components/Header/index.tsx` no longer references `GaiaLogo`, and the subcommand exits 0 with no stdout per its contract. Catches the failure mode where `release-exclude` accidentally strips a file the subcommand needs (template, deletion target, edit target) — Layers 0+1+2 stay green; only this scenario fails.

`08-gaia-init-cli-sequence.sh` runs the full deterministic sequence behind `/gaia-init` Step 3 — `strip-branding` → `configure-i18n --strip false` → `rename` → `wire-statusline --mode project` → `finalize` — and asserts each step's post-conditions on the staged tree. Catches release-exclude drift on every CLI surface the slash command dispatches to: the `existsSync` guards in `configure-i18n`/`rename`/`finalize` mean a missing target file silently no-ops rather than erroring, so this scenario is the gate that turns a no-op into a failure. `--mode project` for `wire-statusline` keeps the merge inside the scaffold's `.claude/settings.json` and never writes to the host's `~/.claude`. The `configure-i18n --strip true` path (full i18n removal via the prose `remove-i18n.md` instruction) is out of scope here — that path is orchestrated by the slash command, not the CLI alone.

Future adopter-flow scenarios cover the `--strip true` removal path and the `gaia setup` subcommands.

#### Local setup for maintainers

```bash
# One-time: generate a long-lived OAuth token on the host.
claude setup-token

# Export the token in the current shell. Do NOT commit it — the .gitignore
# pattern `*.env` covers any local env file you might use.
export CLAUDE_CODE_OAUTH_TOKEN=<paste>

# Or stash in a local env file outside the repo:
echo 'CLAUDE_CODE_OAUTH_TOKEN=<paste>' > /tmp/claude-probe.env
chmod 600 /tmp/claude-probe.env
set -a; . /tmp/claude-probe.env; set +a

bash .gaia/tests/distribution/run-all.sh
```

The image tag defaults to `gaia-dist-claude:latest`; override via `GAIA_DIST_IMAGE` if needed. First build pulls `node:22-bullseye-slim` and runs `claude.ai/install.sh` (~30s); subsequent runs hit Docker's layer cache.

The image is intentionally NOT removed at the end of each run — keeping it preserves the layer cache for repeat local invocations. To reclaim disk space (or force a clean rebuild against an updated `claude.ai/install.sh`), remove it manually:

```bash
docker rmi gaia-dist-claude:latest
```

CI runners are ephemeral, so no cleanup is required there.

#### CI

Two entry points, both consuming `CLAUDE_CODE_OAUTH_TOKEN` from GAIA's GitHub organization secrets:

- **Pre-publish gate inside `release.yml`.** The tag-triggered release workflow runs `bash .gaia/tests/distribution/run-all.sh` after the staging + scrub + runtime-deps phases and before the tarball is built. If any scenario fails the release halts — the tarball never builds and `gh release create` never runs, so a broken release cannot publish. This is the production gate.
- **Manual `distribution.yml`.** `workflow_dispatch` only — used to run the harness on a feature branch (no tag) for ad-hoc verification of harness changes themselves. Never `pull_request_target` (that trigger would expose the secret to fork PRs).

## Claude auth status

**Status: verified 2026-05-08** — `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` attributes to Claude Max subscription on the host generating the token. Layer 2 tests are $0 marginal per run on Max-plan hosts. Full findings in `diagnostic/claude-auth-in-docker.md` § Findings.

## See also

- `.gaia/tests/smoke/README.md` — sibling smoke kit, same shape.
- `wiki/concepts/Release Workflow.md` — what the staged tarball is and how it's built.
