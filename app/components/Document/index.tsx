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
        {!hasExplicitTheme && (
          <script
            dangerouslySetInnerHTML={{__html: THEME_SCRIPT}}
            nonce={nonce}
          />
        )}
        <meta charSet="utf-8" />
        <meta content="width=device-width,initial-scale=1" name="viewport" />
        <MetaHydrated />
        {/* Every React Router component that emits a nonced element takes the
            nonce explicitly. The server renders the real value; the browser
            blanks the nonce attribute after parsing, so the client must render
            the empty-string default to match the DOM it hydrates into. */}
        <Links nonce={nonce} />
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
