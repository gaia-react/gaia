---
class: scaffold
gaia_version: 1.4.2
created: 2026-05-08
gh_issue_url: https://github.com/gaia-react/gaia/issues/207
---

## Symptom

`pnpm install` fails with `ERR_PNPM_PEER_DEP_ISSUES` after a fresh clone; a
peer-dep override in `package.json` resolves it.

## Classification

class: scaffold
evidence: pnpm reports the peer-dep mismatch on a known transitive dep; the
canonical fix lives in `package.json` under `pnpm.overrides`. `package.json`
is in NEITHER the SPEC-002 allowlist nor the denylist, so it is denylisted by
default per UAT-014.

## Capture

```
gaia_version: 1.4.2
node_version: v22.19.0
pnpm_version: 10.33.0
git_branch: main
git_dirty: false
install_exit: 1
```

## Reproduction context

- `package.json`
