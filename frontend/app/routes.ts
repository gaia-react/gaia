/* eslint-disable import-x/no-extraneous-dependencies */
import type {RouteConfig} from '@react-router/dev/routes';
import {getAppDirectory} from '@react-router/dev/routes';
import {flatRoutes} from '@react-router/fs-routes';
import {readdirSync} from 'node:fs';
import path from 'node:path';

// A `+` folder is the retired group convention; fs-routes skips a folder with
// no route/index module, so its routes would 404 silently.
const leftoverPlusFolders = readdirSync(
  path.join(getAppDirectory(), 'routes'),
  {
    withFileTypes: true,
  }
)
  .filter((entry) => entry.isDirectory() && entry.name.endsWith('+'))
  .map((entry) => entry.name);

if (leftoverPlusFolders.length > 0) {
  throw new Error(
    `Leftover "+" route folder(s) found: ${leftoverPlusFolders.join(', ')}. Rename them to flat dot-delimited files per the 2.0.0 update.`
  );
}

export default flatRoutes({
  ignoredRouteFiles: ['**/*.md', '**/*.mdx', '**/.*'],
}) satisfies RouteConfig;
