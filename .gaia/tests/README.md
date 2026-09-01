# .gaia/tests

Internal tests for GAIA's Claude Code hooks, commands, and wiki sync system. Not shipped to adopters via `create-gaia`; excluded by `.gaia/release-exclude`.

## Layout

Read the **Gate** column first. It is the difference between a suite whose red
blocks a merge and one whose red nobody sees until a reader opens the file: an
ungated tree can carry a failing assertion on `main` indefinitely, which is a
defect this repository has actually shipped.

| Tree | Gate | What it is |
|---|---|---|
| `whole-tree-invariants.sh` | by hand, pre-dispatch; its guard suite `lib/whole-tree-invariants.bats` is CI-gated in `audit-ci-tests.yml` via the `lib` shard | the pre-dispatch entry point: runs every check whose input is the whole tree as one set, `shell-lint.sh` and the shard partition among them, in about a minute. Path-scoped selection cannot reach a whole-tree check, so this is the named set that replaces running whichever of them a loaded rule happens to mention. Its header owns the membership rule and every deliberate non-member's reason. Read the Gate cell literally: no workflow runs this script, and the CI-gated suite exercises the aggregation against fixture stubs rather than the real tree, so skipping the hand run on the belief that CI covers the set reopens the exact gap the script closes. What CI does cover is a member joining neither list. |
| `shell-lint.sh` | CI, `shell-lint.yml` (two legs) | shellcheck gate over every tracked `*.sh` and `*.bats`, plus a bash-3.2 parse pass and the custom lints folded in beneath it, each announcing itself with its own `-->` banner as it runs. Free, deterministic. Its paths filter is wider than its name suggests and each entry there carries the reason it was added: a shell script or bats suite arms it, and so do the husky hooks, the workflow and composite-action trees, the adopter workflow templates, every tracked markdown file, and the C-family globs `.claude/rules/code-comments.md` binds, because a folded guard scans each of those. The ubuntu leg runs the whole harness; a `macos-latest` leg runs `--only bash32-parse`, the one pass a bash-5 runner can only skip. Also a member of `whole-tree-invariants.sh` above, which is what to run pre-merge. |
| `hooks/` | CI, `audit-ci-tests.yml` | bats tests for the shell hooks. Free, deterministic, the largest tree here. |
| `lib/` | CI, `audit-ci-tests.yml` | bats suite for the SPEC-ledger machinery under `.specify/extensions/gaia/lib/`. See `lib/README.md`. |
| `forensics/` | CI, `audit-ci-tests.yml` | redaction and capture harness. CI reaches it through the `misc` shard (`bash .gaia/tests/bats-shards.sh run misc`); `forensics/run-all.sh` is the hand-run entry point, also wired to `pnpm test:forensics`. |
| `statusline/` | CI, `audit-ci-tests.yml` | bats tests for the shipped statusline script. |
| `sandbox/` | CI, `audit-ci-tests.yml` | sandbox-enablement conformance greps, via `sandbox/run-all.sh`. Two tests self-skip in CI by design. A hand run recovers the docs-link check; the OS-level enforcement test needs `GAIA_SANDBOX_CAPABLE=1` and a repo-root `.env` on top of that, or it skips there too. |
| `concurrency/` | CI, `audit-ci-tests.yml` | the INV-7 concurrency meter. Admits scenarios that are red by design, so it is adjudicated against `expected-status.txt` by `meter-gate.sh` rather than on its own exit status. See `concurrency/README.md`. |
| `distribution/` | CI, `release.yml` + `distribution.yml` + `cli-tests.yml` | validation of the post-scrub GAIA tarball. Docker-gated. See `distribution/README.md`. |
| `smoke/` | by hand, billable | release-gate harnesses with PASS/FAIL semantics. Subdirs: `wiki-sync/`, `wiki-promote/`, `uat-write/`. Routing rule: `.claude/rules/maintainers/smoke.md`. See `smoke/README.md`. |
| `prose-audit/` | by hand, gated | best-effort dry-run for the prose-complexity audit lens. A judgment call, not a deterministic gate. See `prose-audit/README.md`. |
| `observability/` | by hand | measurement tools that watch agent behavior over time and report metrics. NO PASS/FAIL. Subdirs: `serena/`. See `observability/serena/README.md` (no tree-level README needed for a single occupant; revisit if a second tool lands). |

