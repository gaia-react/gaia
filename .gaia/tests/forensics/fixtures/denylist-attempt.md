---
class: hook
gaia_version: 1.4.2
created: 2026-05-08
gh_issue_url: https://github.com/gaia-react/gaia/issues/206
---

## Symptom

The session-stop hook crashes when the app router has no routes defined;
adding a guard in the hook AND a no-op default route in the app fixes it.

## Classification

class: hook
evidence: stack trace originates in `.claude/hooks/wiki-session-stop.sh` and
in `app/routes/_index.tsx`. A complete fix would touch both files — one in
the allowlist, one on the canonical denylist.

## Capture

```
gaia_version: 1.4.2
node_version: v22.19.0
pnpm_version: 10.33.0
git_branch: main
git_dirty: false
hook_exit: 1
```

## Reproduction context

- `.claude/hooks/wiki-session-stop.sh`
- `app/routes/_index.tsx`
