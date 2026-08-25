# 26-fixture-written-to-fixed-temp-path

**Path**: `test/helpers/seed-project-fixture.ts`
**Line**: 18

## Title

The fixture seeder writes to a constant temp path that every Vitest worker shares.

## Failure mode

The helper writes its seeded project JSON to `os.tmpdir()/gaia-project-fixture.json`, a
name carrying no worker id and no test id. Vitest runs suites across several worker
processes by default, so two suites seeding different project shapes at the same moment
write and read the same file: whichever wrote last decides what both read. The suites
pass in isolation and fail in a full run, and which one fails depends on scheduling
rather than on either suite's own code.

## Verified by

Ran the two suites alone (both pass) and then together with the default worker pool; one
failed on an assertion about a field the other suite's fixture sets, and the failure
moved between the two suites across repeated runs.

## Suggested fix

Include `process.env.VITEST_WORKER_ID` and the test name in the filename, or seed into a
`mkdtemp` directory created per test and removed in teardown.
