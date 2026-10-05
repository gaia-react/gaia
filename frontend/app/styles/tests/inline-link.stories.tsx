import type {Meta, StoryFn} from '@storybook/react-vite';

const meta: Meta = {
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-prose p-4',
  },
  title: 'Styles/InlineLink',
};

export default meta;

// The base `a` rule underlines every anchor that is not a ui component, so a
// link inside running text is told apart by more than its color.
export const Default: StoryFn = () => (
  <div className="flex flex-col gap-4">
    <p>
      Read the <a href="https://example.com/docs">documentation</a> before you
      start.
    </p>
    <p className="text-muted-foreground text-sm">
      Secondary text with an <a href="https://example.com/terms">inline link</a>{' '}
      keeps its underline.
    </p>
  </div>
);
