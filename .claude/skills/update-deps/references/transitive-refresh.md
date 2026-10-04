### Transitive refresh instructions

Operate on the root workspace and its `frontend` package only: run every `pnpm` command from the repository root, never with `-r` or `cd`; `-C frontend` is the one allowed path argument. Frozen names: `{FROZEN_NAMES}`.

1. **Snapshot** the three files the refresh could touch, and the direct dependencies' resolved versions:
   ```bash
   mkdir -p /tmp/update-deps-refresh
   mkdir -p /tmp/update-deps-refresh/frontend
   cp frontend/package.json /tmp/update-deps-refresh/frontend/
   cp package.json pnpm-lock.yaml pnpm-workspace.yaml /tmp/update-deps-refresh/
   pnpm -C frontend ls --depth 0 --json | jq '.[0] | (.dependencies // {}) + (.devDependencies // {}) | map_values(.version)' > /tmp/update-deps-refresh/direct.json
   ```
2. **Refresh:**
   ```bash
   pnpm -C frontend update --no-save
   ```
   `--no-save` leaves every range in `package.json` as declared, so direct specs stay with Waves A and B; pnpm's default depth is unlimited, so this re-resolves the whole tree. Do not pass `--depth Infinity`: pnpm takes only an integer depth and exits on that value. Do not use `pnpm update --latest` (it ignores ranges) or `pnpm dedupe` (it moves a transitive only when that removes a duplicate). pnpm applies `minimumReleaseAge` while it resolves, so no version younger than the window lands; never add a `minimumReleaseAgeExclude` entry or change any setting to get a version through. If the command exits non-zero, revert (step 6) with reason `install error: <first error line>`.
3. **Check what it touched.**
   - `package.json`, `frontend/package.json`, and `pnpm-workspace.yaml` must be byte-identical to the snapshot (`cmp`). A difference means pnpm rewrote a range or recorded a release-age exemption: revert with reason `rewrote <file>`.
   - Re-run the step 1 `pnpm -C frontend ls` line into `/tmp/update-deps-refresh/direct-after.json` and compare each frozen name's version with `direct.json`. A frozen name whose version changed means the refresh moved a held or snoozed package inside its range: revert with reason `moved frozen <name> (<from> -> <to>); pin it to an exact version in package.json to let the refresh run`.
4. **List what moved**, from the lockfile's `packages:` keys before and after:
   ```bash
   lock_keys() {
     awk '/^packages:/{p=1;next} /^[^ ]/{p=0} p && /^  [^ ]/{k=$0; sub(/^  /,"",k); sub(/:$/,"",k); gsub(/\047/,"",k); print k}' "$1" | sort -u
   }
   lock_keys /tmp/update-deps-refresh/pnpm-lock.yaml > /tmp/update-deps-refresh/keys-before
   lock_keys pnpm-lock.yaml > /tmp/update-deps-refresh/keys-after
   { comm -23 /tmp/update-deps-refresh/keys-before /tmp/update-deps-refresh/keys-after | sed 's/^/- /'; comm -13 /tmp/update-deps-refresh/keys-before /tmp/update-deps-refresh/keys-after | sed 's/^/+ /'; } |
     awk '{ i=match($2, /.@[^@]*$/); n=substr($2,1,i); v=substr($2,i+2); if ($1=="-") from[n]=(n in from ? from[n] ", " : "") v; else to[n]=(n in to ? to[n] ", " : "") v; seen[n]=1 }
          END { for (n in seen) printf "%s\t%s\t%s\n", n, (n in from ? from[n] : "(new)"), (n in to ? to[n] : "(removed)") }' | sort
   ```
   Each row is `package<TAB>from<TAB>to`; a package locked at several versions lists them comma-separated. Empty output means nothing moved: report `Nothing moved` and stop, there is nothing to gate.
5. **Quality gate**:
   ```bash
   pnpm typecheck
   pnpm lint
   pnpm test --run
   pnpm pw
   pnpm build
   ```
   On any failure, revert (step 6) with reason `quality gate failed: <step>`. No remediation pass: one gate run cannot say which of the moved packages broke it.
6. **Revert** restores the whole refresh, never part of it:
   ```bash
   cp /tmp/update-deps-refresh/package.json /tmp/update-deps-refresh/pnpm-lock.yaml /tmp/update-deps-refresh/pnpm-workspace.yaml .
   cp /tmp/update-deps-refresh/frontend/package.json frontend/package.json
   pnpm install --frozen-lockfile
   cmp pnpm-lock.yaml /tmp/update-deps-refresh/pnpm-lock.yaml
   ```

Report back: the outcome (`landed`, `Nothing moved`, or `Reverted (<reason>)`), the step 4 rows (for a revert, the rows that would have moved, when step 4 ran), and the quality gate results.
