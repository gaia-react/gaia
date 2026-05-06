# UAT Divergence Policy

When the implementer turns a red Playwright UAT spec green, the test body inevitably has to bind abstract user-acceptance language ("the user sees a confirmation") to concrete UI surface (selectors, button labels, copy strings, route paths). Some of that binding is editable; some of it is not. This rule names the line.

## Contract

- **Cosmetic divergence** — selector text, button label, accessible-name strings, copy, role names, URL slugs, layout-only assertions: **editable** by the implementer. The PO authored the UAT against an idealized UI; the implementer reconciles it with the shipped UI. Edits to cosmetic surface stay in the spec file and require no SPEC reopen.
- **Logical divergence** — the user flow, the success criteria, the error-handling branch, the side-effect being asserted, the precondition, the post-state: **forbidden**. If the implementation cannot satisfy the UAT's logic as written, the spec is NOT edited. The implementer raises the divergence to the PO and the SPEC is reopened to refine the UAT. The hook re-fires on the next `/speckit-implement` and rewrites the spec from the corrected UAT.

## Skeleton

This file is a **stub** authored by SPEC-003 (`before_implement` Playwright UAT auto-write). It exists so that the inline header comment block in every generated spec file can reference a real path on disk rather than a dead link.

The **canonical owner** of this rule is the future verifier-side SPEC, which will define:

- The precise heuristics a verifier agent uses to classify an edit as cosmetic vs logical.
- The escalation procedure when classification is ambiguous.
- The audit trail kept on the SPEC when a UAT is edited post-render.
- Any tooling (lint rule, diff checker) that enforces the boundary mechanically.

Until that SPEC lands, the rule is the two **Contract** bullets above and nothing more. SPEC-003 does not own the canonical rule and must not expand this file beyond the contract surface.
