// Commit-message lint, run by .husky/commit-msg on every commit and by CI on PR
// titles. Enforces Conventional Commits 1.0.0 (`type(scope)!: summary`) with a
// header of at most 100 characters.
//
// The permitted types live in .gaia/conventional-commits.json (`types`), read
// here at load time so the hook, the branch-name validator and the CLI parser
// share one list. Do not copy the list into this file.
//
// Body and footer line length are off: wrapped bodies, long trailers and URLs
// are not what the convention governs.
import {readFileSync} from 'node:fs';

const {types} = JSON.parse(
  readFileSync(new URL('./.gaia/conventional-commits.json', import.meta.url))
);

export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', types],
    'header-max-length': [2, 'always', 100],
    'body-max-line-length': [0],
    'footer-max-line-length': [0],
  },
};
