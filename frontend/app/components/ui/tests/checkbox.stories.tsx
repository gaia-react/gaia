import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {Checkbox} from '~/components/ui/checkbox';

const meta: Meta = {
  component: Checkbox,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/Checkbox',
};

export default meta;

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex gap-4">
      <Checkbox aria-label={t('form.ok')} />
      <Checkbox aria-label={t('form.ok')} defaultChecked={true} />
    </div>
  );
};

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex gap-4">
      <Checkbox aria-invalid={true} aria-label={t('form.ok')} />
      <Checkbox
        aria-invalid={true}
        aria-label={t('form.ok')}
        defaultChecked={true}
      />
    </div>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex gap-4">
      <Checkbox aria-label={t('form.ok')} disabled={true} />
      <Checkbox
        aria-label={t('form.ok')}
        defaultChecked={true}
        disabled={true}
      />
    </div>
  );
};
