---
type: decision
status: active
created: 2026-10-03
updated: 2026-10-03
tags: [decision, claude, skills]
---

# Decision: Vendored Third-Party Skills

GAIA vendors a third-party skill byte-identical to the folder its upstream package publishes, records the vendored version in a GAIA-owned marker, and keeps every word of GAIA's own guidance outside the vendored folder. Updating a vendored skill means re-vendoring the next upstream version, never patching the copy.

## Context

A skill authored by someone else changes with every upstream release: sections move, commands are renamed, whole reference files appear and disappear. A copy GAIA edits by hand turns each upgrade into a three-way merge between upstream's rewrite and GAIA's patches, and a stray patch can hide inside the diff. [[Claude Skills]] describes the skills GAIA authors; this page covers the ones it borrows. The first is the playwright-cli skill under `frontend/.claude/skills/playwright-cli/`.

## Decision

- **Byte-identical copy.** The vendored folder is the upstream package's published skill folder, unmodified. GAIA does not reword it, add to it, or delete files from it.
- **A version marker per skill.** Each vendored skill has a GAIA-owned JSON marker under `.gaia/vendor/`, and that directory is the list of vendored skills. A marker records the upstream package, the version, the tarball integrity, the vendored folder it governs, and a sha256 for every file in it. The marker ships with the skill, so an adopter can read which upstream version they hold.
- **GAIA guidance lives in GAIA-owned files.** What GAIA adds about a vendored skill (which invocation to prefer, how to install the tool, traps to avoid) goes in a wiki page or rule GAIA owns. For playwright-cli that page is [[playwright-cli]]. Nothing GAIA wrote sits inside a vendored folder.
- **Never edited by hand, exempt from GAIA style.** A vendored folder is exempt from GAIA's formatting, because the package's `.prettierignore` lists it, and from the no-em-dash rule, because rewording upstream prose would break the byte-identical copy. A change that looks needed is made upstream or in the GAIA-owned guidance instead.
- **Updates re-vendor.** A new upstream version replaces the folder wholesale and rewrites the marker. For playwright-cli this is a maintainer-only `/update-deps` phase.

<!-- gaia:maintainer-only:start -->
A maintainer-only offline check recomputes every file's sha256 against its marker and fails on a changed, added, or removed file, with no network. It runs in CI, so a hand edit to a vendored folder fails the build rather than drifting in unnoticed. The re-vendor phase fetches the published tarball, verifies its integrity against the registry before writing anything, and replaces the folder and marker together; re-vendoring the same version over an untouched folder produces no diff.
<!-- gaia:maintainer-only:end -->

## Why

Upstream rewrites drift every release, so a patched copy makes each upgrade a hand merge. Keeping GAIA's text out of upstream's files makes an upgrade mechanical: replace the folder, rewrite the marker, and the diff shows exactly what upstream changed. The marker and the offline check make drift visible instead of silent, and the integrity check means a re-vendored copy is the package's published bytes, not whatever a mirror served.

## Related

- [[Claude Skills]]: the skills GAIA authors.
- [[playwright-cli]]: the first vendored skill and GAIA's guidance for it.
