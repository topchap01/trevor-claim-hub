import next from 'eslint-config-next';

const config = [
  ...next,
  {
    rules: {
      // Copy is plain English with apostrophes and quotes; React escapes text, so this rule only adds noise
      'react/no-unescaped-entities': 'off',
      // The claim page loads its data in an effect on purpose (and again when the tab regains focus)
      'react-hooks/set-state-in-effect': 'warn',
    },
  },
  { ignores: ['.next/**', 'node_modules/**'] },
];
export default config;
