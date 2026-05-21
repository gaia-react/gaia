import type {FC} from 'react';
import {useEffect} from 'react';
import {useTranslation} from 'react-i18next';
import {data, Outlet, useLoaderData} from 'react-router';
import {getToast, setToastCookieOptions} from 'remix-toast';
import Document from '~/components/Document';
import RootErrorBoundary from '~/components/Errors/RootErrorBoundary';
import Toast, {notify} from '~/components/Toast';
import {getLanguage, i18nextMiddleware} from '~/middleware/i18next';
import {setApiLanguage} from '~/services/api';
import {languageCookie} from '~/sessions.server/language';
import State from '~/state';
import {isProductionHost} from '~/utils/http.server';
import {useNonce} from '~/utils/nonce';
import {getTheme} from '~/utils/theme.server';
import type {Route} from './+types/root';
import {env, envClient} from './env.server';
import './styles/tailwind.css';

export const middleware = [i18nextMiddleware];

export const loader = async ({context, request}: Route.LoaderArgs) => {
  const isProduction = isProductionHost(request);

  const language = getLanguage(context);

  setApiLanguage(language);

  setToastCookieOptions({secrets: [env.SESSION_SECRET]});

  const {headers, toast} = await getToast(request);

  headers.append('Set-Cookie', await languageCookie.serialize(language));

  headers.set('Vary', 'Cookie');

  const url = new URL(request.url);

  return data(
    {
      ENV: envClient,
      language,
      noIndex: !isProduction,
      requestInfo: {
        origin: url.origin,
        path: url.pathname,
        userPrefs: {theme: getTheme(request)},
      },
      toast,
    },
    {headers}
  );
};

const App: FC = () => {
  const loaderData = useLoaderData<typeof loader>();
  const {i18n} = useTranslation();
  const nonce = useNonce();

  const {ENV, language, noIndex, toast} = loaderData;

  useEffect(() => {
    void i18n.changeLanguage(language);
  }, [i18n, language]);

  useEffect(() => {
    if (toast) {
      notify[toast.type](toast);
    }
  }, [toast]);

  return (
    <Document
      dir={i18n.dir(i18n.language)}
      lang={i18n.language}
      noIndex={noIndex}
    >
      <script
        dangerouslySetInnerHTML={{
          __html: `window.process = ${JSON.stringify({
            env: ENV,
          })}`,
        }}
        nonce={nonce}
      />
      <Outlet />
      <Toast />
    </Document>
  );
};

const AppWithState: FC = () => (
  <State>
    <App />
  </State>
);

export default AppWithState;

export const ErrorBoundary = RootErrorBoundary;
