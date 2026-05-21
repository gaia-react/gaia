import {describe, expect, it} from 'vitest';
import {MentorshipConfigSchema} from '../mentorship-config.js';

const baseConfig = {
  analytics: {enabled: false},
  decided_at: null,
  decided_via: null,
  enabled: null,
};

describe('schemas/mentorship-config', () => {
  it('accepts the pre-decision default (null decided_at)', () => {
    expect(() => MentorshipConfigSchema.parse(baseConfig)).not.toThrow();
  });

  it('accepts an ISO-8601 datetime for decided_at', () => {
    expect(() =>
      MentorshipConfigSchema.parse({
        ...baseConfig,
        decided_at: '2026-05-06T12:34:56.789Z',
        decided_via: 'gaia-init',
        enabled: true,
      })
    ).not.toThrow();
  });

  it('rejects a non-datetime string for decided_at', () => {
    expect(() =>
      MentorshipConfigSchema.parse({
        ...baseConfig,
        decided_at: '2026-05-06',
        decided_via: 'gaia-init',
        enabled: true,
      })
    ).toThrow();
  });

  it('rejects an unknown decided_via value', () => {
    expect(() =>
      MentorshipConfigSchema.parse({
        ...baseConfig,
        decided_via: 'unknown-source',
      })
    ).toThrow();
  });
});
