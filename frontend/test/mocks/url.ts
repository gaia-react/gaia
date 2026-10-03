// Mirrors ky's prefix-join normalization (see ky/distribution/core/Ky.js:285).
// Without this, MSW handler URLs built via raw template literal break whenever
// API_URL is supplied without a trailing slash (handler pattern becomes
// `<URL>things` while ky requests `<URL>/things`; no match → passthrough).
export const url = (path: string): string => {
  // eslint-disable-next-line sonarjs/super-linear-regex
  const prefix = (process.env.API_URL ?? '').replace(/\/+$/, '');
  const input = path.replace(/^\/+/, '');

  return `${prefix}/${input}`;
};
