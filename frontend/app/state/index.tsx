/* eslint-disable canonical/filename-match-exported */
import type {ReactNode} from 'react';

type StateProps = {
  children: ReactNode;
};

const State = ({children}: StateProps) => <>{children}</>;

export default State;
