// Calls each banned imperative fetch through local stand-ins, so the probe
// parses and type-checks in a tree without TanStack Query installed.
type QueryClientStandIn = {
  ensureQueryData: (options: unknown) => unknown;
  fetchQuery: (options: unknown) => unknown;
  prefetchQuery: (options: unknown) => unknown;
};

const queryClient: QueryClientStandIn = {
  ensureQueryData: (options) => options,
  fetchQuery: (options) => options,
  prefetchQuery: (options) => options,
};

const useQueryClient = (): QueryClientStandIn => queryClient;

export const probeImperativeFetches = (options: unknown): unknown[] => [
  queryClient.ensureQueryData(options),
  queryClient.fetchQuery(options),
  queryClient.prefetchQuery(options),
  useQueryClient().fetchQuery(options),
];
