import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import {FaGithub} from 'react-icons/fa6';
import LinkButton from '~/components/LinkButton';

const CHIPS = [
  'framework',
  'language',
  'styling',
  'testing',
  'forms',
  'components',
] as const;

const IndexPage: FC = () => {
  const {t} = useTranslation('pages', {keyPrefix: 'index'});

  return (
    <div className="bg-body relative flex h-full flex-col overflow-hidden">
      {/* Structural grid texture */}
      <div
        aria-hidden={true}
        className="pointer-events-none absolute inset-0 opacity-[0.08] dark:opacity-[0.06]"
        style={{
          backgroundImage:
            'linear-gradient(to right, currentColor 1px, transparent 1px), linear-gradient(to bottom, currentColor 1px, transparent 1px)',
          backgroundSize: '3rem 3rem',
        }}
      />

      {/* Top accent bar */}
      <div className="bg-claude-500 dark:bg-claude-400 absolute left-0 top-0 z-10 h-0.5 w-full" />

      <section
        aria-labelledby="hero-title"
        className="relative z-10 flex flex-1 flex-col justify-center p-8 sm:px-16 sm:py-12"
      >
        <div className="max-w-3xl">
          <p className="text-claude-700 dark:text-claude-400 mb-4 font-mono text-xs uppercase tracking-widest sm:text-sm">
            {t('eyebrow')}
          </p>

          <h1
            className="text-body mb-6 text-4xl/tight font-light tracking-tight sm:text-6xl sm:leading-none"
            id="hero-title"
          >
            {t('heroTitle')}
          </h1>

          <div className="bg-claude-500 dark:bg-claude-400 mb-8 h-px w-16" />

          <p className="text-secondary mb-10 max-w-xl text-base/relaxed sm:text-lg">
            {t('heroTagline')}
          </p>

          <div className="flex">
            <LinkButton
              className="border-claude-500 text-claude-700 hover:bg-claude-500/10 dark:border-claude-400 dark:text-claude-300 dark:hover:bg-claude-500/15"
              icon={FaGithub}
              size="lg"
              to="https://github.com/gaia-react/gaia"
              variant="secondary"
            >
              {t('cta')}
            </LinkButton>
          </div>
        </div>
      </section>

      <div className="relative z-10 px-8 py-6 sm:px-16">
        <dl className="grid grid-cols-2 gap-x-6 gap-y-4 sm:flex sm:flex-wrap sm:gap-x-10">
          {CHIPS.map((key) => (
            <div key={key} className="flex flex-col gap-0.5">
              <dt className="text-secondary font-mono text-xs uppercase tracking-widest">
                {t(`${key}Label`)}
              </dt>
              <dd className="text-body text-sm font-medium">
                {t(`${key}Value`)}
              </dd>
            </div>
          ))}
        </dl>
      </div>
    </div>
  );
};

export default IndexPage;
