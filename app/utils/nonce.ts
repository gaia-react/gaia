import {createContext, use} from 'react';

const NonceContext = createContext<string>('');

export const NonceProvider = NonceContext.Provider;

export const useNonce = (): string => use(NonceContext);
