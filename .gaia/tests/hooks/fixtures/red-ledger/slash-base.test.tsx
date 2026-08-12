import {expect, test} from 'vitest';
import {render} from '@testing-library/react';

test('slash in a string literal', () => {
  const url = 'https://example.test/alpha'; // fetches the alpha document
  expect(url).toContain('alpha');
});

test('slash in a template literal', () => {
  const tail = `value // alpha`; // the doubled slash is data here
  expect(tail).toContain('alpha');
});

test('slash in a regular expression', () => {
  const re = /a\/\/alpha/; // matches a doubled separator
  expect(re.test('a//alpha')).toBe(true);
});

test('slash in jsx text', () => {
  render(<div>// alpha</div>); // the slashes above are rendered text
  expect(true).toBe(true);
});
