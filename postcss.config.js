// PR-D: PostCSS pipeline for build-time Tailwind. Explicit import form (the project
// is ESM, "type": "module") so plugin resolution is unambiguous.
import tailwindcss from 'tailwindcss';
import autoprefixer from 'autoprefixer';

export default {
  plugins: [tailwindcss(), autoprefixer()],
};
