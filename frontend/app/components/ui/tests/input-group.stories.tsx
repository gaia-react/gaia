import type {ComponentProps} from 'react';
import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn, StoryObj} from '@storybook/react-vite';
import {SearchIcon, SendIcon} from 'lucide-react';
import {expect, userEvent, within} from 'storybook/test';
import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
  InputGroupText,
} from '~/components/ui/input-group';

const meta: Meta = {
  component: InputGroup,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/InputGroup',
};

export default meta;

type AddonStoryProps = {align: Align};
type Align = NonNullable<ComponentProps<typeof InputGroupAddon>['align']>;

type ButtonSize = NonNullable<ComponentProps<typeof InputGroupButton>['size']>;
type ButtonStoryProps = {size: ButtonSize};

const AddonStory = ({align}: AddonStoryProps) => {
  const {t} = useTranslation();

  return (
    <InputGroup>
      <InputGroupInput aria-label={t('email')} />
      <InputGroupAddon align={align}>
        <InputGroupText>{t('email')}</InputGroupText>
      </InputGroupAddon>
    </InputGroup>
  );
};

const ButtonStory = ({size}: ButtonStoryProps) => {
  const {t} = useTranslation();

  return (
    <InputGroup>
      <InputGroupInput aria-label={t('email')} />
      <InputGroupAddon align="inline-end">
        <InputGroupButton aria-label={t('form.submit')} size={size}>
          <SendIcon />
        </InputGroupButton>
      </InputGroupAddon>
    </InputGroup>
  );
};

export const AddonInlineStart: StoryFn = () => (
  <AddonStory align="inline-start" />
);

export const AddonInlineEnd: StoryFn = () => <AddonStory align="inline-end" />;

export const AddonBlockStart: StoryFn = () => (
  <AddonStory align="block-start" />
);

export const AddonBlockEnd: StoryFn = () => <AddonStory align="block-end" />;

export const ButtonXs: StoryFn = () => <ButtonStory size="xs" />;

export const ButtonSm: StoryFn = () => <ButtonStory size="sm" />;

export const ButtonIconXs: StoryFn = () => <ButtonStory size="icon-xs" />;

export const ButtonIconSm: StoryFn = () => <ButtonStory size="icon-sm" />;

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <InputGroup>
      <InputGroupInput aria-invalid={true} aria-label={t('email')} />
      <InputGroupAddon>
        <SearchIcon />
      </InputGroupAddon>
    </InputGroup>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <InputGroup>
      <InputGroupInput aria-label={t('email')} disabled={true} />
      <InputGroupAddon>
        <SearchIcon />
      </InputGroupAddon>
    </InputGroup>
  );
};

export const AddonClickFocusesInput: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    const canvas = within(canvasElement);
    const input = canvas.getByRole('textbox', {name: 'Email'});

    await expect(input).not.toHaveFocus();

    await userEvent.click(canvas.getByText('Email'));

    await expect(input).toHaveFocus();
  },
  render: () => <AddonStory align="inline-start" />,
};

export const AddonButtonClickKeepsFocusOnButton: StoryObj<typeof meta> = {
  play: async ({canvasElement}) => {
    const canvas = within(canvasElement);
    const button = canvas.getByRole('button', {name: 'Submit'});

    await userEvent.click(button);

    await expect(button).toHaveFocus();
    await expect(
      canvas.getByRole('textbox', {name: 'Email'})
    ).not.toHaveFocus();
  },
  render: () => <ButtonStory size="xs" />,
};
