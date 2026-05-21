import type {FC, ReactNode} from 'react';
import {Links, Scripts, ScrollRestoration} from 'react-router';
import {twJoin} from 'tailwind-merge';
import {useOptionalTheme} from '~/routes/resources+/theme-switch';
import {useNonce} from '~/utils/nonce';
import {useOptionalRequestInfo} from '~/utils/request-info';
import MetaHydrated from './MetaHydrated';

const THEME_SCRIPT =
  "(function(){try{if(window.matchMedia('(prefers-color-scheme: dark)').matches){document.documentElement.classList.add('dark')}}catch(e){}})()";

type DocumentProps = {
  children: ReactNode;
  className?: string;
  dir?: string;
  lang: string;
  // eslint-disable-next-line react/boolean-prop-naming
  noIndex?: boolean;
  title?: string;
};

const Document: FC<DocumentProps> = ({
  children,
  className,
  dir,
  lang,
  noIndex,
  title,
}) => {
  const nonce = useNonce();
  const theme = useOptionalTheme();
  const requestInfo = useOptionalRequestInfo();
  const hasExplicitTheme = requestInfo?.userPrefs.theme != null;

  return (
    <html
      className={twJoin(theme === 'dark' && 'dark', className)}
      dir={dir}
      lang={lang}
      suppressHydrationWarning={true}
    >
      <head>
        {!hasExplicitTheme && (
          <script
            dangerouslySetInnerHTML={{__html: THEME_SCRIPT}}
            nonce={nonce}
          />
        )}
        <meta charSet="utf-8" />
        <meta content="width=device-width,initial-scale=1" name="viewport" />
        <MetaHydrated />
        <Links />
        <link href="https://fonts.googleapis.com" rel="preconnect" />
        <link
          crossOrigin="anonymous"
          href="https://fonts.gstatic.com"
          rel="preconnect"
        />
        <link
          href="https://fonts.googleapis.com/css2?family=Inter:wght@100..900&display=swap"
          rel="stylesheet"
        />
        {noIndex && <meta content="noindex" name="robots" />}
        {title && <title>{title}</title>}
      </head>
      <body>
        {children}
        <ScrollRestoration nonce={nonce} />
        <Scripts nonce={nonce} />
      </body>
    </html>
  );
};

export default Document;
