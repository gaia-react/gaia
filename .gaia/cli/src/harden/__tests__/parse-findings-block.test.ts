import {describe, expect, test, vi} from 'vitest';
import {parseFindingsBlock} from '../parse-findings-block.js';
import type {RejectReason} from '../parse-findings-block.js';

const block = (payload: string): string =>
  [
    'Human-readable summary line.',
    '<!-- gaia-harden:findings:start -->',
    '<!--',
    payload,
    '-->',
    '<!-- gaia-harden:findings:end -->',
  ].join('\n');

describe('parseFindingsBlock', () => {
  test('extracts findings from the HTML-comment payload between the sentinels', () => {
    const body = block(
      JSON.stringify({
        auditor: 'ci',
        findings: [
          {
            area_tags: ['app/components'],
            finding_class: 'react-doctor/no-generic-handler-names',
            severity: 'warning',
          },
          {
            area_tags: ['app/routes'],
            finding_class: 'holistic/missing-auth-check',
            severity: 'error',
          },
        ],
        pr_number: 42,
        schema: 1,
      })
    );

    const parsedBlock = parseFindingsBlock(body);
    expect(parsedBlock).toEqual({
      auditor: 'ci',
      findings: [
        {
          area_tags: ['app/components'],
          finding_class: 'react-doctor/no-generic-handler-names',
          severity: 'warning',
        },
        {
          area_tags: ['app/routes'],
          finding_class: 'holistic/missing-auth-check',
          severity: 'error',
        },
      ],
    });
  });

  test('returns the auditor verbatim alongside [] for an explicit empty findings block', () => {
    const body = block(
      JSON.stringify({auditor: 'ci', findings: [], pr_number: 7, schema: 1})
    );
    expect(parseFindingsBlock(body)).toEqual({auditor: 'ci', findings: []});
  });

  test('returns null when no sentinels are present', () => {
    expect(parseFindingsBlock('just a normal comment')).toBeNull();
  });

  test('returns null when the payload between sentinels is not valid JSON', () => {
    const body = [
      '<!-- gaia-harden:findings:start -->',
      '<!-- { not json } -->',
      '<!-- gaia-harden:findings:end -->',
    ].join('\n');
    expect(parseFindingsBlock(body)).toBeNull();
  });

  test('drops malformed finding entries but keeps well-formed ones', () => {
    const body = block(
      JSON.stringify({
        auditor: 'local',
        findings: [
          {area_tags: 'not-an-array', finding_class: 5, severity: 'warning'},
          {
            area_tags: ['app'],
            finding_class: 'knip/exports',
            severity: 'warning',
          },
        ],
        pr_number: 9,
        schema: 1,
      })
    );

    expect(parseFindingsBlock(body)).toEqual({
      auditor: 'local',
      findings: [
        {
          area_tags: ['app'],
          finding_class: 'knip/exports',
          severity: 'warning',
        },
      ],
    });
  });

  test('fires onReject naming the unaccepted severity token, UAT-036', () => {
    const body = block(
      JSON.stringify({
        findings: [
          {
            area_tags: ['app'],
            finding_class: 'holistic/missing-auth-check',
            severity: 'Critical',
          },
        ],
        pr_number: 1,
        schema: 1,
      })
    );
    const onReject = vi.fn();

    expect(parseFindingsBlock(body, onReject)).toEqual({
      auditor: '',
      findings: [],
    });
    expect(onReject).toHaveBeenCalledExactlyOnceWith('severity', 'Critical');
  });

  test('fires onReject for a missing finding_class', () => {
    const body = block(
      JSON.stringify({
        findings: [{area_tags: [], severity: 'warning'}],
        pr_number: 1,
        schema: 1,
      })
    );
    const onReject = vi.fn();

    expect(parseFindingsBlock(body, onReject)).toEqual({
      auditor: '',
      findings: [],
    });
    expect(onReject).toHaveBeenCalledExactlyOnceWith(
      'finding_class',
      'undefined'
    );
  });

  test('fires onReject for malformed area_tags', () => {
    const body = block(
      JSON.stringify({
        findings: [
          {
            area_tags: [1, 2],
            finding_class: 'knip/exports',
            severity: 'warning',
          },
        ],
        pr_number: 1,
        schema: 1,
      })
    );
    const onReject = vi.fn();

    expect(parseFindingsBlock(body, onReject)).toEqual({
      auditor: '',
      findings: [],
    });
    expect(onReject).toHaveBeenCalledExactlyOnceWith('area_tags', '[1,2]');
  });

  test('fires onReject for a non-object entry', () => {
    const body = block(
      JSON.stringify({findings: ['not-an-object'], pr_number: 1, schema: 1})
    );
    const onReject = vi.fn();

    expect(parseFindingsBlock(body, onReject)).toEqual({
      auditor: '',
      findings: [],
    });
    expect(onReject).toHaveBeenCalledExactlyOnceWith('shape', 'not-an-object');
  });

  test('never fires onReject on a null return (no parseable block)', () => {
    const onReject = vi.fn();

    expect(parseFindingsBlock('just a normal comment', onReject)).toBeNull();
    expect(
      parseFindingsBlock(
        [
          '<!-- gaia-harden:findings:start -->',
          '<!-- { not json } -->',
          '<!-- gaia-harden:findings:end -->',
        ].join('\n'),
        onReject
      )
    ).toBeNull();
    expect(onReject).not.toHaveBeenCalled();
  });

  test('normalizes a missing auditor field to the "" bucket', () => {
    const body = block(JSON.stringify({findings: [], pr_number: 1, schema: 1}));
    expect(parseFindingsBlock(body)).toEqual({auditor: '', findings: []});
  });

  test('normalizes an empty-string auditor to the "" bucket', () => {
    const body = block(
      JSON.stringify({auditor: '', findings: [], pr_number: 1, schema: 1})
    );
    expect(parseFindingsBlock(body)).toEqual({auditor: '', findings: []});
  });

  test('normalizes a non-string auditor to the "" bucket', () => {
    const body = block(
      JSON.stringify({auditor: 7, findings: [], pr_number: 1, schema: 1})
    );
    expect(parseFindingsBlock(body)).toEqual({auditor: '', findings: []});
  });

  test('accepts every declared reject reason', () => {
    // Type-level assertion: RejectReason is exactly the four drop paths.
    const reasons: RejectReason[] = [
      'area_tags',
      'finding_class',
      'severity',
      'shape',
    ];

    expect(reasons).toHaveLength(4);
  });
});
