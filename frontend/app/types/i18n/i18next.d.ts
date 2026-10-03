import type resources from '~/languages/en';

declare module 'i18next' {
  interface CustomTypeOptions {
    resources: typeof resources;
  }
}
