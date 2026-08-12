import {expect, test} from 'vitest';
import {render} from '@testing-library/react';

test('jsx text begins with a slash', () => {
  render(<div>// alpha{/* trailing note */}</div>);
  expect(true).toBe(true);
});
