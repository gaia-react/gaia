import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {RadioGroup, RadioGroupItem} from '~/components/ui/radio-group';

const meta: Meta = {
  component: RadioGroup,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'w-fit p-4',
  },
  title: 'Components/Ui/RadioGroup',
};

export default meta;

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <RadioGroup aria-label={t('language')} defaultValue="one">
      <RadioGroupItem aria-label={t('form.ok')} value="one" />
      <RadioGroupItem aria-label={t('form.cancel')} value="two" />
    </RadioGroup>
  );
};

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <RadioGroup aria-label={t('language')} defaultValue="one">
      <RadioGroupItem
        aria-invalid={true}
        aria-label={t('form.ok')}
        value="one"
      />
      <RadioGroupItem
        aria-invalid={true}
        aria-label={t('form.cancel')}
        value="two"
      />
    </RadioGroup>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <RadioGroup aria-label={t('language')} defaultValue="one" disabled={true}>
      <RadioGroupItem aria-label={t('form.ok')} value="one" />
      <RadioGroupItem aria-label={t('form.cancel')} value="two" />
    </RadioGroup>
  );
};
