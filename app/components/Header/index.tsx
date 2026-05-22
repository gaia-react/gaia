import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import {Link} from 'react-router';
import {twMerge} from 'tailwind-merge';
import GaiaLogo from '~/components/GaiaLogo';
import LanguageSelect from '~/components/LanguageSelect';
import ThemeSwitch from '~/components/ThemeSwitch';
import {useRequestInfo} from '~/utils/request-info';

type HeaderProps = {
  className?: string;
};

const Header: FC<HeaderProps> = ({className}) => {
  const {t} = useTranslation('common');
  const requestInfo = useRequestInfo();

  return (
    <header
      className={twMerge('relative z-10 w-full px-8 py-4 sm:px-16', className)}
    >
      <div className="flex w-full items-center justify-between">
        <Link aria-label={t('meta.siteName')} to="/">
          <GaiaLogo className="h-6 sm:h-7" />
        </Link>
        <div className="flex items-center gap-6">
          <LanguageSelect />
          <ThemeSwitch userPreference={requestInfo.userPrefs.theme} />
        </div>
      </div>
    </header>
  );
};

Header.displayName = 'Header';

export default Header;
