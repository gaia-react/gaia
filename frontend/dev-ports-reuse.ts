import {buildForeignServerMessage, findListenerOwner} from './dev-ports';

/**
 * Decides whether Playwright may reuse a server already listening on its port.
 * Only a server this tree owns is reused; one another tree owns is refused
 * loudly, because a spec run against another tree's code proves nothing.
 */
export const decideServerReuse = ({
  isContinuousIntegration,
  port,
  probe = findListenerOwner,
  treeRoot,
}: {
  isContinuousIntegration: boolean;
  port: number;
  probe?: typeof findListenerOwner;
  treeRoot: string | undefined;
}): boolean => {
  if (isContinuousIntegration) return false;

  const owner = probe({port, treeRoot});

  if (owner.kind === 'foreign') {
    throw new Error(
      buildForeignServerMessage({ownerPath: owner.ownerPath, port})
    );
  }

  return owner.kind === 'own';
};
