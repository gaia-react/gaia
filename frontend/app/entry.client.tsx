import {startTransition, StrictMode} from 'react';
import {hydrateRoot} from 'react-dom/client';
import {I18nextProvider, initReactI18next} from 'react-i18next';
import {HydratedRouter} from 'react-router/dom';
import i18next from 'i18next';
import LanguageDetector from 'i18next-browser-languagedetector';
import i18n, {DEFAULT_LOCALE} from './i18n';

const prepareApp = async () => {
  if (
    window.process.env.NODE_ENV === 'development' &&
    window.process.env.MSW_ENABLED === true
  ) {
    const {worker} = await import('../test/worker');

    return worker.start({onUnhandledRequest: 'bypass'});
  }
};

const hydrate = async () => {
  await i18next
    .use(initReactI18next)
    .use(LanguageDetector)
    .init({
      ...i18n,
      detection: {
        caches: [],
        order: ['htmlTag'],
      },
      ns: Object.keys(i18n.resources[DEFAULT_LOCALE]),
    });

  await prepareApp().then(() => {
    // The react-perf capture harness sets this global (via addInitScript, before
    // hydration) to opt out of StrictMode for honest, non-doubled render
    // timings; everything else keeps StrictMode on.
    // eslint-disable-next-line no-underscore-dangle -- global injected by the react-perf capture harness
    const isStrictModeDisabled = window.__PERF_NO_STRICT;
    startTransition(() => {
      hydrateRoot(
        document,
        <I18nextProvider i18n={i18next}>
          {isStrictModeDisabled ?
            <HydratedRouter />
          : <StrictMode>
              <HydratedRouter />
            </StrictMode>
          }
        </I18nextProvider>
      );
    });
  });
};

await hydrate();
