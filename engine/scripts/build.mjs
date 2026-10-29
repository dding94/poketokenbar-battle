import {build} from 'esbuild';
import {createHash} from 'node:crypto';
import {readFile, writeFile} from 'node:fs/promises';
await build({entryPoints: ['src/index.js'], outfile: 'dist/battle-engine.js', bundle: true,
  minify: true, keepNames: true, format: 'iife', platform: 'neutral', target: 'es2020',
  mainFields: ['module', 'main'], conditions: ['import'], alias: {path: './probe/empty-path.js'}});
const bytes = await readFile('dist/battle-engine.js');
await writeFile('dist/battle-engine.sha256', `${createHash('sha256').update(bytes).digest('hex')}  battle-engine.js\n`);
