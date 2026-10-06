import {composeStories} from '@storybook/react-vite';
import {describe, expect, test} from 'vitest';
import a11y from '../.storybook/a11y';

type ComposedStoryA11y = {id: string; parameters: {a11y?: {test?: string}}};
type StoryModule = Parameters<typeof composeStories>[0];

// A story's light-theme axe check runs only in the Vitest storybook project,
// under addon-a11y; the Playwright scan covers dark. A story that resolves
// `a11y.test` to 'todo' or 'off' therefore has no light check at all. An
// opt-out needs its story id and a reason in this map.
const A11Y_OPT_OUT_REASONS: Record<string, string> = {};

const storyModules = import.meta.glob<StoryModule>('../app/**/*.stories.tsx', {
  eager: true,
});

const resolveStoryA11yModes = () =>
  Object.values(storyModules).flatMap((storyModule) =>
    Object.values<ComposedStoryA11y>(
      composeStories(storyModule, {parameters: {a11y}})
    ).map((story) => ({id: story.id, mode: story.parameters.a11y?.test}))
  );

describe('story a11y opt-outs', () => {
  test('every story fails on an axe violation unless its opt-out is recorded', () => {
    const resolved = resolveStoryA11yModes();

    expect(resolved).not.toHaveLength(0);

    const unrecorded = resolved.filter(
      ({id, mode}) => mode !== 'error' && !(id in A11Y_OPT_OUT_REASONS)
    );

    expect(unrecorded).toEqual([]);
  });
});
