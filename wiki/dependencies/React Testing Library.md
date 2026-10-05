---
type: dependency
status: superseded
package: '@testing-library/react'
role: integration-testing
created: 2026-04-20
updated: 2026-10-05
tags: [dependency, testing]
---

# React Testing Library

> Superseded. See [[Stories as Tests]]. GAIA ships no React Testing Library, `happy-dom` or `jsdom`: components and pages are tested by story play functions in headless Chromium, and hooks by `vitest-browser-react`. The page remains for an adopter who keeps the library as their own dependency.

An adopter's leftover `*.test.tsx` that imports the library runs in the `browser` Vitest project, in real Chromium. It needs its own render wrapper, `@testing-library/jest-dom` and `@testing-library/user-event` dependencies and setup, because GAIA supplies none of them. Converting the test to a story is the supported path; see [[Testing]].
