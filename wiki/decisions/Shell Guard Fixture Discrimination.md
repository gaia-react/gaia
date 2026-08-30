---
type: decision
status: active
priority: 2
date: 2026-08-30
created: 2026-08-30
updated: 2026-08-30
tags: [decision, shell, lint, bats, awk-lib]
---

# Shell Guard Fixture Discrimination

Three GAIA shell guards scan the tree for a class of shell defect: an unquoted
path-listing call, an unescaped ERE metacharacter, an unguarded status read under
errexit. Each guard reads tracked shell scripts, husky hooks, workflow YAML, and
the fenced code blocks of tracked markdown, and until now none of them read `*.bats`
at all. The exclusion existed because a bats suite is exactly where the defect class
gets demonstrated on purpose: a suite proves a guard's own claim by writing a
deliberately broken fixture and asserting the guard catches it, and a scanner reading
raw lines cannot tell that fixture apart from a real call without more context than
"is this a shell line". Reading `*.bats` with no further discrimination would report
every one of those fixtures as a fresh defect and make the suites themselves fail
the gate they exist to prove.

That exclusion stopped being safe once the suites started doing two jobs on the same
lines. A bats test body is shell, and bats runs every test body under errexit; some
suites also hold interior lines that are not fixture data at all but a call the test
actually executes, including a variable-held shell body run through `bash -c`. A
guard that skips `*.bats` wholesale misses the second job entirely, on the same
surface it was built to police everywhere else. The guards now read `*.bats`, and a
shared library carries the discrimination that makes that safe: it tells a scanned
line apart as fixture data or executed shell, and it reads a suppression pragma that
lets a suite keep a deliberately broken line without the guard reporting it as a
defect.

## Why the suppression is bats-only

The suppression exists to protect deliberately broken evidence, and that evidence
lives only in suites: a fixture that proves a guard catches the unrepaired spelling,
or a positive control that proves the underlying tool really does what the guard's
fix assumes. Nothing outside a suite has a legitimate reason to carry the unrepaired
spelling on purpose. Honoring the pragma on every surface would hand every shipped
script a documented way to opt out of a gate that took several hand fixes to earn,
turning a suppression meant for evidence into a general escape hatch. A pragma that
appears outside a suite, on a surface a guard scans, is therefore reported as honored
nowhere rather than silently accepted; the pragma's presence is visible either way,
but only inside a suite does it actually suppress anything.

The fixture-region skip carries the same scope for the mirror reason. Scoping the
skip to `*.bats` is what makes it a closed, provable claim: a line is data only when
it sits inside the argument region of a recognized fixture-writing shape, checked
against the small set of suites that write fixtures. Letting the same skip apply to
`*.sh`, husky hooks, workflow YAML and markdown would mean silently dropping heredoc
bodies and multi-line continuations across every shipped script on those surfaces,
more than 160 heredoc openers across 65 tracked shell scripts on that surface alone,
which is a net regression against what those guards already catch there today.

## What makes a line fixture data

A candidate line is data, and skipped, only when it lies inside the argument region
of one of a small set of recognized fixture-writing idioms in a `*.bats` file: a call
to one of the framework's own fixture-writing helpers, a `cat`, `printf` or `echo`
statement carrying an output redirect to a path, a quoted heredoc body, or a variable
assignment to a quoted literal where that variable is later passed to a
fixture-writing helper and never appears in an execution position such as `bash -c`,
`sh -c`, `eval` or `source`. The argument region runs from the command word to the
end of the statement, joining backslash continuations and spanning a multi-line
quoted literal, because a large share of the genuine fixture data in the tree sits on
a continuation line rather than a single line.

Everything else fails closed and is reported. This is a rule about shapes, never
about files: the set names call idioms, not a list of suite paths, so a brand-new
suite inherits the discrimination with no registration anywhere. The direction that
matters most is the one that is easy to get backwards: shell the suite actually
executes is scanned however many physical lines it spans, even when that shell is
carried inside a variable and run through `bash -c` from an interior line deep in a
test body. The defect that motivates this whole convention sat on exactly that kind
of line, a variable-held body run through a shell rather than a call written out
directly, and a rule that only looked at command words on their own line would have
missed it again.

## What a pragma must contain

The literal grammar sits on the comment line or lines immediately above the target:
`# gaia-lint-ignore <guard>: <reason>`. `gaia-lint-ignore` must be the first token
after the `#`, or the line is not read as a pragma head at all. `<guard>` is the
naming guard's script basename with `.sh` stripped, resolved by file existence
against the scripts directory, never by execute permission. The reason after the
colon is mandatory and must be non-empty.

The reason is not a restatement of the defect class the guard already knows it
scans for. It is a why-not: the specific failure the repaired spelling would
introduce at this exact site. The clearest case is a positive control, where the
unquoted call is itself the experiment and the repaired idiom would delete the proof
that the underlying tool behaves the way the fix assumes, something close to
`# gaia-lint-ignore lint-git-path-quoting: this call is the positive control proving the tool quotes here; repairing it would delete the proof the test asserts`.
A pragma fails, rather than passes, in three ways, and each has one reader that owns
it: a pragma whose target line carries no instance of the named class is unused, and
the guard named in the pragma is the one that reports it; a guard token that does not
resolve to a real script file is orphaned, and only the path-quoting guard reports
it, because it is the one guard reading every surface a pragma can appear on; a
pragma with no reason after the colon is malformed for the same reason and reported
by the same one guard.

A pragma's reason may wrap onto a following comment line, and a wrapped reason is
textually just an ordinary comment line, which is exactly why an ordinary comment
cannot interrupt a block: nothing distinguishes "wrapped reason" from "unrelated
comment" from inside the block. A following comment line that itself starts with
`gaia-lint-ignore` opens a second, stacked pragma, and both apply to the same
target. A blank line terminates the block outright; a pragma above a blank line
targets nothing beneath it and is reported as unused rather than silently reaching
past the gap. The target of a block is the first non-comment, non-blank line
beneath it.

## Where the blind spots live

Each guard's own header states, in detail, what that guard's scan actually reaches
and where it still fails open: an unbalanced fence, an indented code block a
delimiter-based scanner never enters, an option spelling its own detector does not
recognize, and so on, each guard's list is particular to what it scans and how.
This page does not restate any of it, on purpose. The header sits beside the code an
editor is already reading when they change a guard or add to a surface it scans, and
that is the moment the blind spots are relevant; a reader arriving here first, before
opening any guard, has no participating file in front of them yet for the blind
spots to be about.

## Adopting the convention in a new guard

A fourth guard adopts this convention by sourcing the shared awk library beside its
own script, resolved script-relative rather than against the current working
directory, because a guard can be invoked from anywhere. It then concatenates the
library's exported awk source ahead of its own program at call time, roughly:

```bash
awk -v file="$f" -v is_bats="$is_bats" -v scripts_dir="$scripts_dir" \
  "$GAIA_GUARD_AWK$OWN_AWK" "$f"
```

and calls only the library's own named entry points: one to reset state at the start
of a file, one to accumulate a first pass over the file's lines, one to advance
region, quote, heredoc, continuation and pragma state across each physical line on
the second pass, and a small set of accessors that answer whether the line just fed
is fixture data, is covered by an honored suppression, or carries a pragma at all.
A final call at end of file emits every unused or malformed pragma the library
tracked. The adopting guard writes none of its own fixture-region discrimination or
pragma parsing; every guard sharing the library shares one answer to "is this line
data" and one answer to "is this suppression honored here", rather than each guard
re-deriving its own.
