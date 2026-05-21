export const toInitialCap = (value?: string): string | undefined =>
  value ? value.charAt(0).toUpperCase() + value.slice(1) : value;

export const toTitleCase = (value: string, delimiter = '_'): string =>
  value.split(delimiter).map(toInitialCap).join(' ');

export const isString = (value?: unknown): value is string =>
  typeof value === 'string';
