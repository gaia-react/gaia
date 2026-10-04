import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {Textarea} from '~/components/ui/textarea';

const meta: Meta = {
  component: Textarea,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'max-w-sm p-4',
  },
  title: 'Components/Ui/Textarea',
};

export default meta;

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return <Textarea aria-label={t('description')} />;
};

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return <Textarea aria-invalid={true} aria-label={t('description')} />;
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return <Textarea aria-label={t('description')} disabled={true} />;
};
