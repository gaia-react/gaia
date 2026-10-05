import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {Spinner} from '~/components/ui/spinner';

const meta: Meta = {
  component: Spinner,
  parameters: {
    chromatic: {disableSnapshot: true},
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/Spinner',
};

export default meta;

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return <Spinner aria-label={t('loading')} />;
};
