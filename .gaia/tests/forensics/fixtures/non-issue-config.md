---
class: dev-server
gaia_version: 1.4.2
created: 2026-05-08
gh_issue_url: https://github.com/gaia-react/gaia/issues/203
---

## Symptom

`pnpm dev` exits immediately with `Error: ENOENT: no such file or directory,
open '.env'`.

## Classification

class: dev-server
evidence: the `.env` file is required by `app/i18n.ts` per the README setup
checklist. The reporter has not run the `cp .env.example .env` step. This is
a missing-prerequisite, not a GAIA defect.

## Capture

```
gaia_version: 1.4.2
node_version: v22.19.0
pnpm_version: 10.33.0
git_branch: main
git_dirty: false
env_file_present: false
```

## Reproduction context

- `.env.example`
- `README.md`
