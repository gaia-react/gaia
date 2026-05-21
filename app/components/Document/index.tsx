import type {FC, ReactNode} from 'react';
import {Links, Scripts, ScrollRestoration} from 'react-router';
import {twJoin} from 'tailwind-merge';
import {useOptionalTheme} from '~/routes/resources+/theme-switch';
import {ClientHintCheck} from '~/utils/client-hints';
import {useNonce} from '~/utils/nonce';
import MetaHydrated from './MetaHydrated';

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

  return (
    <html
      className={twJoin(theme === 'dark' && 'dark', className)}
      dir={dir}
      lang={lang}
      suppressHydrationWarning={true}
    >
      <head>
        <ClientHintCheck nonce={nonce} />
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
