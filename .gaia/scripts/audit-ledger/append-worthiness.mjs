#!/usr/bin/env node
// Append one worthiness-audit verdict line to the append-only worthiness
// ledger. The worthiness evaluator (.claude/agents/worthiness-evaluator.md)
// judges each emergent-surface test keep/fix/delete; on the no-orchestrator
// path the tdd skill drives one invocation of this writer per judged test, so
// principle-6 always-on holds even without an orchestrator.
//
// Invocation:
//   node .gaia/scripts/audit-ledger/append-worthiness.mjs \
//     <repo-relative-test-path> <fullName> <verdict> [artifact]
//
//   <verdict>   one of: keep | fix | delete
//   [artifact]  REQUIRED for a non-keep verdict; a machine-checkable string
//               (the cited sibling for a redundancy delete, the specific
//               unreachable assertion / missing-interaction note for a fix).
//               Omitted for keep.
//
// The ledger line (frozen schema the merge presence gate reads):
//   {"schema":1,"file":"<repo-rel>","fullName":"<vitest fullName>",
//    "signal":"sha256:...","verdict":"keep"|"fix"|"delete",
//    "auditedAt":"<iso>","artifact":"<...>"}
//
// IDENTITY: `signal` is the SAME sha256-of-normalized-test-call the RED ledger
// computes via .gaia/scripts/red-ledger/extract-test-signals.mjs. This writer
// reuses that helper directly (spawns it, matches the named test's fullName),
// so the signal byte-matches what the RED ledger and the presence-gate
// recompute produce. It does NOT reinvent the identity primitive.
//
// Ledger path: .gaia/local/audit/worthiness.jsonl (append-only,
// gitignored, grows-forever, sibling to the RED ledger). Override with
// WORTHINESS_LEDGER_PATH (the test seam; production leaves it unset).
//
// Exit 0 on a successful append. Exit non-zero with a one-line stderr message
// on a bad argument, an unknown verdict, a missing artifact for a non-keep, an
// unreadable file, a signal-helper failure, or a fullName the file does not
// contain. The evaluator edits no files; this writer only ever appends to the
// gitignored ledger.

import {execFileSync} from 'node:child_process';
import {appendFileSync, mkdirSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const SIGNAL_HELPER = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'red-ledger',
  'extract-test-signals.mjs',
);

const DEFAULT_LEDGER = '.gaia/local/audit/worthiness.jsonl';
const VERDICTS = new Set(['keep', 'fix', 'delete']);

const fail = (message, code) => {
  process.stderr.write(`append-worthiness: ${message}\n`);
  process.exit(code);
};

const [file, fullName, verdict, artifact] = process.argv.slice(2);

if (!file || !fullName || !verdict) {
  fail(
    'usage: append-worthiness.mjs <repo-rel-test-path> <fullName> <verdict> [artifact]',
    2,
  );
}

if (!VERDICTS.has(verdict)) {
  fail(`unknown verdict "${verdict}" (expected keep | fix | delete)`, 3);
}

// Each non-keep verdict carries a machine-checkable artifact, so an all-keep
// run with no artifacts is a detectable contradiction downstream.
if (verdict !== 'keep' && !artifact) {
  fail(`verdict "${verdict}" requires a machine-checkable artifact argument`, 4);
}

// Reuse the RED-ledger signal helper. Spawning it (rather than recomputing the
// hash here) guarantees the signal byte-matches the canonical primitive.
let signalNdjson;
try {
  signalNdjson = execFileSync('node', [SIGNAL_HELPER, file], {encoding: 'utf8'});
} catch (err) {
  fail(`signal helper failed for ${file}: ${err.message}`, 5);
}

const signal = signalNdjson
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((line) => {
    try {
      return JSON.parse(line);
    } catch {
      return null;
    }
  })
  .find((entry) => entry && entry.fullName === fullName)?.signal;

if (!signal) {
  fail(`no test named "${fullName}" found in ${file}`, 6);
}

const record = {
  schema: 1,
  file,
  fullName,
  signal,
  verdict,
  auditedAt: new Date().toISOString(),
};
if (artifact) {
  record.artifact = artifact;
}

const ledgerPath = process.env.WORTHINESS_LEDGER_PATH || DEFAULT_LEDGER;

try {
  mkdirSync(path.dirname(ledgerPath), {recursive: true});
  appendFileSync(ledgerPath, JSON.stringify(record) + '\n');
} catch (err) {
  fail(`cannot append to ledger ${ledgerPath}: ${err.message}`, 7);
}

process.exit(0);
