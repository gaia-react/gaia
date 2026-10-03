import type {PartialStoryFn} from 'storybook/internal/types';
import State from '~/state';

const decorator = () => (Story: PartialStoryFn) => (
  <State>
    <Story />
  </State>
);

export default decorator;
