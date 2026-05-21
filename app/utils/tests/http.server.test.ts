import {describe, expect, test} from 'vitest';
import {getContentSecurityPolicy} from '../http.server';

describe('getContentSecurityPolicy', () => {
  const nonce = 'abc123def456abc1';

  test('returns a string containing the nonce', () => {
    expect(getContentSecurityPolicy(nonce)).toContain(`'nonce-${nonce}'`);
  });

  test('script-src includes self and report-sample', () => {
    const csp = getContentSecurityPolicy(nonce);
    expect(csp).toContain(`script-src 'self' 'report-sample'`);
  });

  test('style-src allows unsafe-inline and Google Fonts', () => {
    const csp = getContentSecurityPolicy(nonce);
    expect(csp).toContain(
      `style-src 'self' 'unsafe-inline' https://fonts.googleapis.com`
    );
  });

  test('font-src allows Google Fonts static', () => {
    const csp = getContentSecurityPolicy(nonce);
    expect(csp).toContain(`font-src 'self' https://fonts.gstatic.com`);
  });

  test('each request produces a different policy when given a different nonce', () => {
    const csp1 = getContentSecurityPolicy('nonce1111111111111');
    const csp2 = getContentSecurityPolicy('nonce2222222222222');
    expect(csp1).not.toBe(csp2);
  });
});
