# `.gaia/tests/prose-audit/`

UAT-007's verification harness for the prose-complexity audit lens. This is a
**best-effort, gated manual dry-run** for a judgment call, not a deterministic
CI check: the finding is holistic ("this prose is gratuitously long/nested"),
so there is no oracle to script against and no pass/fail assertion to automate.
A maintainer drives it by hand when the lens changes and reads the output for
plausibility, the same latitude every other judgment-lens harness in this repo
takes.

## Fixtures and expected outcomes

- `fixtures/gratuitous.md` — the true-positive fixture. Its "Branch Naming
  Rules" section and "Picking a Good Name for Your Branch" section state the
  same rule twice in different words; nothing in the second section adds
  information the first didn't already carry. The expected outcome is at
  least one finding that names the concrete reduction (cut the second
  section, it repeats the first), mapped to `prose/redundant-instruction`.
- `fixtures/intricate.md` — the false-positive-discipline fixture. Its
  decision procedure for classifying a failed CI run branches five ways, and
  every branch carries a distinct, load-bearing action (retry once vs. pin a
  version vs. fix code vs. quarantine); no branch restates another, and none
  can be cut or flattened without losing a real distinction. The expected
  outcome is a clean pass, zero findings. This is what the Finding Proof
  Gate's false-positive discipline is for: length and nesting alone are not
  findings, only reducible length and nesting are.

## Self-skip scenario

A third best-effort scenario: drive the member against a diff that touches no
`.claude/skills/**/*.md` file. The expected outcome is the member's specific
one-line "no changed file fell in my remit" note, with no marker written, no
stamp, no status post, and no findings sidecar. Nothing else in this plan
exercises the empty-remit path, since the delivering pull request's
`.claude/skills/gaia/references/harden.md` edit is itself in-remit and
dispatches the member live; this scenario is the only place the clean
self-skip gets verified.

## How to drive the dry run

Spawn the `code-audit-maintainer-prose` member (or apply its methodology
directly from `.claude/agents/code-audit-maintainer-prose.md` if dispatch
isn't convenient), pointed at the two fixtures by path rather than by diff.
Driving it by path bypasses remit filtering deliberately, since the fixtures
don't live on a `.claude/skills/**/*.md` path (see below); a live PR diff is
what exercises the remit filter itself. Compare the outcome against the
expected outcomes above: findings on `gratuitous.md` that name a concrete
reduction, a clean pass on `intricate.md`, and the one-line self-skip note
when pointed at an out-of-remit diff.

## Fixture placement rationale

UAT-007 describes fixtures living under a `.claude/skills/**/*.md` path. This
harness stores them under `.gaia/tests/prose-audit/` instead, maintainer-only,
and drives the member against them by path. Reasoning:

- A skills-prose fixture living under `.claude/skills/` would ship to every
  adopter and would permanently sit inside the member's remit on every future
  pull request, a synthetic test file competing for review attention forever.
- `.gaia/tests/` is release-excluded from the adopter tarball and carries no
  file-ownership claim from any Code Audit Team member, so fixtures here stay
  maintainer-only test artifacts that never pollute the live audited surface.
- The fixture content is still authored skills-reference-shaped (heading
  structure, instruction prose, the same register as a real
  `.claude/skills/gaia/references/*.md` file), so the dry-run reads the lens
  against realistic input even though the file path itself is relocated.

## Mapping back to UAT-007

A reviewer checking UAT-007 against the delivered tree should read it as two
halves, each covered by a different mechanism:

- **True-positive / false-positive discipline** — covered by this harness.
  The fixtures under `.gaia/tests/prose-audit/` are not on a live
  `.claude/skills/**/*.md` path, so they are driven by-path rather than
  picked up by remit filtering, but they exercise exactly the judgment call
  UAT-007 is testing: does the lens name a concrete reduction on genuinely
  reducible prose, and does it stay silent on genuinely irreducible prose.
- **`.claude/skills/**/*.md` remit pickup** — covered elsewhere, not by these
  fixtures. The delivering pull request's own `harden.md` edit is a real,
  live `.claude/skills/**` change, so it dispatches `code-audit-maintainer-prose`
  through the normal remit filter at merge, and the roster's `globs` entry for
  the member is the ownership assertion that any `.claude/skills/**/*.md` file
  routes to it. Together those two cover the half this harness intentionally
  does not.

## Complementary to the live run

The delivering pull request exercises the member twice, in two different
modes: this harness is the curated, by-path true/false-positive discipline
check described above, and the `harden.md` change under `.claude/skills/**`
separately triggers a real, remit-filtered dispatch of the member at merge
time. Neither substitutes for the other: the harness controls exactly what
the fixtures contain so the discipline check is unambiguous, while the live
run proves the remit filter itself picks the member up on real input.
