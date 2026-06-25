import {createContext, use} from 'react';

const NonceContext = createContext<string>('');

export const NonceProvider = NonceContext;

export const useNonce = (): string => use(NonceContext);
