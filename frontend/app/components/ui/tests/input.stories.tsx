import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {Input} from '~/components/ui/input';

const meta: Meta = {
  component: Input,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Input',
};

export default meta;

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return <Input aria-label={t('email')} placeholder={t('emailPlaceholder')} />;
};

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Input
      aria-invalid={true}
      aria-label={t('email')}
      placeholder={t('emailPlaceholder')}
    />
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <Input
      aria-label={t('email')}
      disabled={true}
      placeholder={t('emailPlaceholder')}
    />
  );
};
