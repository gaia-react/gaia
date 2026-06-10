import type {FC} from 'react';
import {useState} from 'react';

const AuditVerboseProbe: FC = () => {
  const [count, setCount] = useState(0);

  const handleClick = () => {
    setCount(count + 1);
  };

  return (
    <button onClick={handleClick} type="button">
      {count}
    </button>
  );
};

export default AuditVerboseProbe;
