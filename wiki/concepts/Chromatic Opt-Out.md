---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-05
tags: [concept, testing]
---

# Chromatic Opt-Out

Ask Claude to walk through the opt-out steps. The procedure involves uninstalling `chromatic`, deleting the GitHub workflow, the `frontend/.storybook/chromatic/` folder and `frontend/.storybook/modes.ts`, and updating `frontend/.storybook/preview.ts` to use `WrapDecorator` directly and drop `parameters.chromatic` and the `theme` global.

See [[Chromatic]] for the full removal flow.
