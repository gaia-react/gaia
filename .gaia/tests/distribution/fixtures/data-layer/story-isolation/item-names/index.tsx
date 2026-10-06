import {useQuery} from '@tanstack/react-query';
import {itemsQuery} from '~/services/gaia/items/queries';

const ItemNames = () => {
  const {data, isPending} = useQuery(itemsQuery());

  if (isPending) return <p>Loading items</p>;

  return (
    <ul>
      {data?.map((item) => (
        <li key={item.id}>{item.displayName}</li>
      ))}
    </ul>
  );
};

export default ItemNames;
