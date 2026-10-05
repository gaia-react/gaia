import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import ThemeSwitch from '..';

const meta: Meta = {
  component: ThemeSwitch,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Components/ThemeSwitch',
};

export default meta;

export const Default: StoryFn = () => <ThemeSwitch />;

export const Light: StoryFn = () => <ThemeSwitch userPreference="light" />;

export const Dark: StoryFn = () => <ThemeSwitch userPreference="dark" />;
