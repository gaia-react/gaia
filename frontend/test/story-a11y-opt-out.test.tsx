import {composeStories} from '@storybook/react-vite';
import {isEqual} from 'lodash-es';
import {describe, expect, test} from 'vitest';
import a11y from '../.storybook/a11y';

type ComposedStoryA11y = {
  globals?: {a11y?: {manual?: boolean}};
  id: string;
  parameters: {
    a11y: {
      config?: unknown;
      context?: unknown;
      disable?: boolean;
      options?: unknown;
      test?: string;
    };
  };
  tags: string[];
};
type StoryModule = Parameters<typeof composeStories>[0];

// A story's light-theme axe check runs only in the Vitest storybook project,
// under addon-a11y; the Playwright scan covers dark. addon-a11y hands axe three
// per-story inputs: `a11y.context`, `a11y.config` and `a11y.options`. A story
// is opted out when any of them differs from the shared defaults in
// `.storybook/a11y.ts` (a narrower scope, a disabled rule, a different tag
// set), when `a11y.test` is not 'error', when `a11y.disable` is set, when the
// `a11y.manual` global is on, or when the `test` tag is lost to a `!test` tag.
// An opt-out needs its story id and a reason in this map.
const A11Y_OPT_OUT_REASONS: Record<string, string> = {};

const storyModules = import.meta.glob<StoryModule>('../app/**/*.stories.tsx', {
  eager: true,
});

const hasA11yOptOut = (story: ComposedStoryA11y) => {
  const {
    config,
    context,
    disable,
    options,
    test: testMode,
  } = story.parameters.a11y;

  return (
    testMode !== 'error' ||
    disable === true ||
    story.globals?.a11y?.manual === true ||
    !story.tags.includes('test') ||
    context !== undefined ||
    !isEqual(config, a11y.config) ||
    !isEqual(options, a11y.options)
  );
};

const resolveStoryA11yOptOuts = () =>
  Object.values(storyModules).flatMap((storyModule) =>
    Object.values<ComposedStoryA11y>(
      composeStories(storyModule, {parameters: {a11y}})
    ).map((story) => ({id: story.id, isOptedOut: hasA11yOptOut(story)}))
  );

describe('story a11y opt-outs', () => {
  test('every story fails on an axe violation unless its opt-out is recorded', () => {
    const storyOptOuts = resolveStoryA11yOptOuts();

    expect(storyOptOuts).not.toHaveLength(0);

    const unrecorded = storyOptOuts.filter(
      ({id, isOptedOut}) => isOptedOut && !(id in A11Y_OPT_OUT_REASONS)
    );

    expect(unrecorded).toEqual([]);
  });
});
