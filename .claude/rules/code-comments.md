---
paths:
  - 'app/**/*.{ts,tsx,js,jsx,css}'
  - 'test/**/*.{ts,tsx}'
  - '.playwright/**/*.ts'
  - '.storybook/**/*.{ts,tsx}'
  - '.gaia/**/*.ts'
  - '.gaia/**/*.sh'
  - '.claude/hooks/**/*.sh'
  - '.github/**/*.sh'
  - '.specify/extensions/gaia/lib/**/*.sh'
  - '**/*.bats'
---

# Code Comments

Default to no comment. Write one only when it passes this test:

> **A comment must be about something the file does not make legible.**

A test of subject, not length. A thirty-line comment about a platform quirk earns every one of its lines; a three-line docblock naming the symbol below it earns none. So this rule compresses a comment toward its subject, it never suppresses one: cutting a comment until it is cryptic, or dropping a fact that deserves to survive because the block looked long, fails this rule rather than satisfying it.

## Earns its place

- **The reason a value has the value it has.** The code pins the value, nothing pins the reason. Timeouts, retry counts, thresholds, cache TTLs, debounce intervals, page sizes.
- **A why-not.** An obvious simpler approach, and the specific way it fails here.
- **The contract with the _other_ file.** What fires this code, what shape of input arrives, what a return value or exit code means to the caller. The cross-file half only: a file's own usage and output shape are recoverable by reading it.
- **A platform or version quirk.** A shell version difference, a BSD-vs-GNU tool difference, a language-spec fact, a third-party SDK side effect.
- **An honest limit of a check.** What a guard does not catch, and why that is the safe direction to fail in.
- **An invariant that spans the file.** An ordering or lifecycle rule no single site can state and no test proves.

## Earns nothing

- Restating the line, the signature, or the check below it. The code is the durable form; the copy decays.
- A header re-narrating the implementation sites below, or the same paragraph repeated at each site.
- A banner over a single item, and ASCII section rules (`// ─── Types ───`). A banner over a group is navigation and stays.
- The ceremonial opener: a first line assembled from the filename's own tokens and saying nothing else.
- Historical narration: "used to do X, now does Y", "added in PR #123", "as of <date>". Git carries this.
- A number used as justification that nothing in the repo can reproduce.

## Name less, explain more

Be far harder on a comment that NAMES a thing than on one that EXPLAINS a thing. Explanations age well. Pointers do not, because the file, symbol, or ticket a comment names gets renamed or deleted while the comment stays behind still naming it. A name in a comment carries a maintenance obligation that the reasoning around it does not.

Pointing at a rule stays allowed. Copying a rule's content into a comment does not, because the copy drifts from the rule.

## Editing an existing comment

- **Never truncate a pointer to a bare unresolvable id.** Delete the line instead. A bare id keeps the maintenance obligation and discards the meaning, which is strictly worse than saying nothing.
- **Before deleting a name, grep the rest of the file for it.** A correct deletion can orphan a cross-reference elsewhere in the same file, and no test run, diff check, or type check detects it.

## Exported symbols

A single-line summary earns its place on an exported function, hook, type, or constant even when the implementation is self-evident, because it reaches callers who never open the file. One line, not a paragraph.

No `@param` or `@returns` restating the signature. Types say it, the editor shows it, and the tag rots independently of the parameter it names. Use a tag only for what the type cannot: a unit, an ownership transfer, a mutation.

A wrong doc comment on an exported symbol displays at every call site, so exported-symbol docs get the **highest** scrutiny, not an exemption from it.

## Comments that are not commentary

Linter and type-checker directives, test-environment and editor pragmas, generated-region and codegen markers, and version glosses a bot writes and a test parses. If anything in the repo parses it, it is data wearing comment syntax. Never judge it on worthiness and never reword it: editing or deleting one changes behavior.
