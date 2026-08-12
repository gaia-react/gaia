const double = (n: number): number => n * 2;
test('directive relocates', () => {
  // @ts-expect-error - double requires a number
  double('nope');
  double('also nope');
});
