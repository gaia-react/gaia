---
spec_id: SPEC-099
type: feature
status: in-progress
immutable: false
intent: |
  Sandbox SPEC for smoke-testing the before_implement UAT-write hook. Not a real
  feature; deliberately tiny so the renderer can be exercised end-to-end without
  contaminating the real SPEC archive. Three concrete UATs, one per renderer
  branch (write / rewrite / delete).
success_criteria:
  - The renderer writes one Playwright spec file per UAT under .playwright/e2e/spec-099/.
  - All three rendered tests fail as assertions (not parse errors) when run against an unimplemented codebase.
  - Re-running the renderer on this SPEC unchanged produces zero file diffs.
uats:
  - uat_id: UAT-001
    given: The user is on the home page at "/".
    when: The user clicks the "Sign in" button.
    then: The page navigates to "/sign-in" and a heading reading "Sign in" is visible.
  - uat_id: UAT-002
    given: A signed-in user on the dashboard at "/dashboard".
    when: The user clicks the "Log out" link in the header.
    then: The page navigates to "/" and the "Sign in" button is visible again.
  - uat_id: UAT-003
    given: A user on the help page at "/help".
    when: The user types "billing" into the search box and presses Enter.
    then: A results list appears containing a link with text "Billing FAQ".
open_questions: []
dependencies:
  - Sandbox only; depends on nothing real.
---

# Sandbox SPEC for smoke testing

This SPEC exists solely to exercise the `before_implement` UAT-write hook
during the SPEC-003 smoke runbook. It is not a real product feature. Delete
or relocate after smoke verification completes.

The three UATs cover the basic write/rewrite/delete cycle:

- UAT-001 — concrete URL + quoted button text → renders normally
- UAT-002 — same shape; used as the "rewrite" target in UAT-003b
- UAT-003 — same shape; used as the "delete" target in UAT-004

To exercise the abstraction heuristic for UAT-007, mutate UAT-001's `then:`
clause to remove all quoted strings and URL fragments — see the UAT-007
smoke step.
