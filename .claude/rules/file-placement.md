---
paths:
  - '.claude/hooks/**'
  - '.gaia/scripts/**'
  - '.gaia/cli/src/**'
---

# File Placement

Where a new file goes, and why the answer differs between trees that sit next to each other.

## The deciding factor is whether the language checks your references

A tree whose references are compiler-checked can be reorganized: a move is a mechanical refactor and the build fails on every reference it missed. A tree whose references are unchecked path strings cannot, because nothing fails when a reference goes stale; the path is the identity, and it is spelled out by hand in manifests, JSON registries, CI path filters, agent prose, and wiki pages.

So the conventions here are opposite by tree, and each is correct for its own reason. Pattern-matching off a neighbouring tree gets it backwards in either direction, which is why this is written down rather than inferred.

## `.claude/hooks/**` is flat on purpose

**Add a new hook at the root of `.claude/hooks/`. Do not create a subdirectory.**

**Most of what names a hook is an unchecked string.** A hook is spelled out by hand in CI path filters, rule globs, agent prose, and wiki pages, and a move leaves those pointing at nothing: no build step fails, and no test necessarily covers the reference that broke. The cost is paid per reference, which is what keeps the directory flat rather than grouped into subfolders.

Filename prefixes already group the directory, and they cost nothing to adopt: a new hook named for what it does sorts next to its family without moving anything.

A second obligation rides on the first, and it binds whoever writes a check rather than whoever adds a hook: **every discovery over this directory has to descend.** A single-level glob does not, so a check written that way reports clean over shell it never opened, which is the discovery-stage fail-open `.claude/rules/guards-must-fail.md` names first. Walk the tree, and state the size of the set you expected to find.

## Register the hook

One obligation, with its check in your own tree so you can verify it locally.

### A cwd-independent command, when you register it in `.claude/settings.json`

**The command has to name the script by a path that resolves wherever the shell happens to be.** `/bin/sh` runs the command string against a working directory that persists for the whole session, so a bare relative registration becomes unfindable after a single `cd`. The script then exits 127, and 127 neither blocks nor is reported, so the guard fails open in silence and the hook you just wrote protects nothing.

```bash
bash .gaia/scripts/check-hook-command-rooting.sh .
```

Copy the form from a registration already in the file rather than inventing one; the check reads every registered command, so it tells you either way.

## `.gaia/scripts/**`: do not add files here

`.gaia/` is GAIA's own machinery, not a place for project files. `.claude/rules/gaia-folder.md` owns that boundary and the reasoning behind it.

<!-- gaia:maintainer-only:start -->
## Maintainer: the rest of the obligations and the other trees

**A new file under `.claude/hooks/lib/**` or `.claude/rules/**` needs a tier**, and a registered hook owes two further obligations the shipped half above leaves out: a jq-availability arm, and an entry in `.gaia/hook-capabilities.json`. `.claude/rules/maintainers/hook-registration.md` owns the whole set and the checks that enforce it. The tier for a convention rule like this one is merely-shared; global is reserved for rules that decide what the gate does with a clearance.

Those two are omitted from the shipped half because their checkers are the release-excluded ones: an instruction to satisfy something nothing in the reader's tree can verify is an instruction they cannot act on and we cannot enforce. The split is per checker rather than per obligation, so check which side a new one falls on rather than assuming the whole maintainer set is withheld. The tier and rooting checks both ship and both run standalone on an adopter clone, which is why the rooting obligation is stated up there rather than here.

**Keep `.gaia/scripts/**` flat too, for a stronger version of the same reason.** Its scripts carry far more referencing files each, so a move is a rename across CI workflows, rules, wiki prose and bats suites for no functional gain. The subdirectories it already holds are established exceptions, not a precedent for filing a new script into one. An under-reaching `paths:` glob is caught loudly rather than silently here: `lint-guard-rule-shell-coverage.sh` reds and names the file the glob missed. This directory has already been burned once by a location change that un-excluded a tree without adding it as a scan target.

**The manifest keys by path, so a move is a delete plus an add.** The Update Workflow asks an adopter before removing a file they still have, so reorganizing a shipped tree manufactures a prompt per moved file on every adopter's next update, plus a merge conflict for anyone who customized one.

**`.gaia/cli/src/**` is the opposite case and its subdirectories are correct.** TypeScript imports are compiler-checked, so a move is a mechanical refactor the build verifies, and the domain-folder convention there is the one to follow: put a new module in the folder for its domain rather than at the root. This tree has no manifest entries at all, so it does not exist on an adopter clone and nothing in this section reaches them.
<!-- gaia:maintainer-only:end -->
