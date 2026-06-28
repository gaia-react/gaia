import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import LanguageSelect from '~/components/LanguageSelect';
import ThemeSwitch from '~/components/ThemeSwitch';
import {useOptionalRequestInfo} from '~/utils/request-info';

const IndexPage: FC = () => {
  const {t} = useTranslation('common');
  const requestInfo = useOptionalRequestInfo();

  return (
    <div>
      <h1>{t('meta.siteName')}</h1>
      <ThemeSwitch userPreference={requestInfo?.userPrefs.theme} />
      <LanguageSelect />
    </div>
  );
};

export default IndexPage;
