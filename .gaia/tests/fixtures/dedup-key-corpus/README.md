# Dedup-key corpus (SPEC-082, Phase 1)

Fixtures for the reader-set conformance work in
`.gaia/local/specs/SPEC-082/plan/task-conformance-suite.md` and
`task-doc-fence-suites.md`. This phase writes test data only; it changes no
reader and no production pattern. Everything here is green against the tree
as captured and stays green once Phase 2 moves the grammar.

## Deliverable 1: `recorded-keys.txt` (UAT-009)

Every distinct dedup-key **line** present in open/closed tech-debt issue
bodies and merged pull-request bodies, captured once against live GitHub
state before the grammar changed.

Commands run, verbatim:

```bash
gh issue list --label tech-debt --state all --json number,body --limit 2000 \
  --jq '.[] | (.body // "") | split("\n")[] | select(test("<!-- gaia-debt-key:"))'
gh pr list --state merged --limit 2000 --json number,body \
  --jq '.[] | (.body // "") | split("\n")[] | select(test("<!-- gaia-debt-key:"))'
```

The first returned 716 lines, the second 65, for 781 lines combined.
Concatenated and `sort -u`'d, 773 distinct lines remained.

### Exclusion applied

Two lines were dropped, not one. The task brief names issue #2048 (the issue
this SPEC answers) as carrying a prose sentence that quotes the grammar
itself, and that line was found and dropped:

```
    key_re='<!-- gaia-debt-key: v1 class=[^ ]+ path=[^ ]+ line=[0-9]+ -->'
```

A second line meeting the identical criterion (`path=` value is a regex
literal rather than a path) was found in a different issue, #1118, not named
in the task brief:

```
$ jq -r 'capture("<!-- gaia-debt-key: v1 class=(?<class>[^ ]+) path=(?<path>[^ ]+) line=(?<line>[0-9]+) -->") // "NULL"'
```

