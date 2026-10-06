import {z} from 'zod';
import {create} from '../api';

export const api = create();

export const envelope = <T extends z.ZodType>(
  schema: T
): z.ZodObject<{data: T}> => z.object({data: schema});
