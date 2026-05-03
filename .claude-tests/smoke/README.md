# Smoke tests

End-to-end tests that drive `claude -p` (headless) through real wiki-sync scenarios. Costs ~$0.10 per full run on Sonnet under your subscription or API key.

These are MANUAL / pre-release. Not run in CI. Run them before cutting a GAIA release to verify the wiki-sync system works under real Claude judgment.

## Prerequisites

- `claude` CLI on PATH with a working subscription or `ANTHROPIC_API_KEY`
- `bash`, `git`, `jq`, `mktemp`
- Internet access
- ~$0.50 of headroom on your Anthropic account (each scenario can take 30s-2min and cost up to $0.10)

## Running

### All scenarios

```bash
bash .claude-tests/smoke/run-all.sh
```

Prints PASS/FAIL per scenario and a final summary. Exits non-zero on any failure.

### Individual scenario

```bash
bash .claude-tests/smoke/01-meaningful-change.sh
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

- `01-meaningful-change.sh` — Real change → drift detected → /wiki-sync runs → wiki updated → state advances
- `02-typo-only-skip.sh` — Typo commit → drift detected → /wiki-sync runs → SKIP logged, no wiki edits, state advances
- `03-multi-commit-catchup.sh` — N commits accumulated → drift detected on session start → /wiki-sync handles all → log has N entries
- `04-non-claude-merge.sh` — Commit made via shell (bypassing Claude) → next Claude session detects drift on first prompt → /wiki-sync catches up

## Updating

When you add hooks or change reminder text, update the scenario's expected-output assertions to match. The fixtures in each scenario are intentionally minimal so they're cheap to update.
