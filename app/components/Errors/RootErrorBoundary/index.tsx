/* eslint-disable no-console */
import {isRouteErrorResponse} from 'react-router';
import Document from '~/components/Document';
import ErrorStack from '~/components/Errors/ErrorStack';
import {DEFAULT_LOCALE} from '~/i18n';
import {canUseDOM} from '~/utils/dom';
import type {Route} from '../../../../.react-router/types/app/+types/root';

// This boundary intentionally does NOT use useTranslation: it renders when
// the app (potentially including i18n) has already failed, so its visible
// strings stay as English literals to avoid a cascade failure. lang is
// derived from DEFAULT_LOCALE rather than hardcoded.
const RootErrorBoundary = ({error}: Route.ErrorBoundaryProps) => {
  if (!canUseDOM) {
    // Server-Side log of error
    console.error(error);
  }

  if (isRouteErrorResponse(error)) {
    return (
      <Document lang={DEFAULT_LOCALE} noIndex={true} title={error.statusText}>
        <main className="absolute inset-0 flex items-center justify-center p-4">
          <div className="flex flex-col items-center gap-5 text-center">
            <h1 className="flex items-center gap-4 text-2xl tracking-wide">
              <span className="text-2xl leading-none">{error.status}</span>
              {error.statusText && (
                <>
                  <span className="mt-0.75 h-8 w-px bg-gray-900" />
                  <span className="mt-0.5 text-base leading-none font-light">
                    {error.statusText}
                  </span>
                </>
              )}
            </h1>
            {process.env.NODE_ENV !== 'production' && error.status !== 404 && (
              <ErrorStack
                className="max-h-128 overflow-y-auto"
                stack={typeof error.data === 'string' ? error.data : undefined}
              />
            )}
          </div>
        </main>
      </Document>
    );
  }

  if (error instanceof Error) {
    return (
      <Document lang={DEFAULT_LOCALE} noIndex={true} title="Error">
        <main className="space-y-4 p-4">
          <h1 className="text-2xl">Error</h1>
          <p>{error.message}</p>
          <ErrorStack stack={error.stack} />
        </main>
      </Document>
    );
  }

  return (
    <Document lang={DEFAULT_LOCALE} noIndex={true} title="Unexpected error">
      <main className="p-4">
        <h1 className="text-2xl">An unexpected error occurred</h1>
      </main>
    </Document>
  );
};

export default RootErrorBoundary;
