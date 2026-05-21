import {createContext, useContext} from 'react';

// No NonceProvider wraps the hydrated client tree; the '' default covers that path.
const NonceContext = createContext<string>('');

export const NonceProvider = NonceContext.Provider;

export const useNonce = (): string => useContext(NonceContext);
