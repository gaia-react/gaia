import {create} from '../api';

type GaiaServerResponse = {
  data: unknown;
  error?: Error;
};

export const api = create<GaiaServerResponse>();
