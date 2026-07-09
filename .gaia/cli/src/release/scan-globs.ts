/**
 * Top-level directories `gaia-maintainer release runtime-deps` walks for
 * shipped `.sh` files (recursing into nested subdirectories, collecting
 * `*.sh` only). `.gaia/cli/templates` currently has zero `.sh` files (only
 * `*.tmpl`); this entry future-proofs any future `.sh` landing under
 * templates. Template CONTENT leaks (`.tmpl`, any extension) are a separate
 * concern owned by the scrub `maintainer-paths` check in
 * `.gaia/release-scrub.yml`, whose scope includes `.gaia/cli/templates/**`
 * and scans file content regardless of extension.
 *
 * Its own leaf module, imported by both `runtime-deps.ts` and
 * `manifest.ts`'s `lintScanScopes`, so the two never drift and neither file
 * has to import the other (both already import from / are imported by
 * `manifest.ts` elsewhere, and a two-way edge there would risk a
 * circular-import TDZ failure since `runtime-deps.ts` dereferences its
 * `manifest.ts` import at module top level).
 */
export const SCAN_GLOBS = [
  '.gaia/statusline',
  '.gaia/cli/templates',
  '.gaia/scripts',
  '.claude/hooks',
  '.github/actions',
  '.github/audit',
  '.specify/extensions/gaia/lib',
] as const;
