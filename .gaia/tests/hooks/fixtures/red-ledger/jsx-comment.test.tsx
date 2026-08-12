import {expect, test} from 'vitest';
import {render} from '@testing-library/react';

test('jsx text begins with a slash', () => {
  render(<div>// alpha{/* revised note */}</div>);
  expect(true).toBe(true);
});
