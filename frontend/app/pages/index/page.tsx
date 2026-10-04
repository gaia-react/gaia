import {useTranslation} from 'react-i18next';
import LanguageSelect from '~/components/language-select';
import ThemeSwitch from '~/components/theme-switch';
import {useOptionalRequestInfo} from '~/utils/request-info';

const IndexPage = () => {
  const {t} = useTranslation('common');
  const requestInfo = useOptionalRequestInfo();

  return (
    <div className="flex h-full flex-col items-center justify-center gap-4">
      <h1>{t('meta.siteName')}</h1>
      <ThemeSwitch userPreference={requestInfo?.userPrefs.theme} />
      <LanguageSelect />
    </div>
  );
};

export default IndexPage;
