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

const Options = () => {
  const {t} = useTranslation();

  return (
    <>
      <NativeSelectOption value="">
        {t('theme.useSystemTheme')}
      </NativeSelectOption>
      <NativeSelectOptGroup label={t('form.optional')}>
        <NativeSelectOption value="light">
          {t('theme.light')}
        </NativeSelectOption>
        <NativeSelectOption value="dark">{t('theme.dark')}</NativeSelectOption>
      </NativeSelectOptGroup>
    </>
  );
};

export const Default: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <div className="flex flex-col items-start gap-4">
      <NativeSelect aria-label={t('theme.useSystemTheme')}>
        <Options />
      </NativeSelect>
      <NativeSelect aria-label={t('theme.useSystemTheme')} size="sm">
        <Options />
      </NativeSelect>
    </div>
  );
};

export const Invalid: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <NativeSelect aria-invalid={true} aria-label={t('theme.useSystemTheme')}>
      <Options />
    </NativeSelect>
  );
};

export const Disabled: StoryFn = () => {
  const {t} = useTranslation();

  return (
    <NativeSelect aria-label={t('theme.useSystemTheme')} disabled={true}>
      <Options />
    </NativeSelect>
  );
};
