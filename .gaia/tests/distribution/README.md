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

Layer 0 — host pnpm available, scenarios run with the maintainer's PATH (default). Layer 1 — PATH-stripped subshell (`05-clean-env.sh`) verifies the bootstrapper extracts cleanly with only `/usr/bin:/bin`. Layer 2 — Docker (`06-claude-runs-staged.sh`) verifies the Claude-in-container plumbing against a staged release tree.

### Layer 1: clean-env bootstrap (`05-clean-env.sh`)

Covers tarball extraction and the corepack-driven pnpm bootstrap inside a PATH-stripped subshell with an isolated `$HOME`. Reuses `lib/build-staging.sh` to produce a release-shape tree, tars it, and extracts into a scratch scaffold — the same shape `create-gaia` runs on an adopter's machine. The subshell's PATH is reduced to `/usr/bin:/bin` plus symlinks to the outer `node`/`corepack`/`tar`/`git`, so any maintainer-local `pnpm`/`uv`/`claude` becomes invisible. The scenario asserts pnpm is *not* visible before bootstrap, then exercises `corepack enable pnpm` followed by `pnpm install --frozen-lockfile`.

Does not cover `/gaia-init` or `/setup-gaia` execution (no Claude in the subshell — see `diagnostic/claude-auth-in-docker.md`), full filesystem isolation (a true Docker run is the answer), or non-host operating systems. The `npm install -g pnpm` fallback path inside `create-gaia`'s `ensurePnpm()` is intentionally untested here — exercising it would mutate the host's global npm state with no clean rollback.

Skips automatically if `corepack` is not on the host PATH (Node 16.13+ ships corepack, so this is rare). Skip is reported as a soft PASS so `run-all.sh` summaries stay green on hosts where the layer cannot run.

### Layer 2: Claude-in-Docker plumbing (`06-claude-runs-staged.sh`)

Builds a `gaia-dist-claude` image (`node:22-bullseye-slim` + `claude.ai/install.sh`, with `/root/.local/bin` on PATH per the verified pattern in `diagnostic/claude-auth-in-docker.md`), bind-mounts the staged tree at `/work` read-only, and runs `claude --print "Reply with the single word: ok"` with `CLAUDE_CODE_OAUTH_TOKEN` passed through from the host env. The OAuth token attributes to the maintainer's Claude Max subscription, so per-run cost is $0.

What it covers: image build, claude binary on PATH inside the container, OAuth auth from container to Anthropic, staged tree reachable as the container's working directory. What it does NOT cover: adopter flows like `/gaia-init` or `/setup-gaia` — those exercise interactive skills and live in follow-up scenarios; this is the harness smoke that proves Layer 2 is wired.

Skips automatically if Docker is unavailable OR `CLAUDE_CODE_OAUTH_TOKEN` is unset, so contributors without auth can still run Layers 0 + 1 via `run-all.sh`. Both skips report as soft PASS.

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

#### CI

`.github/workflows/distribution.yml` runs `run-all.sh` on `ubuntu-latest` with `CLAUDE_CODE_OAUTH_TOKEN` injected from GAIA's GitHub organization secrets. Trigger is `workflow_dispatch` only (manual, maintainer-initiated). The intended steady-state trigger is `release.published` — only the maintainer publishes releases, so contributors structurally cannot trigger Layer 2 spend. The workflow never uses `pull_request_target` (that trigger would expose the secret to fork PRs).

## Claude auth status

**Status: verified 2026-05-08** — `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` attributes to Claude Max subscription on the host generating the token. Layer 2 tests are $0 marginal per run on Max-plan hosts. Full findings in `diagnostic/claude-auth-in-docker.md` § Findings.

## See also

- `.gaia/tests/smoke/README.md` — sibling smoke kit, same shape.
- `wiki/concepts/Release Workflow.md` — what the staged tarball is and how it's built.
