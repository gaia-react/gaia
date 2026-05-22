import {defineConfig} from 'vitest/config';

export default defineConfig({
  test: {
    include: ['./src/**/*.test.{ts,tsx}', './test-fixtures/**/*.test.{ts,tsx}'],
  },
});
