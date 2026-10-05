import tailwindcss from '@tailwindcss/vite';
import {defineConfig} from 'vite';
import {reactCompiler} from '../react-compiler.config.ts';

export default defineConfig({
  plugins: [tailwindcss(), reactCompiler],
  resolve: {
    tsconfigPaths: true,
  },
  ssr: {
    noExternal: ['lodash'],
    optimizeDeps: {
      include: ['lodash'],
    },
  },
});
