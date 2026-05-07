# Distribution tests

Maintainer-only validation of the post-scrub GAIA tarball. Excluded from the release bundle via category 3 (`.claude-tests/`). Audience is the machine — every scenario reports PASS/FAIL with a deterministic exit code. Convention: `.claude/rules/_internal/smoke.md`.

## When to run

- Before cutting a GAIA release (`/gaia-release`).
- When modifying any file that shapes the staged tarball:
  - `.gaia/release-scrub.yml`
  - `.gaia/release-exclude`
  - `.github/workflows/release.yml`
  - `.gaia/manifest.ts`

## Layout

```
.claude-tests/distribution/
├── run-all.sh             # top-level driver
├── lib/
│   ├── lib.sh             # pass/fail/log/require_cmd, PROJECT_ROOT
│   └── build-staging.sh   # builds staging tarball into $1 (mktemp dir)
├── 01-files-present.sh    # manifest/exclude/sentinel presence
├── 02-leak-replay.sh      # re-runs scrub regexes against staged tree
├── 03-marker-strip.sh     # asserts maintainer-only markers gone
├── 04-scaffold-runs.sh    # extract + pnpm install + typecheck/lint/test/build
├── 05-clean-env.sh        # PATH-stripped subshell (Layer 1)
└── diagnostic/
    └── claude-auth-in-docker.md
```

## Running

```bash
bash .claude-tests/distribution/run-all.sh
```

Walks `*.sh` (excluding `run-all.sh` and anything under `lib/`/`diagnostic/`) in lexicographic order, prints PASS/FAIL per scenario, exits non-zero on any failure.

Individual scenarios are runnable directly:

```bash
bash .claude-tests/distribution/01-files-present.sh
```

## Prerequisites

- `.gaia/cli/gaia` binary built and present — scenarios shell out to it directly, not to `pnpm -C .gaia/cli`.
- Host has `git`, `tar`, `rsync`, `pnpm` on PATH (Layer 0).

## Layered isolation

Layer 0 — host pnpm available, scenarios run with the maintainer's PATH (default). Layer 1 — PATH-stripped subshell (`05-clean-env.sh`) verifies the bootstrapper extracts cleanly with only `/usr/bin:/bin`. Layer 2 — Docker (deferred; tracked under `diagnostic/`).

### Layer 1: clean-env bootstrap (`05-clean-env.sh`)

Covers tarball extraction and the corepack-driven pnpm bootstrap inside a PATH-stripped subshell with an isolated `$HOME`. Reuses `lib/build-staging.sh` to produce a release-shape tree, tars it, and extracts into a scratch scaffold — the same shape `create-gaia` runs on an adopter's machine. The subshell's PATH is reduced to `/usr/bin:/bin` plus symlinks to the outer `node`/`corepack`/`tar`/`git`, so any maintainer-local `pnpm`/`uv`/`claude` becomes invisible. The scenario asserts pnpm is *not* visible before bootstrap, then exercises `corepack enable pnpm` followed by `pnpm install --frozen-lockfile`.

Does not cover `/gaia-init` or `/setup-gaia` execution (no Claude in the subshell — see `diagnostic/claude-auth-in-docker.md`), full filesystem isolation (a true Docker run is the answer), or non-host operating systems. The `npm install -g pnpm` fallback path inside `create-gaia`'s `ensurePnpm()` is intentionally untested here — exercising it would mutate the host's global npm state with no clean rollback.

Skips automatically if `corepack` is not on the host PATH (Node 16.13+ ships corepack, so this is rare). Skip is reported as a soft PASS so `run-all.sh` summaries stay green on hosts where the layer cannot run. Layer 2 (Docker) is deferred — see `diagnostic/claude-auth-in-docker.md` for the next-step plan.

## Claude auth status

**Status: not yet verified.** See `diagnostic/claude-auth-in-docker.md`.

## See also

- `.claude-tests/smoke/README.md` — sibling smoke kit, same shape.
- `wiki/concepts/Release Workflow.md` — what the staged tarball is and how it's built.
