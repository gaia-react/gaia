export const VERSION = process.env.npm_package_version;

const COMMIT_SHA =
  process.env.COMMIT_SHA ? `-${process.env.COMMIT_SHA.slice(0, 6)}` : '';

export const VERSION_WITH_SHA = `${VERSION}${COMMIT_SHA}`;

export const getApplicationVersion = (omitSHA?: boolean): string | undefined =>
  omitSHA ? VERSION : VERSION_WITH_SHA;
