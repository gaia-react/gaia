import {describe, expect, test} from 'vitest';
import {
  advisoriesFromAudit,
  applyBaseline,
  classifyCandidates,
  countAdvisories,
  joinAuditToAlerts,
  normalizeAlerts,
  normalizeChain,
  normalizePnpmAudit,
  rankAdvisories,
} from './advisory-model.js';
import type {Advisory, UpdateOffers} from './advisory-model.js';
import {
  ADVISORY_REASON_TEXT,
  ADVISORY_REASON_TOKENS,
  reasonText,
} from './advisory-reasons.js';

const NO_OFFERS: UpdateOffers = {waveA: new Set(), waveB: new Set()};
const NO_APPLY: ReadonlySet<string> = new Set();
const OPEN: ReadonlySet<string> = new Set(['open']);

const auditAdvisory = (overrides: Record<string, unknown>) => ({
  findings: [{paths: ['.>cookie'], version: '0.6.0'}],
  github_advisory_id: 'GHSA-pxg6-pf52-xh8x',
  id: 1_098_765,
  module_name: 'cookie',
  patched_versions: '>=0.7.0',
  severity: 'moderate',
  vulnerable_versions: '<0.7.0',
  ...overrides,
});

const auditReport = (...advisories: Record<string, unknown>[]) => ({
  advisories: Object.fromEntries(
    advisories.map((advisory, index) => [String(index), advisory])
  ),
});

const advisory = (overrides: Partial<Advisory>): Advisory => {
  const [base] = advisoriesFromAudit(
    normalizePnpmAudit(auditReport(auditAdvisory({}))).records
  );

  if (base === undefined) throw new Error('fixture advisory missing');

  return {...base, ...overrides};
};

describe('normalizeChain and the fallback relationship', () => {
  test.each([
    ['.>cookie', ['.', 'cookie'], 'direct', 'cookie'],
    ['.>a>cookie', ['.', 'a', 'cookie'], 'transitive', 'a'],
    ['frontend>cookie', ['frontend', 'cookie'], 'direct', 'cookie'],
    [
      'frontend>react-router>cookie',
      ['frontend', 'react-router', 'cookie'],
      'transitive',
      'react-router',
    ],
  ])('%s', (auditPath, chain, relationship, head) => {
    expect(normalizeChain(auditPath)).toStrictEqual(chain);

    const [built] = advisoriesFromAudit(
      normalizePnpmAudit(
        auditReport(
          auditAdvisory({findings: [{paths: [auditPath], version: '0.6.0'}]})
        )
      ).records
    );

    expect(built?.relationship).toBe(relationship);
    expect(built?.scope).toBe('n/a');
    expect(built?.chains[0]?.[1]).toBe(head);
  });

  test('the parent is the segment before the package', () => {
    expect(normalizeChain('.>a>cookie').at(-2)).toBe('a');
  });
});

describe('normalizePnpmAudit', () => {
  test('a null patched_versions is valid and maps to no patch', () => {
    const result = normalizePnpmAudit(
      auditReport(
        auditAdvisory({
          patched_versions: null,
          patched_versions_unpublished: true,
        })
      )
    );

    expect(result.rejectedCount).toBe(0);
    expect(result.records[0]?.firstPatchedVersion).toBeNull();
  });

  test('a malformed patched_versions rejects the record', () => {
    const result = normalizePnpmAudit(
      auditReport(auditAdvisory({patched_versions: '>=1.0.0; rm'}))
    );

    expect(result).toStrictEqual({records: [], rejectedCount: 1});
  });

  test('the first patched version is the range minimum', () => {
    const result = normalizePnpmAudit(auditReport(auditAdvisory({})));

    expect(result.records[0]?.firstPatchedVersion).toBe('0.7.0');
  });

  test.each([
    ['a non-positive id', {id: -3}],
    ['a malformed GHSA id', {github_advisory_id: 'GHSA-0000-0000-0000'}],
    ['a module name with a space', {module_name: 'evil pkg'}],
    ['an unknown severity', {severity: 'urgent'}],
    [
      'a finding version with a command',
      {findings: [{paths: ['.>cookie'], version: '1.0.0; rm'}]},
    ],
    [
      'a path segment with a metacharacter',
      {findings: [{paths: ['.>$(x)>cookie'], version: '0.6.0'}]},
    ],
  ])('rejects %s', (_label, overrides) => {
    expect(
      normalizePnpmAudit(auditReport(auditAdvisory(overrides))).rejectedCount
    ).toBe(1);
  });
});

const alert = (overrides: Record<string, unknown> = {}) => ({
  dependency: {
    manifest_path: 'pnpm-lock.yaml',
    package: {ecosystem: 'npm', name: 'cookie'},
    relationship: 'transitive',
    scope: 'runtime',
  },
  number: 41,
  security_advisory: {
    epss: [{percentage: 0.25, percentile: 0.9}],
    ghsa_id: 'GHSA-pxg6-pf52-xh8x',
    severity: 'high',
  },
  security_vulnerability: {
    first_patched_version: {identifier: '0.7.0'},
    vulnerable_version_range: '< 0.7.0',
  },
  state: 'open',
  ...overrides,
});

