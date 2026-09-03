/**
 * Behavior of the shared `gaia <command>` invocation matcher.
 *
 * No `skipIf`: this exercises the pattern against fixture strings only, so it
 * is runnable wherever the file is, with no routers, templates, or repository
 * corpus in reach. Both consuming guards depend on exactly the shapes asserted
 * here, and neither can show the difference between "this form is unmatchable"
 * and "no such invocation exists in my corpus".
 */
import {describe, expect, test} from 'vitest';
import {
  matchesInvocation,
  matchesUnquotedInvocation,
} from './gaia-invocation-matcher.js';

describe('gaia invocation matcher', () => {
  test('reads a quoted binary path', () => {
    // A release-resolved invocation is frozen in quoted form. Why that counts
    // is argued once, above `invocationPattern` in the module under test.
    expect(
      matchesInvocation(
        'update merge-region',
        '"$LATEST_DIR/.gaia/cli/gaia" update merge-region'
      )
    ).toBe(true);
    expect(
      matchesInvocation(
        'release scrub',
        "'/opt/g/.gaia/cli/gaia-maintainer' release scrub"
      )
    ).toBe(true);

    // Regression controls for the two forms that already worked: a bare name,
    // and an unquoted path prefix.
    expect(
      matchesInvocation('update merge-region', 'gaia update merge-region')
    ).toBe(true);
    expect(
      matchesInvocation(
        'update merge-region',
        '$LATEST_DIR/.gaia/cli/gaia update merge-region'
      )
    ).toBe(true);

    // The quote is permitted beside the separator, never instead of it.
    expect(
      matchesInvocation('update merge-region', 'gaia"update merge-region')
    ).toBe(false);
    // Both boundaries survive: a longer command name is not a prefix match,
    // and a longer binary name is not the binary.
    expect(
      matchesInvocation('wiki state', '"$D/.gaia/cli/gaia" wiki state-bump')
    ).toBe(false);
    expect(
      matchesInvocation('update merge-region', 'notgaia update merge-region')
    ).toBe(false);
  });

  test('the unquoted control is the pre-widening shape, and nothing else', () => {
    // What makes the control a control: it refuses exactly the quoted form and
    // accepts everything the widened matcher accepted before `#1037`. Without
    // this, a control that had silently become a synonym for `matchesInvocation`
    // would still green every assertion that uses it, and the two guards would
    // lose their only evidence that the widening is what their fixtures prove.
    expect(
      matchesUnquotedInvocation(
        'update merge-region',
        '"$LATEST_DIR/.gaia/cli/gaia" update merge-region'
      )
    ).toBe(false);
    expect(
      matchesUnquotedInvocation(
        'update merge-region',
        'gaia update merge-region'
      )
    ).toBe(true);
    expect(
      matchesUnquotedInvocation(
        'update merge-region',
        '$LATEST_DIR/.gaia/cli/gaia update merge-region'
      )
    ).toBe(true);
  });
});
