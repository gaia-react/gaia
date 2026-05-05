import type {FC, ReactNode} from 'react';

type FieldExtraProps = {
  children: ReactNode;
};

const FieldExtra: FC<FieldExtraProps> = ({children}) => (
  <div className="ml-4 w-fit select-none py-px text-xs font-normal">
    {children}
  </div>
);

export default FieldExtra;
