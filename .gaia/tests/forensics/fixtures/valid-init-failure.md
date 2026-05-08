---
class: init
gaia_version: 1.4.2
created: 2026-05-08
gh_issue_url: https://github.com/gaia-react/gaia/issues/201
---

## Symptom

`/gaia-init` fails halfway through with `Error: cannot read property 'replace'
of undefined` after the project-name prompt.

## Classification

class: init
evidence: stack trace points at the init skill's name-substitution step in
`.claude/skills/gaia-init/SKILL.md`; the failure reproduces on a clean clone.

## Capture

```
gaia_version: 1.4.2
node_version: v22.19.0
pnpm_version: 10.33.0
git_branch: main
git_dirty: false
prompt_value: <redacted>
```

## Reproduction context

- `.claude/skills/gaia-init/SKILL.md`
- `.gaia/cli/templates/init/post-init.sh`
