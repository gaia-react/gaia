import {composeStories} from '@storybook/react-vite';
import {describe, expect, test} from 'vitest';
import a11y from '../.storybook/a11y';

type A11yRule = {enabled?: boolean; id?: string};
type ComposedStoryA11y = {
  globals?: {a11y?: {manual?: boolean}};
  id: string;
  parameters: {
    a11y: {
      config?: {rules?: A11yRule[]};
      disable?: boolean;
      test?: string;
    };
  };
  tags: string[];
};
type StoryModule = Parameters<typeof composeStories>[0];

// A story's light-theme axe check runs only in the Vitest storybook project,
// under addon-a11y; the Playwright scan covers dark. A story that resolves
// `a11y.test` to 'todo' or 'off', sets `a11y.disable`, turns on the
// `a11y.manual` global, loses the `test` tag to a `!test` tag, or disables a
// rule beyond the shared config therefore has no full light check. An opt-out
// needs its story id and a reason in this map.
const A11Y_OPT_OUT_REASONS: Record<string, string> = {};

const storyModules = import.meta.glob<StoryModule>('../app/**/*.stories.tsx', {
  eager: true,
});

const sharedRules: A11yRule[] = a11y.config.rules;
const sharedDisabledRuleIds = new Set(
  sharedRules.filter(({enabled}) => enabled === false).map(({id}) => id)
);

const isOptedOut = (story: ComposedStoryA11y) =>
  story.parameters.a11y.test !== 'error' ||
  story.parameters.a11y.disable === true ||
  story.globals?.a11y?.manual === true ||
  !story.tags.includes('test') ||
  Boolean(
    story.parameters.a11y.config?.rules?.some(
      ({enabled, id}) =>
        enabled === false && !(id && sharedDisabledRuleIds.has(id))
    )
  );

const resolveStoryA11yOptOuts = () =>
  Object.values(storyModules).flatMap((storyModule) =>
    Object.values<ComposedStoryA11y>(
      composeStories(storyModule, {parameters: {a11y}})
    ).map((story) => ({id: story.id, optedOut: isOptedOut(story)}))
  );

describe('story a11y opt-outs', () => {
  test('every story fails on an axe violation unless its opt-out is recorded', () => {
    const resolved = resolveStoryA11yOptOuts();

    expect(resolved).not.toHaveLength(0);

    const unrecorded = resolved.filter(
      ({id, optedOut}) => optedOut && !(id in A11Y_OPT_OUT_REASONS)
    );

    expect(unrecorded).toEqual([]);
  });
});
