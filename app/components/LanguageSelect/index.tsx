import type {ChangeEvent, FC} from 'react';
import {useTranslation} from 'react-i18next';
import {useFetcher, useLocation} from 'react-router';
import {twMerge} from 'tailwind-merge';
import {LANGUAGES} from '~/languages';

const SET_LANGUAGE_ACTION = '/actions/set-language';

// Native <select> intentional: this is a non-Conform chrome control, not a form field.
const LANGUAGE_LABELS: Record<string, string> = {en: 'English'};
const OPTIONS = LANGUAGES.map((value) => ({
  label: LANGUAGE_LABELS[value] ?? value,
  value,
}));

type LanguageSelectProps = {
  className?: string;
  onChange?: () => void;
};

const LanguageSelect: FC<LanguageSelectProps> = ({className, onChange}) => {
  const {
    i18n: {language},
    t,
  } = useTranslation();

  const fetcher = useFetcher();
  const location = useLocation();

  const redirectUrl = `${location.pathname}${location.search}${location.hash}`;

  const handleChangeLanguageForm = async (
    event: ChangeEvent<HTMLFormElement>
  ) => {
    await fetcher.submit(event.currentTarget, {
      action: SET_LANGUAGE_ACTION,
      method: 'POST',
    });

    onChange?.();
  };

  return (
    <fetcher.Form
      action={SET_LANGUAGE_ACTION}
      className={twMerge('relative flex-none text-sm', className)}
      method="POST"
      onChange={handleChangeLanguageForm}
    >
      <input name="redirectUrl" type="hidden" value={redirectUrl} />
      <select
        aria-label={t('language')}
        className="cursor-pointer border-none bg-transparent! bg-none p-0 text-sm ring-0!"
        defaultValue={language}
        name="language"
      >
        {OPTIONS.map(({label, value}) => (
          <option key={value} className="text-sm" value={value}>
            {label}
          </option>
        ))}
      </select>
    </fetcher.Form>
  );
};

export default LanguageSelect;