describe('normalizeAlerts', () => {
  test('keeps the allowlisted fields, EPSS from the array shape', () => {
    expect(normalizeAlerts([alert()], OPEN).records).toStrictEqual([
      {
        epssPercentage: 0.25,
        firstPatchedVersion: '0.7.0',
        ghsa: 'GHSA-pxg6-pf52-xh8x',
        manifestPath: 'pnpm-lock.yaml',
        number: 41,
        package: 'cookie',
        relationship: 'transitive',
        scope: 'runtime',
        severity: 'high',
        vulnerableRange: '< 0.7.0',
      },
    ]);
  });

  test('reads the object EPSS shape and drops a non-finite one', () => {
    const objectShape = alert({
      security_advisory: {
        epss: {percentage: 0.5},
        ghsa_id: 'GHSA-pxg6-pf52-xh8x',
        severity: 'high',
      },
    });
    const textShape = alert({
      security_advisory: {
        epss: [{percentage: 'high'}],
        ghsa_id: 'GHSA-pxg6-pf52-xh8x',
        severity: 'high',
      },
    });

    expect(
      normalizeAlerts([objectShape, textShape], OPEN).records.map(
        (record) => record.epssPercentage
      )
    ).toStrictEqual([0.5, null]);
  });

  test('skips other states and ecosystems without counting them rejected', () => {
    const result = normalizeAlerts(
      [
        alert({state: 'fixed'}),
        alert({state: 'dismissed'}),
        alert({
          dependency: {
            manifest_path: 'requirements.txt',
            package: {ecosystem: 'pip', name: 'cookie'},
          },
        }),
      ],
      OPEN
    );

    expect(result).toStrictEqual({records: [], rejectedCount: 0});
  });
});

describe('baseline', () => {
  test('acknowledges only through pnpm ids, never by module name', () => {
    const base = advisory({pnpmIds: [111]});

    expect(applyBaseline(base, new Set([999]))).toMatchObject({
      baselineAcknowledged: false,
      baselineIds: [],
    });
    expect(applyBaseline(base, new Set([111]))).toMatchObject({
      baselineAcknowledged: true,
      baselineIds: [111],
    });
  });

  test('an advisory with no pnpm ids is never acknowledged', () => {
    expect(
      applyBaseline(advisory({pnpmIds: []}), new Set([111]))
        .baselineAcknowledged
    ).toBe(false);
  });

  test('the pnpm-audit count drops acknowledged keys; the alerts count does not', () => {
    const acknowledged = advisory({baselineAcknowledged: true, key: 'a'});
    const open = advisory({key: 'b'});

    expect(countAdvisories('pnpm-audit', [acknowledged, open])).toBe(1);
    expect(countAdvisories('dependabot', [acknowledged, open])).toBe(2);
  });
});

describe('joinAuditToAlerts', () => {
  test('one advisory per GHSA, with pnpm ids and chains joined by GHSA', () => {
    const alerts = normalizeAlerts(
      [41, 42].map((number) => ({
        dependency: {
          manifest_path: 'pnpm-lock.yaml',
          package: {ecosystem: 'npm', name: 'cookie'},
          relationship: 'transitive',
          scope: 'development',
        },
        number,
        security_advisory: {ghsa_id: 'GHSA-pxg6-pf52-xh8x', severity: 'high'},
        security_vulnerability: {vulnerable_version_range: '< 0.7.0'},
        state: 'open',
      })),
      OPEN
    ).records;
    const audit = normalizePnpmAudit(
      auditReport(
        auditAdvisory({
          findings: [
            {paths: ['frontend>react-router>cookie'], version: '0.6.0'},
          ],
        }),
        auditAdvisory({github_advisory_id: 'GHSA-2222-3333-4444', id: 7})
      )
    ).records;
    const [joined, ...rest] = joinAuditToAlerts(alerts, audit);

    expect(rest).toHaveLength(0);
    expect(joined).toMatchObject({
      alerts: [
        {manifestPath: 'pnpm-lock.yaml', number: 41},
        {manifestPath: 'pnpm-lock.yaml', number: 42},
      ],
      chains: [['frontend', 'react-router', 'cookie']],
      key: 'GHSA-pxg6-pf52-xh8x',
      pathCount: 1,
      pnpmIds: [1_098_765],
      scope: 'development',
    });
  });
});

describe('rankAdvisories', () => {
  test('severity first, then EPSS descending, then key', () => {
    const ranked = rankAdvisories([
      advisory({epssPercentage: 0.1, key: 'high-low-epss', severity: 'high'}),
      advisory({epssPercentage: 0.9, key: 'high-high-epss', severity: 'high'}),
      advisory({epssPercentage: 0.01, key: 'critical', severity: 'critical'}),
    ]);

    expect(ranked.map((entry) => entry.key)).toStrictEqual([
      'critical',
      'high-high-epss',
      'high-low-epss',
    ]);
  });

  test('without EPSS it ranks by severity then key, null EPSS last', () => {
    const ranked = rankAdvisories([
      advisory({key: 'pnpm:2', severity: 'low'}),
      advisory({key: 'pnpm:9', severity: 'high'}),
      advisory({key: 'pnpm:3', severity: 'high'}),
      advisory({epssPercentage: 0.001, key: 'pnpm:99', severity: 'high'}),
    ]);

    expect(ranked.map((entry) => entry.key)).toStrictEqual([
      'pnpm:99',
      'pnpm:3',
      'pnpm:9',
      'pnpm:2',
    ]);
  });

  test('two equal advisories tie-break by key ascending', () => {
    const ranked = rankAdvisories([advisory({key: 'b'}), advisory({key: 'a'})]);

    expect(ranked.map((entry) => entry.key)).toStrictEqual(['a', 'b']);
  });
});

