# Wiki-sync smoke tests

End-to-end tests that drive `claude -p` (headless) through real `/gaia wiki sync` scenarios. Costs ~$0.10 per full run on Sonnet under your subscription or API key.

These are MANUAL / pre-release. Not run in CI. Run them before cutting a GAIA release to verify the wiki-sync system works under real Claude judgment.

## Prerequisites

- `claude` CLI on PATH with a working subscription or `ANTHROPIC_API_KEY`
- `bash`, `git`, `jq`, `mktemp`
- Internet access
- ~$0.50 of headroom on your Anthropic account (each scenario can take 30s-2min and cost up to $0.10)

## Running

### All wiki-sync scenarios

```bash
bash .gaia/tests/smoke/run-all.sh
```

Prints PASS/FAIL per scenario and a final summary. Exits non-zero on any failure.

### Individual scenario

```bash
bash .gaia/tests/smoke/wiki-sync/01-meaningful-change.sh
```

Each scenario:

- Creates a tmp directory
- Scaffolds a minimal GAIA-like project with the wiki-sync hooks installed
- Drives `claude -p` through prompts
- Asserts the expected behavior
- Cleans up

## Cost discipline

Scenarios use Sonnet (not Opus) to keep cost low. A full run touches ~5 sessions of 5–15K tokens each = ~30–75K tokens total ≈ $0.05–0.15.

If you're iterating on a hook and want a single fast check, run just `01-meaningful-change.sh`.

## Scenarios

- `01-meaningful-change.sh` — Service add with an `Invariant:` body → WORTHY → wiki page created → state advances. Body-decision rule.
- `02-typo-only-skip.sh` — Typo commit → SKIP logged, no wiki edits, state advances.
- `03-multi-commit-catchup.sh` — 5 mixed commits (4 inventory-class + 1 invariant-bearing fix) → log carries WORTHY for the fix, `Serena handles inventory` markers for the rest, state advances to HEAD.
- `04-non-claude-merge.sh` — Shell commit (bypassing Claude) → next session detects drift on first prompt → /gaia wiki sync catches up.
- `05-serena-inventory-skip.sh` — Vanilla service add with no decision body → `SKIP: Serena handles inventory` marker → no wiki page → state advances. Positive test for the post-Serena WORTHY narrowing.

## Post-Serena rubric notes

`/gaia wiki sync` Step 3 narrowed in 2026-05 to treat `app/components/`, `app/hooks/`, `app/services/`, and `app/pages/` commits as SKIP unless the body carries durable knowledge (trade-off / invariant / gotcha / workaround). Serena's LSP index now owns inventory.

The fixtures in `01` and `03` carry an explicit `Invariant:` line so they cross the WORTHY threshold; `05` deliberately omits it to land on the SKIP path. If you change the rubric in `.claude/skills/gaia/references/wiki/sync.md`, update the matching fixtures here and the `Serena handles inventory` greppable assertion in `03` and `05`.

## Updating

When you add hooks or change reminder text, update the scenario's expected-output assertions to match. The fixtures in each scenario are intentionally minimal so they're cheap to update.
