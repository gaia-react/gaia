/* eslint-disable import-x/no-extraneous-dependencies */
import config from '@gaia-react/lint/stylelint';

// Tailwind's @apply takes utility class names, which never parse as a valid
// at-rule prelude. Remove this override once the pinned @gaia-react/lint
// ignores @apply in at-rule-prelude-no-invalid itself.
export default {
  ...config,
  rules: {
    ...config.rules,
    'at-rule-prelude-no-invalid': [true, {ignoreAtRules: ['apply']}],
  },
};
