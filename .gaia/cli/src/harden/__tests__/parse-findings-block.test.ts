import {describe, expect, it} from 'vitest';
import {parseFindingsBlock} from '../parse-findings-block.js';

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
  it('extracts findings from the HTML-comment payload between the sentinels', () => {
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

    const findings = parseFindingsBlock(body);
    expect(findings).toEqual([
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
    ]);
  });

  it('returns [] for an explicit empty findings block', () => {
    const body = block(
      JSON.stringify({auditor: 'ci', findings: [], pr_number: 7, schema: 1})
    );
    expect(parseFindingsBlock(body)).toEqual([]);
  });

  it('returns null when no sentinels are present', () => {
    expect(parseFindingsBlock('just a normal comment')).toBeNull();
  });

  it('returns null when the payload between sentinels is not valid JSON', () => {
    const body = [
      '<!-- gaia-harden:findings:start -->',
      '<!-- { not json } -->',
      '<!-- gaia-harden:findings:end -->',
    ].join('\n');
    expect(parseFindingsBlock(body)).toBeNull();
  });

  it('drops malformed finding entries but keeps well-formed ones', () => {
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

    expect(parseFindingsBlock(body)).toEqual([
      {area_tags: ['app'], finding_class: 'knip/exports', severity: 'warning'},
    ]);
  });
});
