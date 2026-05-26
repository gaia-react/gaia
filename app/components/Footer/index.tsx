import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import {twMerge} from 'tailwind-merge';

type FooterProps = {
  className?: string;
};

const Footer: FC<FooterProps> = ({className}) => {
  const {t} = useTranslation('common');

  return (
    <footer
      className={twMerge(
        'text-secondary relative z-10 w-full px-8 py-6 text-xs sm:px-16',
        className
      )}
    >
      <div className="flex w-full flex-col items-center justify-between gap-1 sm:flex-row">
        <span suppressHydrationWarning={true}>
          &copy;{new Date().getFullYear()} GAIA Framework
        </span>
        <span className="text-secondary">
          Powered by React Router and Tailwind CSS
        </span>
        <a
          className="hover:text-body transition-colors"
          href="https://github.com/gaia-react/gaia?tab=MIT-1-ov-file#readme"
          rel="noreferrer"
          target="_blank"
        >
          {t('license')}
        </a>
      </div>
    </footer>
  );
};

Footer.displayName = 'Footer';

export default Footer;
