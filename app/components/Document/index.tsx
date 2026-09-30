import type {FC, ReactNode} from 'react';
import {Links, Scripts, ScrollRestoration} from 'react-router';
import {twJoin} from 'tailwind-merge';
import {useOptionalTheme} from '~/hooks/useTheme';
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
  const hasExplicitTheme = !!requestInfo?.userPrefs.theme;

  return (
    <html
      className={twJoin(theme === 'dark' && 'dark', className)}
      dir={dir}
      lang={lang}
      suppressHydrationWarning={true}
    >
      <head>
        {/* The server renders the real nonce and the client renders the
            empty-string default, so the nonce never reaches the client bundle.
            React 19.3+ hydrates against the element's `.nonce` property, which
            keeps the real value after the browser blanks the attribute, so a
            nonced element must suppress that hydration diff: React Router's
            <ScrollRestoration> and <Scripts> do it internally, and app-authored
            inline scripts set suppressHydrationWarning themselves. */}
        {!hasExplicitTheme && (
          <script
            dangerouslySetInnerHTML={{__html: THEME_SCRIPT}}
            nonce={nonce}
            suppressHydrationWarning={true}
          />
        )}
        <meta charSet="utf-8" />
        <meta content="width=device-width,initial-scale=1" name="viewport" />
        <MetaHydrated />
        {/* <Links> emits stylesheets without suppressing the nonce diff, and
            style-src carries no nonce (getContentSecurityPolicy), so it gets an
            empty one on both sides. Omitting the prop does not work: <Links>
            then falls back to the server router's real nonce, and the client
            renders none. */}
        <Links nonce="" />
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
