import {expect, test} from 'vitest';
import {render} from '@testing-library/react';

test('slash in a string literal', () => {
  const url = 'https://example.test/alpha'; // retrieves the alpha resource
  expect(url).toContain('alpha');
});

test('slash in a template literal', () => {
  const tail = `value // alpha`; // this doubled slash is not a comment opener
  expect(tail).toContain('alpha');
});

test('slash in a regular expression', () => {
  const re = /a\/\/alpha/; // asserts a literal doubled separator
  expect(re.test('a//alpha')).toBe(true);
});

test('slash in jsx text', () => {
  render(<div>// alpha</div>); // rendered text, not a code comment
  expect(true).toBe(true);
});
