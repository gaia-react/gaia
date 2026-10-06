---
spec_id: SPEC-002
type: feature
status: in-progress
immutable: true
wiki_promote_default: yes
chain_trigger: gaia-plan
lineage: []
intent: |
  A signed-in reader can pin a saved article so it stays at the top of their
  reading list across devices.
success_criteria:
  - A pinned article appears first in the reading list after a reload.
uats:
  - uat_id: UAT-001
    given: A signed-in reader with three saved articles.
    when: The reader pins the second article.
    then: The second article is listed first in the reading list.
scope_boundaries:
  always:
    - Keep the pinned order stable across reloads.
  ask_first:
    - Pin more than ten articles at once.
  never:
    - Reorder articles the reader did not pin.
clarifications:
  answered:
    - q: Is there a pin limit?
      a: No limit beyond the reading list size.
  pending: []
research_summary: |
  No prior art in the repository; the reading list is a plain ordered list.
created: 2026-01-01
updated: 2026-01-01
---

# Pin saved articles

## One-line summary

Readers can pin a saved article to keep it at the top of their reading list.
