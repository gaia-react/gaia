import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import IndexPage from '..';

const meta: Meta = {
  component: IndexPage,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Pages/Public/IndexPage',
};

export default meta;

export const Default: StoryFn = () => <IndexPage />;

export const Mobile: StoryFn = () => <IndexPage />;
Mobile.parameters = {
  chromatic: {viewports: [375]},
};
