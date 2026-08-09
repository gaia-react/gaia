import {defineConfig} from 'vitest/config';

export default defineConfig({
  test: {
    include: ['./src/**/*.test.{ts,tsx}', './test-fixtures/**/*.test.{ts,tsx}'],
    // Suppresses git's background auto-maintenance for every git subprocess the
    // run spawns. Its own docblock carries the rationale, and
    // `src/util/git-maintenance-env.test.ts` proves it reaches git.
    setupFiles: ['./src/util/git-maintenance-env.ts'],
  },
});
