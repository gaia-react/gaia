---
paths:
  - '.gaia/cli/health/**/*.sh'
  - '.gaia/cli/src/**/*.ts'
  - '.gaia/cli/test-fixtures/**/*.sh'
  - '.gaia/tests/**/*.sh'
---

# Guard and Diagnostic Rules on the Maintainer-Only Surfaces

Two shipped rules govern how a guard is written and how a diagnostic names its causes:

- `.claude/rules/guards-must-fail.md`, on the three stages at which a guard silently loses the ability to go red.
- `.claude/rules/partial-cause-reporting.md`, on a branch reachable from several conditions whose message admits to one of them.

**Read both before writing or changing a guard or a diagnostic here.** Their guidance applies on these surfaces in full, and neither rule's own text reaches you on them: a `paths:` glob loads the file carrying it and nothing else, so both arrive as this pointer instead. Carrying that pointer to the surfaces their own `paths:` cannot name is the whole of this file's job: the CLI source and its test suites under `.gaia/cli/src/**`, the health-audit depth gauge under `.gaia/cli/health/**` and the CI-shape smoke harness under `.gaia/cli/test-fixtures/**`, and the bats harness scripts under `.gaia/tests/**`. Every directory named above is release-excluded, and the shipped-surface leak check forbids a file an adopter receives from referencing a path their clone does not have, so the globs live here instead of there.

**The `.gaia/cli/` globs name those subtrees rather than the directory, and the narrowness is the point.** `.gaia/cli/` is only partly release-excluded: the bundled `gaia` binary and `.gaia/cli/templates/` both ship. A blanket `.gaia/cli/**/*.sh` here would therefore claim shipped territory on a maintainer-only justification, and the way that fails is quiet: a shell file added under `templates/` later would read as already governed, this file's coverage check would agree, and the adopter receiving it would have neither shipped rule. Named subtrees make that case red instead, which sends the glob to the shipped rules where it belongs.

That split is why the two rules' `paths:` lists are not derived from "every shipped shell surface" but stay explicit on both sides of it. `.gaia/scripts/lint-guard-rule-shell-coverage.sh` is what keeps them honest: it fails when a tracked shell file is reached by neither the shipped pair nor this file, so a new shell directory reds on the pull request that adds it rather than surfacing an audit round later. A glob added here counts as coverage for both shipped rules, because this pointer carries both.

Nothing else is scoped to this file. It carries no provenance marker: the markers for the promoted classes stay in the two shipped rules, where the coverage scan reads them.
