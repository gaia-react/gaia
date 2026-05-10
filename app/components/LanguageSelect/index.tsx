import type {ChangeEvent, FC} from 'react';
import {useTranslation} from 'react-i18next';
import {useFetcher, useLocation} from 'react-router';
import {twMerge} from 'tailwind-merge';

const OPTIONS = [{label: 'English', value: 'en'}];

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

  const handleChangeLanguage = async (event: ChangeEvent<HTMLFormElement>) => {
    await fetcher.submit(event.currentTarget, {
      action: '/actions/set-language',
      method: 'POST',
    });

    onChange?.();
  };

  return (
    <fetcher.Form
      action="/actions/set-language"
      className={twMerge('relative flex-none text-sm', className)}
      method="POST"
      onChange={handleChangeLanguage}
    >
      <input name="redirectUrl" type="hidden" value={redirectUrl} />
      <select
        aria-label={t('language')}
        className="bg-transparent! ring-0! cursor-pointer border-none bg-none p-0 text-sm"
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
