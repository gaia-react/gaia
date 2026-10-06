import {useQueryClient} from '@tanstack/react-query';

// Renders whatever the provider's client holds under the seed page's key, so
// a client carried over from an earlier request shows its value here.
const SsrReadPage = () => {
  const queryClient = useQueryClient();

  return (
    <p>
      {queryClient.getQueryData<string>(['ssr-isolation-probe']) ??
        'isolation-cache-empty'}
    </p>
  );
};

export default SsrReadPage;
