import {createContext, useContext} from 'react';

const NonceContext = createContext<string>('');

export const NonceProvider = NonceContext.Provider;

export const useNonce = (): string => useContext(NonceContext);
