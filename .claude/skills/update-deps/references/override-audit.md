### Phase 0: Override audit

Each key in the top-level `overrides:` map in `pnpm-workspace.yaml` exists for one of two reasons: to resolve a **peer-dependency conflict**, or to enforce a **security floor** (pin a transitive dependency at or above a patched version to clear a known advisory). The two are detected by different tests, and an override is obsolete only when removing it regresses **neither**. A peer-dep test alone is blind to security-floor pins (a CVE pin never produces a peer-dep error), so it would wrongly delete every one of them. (pnpm 11 reads overrides here; the `package.json` `pnpm.overrides` field is no longer honored.)

**Capture the advisory baseline first**, with every override still in place:

```bash
pnpm audit --json 2>/dev/null | jq -r '.advisories // {} | keys[]?' | sort -u > /tmp/audit-baseline.txt
```

Each `.advisories` key is one advisory ID; this file is the set of advisories the current overrides tolerate. (If a future pnpm emits the `vulnerabilities` shape instead of `advisories`, read whichever key is present, the goal is a stable ID set to diff against.)

Then, for each override key, one at a time, leaving every other `pnpm-workspace.yaml` setting untouched:

1. Temporarily remove that single key from the `overrides:` map.
2. Run `pnpm dedupe`. A bare `pnpm install`, even `pnpm install --force`, short-circuits with "Already up to date" when only the `overrides:` map changed and leaves the lockfile untouched, so the toggle would not re-resolve and the test below would read the stale tree; `pnpm dedupe` performs a full install that re-resolves and applies the override change. See `wiki/dependencies/pnpm-overrides.md`. If it exits non-zero, restore the key, note as **retained (install error)**, and move to the next key, do not diagnose the failure or run the tests below for this key.
3. **Peer-dep test:** run `pnpm ls 2>&1` and scan for peer-dep errors.
4. **Security-floor test:** run `pnpm audit --json` and extract its advisory IDs the same way. Any ID present now but absent from `/tmp/audit-baseline.txt` means removing this override reintroduced a known vulnerability.

   ```bash
   pnpm audit --json 2>/dev/null | jq -r '.advisories // {} | keys[]?' | sort -u > /tmp/audit-now.txt
   comm -13 /tmp/audit-baseline.txt /tmp/audit-now.txt   # IDs this removal introduced
   ```

5. Decide:
   - Peer-dep errors **or** any newly introduced advisory → the override is load-bearing. Restore the key. Note as **retained** (record which test failed, and the advisory ID + package if it was the security-floor test).
   - Neither regressed → the override is obsolete. Leave it removed. Note as **removed**.

The security-floor test is **severity-agnostic on purpose**: an override is a deliberate maintainer artifact, so any advisory it was silencing, at any severity, is reason to keep it. This is intentionally stricter than the high/critical surfacing floor in the Noise scoping section of `wiki/dependencies/pnpm-audit.md`: deciding whether to *delete a maintainer's pin* warrants more caution than deciding whether to *surface* an advisory for review. A maintainer who wants a pin gone removes it by hand.

**After the toggle loop, assert the lockfile matches config.** Once every retained key is restored, the lockfile's top-level `overrides:` block must list exactly the keys present in the `overrides:` map in `pnpm-workspace.yaml`. Compare the two; on any drift (a config key missing from the lockfile block, or vice versa) the floor is unapplied, so run `pnpm dedupe` once more and re-run the quality gate. This assertion guarantees that every retained floor is applied, never silently disabled. It says nothing about whether a floor is current. Note the tradeoff: `pnpm dedupe` re-optimizes the whole tree, so a single toggle can yield a wider lockfile diff than the one key it touched (it may also drop now-redundant transitives). That broader diff is expected, and correct, the alternative is an unapplied override.

### Quality gate

```bash
pnpm typecheck
pnpm lint
pnpm test --run
pnpm pw
pnpm build
```