describe('classifyCandidates', () => {
  const headChain = [['frontend', 'react-router', 'cookie']];

  test('no patched version blocks with no-patch and no candidates', () => {
    expect(
      classifyCandidates(
        advisory({firstPatchedVersion: null}),
        NO_OFFERS,
        NO_APPLY
      )
    ).toStrictEqual({blockedReason: 'no-patch', candidates: []});
  });

  test('a patch inside the release-age window blocks with release-age', () => {
    expect(
      classifyCandidates(
        advisory({
          insideReleaseAgeWindow: true,
          patchEligibleAt: '2026-10-06T08:00:00.000Z',
        }),
        NO_OFFERS,
        NO_APPLY
      )
    ).toStrictEqual({blockedReason: 'release-age', candidates: []});
  });

  test('a parent range that refuses the patch omits in-range-refresh', () => {
    expect(
      classifyCandidates(
        advisory({parentRangeAdmitsPatch: false}),
        NO_OFFERS,
        NO_APPLY
      ).candidates
    ).toStrictEqual(['override']);
  });

  test('a wave_b chain head with an empty apply set yields chain-head-major last', () => {
    expect(
      classifyCandidates(
        advisory({chains: headChain}),
        {waveA: new Set(), waveB: new Set(['react-router'])},
        NO_APPLY
      ).candidates
    ).toStrictEqual(['in-range-refresh', 'override', 'chain-head-major']);
  });

  test('a wave_a chain head yields exactly one chain-head-minor', () => {
    expect(
      classifyCandidates(
        advisory({chains: headChain}),
        {waveA: new Set(['react-router']), waveB: new Set()},
        NO_APPLY
      ).candidates
    ).toStrictEqual(['in-range-refresh', 'chain-head-minor', 'override']);
  });

  test('a head in the apply set yields chain-head-in-run and no chain-head-minor', () => {
    expect(
      classifyCandidates(
        advisory({chains: headChain}),
        {waveA: new Set(['react-router']), waveB: new Set(['react-router'])},
        new Set(['react-router'])
      ).candidates
    ).toStrictEqual(['in-range-refresh', 'chain-head-in-run', 'override']);
  });

  test('an empty apply set never yields chain-head-in-run', () => {
    const offers = {
      waveA: new Set(['react-router']),
      waveB: new Set(['react-router']),
    };

    expect(
      classifyCandidates(advisory({chains: headChain}), offers, NO_APPLY)
        .candidates
    ).not.toContain('chain-head-in-run');
  });
});

// The contract's fixed texts, written out here rather than read from the
// module, so a drifted text fails instead of agreeing with itself.
const CONTRACT_REASON_TEXT = {
  'alerts-disabled': 'Dependabot alerts are disabled',
  'alerts-invalid-response': 'alerts response was not valid JSON',
  'alerts-request-failed': 'alerts request failed',
  ci: 'CI run',
  'cli-failed': 'advisories refresh failed',
  forbidden: 'token lacks permission to read Dependabot alerts',
  'gh-missing': 'gh not installed',
  'gh-unauthenticated': 'gh not authenticated',
  'jq-missing': 'jq not installed',
  'no-remote': 'no origin remote',
  'non-github-remote': 'origin is not a GitHub remote',
  'pnpm-audit-failed': 'pnpm audit produced no advisories object',
} as const;

describe('reason text', () => {
  test('the token set is exactly the contract set', () => {
    expect(
      ADVISORY_REASON_TOKENS.toSorted((a, b) => a.localeCompare(b))
    ).toStrictEqual(
      Object.keys(CONTRACT_REASON_TEXT).toSorted((a, b) => a.localeCompare(b))
    );
    expect(
      Object.keys(ADVISORY_REASON_TEXT).toSorted((a, b) => a.localeCompare(b))
    ).toStrictEqual(
      Object.keys(CONTRACT_REASON_TEXT).toSorted((a, b) => a.localeCompare(b))
    );
  });

  test.each(Object.entries(CONTRACT_REASON_TEXT))(
    '%s renders its fixed text',
    (token, text) => {
      expect(reasonText([token as keyof typeof CONTRACT_REASON_TEXT])).toBe(
        text
      );
    }
  );

  test('joins several texts with a semicolon, and nothing for no tokens', () => {
    expect(reasonText(['forbidden', 'pnpm-audit-failed'])).toBe(
      'token lacks permission to read Dependabot alerts; pnpm audit produced no advisories object'
    );
    expect(reasonText([])).toBe('');
  });
});
