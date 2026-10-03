/* eslint-disable canonical/filename-match-exported */
import type {FC, ReactNode} from 'react';

type StateProps = {
  children: ReactNode;
};

const State: FC<StateProps> = ({children}) => <>{children}</>;

export default State;
