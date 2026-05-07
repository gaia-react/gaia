---
spec_id: SPEC-999
type: feature
status: implemented
immutable: false
wiki_promote_default: yes
wiki_promote_targets:
  - decisions
  - concepts
intent: |
  Synthetic SPEC fixture for the wiki-promote smoke. Exists only so
  downstream tests have a frontmatter shape to load. Not a real SPEC.
success_criteria:
  - The fixture parses as YAML.
  - The fixture exposes the two SPEC-004 frontmatter fields the wiki-promote
    command body reads (`wiki_promote_default`, `wiki_promote_targets`).
uats:
  - uat_id: UAT-FIXTURE-001
    summary: Smoke-fixture marker UAT.
    given: This fixture file exists.
    when: A smoke harness loads it.
    then: Frontmatter parses and the two wiki-promote fields are present.
tags:
  - smoke
  - wiki-promote
---

# Synthetic wiki-promote smoke fixture

Used by `.gaia/tests/smoke/wiki-promote/run.sh` and any downstream test that needs a SPEC with `wiki_promote_default: yes` and a multi-target `wiki_promote_targets` list.

## Intent

Promotes nothing. This SPEC is fictional — it exists to give the smoke harness a SPEC artifact shape it can read without touching a real `.gaia/local/specs/SPEC-NNN.md` entry.

## Composition with SPEC-001 architecture

None. The fixture intentionally references no contracts so it cannot drift against SPEC-001.

## Notes

- `spec_id` is `SPEC-999` — outside the live SPEC numbering window.
- `wiki_promote_targets` lists `decisions` and `concepts` so the wiki-promote routing logic (Step 4) sees a multi-target case and the `## Related` sibling-wikilink branch (Step 5b §5) is exercised.
