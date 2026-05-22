## Symptom

update conflict in .claude/hooks/wiki-session-stop.sh — the three-way merge failed after running /update-gaia. The conflicting file has both GAIA upstream changes and local customizations that overlap.

## Classification

class: update
evidence: "update conflict" + .claude/hooks/wiki-session-stop.sh

## Capture

gaia_version: 1.2.0
node: v20.11.0
pnpm: 8.15.4
claude_code: 1.0.0
branch: main
dirty: true
class_state_files:

- .gaia/manifest.json: present, version 1.2.0
- .claude/hooks/wiki-session-stop.sh: conflict marker present

## Reproduction context

The user ran /update-gaia to pull in the latest GAIA template changes. A merge conflict appeared in .claude/hooks/wiki-session-stop.sh because the upstream changed the hook structure while the user had added a custom notification block. The three-way merge could not resolve the overlap automatically.
