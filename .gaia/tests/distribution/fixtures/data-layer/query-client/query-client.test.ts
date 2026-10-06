import {describe, expect, test} from 'vitest';
import {getQueryClient} from '~/query-client';

describe('getQueryClient on the server', () => {
  test('returns a new client on every call', () => {
    expect(getQueryClient()).not.toBe(getQueryClient());
  });
});
