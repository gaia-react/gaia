import type {Config} from '@react-router/dev/config';

export default {
  future: {
    v8_middleware: true,
    v8_passThroughRequests: true,
    v8_splitRouteModules: true,
    v8_trailingSlashAwareDataRequests: true,
  },
  ssr: true,
} satisfies Config;
