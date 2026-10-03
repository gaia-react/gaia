import type {Meta, StoryFn} from '@storybook/react-vite';
import FieldRequiredText from '..';

const meta: Meta = {
  component: FieldRequiredText,
  parameters: {
    controls: {hideNoControlsWarning: true},
  },
  title: 'Form/FieldRequiredText',
};

export default meta;

export const Default: StoryFn = () => (
  <div className="grid max-w-md grid-cols-2 items-center gap-4 p-4">
    <div className="text-sm">Required</div>
    <div>
      <FieldRequiredText />
    </div>
    <div className="text-sm">Validation Failed</div>
    <div>
      <FieldRequiredText error="required" />
    </div>
    <div className="text-sm">Disabled</div>
    <div>
      <FieldRequiredText disabled={true} />
    </div>
  </div>
);
