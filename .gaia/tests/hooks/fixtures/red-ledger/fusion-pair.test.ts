test('token fusion', () => {
  const s = typeof/* joins */'x';
  expect(s).toBe('string');
});

test('token fusion', () => {
  const s = typeof'x';
  expect(s).toBe('string');
});
