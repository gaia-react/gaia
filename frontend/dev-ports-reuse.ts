import {foreignServerMessage, listenerOwner} from './dev-ports';
import type {ListenerOwner} from './dev-ports';

/**
 * Decides whether Playwright may reuse a server already listening on its port.
 * Only a server this tree owns is reused; one another tree owns is refused
 * loudly, because a spec run against another tree's code proves nothing.
 */
export const decideServerReuse = ({
  isContinuousIntegration,
  port,
  probe = listenerOwner,
  treeRoot,
}: {
  isContinuousIntegration: boolean;
  port: number;
  probe?: (input: {
    port: number;
    treeRoot: string | undefined;
  }) => ListenerOwner;
  treeRoot: string | undefined;
}): boolean => {
  if (isContinuousIntegration) return false;

  const owner = probe({port, treeRoot});

  if (owner.kind === 'foreign') {
    throw new Error(foreignServerMessage({ownerPath: owner.ownerPath, port}));
  }

  return owner.kind === 'own';
};
