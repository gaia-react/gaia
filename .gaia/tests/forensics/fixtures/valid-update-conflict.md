---
class: update
gaia_version: 1.4.2
created: 2026-05-08
gh_issue_url: https://github.com/gaia-react/gaia/issues/202
---

## Symptom

After `/update-gaia`, the app router throws `Cannot find module
'app/routes/_session+/dashboard'` at boot.

## Classification

class: update
evidence: the merge appears to have dropped a route file under `app/routes/`;
restoring it from git history fixes boot. The fix necessarily lives inside
`app/`, which is on the SPEC-002 canonical denylist.

## Capture

```
gaia_version: 1.4.2
node: v22.19.0
pnpm: 10.33.0
claude_code: 1.0.0
branch: main
dirty: true
class_state_files:
  - .gaia/manifest.json: present, version 1.4.2
  - app/routes/_session+/dashboard.tsx: absent (dropped by merge)
```

## Reproduction context

- `app/routes/_session+/dashboard.tsx`
- `app/router.ts`
