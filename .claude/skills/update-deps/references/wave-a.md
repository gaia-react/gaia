### Wave A input

You are given the **Wave A apply set**: the `wave_a` entries from the
orchestrator's discovery, minus any group the human chose to skip. Each entry
carries `name`, `current`, `latest`, `is_pinned`, and `kind` (`minor` or
`patch`). Do **not** run `pnpm outdated` or re-discover, the ESLint 9.x cap, the
release-age cooldown, and companion-group expansion are already applied. If the
Wave A apply set is empty, skip straight to the quality gate (Wave B groups, if
any, are handled by the orchestrator).

### Wave A (batch minor/patch)

1. Build install args. For each entry: if `is_pinned` use the exact target, else use `^<latest>`. Example: `pnpm -C frontend add foo@1.2.3 bar@^4.5.0 ...` (an entry declared in the root `package.json` goes through `pnpm add -w` instead).
2. Run the single `pnpm -C frontend add` command (plus one `pnpm add -w` for any root-declared entries). If `msw` is in the batch, then run `pnpm -C frontend msw:init` (`pnpm -C frontend exec msw init` when the project has no such script) to regenerate `frontend/public/mockServiceWorker.js`.
3. Run `pnpm ls 2>&1`. Scan for peer-dep errors.
4. On error: try one targeted fix in the `overrides:` map in `pnpm-workspace.yaml` (e.g. add a `parent>child` pin), then `pnpm dedupe` to apply it, a bare `pnpm install` won't re-resolve an overrides-only change.
5. If still failing: revert the offending packages (`pnpm -C frontend add <pkg>@<previous>`, or `pnpm add -w` for a root-declared package) and log them as **skipped** with the reason.
6. Run the quality gate in override-audit.md. If it fails, revert the entire Wave A batch.

### Return value

Report back to the orchestrator with:

- Override audit results (removed / retained)
- Wave A results (updated packages, any skipped)
- For each entry the orchestrator marked as a security chain-head bump: landed, skipped, or reverted with the batch (the orchestrator then checks whether its advisory cleared)
- Quality gate results
