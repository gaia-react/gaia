import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {SearchIcon} from 'lucide-react';
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

type Align = 'block-end' | 'block-start' | 'inline-end' | 'inline-start';
type ButtonSize = 'icon-sm' | 'icon-xs' | 'sm' | 'xs';

const AddonStory = ({align}: {align: Align}) => {
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

const ButtonStory = ({size}: {size: ButtonSize}) => {
  const {t} = useTranslation();

  return (
    <InputGroup>
      <InputGroupInput aria-label={t('email')} />
      <InputGroupAddon align="inline-end">
        <InputGroupButton aria-label={t('form.submit')} size={size}>
          <SearchIcon />
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
