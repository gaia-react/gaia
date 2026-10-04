import type {ChangeEventHandler} from 'react';
import {useTranslation} from 'react-i18next';
import {useFetcher, useLocation} from 'react-router';
import {cn} from 'cn';
import {ACTION_PATHS} from '~/action-paths';
import {NativeSelect, NativeSelectOption} from '~/components/ui/native-select';
import {LANGUAGES} from '~/languages';

// Native select intentional: this is a non-Conform chrome control, not a form field.
const LANGUAGE_LABELS: Record<string, string> = {en: 'English'};
const OPTIONS = LANGUAGES.map((value) => ({
  label: LANGUAGE_LABELS[value] ?? value,
  value,
}));

type LanguageSelectProps = {
  className?: string;
  onChange?: () => void;
};

const LanguageSelect = ({className, onChange}: LanguageSelectProps) => {
  const {
    i18n: {language},
    t,
  } = useTranslation();

  const fetcher = useFetcher();
  const location = useLocation();

  // A single configured language offers nothing to switch, so render nothing.
  // The switcher appears once a second locale is added (LANGUAGES grows via the
  // add-locale runbook).
  if (LANGUAGES.length <= 1) return undefined;

  const redirectUrl = `${location.pathname}${location.search}${location.hash}`;

  const handleChangeLanguageForm: ChangeEventHandler<HTMLFormElement> = async (
    event
  ) => {
    await fetcher.submit(event.currentTarget, {
      action: ACTION_PATHS.setLanguage,
      method: 'POST',
    });

    onChange?.();
  };

  return (
    <fetcher.Form
      action={ACTION_PATHS.setLanguage}
      className={cn('flex-none', className)}
      method="POST"
      onChange={handleChangeLanguageForm}
    >
      <input name="redirectUrl" type="hidden" value={redirectUrl} />
      <NativeSelect
        aria-label={t('language')}
        defaultValue={language}
        name="language"
        size="sm"
      >
        {OPTIONS.map(({label, value}) => (
          <NativeSelectOption key={value} value={value}>
            {label}
          </NativeSelectOption>
        ))}
      </NativeSelect>
    </fetcher.Form>
  );
};

export default LanguageSelect;
