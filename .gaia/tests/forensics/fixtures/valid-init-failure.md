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
node: v22.19.0
pnpm: 10.33.0
claude_code: 1.0.0
branch: main
dirty: false
class_state_files:
  - .gaia/manifest.json: present, version 1.4.2
  - .gaia/local/setup-state.json: present, lastStep "rename"
  - package.json: present, name "gaia" (rename incomplete)
```

## Reproduction context

- `.claude/skills/gaia-init/SKILL.md`
- `.gaia/cli/templates/init/post-init.sh`
