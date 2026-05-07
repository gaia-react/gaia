# UAT Divergence Policy

When the implementer turns a red Playwright UAT spec green, the test body inevitably has to bind abstract user-acceptance language ("the user sees a confirmation") to concrete UI surface (selectors, button labels, copy strings, route paths). Some of that binding is editable; some of it is not. This rule names the line.

## Contract

- **Cosmetic divergence** — selector text, button label, accessible-name strings, copy, role names, URL slugs, layout-only assertions: **editable** by the implementer. The PO authored the UAT against an idealized UI; the implementer reconciles it with the shipped UI. Edits to cosmetic surface stay in the spec file and require no SPEC reopen.
- **Logical divergence** — the user flow, the success criteria, the error-handling branch, the side-effect being asserted, the precondition, the post-state: **forbidden**. If the implementation cannot satisfy the UAT's logic as written, the spec is NOT edited. The implementer raises the divergence to the PO and the SPEC is reopened to refine the UAT. The hook re-fires on the next `/speckit-implement` and rewrites the spec from the corrected UAT.

## Scope

This rule defines only the cosmetic/logical contract above. Heuristics for classifying ambiguous edits, escalation procedure, post-render audit trail, and any mechanical enforcement (lint, diff checker) are out of scope and belong to the verifier surface, not this rule.
