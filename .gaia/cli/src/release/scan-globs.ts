/**
 * Top-level directories `gaia-maintainer release runtime-deps` walks for
 * shipped `.sh` files (recursing into nested subdirectories, collecting
 * `*.sh` only). `.gaia/cli/templates` currently has zero `.sh` files (only
 * `*.tmpl`); this entry future-proofs any future `.sh` landing under
 * templates. Template CONTENT leaks (`.tmpl`, any extension) are a separate
 * concern owned by the scrub `excluded-refs` check in
 * `.gaia/release-scrub.yml`, whose `**` scope includes `.gaia/cli/templates/**`
 * and scans file content regardless of extension.
 *
 * Its own leaf module, imported by `runtime-deps.ts` and by the
 * `runtime-deps.test.ts` fixture that holds every owned `.sh` file in the
 * committed manifest to these globs.
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
