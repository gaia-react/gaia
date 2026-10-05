import type {Meta, StoryFn} from '@storybook/react-vite';
import stubs from 'test/stubs';
import LanguageSelect from '..';

const meta: Meta = {
  component: LanguageSelect,
  decorators: [stubs.reactRouter()],
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Components/LanguageSelect',
};

export default meta;

// Renders nothing until a second locale is added to LANGUAGES.
export const Default: StoryFn = () => <LanguageSelect />;
