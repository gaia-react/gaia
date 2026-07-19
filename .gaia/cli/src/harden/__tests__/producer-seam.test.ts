/**
 * End-to-end seam test: member sidecar -> `post-findings-block.sh` (the real
 * producer, spawned as a subprocess with a stubbed `gh`) -> `parseFindingsBlock`
 * -> `computeTally`. Every other suite in this directory feeds `computeTally`
 * or `run()` from hand-written fixtures; this one proves the loop also fires
 * on a REAL producer run over a REAL sidecar file (UAT-009), and that a
 * sidecar's classless finding survives the seam stamped `holistic/unclassified`
 * (UAT-004). No network: `gh` is a local stub script that never leaves the
 * sandbox.
 */
import {describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {computeTally} from '../compute-tally.js';
import type {TallyPrRecord} from '../compute-tally.js';
import {parseFindingsBlock} from '../parse-findings-block.js';

// Walk up from this file's location to the repo root (contains .git), the
// same resolver `gaia-ci-template-refs.test.ts` uses, so this test needs no
// hardcoded machine path to find the sibling `.gaia/scripts/` producer.
const resolveRepoRoot = (): string => {
  let dir = path.dirname(fileURLToPath(import.meta.url));

  for (let attempts = 0; attempts < 20; attempts += 1) {
    if (existsSync(path.join(dir, '.git'))) return dir;
    const parent = path.dirname(dir);

    if (parent === dir) break;
    dir = parent;
  }

  throw new Error('Could not find repo root (no .git directory found)');
};

const PRODUCER_SCRIPT = path.join(
  resolveRepoRoot(),
  '.gaia',
  'scripts',
  'post-findings-block.sh'
);

const SEEDED_FINDING = {
  area_tags: ['app/routes'],
  finding_class: 'holistic/hardcoded-string',
  severity: 'suggestion',
};

const CLASSLESS_FINDING = {
  area_tags: ['app/services'],
  finding_class: 'holistic/unclassified',
  severity: 'warning',
};

// A fake `gh` answering exactly the calls `post-findings-block.sh` makes when
// `--pr` is passed explicitly (so `gh pr view` is never invoked): `auth
// status` ok, `repo view` names a repo, a plain `api` call (the existing-
// comment lookup) runs the REAL `--jq` filter against an empty comment list
// via the real `jq` (so it resolves to "no existing comment", same as gh
// itself would), and an `api --method ...` call captures the posted body to
// `postedBodyFile` and reports success. Modeled on the stub in
// `.gaia/scripts/tests/post-findings-block.bats`.
const fakeGh = (postedBodyFile: string): string => `#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
esac
case "$1" in
  repo)
    echo "acme/widgets"
    ;;
  api)
    method=""
    filter=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--method" ] && method="$a"
      [ "$prev" = "--jq" ] && filter="$a"
      prev="$a"
    done
    if [ -z "$method" ]; then
      printf '%s' '[]' | jq -r "$filter"
    else
      for a in "$@"; do
        case "$a" in
          body=@*) cp "\${a#body=@}" "${postedBodyFile}" ;;
        esac
      done
      echo '{"id":999}'
    fi
    ;;
esac
exit 0
`;

type RawFinding = {
  area_tags: string[];
  finding_class: string;
  severity: string;
};

// Runs the REAL producer against a fresh, isolated sandbox: writes one
// member's sidecar, stubs `gh` on PATH, spawns `post-findings-block.sh`, and
// returns the composed comment body the stub captured. No network: `gh` never
// leaves this process tree.
const runProducer = (args: {
  base: string;
  findings: RawFinding[];
  prNumber: number;
}): string => {
  const sandbox = mkdtempSync(path.join(tmpdir(), 'gaia-seam-'));

  try {
    execFileSync('git', ['init', '-q'], {cwd: sandbox});

    const auditDir = path.join(sandbox, '.gaia', 'local', 'audit');

    mkdirSync(auditDir, {recursive: true});
    writeFileSync(
      path.join(auditDir, `${args.base}.code-audit-frontend.findings.json`),
      JSON.stringify({
        findings: args.findings,
        member: 'code-audit-frontend',
        schema: 1,
      })
    );

    const binDir = path.join(sandbox, 'bin');

    mkdirSync(binDir, {recursive: true});
    const postedBodyFile = path.join(sandbox, 'posted-body.txt');

    writeFileSync(path.join(binDir, 'gh'), fakeGh(postedBodyFile), {
      mode: 0o755,
    });

    const stdout = execFileSync(
      PRODUCER_SCRIPT,
      ['--base', args.base, '--pr', String(args.prNumber)],
      {
        cwd: sandbox,
        encoding: 'utf8',
        env: {...process.env, PATH: `${binDir}:${process.env.PATH ?? ''}`},
      }
    );

    expect(stdout.trim()).toMatch(/^findings: posted \d+ finding\(s\)/);

    return readFileSync(postedBodyFile, 'utf8');
  } finally {
    rmSync(sandbox, {force: true, recursive: true});
  }
};

// Three plain hand-authored block bodies (not producer output), for UAT-006:
// the parse-then-tally seam is exercised on its own, distinct from the
// producer-composed path the tests below cover.
const handWrittenBlock = (prNumber: number, findings: RawFinding[]): string =>
  [
    '<!-- gaia-harden:findings:start -->',
    '<!--',
    JSON.stringify({
      auditor: 'local',
      findings,
      pr_number: prNumber,
      schema: 1,
    }),
    '-->',
    '<!-- gaia-harden:findings:end -->',
  ].join('\n');

describe('producer seam: sidecar -> post-findings-block.sh -> parseFindingsBlock -> computeTally', () => {
  test('UAT-009 / UAT-004: a real sidecar, merged by the real producer over 3 PRs, reaches the tally as a candidate; its classless finding lands in unclassified', () => {
    const prNumbers = [101, 102, 103];
    const bases = ['a'.repeat(40), 'b'.repeat(40), 'c'.repeat(40)];

    const prs: TallyPrRecord[] = prNumbers.map((prNumber, index) => {
      const body = runProducer({
        base: bases[index],
        findings: [SEEDED_FINDING, CLASSLESS_FINDING],
        prNumber,
      });

      expect(body).toContain('<!-- gaia-harden:findings:start -->');

      const parsed = parseFindingsBlock(body);

      expect(parsed).not.toBeNull();
      expect(parsed?.findings.length).toBe(2);

      return {findings: parsed?.findings ?? [], pr_number: prNumber};
    });

    const result = computeTally({
      coveredClass: () => false,
      prs,
      suppressedClass: () => false,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(1);
    const [candidate] = result.candidates;

    expect(candidate.finding_class).toBe('holistic/hardcoded-string');
    expect(candidate.distinct_pr_count).toBe(3);
    expect(candidate.severity_max).toBe('suggestion');

    expect(result.unclassified).not.toBeNull();
    expect(result.unclassified?.distinct_pr_count).toBe(3);
    expect(result.unclassified?.severity_max).toBe('warning');
    expect(
      result.candidates.some((c) => c.finding_class === 'holistic/unclassified')
    ).toBe(false);
  });

  test('UAT-004 negative arm: a sidecar finding written with a raw (unmapped) grading is dropped by the parser, its sibling finding survives', () => {
    const onReject = vi.fn();
    const body = runProducer({
      base: 'd'.repeat(40),
      findings: [
        // Raw grading, not the lowercase mapped severity the contract
        // requires: `severity-map.ts` maps `Critical` -> `error`, but a
        // member that stamped the raw grading verbatim violates the
        // contract, and the parser must drop it rather than accept it.
        {
          area_tags: ['app/routes'],
          finding_class: 'holistic/hardcoded-string',
          severity: 'Critical',
        },
        {
          area_tags: ['app/routes'],
          finding_class: 'holistic/non-null-assertion',
          severity: 'warning',
        },
      ],
      prNumber: 201,
    });

    const parsed = parseFindingsBlock(body, onReject);

    expect(parsed).not.toBeNull();
    expect(parsed?.findings).toHaveLength(1);
    expect(parsed?.findings[0]?.finding_class).toBe(
      'holistic/non-null-assertion'
    );
    expect(onReject).toHaveBeenCalledWith('severity', 'Critical');
  });

  test('UAT-006: three hand-written block fixtures parse and tally into one recurring candidate', () => {
    const prNumbers = [11, 12, 13];
    const prs: TallyPrRecord[] = prNumbers.map((prNumber) => {
      const parsed = parseFindingsBlock(
        handWrittenBlock(prNumber, [SEEDED_FINDING])
      );

      expect(parsed).not.toBeNull();

      return {findings: parsed?.findings ?? [], pr_number: prNumber};
    });

    const result = computeTally({
      coveredClass: () => false,
      prs,
      suppressedClass: () => false,
      windowDays: 90,
    });

    expect(result.candidate_count).toBe(1);
    expect(result.candidates[0]?.finding_class).toBe(
      'holistic/hardcoded-string'
    );
    expect(result.candidates[0]?.distinct_pr_count).toBe(3);
  });
});
