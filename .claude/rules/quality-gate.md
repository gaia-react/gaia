# Quality Gate

Before any `git commit` that touches source, run the Quality Gate - unless it has nothing to check (no staged `.ts|tsx|js|jsx|mjs|cjs|css` or gate-affecting config). When it applies, **read `wiki/decisions/Quality Gate.md` and run its steps as written; do not rely on a remembered gate.** The page is the source of truth for the steps, skip logic, and rationale. Fix all warnings before reporting. STOP and report before committing.
