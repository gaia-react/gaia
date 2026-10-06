import {queryOptions} from '@tanstack/react-query';

type SsrQueryData = {
  label: string;
};

// A relative URL has no origin to resolve against on the server, so the
// fetch throws there: a server render that ran this query would error rather
// than quietly render the fallback.
export const ssrQueryOptions = () =>
  queryOptions({
    queryFn: async ({signal}) => {
      const response = await fetch('/ssr-query-probe.json', {signal});

      return (await response.json()) as SsrQueryData;
    },
    queryKey: ['ssr-query-probe'],
  });
