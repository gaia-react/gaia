import {expect, test} from 'vitest';
import * as impl from './impl';

test('calls a not-yet-implemented function', () => {
  // @ts-expect-error intentionally missing implementation
  expect(impl.notImplemented()).toBe(1);
});
