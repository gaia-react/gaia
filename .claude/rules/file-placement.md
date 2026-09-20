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

**Nothing checks a hook's path.** A hook is named as a string everywhere it is registered, filtered, or described: manifests, JSON registries, CI path filters, rule globs, agent prose, wiki pages. A move leaves every one of those spellings pointing at nothing, and no build step fails and no test necessarily covers the reference that broke. The cost is paid per reference, which is what keeps the directory flat rather than grouped into subfolders.

Filename prefixes already group the directory, and they cost nothing to adopt: a new hook named for what it does sorts next to its family without moving anything.

A second obligation rides on the first, and it binds whoever writes a check rather than whoever adds a hook: **every discovery over this directory has to descend.** A single-level glob does not, so a check written that way reports clean over shell it never opened, which is the discovery-stage fail-open `.claude/rules/guards-must-fail.md` names first. Walk the tree, and state the size of the set you expected to find.

## Register the hook in `.gaia/hook-scopes.json`

**Every `.sh` under `.claude/hooks/**` needs exactly one entry in `.gaia/hook-scopes.json`.** The entry declares which tree the hook's state belongs to, the state it touches, and why. The manifest's own schema is the authority on the fields; read a neighbouring entry and follow it.

Verify it:

```bash
bash .gaia/scripts/check-hook-scope-manifest.sh
```

The check walks the directory rather than a second hand-kept list, so an unregistered hook is a finding the moment it exists. Both the manifest and the check are in your tree, so this obligation is verifiable locally, which is why it is the one stated here.

## `.gaia/scripts/**`: do not add files here

`.gaia/` is GAIA's own machinery, not a place for project files. `.claude/rules/gaia-folder.md` owns that boundary and the reasoning behind it.

<!-- gaia:maintainer-only:start -->
## Maintainer: the rest of the obligations and the other trees

**A new file under `.claude/hooks/lib/**` or `.claude/rules/**` needs a tier**, and a registered hook carries further obligations beyond the scope manifest: the jq-availability arm, the capability entry, and the rooting form of its registration. `.claude/rules/maintainers/hook-registration.md` owns that whole set and the checks that enforce it. The tier for a convention rule like this one is merely-shared; global is reserved for rules that decide what the gate does with a clearance.

Those additional checkers are release-excluded, so an adopter cannot run them. That is why the shipped half above states the scope-manifest obligation and no other: an instruction to satisfy something nothing in the reader's tree can verify is an instruction they cannot act on and we cannot enforce.

**Keep `.gaia/scripts/**` flat too, for a stronger version of the same reason.** Its scripts carry far more referencing files each, so a move is a rename across CI workflows, rules, wiki prose and bats suites for no functional gain. The subdirectories it already holds are established exceptions, not a precedent for filing a new script into one. An under-reaching `paths:` glob is caught loudly rather than silently here: `lint-guard-rule-shell-coverage.sh` reds and names the file the glob missed. This directory has already been burned once by a location change that un-excluded a tree without adding it as a scan target.

**The manifest keys by path, so a move is a delete plus an add.** The Update Workflow asks an adopter before removing a file they still have, so reorganizing a shipped tree manufactures a prompt per moved file on every adopter's next update, plus a merge conflict for anyone who customized one.

**`.gaia/cli/src/**` is the opposite case and its subdirectories are correct.** TypeScript imports are compiler-checked, so a move is a mechanical refactor the build verifies, and the domain-folder convention there is the one to follow: put a new module in the folder for its domain rather than at the root. This tree has no manifest entries at all, so it does not exist on an adopter clone and nothing in this section reaches them.
<!-- gaia:maintainer-only:end -->
