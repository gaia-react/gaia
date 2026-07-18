# Reference: Classifying a Failed CI Run Before Retrying

Do not reflexively retry a failed CI job. Walk this decision procedure to classify the failure first, then act. The branches below are not interchangeable: retrying, pinning a version, or fixing code are different remedies for different causes, and applying the wrong one wastes CI minutes or hides a real bug until it reappears on someone else's PR.

## 1. Read the failure signature first

Open the failed job's log and find the first non-zero exit, not the last line printed; a downstream step often fails noisily as a side effect of an earlier, quieter failure. Note the exact error string, the step it occurred in, and whether the same commit passed on a previous run.

## 2. Classify by signature

### 2a. Network or infra transient

Symptoms: connection reset, DNS resolution failure, a registry timeout, or a `503` from a package host, with no code or config change in the diff.

Action: retry once on the same commit, no code change. If the retry passes, no further action is needed. If it fails identically a second time, escalate to infra rather than retrying again blindly; a second identical failure on an unchanged commit rules out a one-off network blip.

### 2b. Test-order dependency

Symptoms: a test passes when run alone but fails only inside the full suite, or the failure reproduces only in CI's parallel shard and not in a local single-threaded run.

Action: do not retry blindly. Reproduce locally by running the full suite in the same shard configuration and, if available, the same random seed CI used. This class never resolves by retrying: the failure comes from state one test leaks into another under a specific execution order, and the next CI run may or may not hit that same order.

### 2c. Environment drift

Symptoms: a tool or runtime version differs between CI and the local machine (a Node version mismatch, a lockfile out of sync with `package.json`, a global binary CI has that the contributor's machine lacks, or vice versa).

Action: diff the versions CI reports against the local toolchain and pin the mismatched one. Retrying does nothing here, since the environment itself is wrong on every attempt, not just this one; that is what distinguishes it from 2a, where the environment is fine and a single network call is what misbehaved.

### 2d. Genuine regression

Symptoms: the same failure reproduces locally on a clean checkout of the PR branch, deterministically, every time, with no dependence on shard, seed, or tool version.

Action: this is a real defect in the change. Fix the code. Do not touch CI configuration and do not retry; retrying a deterministic regression only delays the fix and lets it land on a teammate's PR instead.

### 2e. Unexplained flake

Symptoms: fails intermittently both locally and in CI, with no correlation to execution order, environment, or network conditions found after checking 2a through 2d.

Action: quarantine it explicitly, skip with a tracked reason naming what was checked and ruled out, and file it for follow-up. Do not leave it silently retried forever: an untracked flake that keeps getting re-run erodes trust in the whole gate, since a red run stops meaning anything.

## 3. Where the branches are easy to confuse

Environment drift (2c) can masquerade as a genuine regression (2d) when the only reproduction attempted is inside CI itself. The deciding check is whether a clean local checkout, on the contributor's own machine, reproduces the failure deterministically. If it does, treat it as 2d regardless of what CI's environment looks like; if it does not, and CI alone fails consistently, treat it as 2c and compare toolchain versions before assuming the code is at fault.
