import type {FC, ReactNode} from 'react';

type FieldExtraProps = {
  children: ReactNode;
};

const FieldExtra: FC<FieldExtraProps> = ({children}) => (
  <div className="ml-4 w-fit py-px text-xs font-normal select-none">
    {children}
  </div>
);

export default FieldExtra;
