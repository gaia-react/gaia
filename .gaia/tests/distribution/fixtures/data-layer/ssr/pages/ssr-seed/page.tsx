import {useQueryClient} from '@tanstack/react-query';

// Writes into the provider's client during render. If the server shares one
// client across requests, the next request's read page renders this value.
const SsrSeedPage = () => {
  const queryClient = useQueryClient();

  queryClient.setQueryData(['ssr-isolation-probe'], 'isolation-seed-value');

  return <p>{queryClient.getQueryData<string>(['ssr-isolation-probe'])}</p>;
};

export default SsrSeedPage;