A CI gate is only as good as its paths filter. `audit-ci-tests.yml` runs each
tree behind a `dorny/paths-filter` output, and a filter that omits a path a
suite reads reports `code=false`, skips every bats step, and greens the job
having run zero tests. When you add a suite, add every source it reads to that
workflow's filter, and say why in a comment beside it.

## Running

### Whole-tree invariants (pre-dispatch, ~40s)

```bash
bash .gaia/tests/whole-tree-invariants.sh
```

Run this before the first Code Audit Team dispatch, alongside the bats suites
for the paths the change touches. It supersedes running `shell-lint.sh` alone,
which it already includes. `--list` prints its members and `--list-excluded`
prints every deliberate non-member with the reason it is out.

### Shell lint (free, fast)

```bash
bash .gaia/tests/shell-lint.sh
```

Requires `shellcheck` (`brew install shellcheck`). Lints at a per-type severity floor and exits non-zero on any finding: tracked `*.sh` at `style` (the strictest tier) and tracked `*.bats` at `warning`. On `*.sh`, the intentional single-quoted `jq`/`awk` programs (SC2016) carry file-level disable directives and the unresolvable dynamic `source` paths (SC1091/SC1090) are excluded as tooling artifacts, so a genuine style-tier bug still gates. On `*.bats`, the `warning` floor sits above the structural false positives of the bats execution model (SC2317 unreachable `@test` bodies, SC2030/SC2031 subshell state from `run`, SC2016 assertion strings) while still catching live failure modes (SC2314 masked `!` assertions, SC2155, SC2164). See the sub-floor tiers with `shellcheck -S style <file>`.

This is the deterministic backstop for the `code-audit-maintainer-shell` agent, which already treats shellcheck as an authoritative oracle but is model-dispatched and advisory-only. The agent keeps the lenses shellcheck cannot model (hook fail-open, stdin-JSON shape, `jq -n` injection safety).

### Hooks tests (free, slow)

```bash
bats .gaia/tests/hooks/
```

Requires `bats` (`brew install bats-core`). Tests are self-contained; they spin up tmp git repos via `helpers/tmp-git-repo.sh` and feed synthetic JSON to hooks via `helpers/mock-hook-input.sh`.

### All shards in parallel (free, slow)

```bash
bash .gaia/tests/run-bats-parallel.sh
```

Forks the same partition CI runs (`.gaia/tests/bats-shards.sh`), one bats process per shard, all on one box.

### Sandbox conformance tests (free, fast)

```bash
pnpm test:sandbox
```

Static conformance greps over the `/setup-gaia` sandbox-decision block, the OS Sandbox wiki page, and the `.env` guard. CI runs the same script, so a local green and a CI green mean the same thing with two documented exceptions. The docs-link reachability check skips under `CI` so a third-party outage cannot red a required check, and a hand run is what recovers it. The OS-level enforcement test skips in both places unless you give it a sandbox-capable session: export `GAIA_SANDBOX_CAPABLE=1` after `gaia sandbox apply` and a restart, and have a repo-root `.env` for it to probe. A plain `pnpm test:sandbox` supplies neither, so a green run here is not evidence that the OS-level path was exercised.

### Wiki-sync smoke tests (manual, billable)

```bash
bash .gaia/tests/smoke/run-all.sh
```

Requires `claude` CLI on PATH and a working subscription or API key. See `smoke/wiki-sync/README.md` for details and per-scenario commands.

### Serena usage scan (free, diagnostic)

```bash
python3 .gaia/tests/observability/serena/usage_scan.py
```

Reads `~/.claude/projects/.../*.jsonl` and prints tool-call counts. See `observability/serena/README.md`.

## Why a separate folder

`tests/` already exists in this repo for application tests. `.gaia/tests/` is dev infrastructure for the harness itself; different audience (GAIA maintainers, not adopters), different runtime (shell + claude CLI, not vitest).
