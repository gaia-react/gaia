const double = (n: number): number => n * 2;
test('directive relocates', () => {
  double('nope');
  // @ts-expect-error - double requires a number
  double('also nope');
});
