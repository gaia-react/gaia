import {describe, expect, test} from 'vitest';
import {
  createQueryClient,
  getQueryClient,
  setBrowserQueryClient,
} from '~/query-client';

describe('getQueryClient in the browser', () => {
  test('returns the same client on every call', () => {
    expect(getQueryClient()).toBe(getQueryClient());
  });

  test('returns the client setBrowserQueryClient registered', () => {
    const replacement = createQueryClient();

    setBrowserQueryClient(replacement);

    expect(getQueryClient()).toBe(replacement);
  });
});
