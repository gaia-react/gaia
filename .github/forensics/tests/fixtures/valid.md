---
class: quality-gate
gaia_version: 1.4.2
created: 2026-05-08
gh_issue_url: https://github.com/gaia-react/gaia/issues/123
---

## Symptom

`pnpm typecheck` reports `TS2304: Cannot find name 'foo'` after the
0.4.0 update.

## Classification

class: quality-gate
evidence: typecheck output cites the missing identifier across two
hook files in `.claude/hooks/`.

## Capture

```
gaia_version: 1.4.2
node_version: v20.11.0
pnpm_version: 9.0.0
git_branch: main
git_dirty: false
```

## Reproduction context

- `.claude/hooks/wiki-session-stop.sh`
- `.claude/hooks/post-tool.sh`
