import type {Meta, StoryFn} from '@storybook/react-vite';
import {expect, within} from 'storybook/test';
import {
  InputGroup,
  InputGroupAddon,
  InputGroupInput,
} from '~/components/ui/input-group';
import MaxLength from '..';

const meta: Meta = {
  component: MaxLength,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Components/Form/MaxLength',
};

export default meta;

export const Default: StoryFn = () => <MaxLength length={12} maxLength={100} />;

Default.play = async ({canvasElement}) => {
  const counter = within(canvasElement).getByText('12 / 100');

  await expect(counter).toBeVisible();
  await expect(counter).toHaveClass('text-muted-foreground', 'min-w-16');
  await expect(counter).not.toHaveClass('text-destructive');
};

export const AtLimit: StoryFn = () => (
  <MaxLength length={100} maxLength={100} />
);

AtLimit.play = async ({canvasElement}) => {
  const counter = within(canvasElement).getByText('100 / 100');

  await expect(counter).toHaveClass('text-destructive');
  await expect(counter).not.toHaveClass('text-muted-foreground');
};

export const BelowLimit: StoryFn = () => (
  <MaxLength length={99} maxLength={100} />
);

BelowLimit.play = async ({canvasElement}) => {
  await expect(within(canvasElement).getByText('99 / 100')).toHaveClass(
    'text-muted-foreground'
  );
};

export const DigitWidths: StoryFn = () => (
  <div className="flex flex-col gap-2">
    <MaxLength length={1} maxLength={50} />
    <MaxLength length={1} maxLength={5000} />
  </div>
);

DigitWidths.play = async ({canvasElement}) => {
  const canvas = within(canvasElement);

  await expect(canvas.getByText('1 / 50')).toHaveClass('min-w-12');
  await expect(canvas.getByText('1 / 5000')).toHaveClass('min-w-20');
};

export const InInputGroup: StoryFn = () => (
  <InputGroup className="max-w-sm">
    <InputGroupInput aria-label="Nickname" defaultValue="gaia" />
    <InputGroupAddon align="inline-end">
      <MaxLength length={4} maxLength={20} />
    </InputGroupAddon>
  </InputGroup>
);

export const WithClassName: StoryFn = () => (
  <MaxLength className="ml-2" length={1} maxLength={10} />
);

WithClassName.play = async ({canvasElement}) => {
  await expect(within(canvasElement).getByText('1 / 10')).toHaveClass('ml-2');
};