Both are wrapped `<!-- gaia-debt-key: ... -->` comments whose own `path=`
field is a regex character class (`[^ ]+` and `(?<path>[^ ]+)`
respectively), not a real path, so both meet the stated criterion exactly.
The general rule ("drop any captured line whose `path=` value is a regex
literal rather than a path") was applied as written rather than narrowed to
the one issue the brief happened to name; a targeted
`git grep -nE '<!-- gaia-debt-key:.*path=(\[\^|\(\?<)'` over the raw capture
confirms these are the only two matches.

`recorded-keys.txt` therefore holds 773 - 2 = **771** distinct key lines,
sorted and unique, every line containing the literal `<!-- gaia-debt-key:`.

### A third prose-quoting shape, found but NOT excluded (see Finding 1 below)

One further line quotes a fragment of the grammar (`` `path=(?<path>.+)` ``)
and separately mentions the literal opener (`` the `<!-- gaia-debt-key: v1 `
prefix ``) in running prose, **on the same line as a real, well-formed
trailing key** (`path=.gaia/tests/lib/doc-debt-query.bats line=101`). Its own
wrapped key's `path=` field is a real path, not a regex literal, so it does
not meet the stated exclusion criterion and was kept. Its effect on the
`lenient` group's classification is reported under Finding 1.

## Deliverable 2: `classification.tsv` (UAT-009)

One old/new column-pair group per modelled consumer, not one derived from
the gate alone:

| group | models | pre-change spelling | post-change spelling |
|---|---|---|---|
| `gate` | the line-scoped strict readers (the gate's `key_re`, `KEY_PATTERN`, the merge-workflow query) | `<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^ ]+ line=[0-9]+) -->` | `<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->` |
| `waive` | the line-scoped narrowing reader (the machinery-waive validator) | `^v1 class=[^[:space:]]+ path=.+ line=[0-9]+$` | `^v1 class=[^[:space:]]+ path=[^>]+ line=[0-9]+$` |
| `lenient` | the body-scoped narrowing readers (`LENIENT_KEY_PATTERN`, the filer jq scan, `debt.md`'s capture) | `<!-- gaia-debt-key:[^>]*?path=(.+?) line=` | `<!-- gaia-debt-key:[^>]*?path=([^>\n]+) line=` |

### Methodology

- **`gate`** runs its pre/post spelling, expanded with three capture groups
  (class, path, line), **unanchored, directly against the raw key line** —
  this matches how `KEY_PATTERN`/the gate's `key_re` actually operate today
  (no `^$` anchors), so surrounding backticks, bullets, or prose around the
  wrapped comment do not block a match.
- **`waive`** runs its pre/post spelling **anchored (`^...$`), against a
  ground-truth-extracted inner key**, because the machinery-waive validator's
  real subject is an already-unwrapped sidecar key, never the wrapped comment
  or the prose around it. The ground-truth
  extraction anchors on the **last** literal `<!-- gaia-debt-key:` occurrence
  in the line (not the first) through the first ` -->` that follows it; every
  row but one in this corpus carries exactly one such occurrence, so this
  choice changes nothing for them (see Finding 1 for the one row it matters
  to).
- **`lenient`** runs its pre/post spelling **unanchored, directly against the
  raw key line**, matching how `LENIENT_KEY_PATTERN`/the filer scan/`debt.md`'s
  capture are actually used, over whole raw body text.
- `line_eq_count` and `path_eq_count` are counted over the same
  ground-truth-extracted inner key text the `waive` group uses (i.e. scoped
  to the key comment itself, not to any prose elsewhere on the corpus line).

Generated with this script (run from the repo root with Node 24):

```js
#!/usr/bin/env node
// Builds .gaia/tests/fixtures/dedup-key-corpus/classification.tsv from
// recorded-keys.txt. One row per distinct key line.
'use strict';

const fs = require('fs');

// Run from the repo root.
const IN = '.gaia/tests/fixtures/dedup-key-corpus/recorded-keys.txt';
const OUT = '.gaia/tests/fixtures/dedup-key-corpus/classification.tsv';

const lines = fs.readFileSync(IN, 'utf8').split('\n').filter((l) => l.length > 0);

// Ground-truth extraction of "the key comment": the LAST opener occurrence
// through the first subsequent literal " -->". Anchoring on the last opener
// (not the first) matters for exactly one row in this corpus, which carries
// two literal "<!-- gaia-debt-key:" occurrences on one line (a prose mention
// of the opener prefix, then the real trailing key); anchoring on the first
// occurrence would span the extraction across the intervening prose to the
// real key's own closer. Every other row carries exactly one occurrence.
function groundTruthInner(line) {
  const openerIdx = line.lastIndexOf('<!-- gaia-debt-key:');
  if (openerIdx === -1) return null;
  const afterOpener = openerIdx + '<!-- gaia-debt-key:'.length;
  const closerIdx = line.indexOf(' -->', afterOpener);
  if (closerIdx === -1) return null;
  return line.slice(afterOpener, closerIdx).trim();
}

// gate group: unanchored, run directly against the raw key_line.
const GATE_OLD = /<!-- gaia-debt-key: v1 class=([^ ]+) path=([^ ]+) line=([0-9]+) -->/;
const GATE_NEW = /<!-- gaia-debt-key: v1 class=([^ ]+) path=([^>]+) line=([0-9]+) -->/;

// waive group: anchored, run against the ground-truth-extracted inner key.
const WAIVE_OLD = /^v1 class=[^ \t]+ path=(.+) line=([0-9]+)$/;
const WAIVE_NEW = /^v1 class=[^ \t]+ path=([^>]+) line=([0-9]+)$/;

// lenient group: body-scoped, run directly against the raw key_line.
const LENIENT_OLD = /<!-- gaia-debt-key:[^>]*?path=(.+?) line=/;
const LENIENT_NEW = /<!-- gaia-debt-key:[^>]*?path=([^>\n]+) line=/;

function testAnchored(re, text) {
  if (text === null) return {parses: 0, path: '-', line: '-'};
  const m = re.exec(text);
  if (!m) return {parses: 0, path: '-', line: '-'};
  return {parses: 1, path: m[1], line: m[2]};
}

function testUnanchored(re, text) {
  const m = re.exec(text);
  if (!m) return {parses: 0, path: '-', line: '-'};
  return {parses: 1, path: m[2], line: m[3]};
}

function testLenient(re, text) {
  const m = re.exec(text);
  if (!m) return {parses: 0, path: '-'};
  return {parses: 1, path: m[1]};
}

const header = [
  'key_line', 'contains_gt', 'line_eq_count', 'path_eq_count',
  'gate_old_parses', 'gate_new_parses', 'gate_old_path', 'gate_new_path', 'gate_old_line', 'gate_new_line',
  'waive_old_parses', 'waive_new_parses', 'waive_old_path', 'waive_new_path',
  'lenient_old_parses', 'lenient_new_parses', 'lenient_old_path', 'lenient_new_path',
].join('\t');

const rows = [header];

for (const line of lines) {
  const inner = groundTruthInner(line);
  const lineEqCount = inner === null ? 0 : (inner.match(/ line=/g) || []).length;
  const pathEqCount = inner === null ? 0 : (inner.match(/path=/g) || []).length;

  const gateOld = testUnanchored(GATE_OLD, line);
  const gateNew = testUnanchored(GATE_NEW, line);
  const waiveOld = testAnchored(WAIVE_OLD, inner);
  const waiveNew = testAnchored(WAIVE_NEW, inner);
  const lenientOld = testLenient(LENIENT_OLD, line);
  const lenientNew = testLenient(LENIENT_NEW, line);

  let canonicalPath = null;
  if (gateNew.parses) canonicalPath = gateNew.path;
  else if (waiveOld.parses) canonicalPath = waiveOld.path;
  else if (lenientOld.parses) canonicalPath = lenientOld.path;
  const containsGt = canonicalPath !== null && canonicalPath.includes('>') ? 1 : 0;

  rows.push([
    line, containsGt, lineEqCount, pathEqCount,
    gateOld.parses, gateNew.parses, gateOld.path, gateNew.path, gateOld.line, gateNew.line,
    waiveOld.parses, waiveNew.parses, waiveOld.path, waiveNew.path,
    lenientOld.parses, lenientNew.parses, lenientOld.path, lenientNew.path,
  ].join('\t'));
}

fs.writeFileSync(OUT, rows.join('\n') + '\n');
```

### Results

- **Distinct key lines** (the table's unit): **771**. Distinct paths among
  the 765 rows `gate_new` parses: **335**. Distinct `class|path|line`
  combinations among those same rows: **758**. These are three different
  numbers over this corpus, stated separately per the task's own warning
  against conflating them.
- `contains_gt` is **all zeros** (771/771) over this corpus: no captured
  path contains a literal `>`.
- `line_eq_count` distribution: **6** rows at 0 (no ` line=` token inside
  their ground-truth-scoped key comment — these are the malformed/prose-only
  lines below), **765** rows at 1. **Zero** rows carry more than one
  ` line=` token; see criterion 4a / Finding 2 for the scratch-file
  demonstration this does not exempt the divergence from being real.
- `path_eq_count` distribution: 6 rows at 0, 765 rows at 1 (scoped to the
  ground-truth key comment; the one row with two `path=` tokens anywhere on
  its raw line has only one inside its own key comment once correctly
  scoped — see Finding 1).
- The 6 rows carrying no `line=`/`path=` token are legitimate corpus noise:
  4 are prose sentences that merely mention `<!-- gaia-debt-key:` without
  real fields, and 2 are pre-`v1`-grammar malformed keys
  (`<!-- gaia-debt-key: .claude/skills/gaia/references/spec.md:319 -->` and
  `<!-- gaia-debt-key: code-review-audit.md:594 react-doctor-latest-pin -->`).
  All six correctly report `parses=0` for every group under both spellings.

### Criterion 3 (narrowing check, per group)

For every group, every row whose `contains_gt` is 0 and whose
`<group>_old_parses` is 1 must have `<group>_new_parses` 1 and a
byte-identical `<group>_new_path` (gate additionally: equal `gate_new_line`).

| group | checked | ok | fail |
|---|---|---|---|
| `gate` | 737 | 737 | 0 |
| `waive` | 765 | 765 | 0 |
| `lenient` | 765 | 764 | **1** |

`gate` and `waive` hold the invariant with zero exceptions. `lenient` has
**one** real exception, reported in full as Finding 1 below rather than
suppressed or waived away.

### Criterion 4 (gate widening)

Rows where `gate_old_parses` is 0 and `gate_new_parses` is 1: **28**. Rows
where the two columns differ in the other direction (`old`=1, `new`=0):
**0**. Every one of the 28 newly-parsing rows' `gate_new_path` contains a
space (0 mismatches). This is the SPEC's central claim, verified directly
over the real corpus: the parsing key-line count rises by exactly the number
of key lines carrying a spaced path.

### Criterion 4a (the lenient lazy-to-greedy divergence)

`line_eq_count > 1` occurs in **zero** rows of this corpus. Per the task's
own instruction, a zero count is not evidence the divergence is not real;
the body was constructed in a scratch file and both spellings run over it:

```
body: <!-- gaia-debt-key: v1 class=c path=app/a.ts line=1 line=2 -->

old (path=(.+?) line=):    match[1] = "app/a.ts"
new (path=([^>\n]+) line=): match[1] = "app/a.ts line=1"
```

This confirms the `line_eq_count` column would catch the divergence if this
corpus carried such a row; it currently does not.

## Finding 1: a third, single-line prose-decoy shape (`lenient` group only)

Beyond the one exclusion the task named (#2048) and the second instance of
the same exclusion criterion found independently (#1118, both dropped, see
above), the corpus contains a **third** shape that was found but does **not**
meet the stated exclusion criterion (its own wrapped key's `path=` is a real
path, not a regex literal), so it was **kept**:

```
- `.gaia/tests/lib/doc-debt-query.bats:101` — the suite asserts only dedup-key query *shape* (`capture(`, the `<!-- gaia-debt-key: v1 ` prefix), never parse behavior, and every fixture body uses a space-free path. Nothing in it would fail if this PR's `path=(?<path>.+)` widening regressed back to `[^ ]+`. `<!-- gaia-debt-key: v1 class=holistic/unclassified path=.gaia/tests/lib/doc-debt-query.bats line=101 -->`
```

This single line carries **two** literal `<!-- gaia-debt-key:` occurrences:
a prose mention of the opener prefix, and the real trailing key. The
`gate` and `waive` groups are unaffected (both land cleanly on the real
key: `gate` because its unanchored full-shape match cannot succeed against
the earlier prose fragment at all, `waive` because its ground-truth
extraction anchors on the *last* opener occurrence). The `lenient` group
**is** affected, because it runs unanchored directly against the raw line
exactly as the real readers do, and its match search starts from the
*first* opener occurrence:

```
old (path=(.+?) line=), first match from the FIRST opener:
  captures "(?<path>.+)` widening regressed back to `[^ ]+`. `<!-- gaia-debt-key: v1 class=holistic/unclassified path=.gaia/tests/lib/doc-debt-query.bats"
  (a garbled splice: the lazy capture group has no '>' exclusion, so it
  crosses through the '>' embedded in the prose fragment "(?<path>" and
  keeps going to the real key's own " line=101")

new (path=([^>\n]+) line=), same starting point:
  the FIRST-opener attempt fails outright: the greedy capture group DOES
  exclude '>', and the prose fragment "(?<path>" contains one right where
  capture would need to cross it, so the match cannot complete from that
  position. The engine advances to the SECOND (real) opener and matches
  cleanly there: captures ".gaia/tests/lib/doc-debt-query.bats"
```

So for this one row, `lenient_old` produces a **wrong, garbled** path and
`lenient_new` produces the **correct** one: the terminator change happens to
fix a latent splice bug in the old lenient reader, rather than regress
anything. This is the opposite of a narrowing violation, but it still trips
the mechanical byte-identity check in criterion 3's `lenient` row (a
genuinely differing path, not a mistake in the check), so it is reported as
the one real exception rather than folded into the `ok` count.

This shape (an unrelated, non-wrapped prose mention of the opener/a grammar
fragment, sharing one raw line with a real key) is different from both the
task's named exclusion (a full wrapped key whose own `path=` is a regex
literal) and from deliverable 4's multi-line decoy (a real key split across
a newline). It was not anticipated by the plan's own two "Plan-time
findings" and is surfaced here for Phase 3 to account for, not resolved
unilaterally: this phase does not invent a third exclusion criterion beyond
the one the task specified.

## Deliverable 3: `issue-1250-key.txt` (UAT-006)

```bash
gh issue view 1250 --json body --jq '.body' \
  | tr -d '\r' \
  | grep -nE '^<!-- gaia-debt-key: v1 .* -->$'
```

Returned **exactly one line** (criterion 7a):

```
1:<!-- gaia-debt-key: v1 class=holistic/unclassified path=wiki/concepts/PR Merge Workflow.md line=175 -->
```

Matches the shape stated in the task exactly. Written to the fixture with a
single trailing newline and nothing else.

## Deliverable 4: `multiline-decoy-body.txt` (UAT-013)

Guard-can-fail, run against the committed fixture:

```
=== old spelling path=([^>]+) line= ===
["a.ts line=\nprose\n<!-- gaia-debt-key: v1 class=real path=app/real.ts"]

=== new spelling path=([^>\n]+) line= ===
["a.ts", "app/real.ts"]
```

Old produces one spliced member spanning both lines and losing the real key;
new produces two members, the second of which is `app/real.ts`. Matches the
task's stated expectation exactly.

## Deliverable 5: `two-keys-one-line.md` / `two-keys-one-line-issues.json` (UAT-003)

Both spaced paths (`wiki/concepts/PR Merge Workflow.md`,
`wiki/concepts/Task Orchestration.md`) verified to exist in the tree via
`git ls-files --error-unmatch`.

Guard-can-fail, the current `debt.md` jq capture run against
`two-keys-one-line-issues.json`:

```json
{
  "class": "a",
  "path": "wiki/concepts/PR Merge Workflow.md line=7 --> and <!-- gaia-debt-key: v1 class=b path=wiki/concepts/Task Orchestration.md",
  "line": 9
}
```

The path is spliced across both keys, and the **second** key's line number
(9) attaches to the **first** key's class (`a`), exactly as the task
predicted. This is the red Phase 2's edit repairs and Phase 3 pins.

## Deliverable 6: `backlog.json` append (MIG-013)

Appended issue #105 (`severity:suggestion`, `createdAt` 2026-01-05, one day
after the latest existing entry #104) whose key cites
`path=wiki/concepts/PR Merge Workflow.md line=175`, a single key with a
single ` line=` token, so it parses identically under `debt.md`'s current
greedy `.+` and the post-change `[^>\n]+`:

```
old: {"class":"holistic/unclassified","path":"wiki/concepts/PR Merge Workflow.md","line":"175"}
new: {"class":"holistic/unclassified","path":"wiki/concepts/PR Merge Workflow.md","line":"175"}
```

`.gaia/tests/lib/doc-debt-query.bats` Arm 2's tests assert only `.number ==
101`, per-field values for issues 101-104, and body/label shapes; none
assert array length or last-element identity, so appending #105 as the last
element does not disturb any existing assertion. Confirmed by running the
suite after the append:

```
1..13
ok 1..13 (all pass, clean run, jq present, no skips)
```

## Notes for orchestrator

### Findings

- **A third prose-decoy shape** (documented above as "Finding 1") exists in
  the real corpus beyond the plan's two anticipated "Plan-time findings": one
  corpus line carries two literal `<!-- gaia-debt-key:` occurrences (an
  unrelated prose mention of the opener/a grammar fragment, then a real
  trailing key). It does not meet the task's stated exclusion criterion (its
  own key's `path=` is a real path), so it was kept. It trips criterion 3's
  `lenient`-group byte-identity check (1 of 765 checked rows), but in the
  **safe direction**: the terminator change fixes a latent splice bug in the
  old lenient reader for this row rather than regressing it. Phase 3's
  conformance suite should account for this one row explicitly (e.g. as a
  documented, expected exception) rather than assume criterion 3 holds
  without exception for the `lenient` group.
- The exclusion criterion in the task brief names only issue #2048, but the
  same criterion (a wrapped key whose own `path=` is a regex literal) also
  matches a line in issue #1118. Both were dropped; see "Exclusion applied"
  above.
- Criterion 4a's `line_eq_count > 1` count is 0 over the real corpus. Per
  the task's instruction this is reported as the finding, not treated as
  evidence the divergence is unreal; see the scratch-file demonstration
  above.

### Deviations from plan

None. All six deliverables and all acceptance criteria (1 through 9, 4a,
7a) were met as specified; the one place this phase's output diverges from
a "clean" table (criterion 3's `lenient` exception) is real corpus behavior
surfaced under Finding 1, not a shortcut or a skipped check.

### Follow-ups

- Phase 3's frozen reader-set derivation and conformance suite should decide,
  with Finding 1 in hand, whether the single-line prose-decoy shape needs a
  documented exception in its `lenient`-group invariant assertion, or whether
  it is narrow enough (1 row, found only via this one real PR body) to leave
  as an accepted, explained residual.
