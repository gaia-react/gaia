import {describe, expect, test} from 'vitest';
import {ACTION_PATHS} from '~/action-paths';
import routes from '~/routes';

// Resolving the app's own route config is what gives this test its teeth: the
// paths come back derived from the route files' names by the same convention
// the server uses, so renaming a route file changes what this sees. Comparing
// the declared paths against a hand-written list of expected filenames would
// reimplement that convention and agree with itself while the app 404s.
type RouteEntry = Awaited<typeof routes>[number];

const servedPaths = (entries: RouteEntry[], parent = ''): string[] =>
  entries.flatMap((entry) => {
    const path = [parent, entry.path].filter(Boolean).join('/');
    // A layout route carries children but no path of its own, so it
    // contributes only its children's prefix.
    const own = entry.path === undefined ? [] : [`/${path}`];

    return [...own, ...servedPaths(entry.children ?? [], path)];
  });

describe('ACTION_PATHS', () => {
  test.each(Object.entries(ACTION_PATHS))(
    '%s resolves to a route the app serves',
    async (_name, actionPath) => {
      expect(servedPaths(await routes)).toContain(actionPath);
    }
  );
});
