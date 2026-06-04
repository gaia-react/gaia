# Wiki-sync smoke tests

End-to-end tests that drive `claude -p` (headless) through real `/gaia-wiki sync` scenarios. Costs ~$0.10 per full run on Sonnet under your subscription or API key.

These are MANUAL / pre-release. Not run in CI. Run them before cutting a GAIA release to verify the wiki-sync system works under real Claude judgment.

## Prerequisites

- `claude` CLI on PATH with a working subscription or `ANTHROPIC_API_KEY`
- `bash`, `git`, `jq`, `mktemp`
- Internet access
- ~$0.50 of headroom on your Anthropic account (each scenario can take 30s-2min and cost up to $0.10)

## Running

### All wiki-sync scenarios (advisory)

```bash
bash .gaia/tests/smoke/wiki-sync/run.sh
```

Runs every scenario with bounded retries (one retry by default; override with
`WIKI_SYNC_MAX_ATTEMPTS`), prints a PASS/FAIL summary, and on a final failure
surfaces the captured `claude` session output so the failure is diagnosable.
`run-all.sh` invokes this same runner as an ADVISORY lane: it reports a signal
but never sets the release gate's exit code (see "Why advisory" below).

### Individual scenario

```bash
bash .gaia/tests/smoke/wiki-sync/01-meaningful-change.sh
```

Runs from any cwd: each scenario resolves the gaia repo root from its own
location, so you do not need to `cd` first or export `GAIA_REPO` (set
`GAIA_REPO=/path/to/gaia` to override the source repo).

Each scenario:

- Creates a tmp directory
- Scaffolds a minimal GAIA-like project: the wiki-sync hooks, the `gaia-wiki`
  skill + sync runbook, AND the bundled `.gaia/cli/gaia` binary the playbook
  shells out to at every step
- Drives `claude -p` through prompts
- Asserts the expected behavior, dumping the captured session output on failure
- Cleans up

## Why advisory (not a blocking gate)

The sync playbook runs every step through the `.gaia/cli/gaia` CLI (state read,
commit classification, log writes, land), so the binary must be present in the
fixture for the playbook to execute at all. With the CLI provisioned the
scenarios exercise the real deterministic path, but their assertions still ride
on free-form LLM output: which page got created, the exact reason string logged
to `wiki/log.md`, whether a prose answer mentions "drift". That output is not
reproducible run-to-run, so a green run today can flake red tomorrow on
identical code. Blocking a release on that is the flaky-gate anti-pattern.

The deterministic core (`commit-classify`, `log-prepend`, `state`, `sync land`)
is unit-tested under `.gaia/cli/src/wiki/` and gated by `cli-tests.yml`; these
E2E scenarios uniquely cover the LLM-playbook integration, which cannot be made
deterministic. So they run as an advisory signal with retries, and the
deterministic layer stays the hard gate.

## Cost discipline

Scenarios use Sonnet (not Opus) to keep cost low. A full run touches ~5 sessions of 5–15K tokens each = ~30–75K tokens total ≈ $0.05–0.15.

If you're iterating on a hook and want a single fast check, run just `01-meaningful-change.sh`.

## Scenarios

- `01-meaningful-change.sh`; Service add with an `Invariant:` body → WORTHY → wiki page created → state advances. Body-decision rule.
- `02-typo-only-skip.sh`; Typo commit → SKIP logged, no wiki edits, state advances.
- `03-multi-commit-catchup.sh`; 5 mixed commits (4 inventory-class + 1 invariant-bearing fix) → log carries WORTHY for the fix, `Serena handles inventory` markers for the rest, state advances to HEAD.
- `04-non-claude-merge.sh`; Shell commit (bypassing Claude) → next session detects drift on first prompt → /gaia-wiki sync catches up.
- `05-serena-inventory-skip.sh`; Vanilla service add with no decision body → `SKIP: Serena handles inventory` marker → no wiki page → state advances. Positive test for the post-Serena WORTHY narrowing.

## Post-Serena rubric notes

`/gaia-wiki sync` Step 3 narrowed in 2026-05 to treat `app/components/`, `app/hooks/`, `app/services/`, and `app/pages/` commits as SKIP unless the body carries durable knowledge (trade-off / invariant / gotcha / workaround). Serena's LSP index now owns inventory.

The fixtures in `01` and `03` carry an explicit `Invariant:` line so they cross the WORTHY threshold; `05` deliberately omits it to land on the SKIP path. If you change the rubric in `.claude/skills/gaia/references/wiki/sync.md`, update the matching fixtures here and the `Serena handles inventory` greppable assertion in `03` and `05`.

## Updating

When you add hooks or change reminder text, update the scenario's expected-output assertions to match. The fixtures in each scenario are intentionally minimal so they're cheap to update.
