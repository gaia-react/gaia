import {useSuspenseQuery} from '@tanstack/react-query';
import {ssrQueryOptions} from './query';

const SsrQueryPage = () => {
  const {data} = useSuspenseQuery(ssrQueryOptions());

  return <p>query-data-rendered {data.label}</p>;
};

export default SsrQueryPage;
