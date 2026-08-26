# Clustering record: the eleven seeded language-neutral holistic classes

Two waves, each measured against its own corpus and each stating its own provenance
bound. The first wave's section is unchanged; the second amends exactly one of its
verdicts and says so.

## Wave 1: the first six classes

### Provenance, read this before any count below

- A published findings block carries a class, a severity, and area tags, and **no
  finding text at all**. No count in this record is derived from a published block.
- Two mechanisms erase earlier rounds: a sidecar key that rotates when a clean round
  stamps its trailer, and a same-key write that replaces rather than accumulates. The
  merge-time publisher resolves exactly one key. A finding found and fixed during
  review leaves no trace, and a member not re-dispatched in the final window
  contributes nothing.
- The corpus this record rests on is 27 surviving audit sidecars carrying 44 findings
  across 16 branches, plus the bodies of all 27 pull requests, of which 26 carried
  recoverable finding text. Roughly 130 findings were recovered by hand. Only 10 of
  the 27 pull requests still hold a sidecar on disk; the other 17 contribute body
  prose alone.
- **Therefore every count below is a floor, not an estimate**, and every one is
  narrative-derived: read by hand from surviving sidecars and pull-request body prose,
  not queried from a database.
- The surviving records are reaped on a timer, so these counts are a snapshot, and
  re-deriving them gets harder the longer this record goes unrefreshed.

### Per-class counts

| Class | Distinct PRs | Basis |
| --- | --- | --- |
| `holistic/uncoupled-restatement` | 19 | largest family in the corpus on the distinct-pull-request axis |
| `holistic/hollow-assertion` | 15 | |
| `holistic/unarmed-guard` | 9 | |
| `holistic/stale-figure` | 8 | no boundary collisions against anything |
| `holistic/fail-open-discovery` | 6 | |
| `holistic/partial-cause-reporting` | 1 in-window | exception, see below |

The recurrence bar is 3 distinct pull requests inside a rolling 90-day window. Five of
the six classes clear it with room to spare.

### The named exception: `holistic/partial-cause-reporting`

One recorded in-window instance, well under the bar. This class is seeded on
**assignability**, not frequency, which is the vocabulary's own stated bar: seed only
classes an agent can reliably and repeatably assign. Its recurrence was directly
observed three times by three separate members inside one pull request whose published
findings block carried zero findings, which is exactly the evidence a published block
cannot hold. Of the six seeded classes, this is the one whose count rests on evidence
the block cannot hold.

### The residual-cluster denominator

Seven surviving findings were filed classless against classes that already existed in
the schema at the time (six against the already-seeded swallowed-error meaning, one
against a workflow script-injection shape), and one agent invented a class name the
schema has never carried, which the tally discarded entirely rather than counting.
Those seven are a labelling failure, not evidence of a vocabulary gap. The counts above
are measured against the residual cluster with all seven set aside. This matters
because correcting the misfilings before measuring is what stops a seeded class
inheriting a count from findings that were only ever misfiled, rather than from a real
recurring shape.

### The three rejected shapes, and what would change the answer

- **Lockstep copy drift**, on 8 pull requests, rejected on assignability rather than
  frequency: its instances split into a correctness half already reported under the
  already-seeded assertion-width meaning and a duplication half this repository has
  explicitly declined to act on as its own defect. Earns a class of its own when the
  repository decides to act on cross-file duplication as a defect in its own right,
  independent of the already-seeded prose meaning that currently absorbs it.
  **Wave 2 reverses this verdict**; see "The reversed rejection" under Wave 2 for the
  evidence and for the scope the seeded class takes.
- **A deictic or positional reference**, one instance inside this cluster and two more
  across every pull request read, against a form whose own description concedes a high
  false-positive rate. Earns reconsideration at 3 distinct pull requests inside one
  window.
- **A self-referential status claim**, three instances, rejected on **habitat**: its
  dominant home is issue and comment prose, which no audit member reviews, and the
  repository's present-tense prose rule already governs its in-tree half. Earns seeding
  the moment a surface exists that reads issue and comment prose.
- **A falsification framing** for any of the above three, rejected on measurement: 53
  percent of the false-statement instances in the corpus were never true at all, 33
  percent were falsified by the change under review, and 14 percent by some earlier
  change, so 67 percent fail a falsification test, and 10 of the 23 pull requests
  carrying the family hold no diff-falsified instance at all. Earns reconsideration only
  if a future corpus inverts that measurement.

## Wave 2: the second five classes

### Provenance, read this before any count below

