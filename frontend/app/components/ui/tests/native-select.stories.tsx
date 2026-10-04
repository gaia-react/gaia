import {useTranslation} from 'react-i18next';
import type {Meta, StoryFn} from '@storybook/react-vite';
import {
  NativeSelect,
  NativeSelectOptGroup,
  NativeSelectOption,
} from '~/components/ui/native-select';

const meta: Meta = {
  component: NativeSelect,
  parameters: {
    controls: {hideNoControlsWarning: true},
    wrap: 'p-4',
  },
  title: 'Components/Ui/NativeSelect',
};

export default meta;

const Options = () => (
  <>
    <NativeSelectOption value="">Select</NativeSelectOption>
    <NativeSelectOptGroup label="Group">
      <NativeSelectOption value="one">One</NativeSelectOption>
      <NativeSelectOption value="two">Two</NativeSelectOption>
    </NativeSelectOptGroup>
  </>
);

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex flex-col items-start gap-4">
      <NativeSelect aria-label={t('language')}>
        <Options />
      </NativeSelect>
      <NativeSelect aria-label={t('language')} size="sm">
        <Options />
      </NativeSelect>
    </div>
  );
};

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <NativeSelect aria-invalid={true} aria-label={t('language')}>
      <Options />
    </NativeSelect>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <NativeSelect aria-label={t('language')} disabled={true}>
      <Options />
    </NativeSelect>
  );
};
