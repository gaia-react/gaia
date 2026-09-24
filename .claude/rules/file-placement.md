---
paths:
  - '.claude/hooks/**'
  - '.gaia/scripts/**'
  - '.gaia/cli/src/**'
---

# File Placement

## `.claude/hooks/**`

**Add a new hook at the root of `.claude/hooks/`. Do not create a subdirectory.**

## Register the hook

Two obligations, each with its check in your own tree, so you can verify either one locally.

### No bare `.gaia/local` literal

**A hook reaches `.gaia/local` only by joining a root from `main-root-lib.sh`** (or a caller-supplied root, in a lib under `.claude/hooks/lib/`). A bare literal resolves against whatever tree the hook runs in, so from a linked worktree the write lands in the wrong tree with no error.

```bash
bash .gaia/scripts/check-hook-scope-manifest.sh
```

It walks the whole directory, so a new hook is checked the moment it exists.

### A cwd-independent command, when you register it in `.claude/settings.json`

**The command has to name the script by a path that resolves wherever the shell happens to be.** `/bin/sh` runs the command string against a working directory that persists for the whole session, so a bare relative registration becomes unfindable after a single `cd`. The script then exits 127, and 127 neither blocks nor is reported, so the guard fails open in silence and the hook you just wrote protects nothing.

```bash
bash .gaia/scripts/check-hook-command-rooting.sh .
```

Copy the form from a registration already in the file rather than inventing one; the check reads every registered command, so it tells you either way.

## `.gaia/scripts/**`: do not add files here

`.gaia/` is GAIA's own machinery, not a place for project files.

<!-- gaia:maintainer-only:start -->
## Maintainer: the rest of the obligations and the other trees

**A new file under `.claude/hooks/lib/**` or `.claude/rules/**` needs a tier**, and a registered hook owes one further obligation the shipped half above leaves out: a jq-availability arm. `.claude/rules/maintainers/hook-registration.md` owns the whole set and names the checks that enforce the checkable ones. The tier for a convention rule like this one is merely-shared; global is reserved for rules that decide what the gate does with a clearance.

That obligation is omitted from the shipped half because its checker is release-excluded: an instruction to satisfy something nothing in the reader's tree can verify is an instruction they cannot act on and we cannot enforce. The rooting check ships and runs standalone on an adopter clone; the tier obligation has no check, which is why the rooting obligation is stated up there rather than here.
<!-- gaia:maintainer-only:end -->