- This wave rests on a **different corpus** from wave 1, so the two sets of counts are
  not comparable and must not be added together. Wave 1 read 27 surviving audit
  sidecars and 26 pull-request bodies. Wave 2 reads the **485 `tech-debt` issues** in
  this repository's tracker, every one carrying a title, a body, and a `gaia-debt-key`.
- The issue corpus is larger and its text survives, which is what the sidecar corpus
  could not offer. It carries a different bias in exchange: **an issue exists only for a
  finding that was deferred rather than repaired in review.** A recurring shape that
  reviewers always fix on the spot is invisible here, so these counts are a floor for a
  different reason than wave 1's, not the same one.
- Counts are distinct issues, not distinct pull requests. The recurrence bar of 3 inside
  a rolling 90-day window is applied to distinct issues here; the whole corpus falls
  inside one such window, so no count below is diluted by age.
- Every count was read by hand from issue titles and bodies after a keyword sweep
  proposed candidates. The sweep proposed; it did not decide.

### Per-class counts

| Class | Distinct issues | Basis |
| --- | --- | --- |
| `holistic/drifting-duplicate` | ~20 | largest family in this corpus; see the reversal below |
| `holistic/ambient-context-resolution` | ~16 | one issue alone names eight sites |
| `holistic/dangling-reference` | ~11 | the shape `holistic/uncoupled-restatement`'s own Not-clause excludes |
| `holistic/shared-state-collision` | ~10 | concentrated in concurrent worktree and co-dispatch paths |
| `holistic/unbounded-invocation` | ~10 | splits evenly between an absent bound and a superlinear cost |

All five clear the bar with room. Each is seeded on frequency **and** assignability;
none of the five needed the frequency exception wave 1 granted
`holistic/partial-cause-reporting`.

### The reversed rejection: lockstep copy drift

Wave 1 rejected this shape on assignability, on the ground that its duplication half was
a defect this repository declined to act on independently, and named the condition that
would earn it a class: the repository deciding to act on cross-file duplication as a
defect in its own right. **That condition is met, and the issue corpus is what shows
it.** Duplication is filed and drained here as its own defect, with the copy count as the
finding rather than as context: three disagreeing exclude-pattern parsers (#679, #839,
#856), three byte-identical copies of one merge-gate predicate (#737), five copies of one
status writer (#1286), five copies of one version-read idiom (#1297), a precondition
chain across 27 guards (#1284), one invocation idiom hand-rolled 29 times (#1219) and
another 14 times (#1232), and leak-check scopes drifted six times (#1439).

`holistic/drifting-duplicate` is therefore seeded, and it is scoped to **implementations**:
two or more independent copies of one construct with no shared source. Prose duplicated
across files stays with `prose/redundant-instruction` while its copies still agree with
each other and with the code; a copy that has drifted into disagreeing with what it
restates is `holistic/uncoupled-restatement`, which that member's own carve-out says in
so many words. Either way the `code-audit-maintainer-prose` member does not assign the
holistic duplicate class, so no member holds both sides of that pair.

### The rejected shape, and what would change the answer

- **A text-pattern match standing in for a grammar**, roughly 30 distinct issues and the
  largest family this corpus holds, rejected on **assignability** rather than frequency.
  Its instances are guards and parsers reading shell command text, git path output, or
  JSON as flat text, so a valid alternative spelling escapes (a quoted operand, a
  C-quoted path, a clustered short flag) or a described mention false-positives. The
  boundary against `holistic/hollow-assertion` does not resolve: that class already reads
  as a match region admitting a state the construct forbids, which is what every one of
  these instances also is, and wave 1's own corpus labels a grep needle satisfied by an
  unrelated comment as a hollow assertion. Seeding both would put a large family in front
  of two criteria that separate it inconsistently, and the multi-match rule would route it
  to the fallback anyway, which is where it already goes. Wave 1's precedent governs: a
  tie-break that resolves a genuinely unresolvable pair makes the pair look decidable and
  is worse than no class. **Earns seeding when a criterion exists that separates it from
  `holistic/hollow-assertion` on something an assigner can read off a single finding**,
  rather than on whether the reader chose to call the subject a check.

### What wave 2 does not revisit

The other two wave-1 rejections stand unexamined here: the deictic-or-positional
reference and the self-referential status claim. Neither was measured against this
corpus, so wave 1's counts and earning conditions for them are still the current record.
The habitat bound at the end of this file is unchanged and governs both waves.

## The habitat bound (both waves)

An audit member reviews the repository tree. Nothing in the instruction, harness, or
workflow surfaces reads a pull-request or issue body at all, so a defect living only
there is invisible to the recording mechanism as well as to any path-scoped rule or
tree lint. No class seeded here implies coverage of a surface no member reviews.
