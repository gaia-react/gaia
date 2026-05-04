# Smoke tests

Two subtrees. Both are maintainer-only — neither runs in CI, both inform release decisions.

## Layout

- `wiki-sync/` — bash-driven E2E scenarios that spin up tmp git repos and drive `claude -p` through `/wiki-sync` runs. Billable (~$0.10/full run on Sonnet). See `wiki-sync/README.md`.
- `serena/` — python-driven scanner that reads existing Claude Code transcripts and reports Serena vs grep usage. Free (no API calls). See `serena/README.md`.

## Running

### Wiki-sync E2E (billable)

```bash
bash .claude-tests/smoke/run-all.sh
```

Walks every `wiki-sync/*.sh` scenario, prints PASS/FAIL, exits non-zero on any failure.

### Serena usage scan (free, diagnostic)

```bash
python3 .claude-tests/smoke/serena/usage_scan.py --days 7
```

Reports tool-call counts from your actual sessions. No PASS/FAIL — it's a measurement.

## When to run

- **Before cutting a GAIA release** — wiki-sync E2E. Verifies the wiki-sync system works under real Claude judgment, including the post-Serena WORTHY narrowing.
- **Periodically during the Serena dogfooding window** — usage scan. Tracks whether the routing rule is actually changing behavior.
