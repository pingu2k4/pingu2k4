const { readFileSync, writeFileSync, renameSync } = require('node:fs');
const { resolve } = require('node:path');

// Resolve the pinned renderer from the workflow's disposable dependency directory.
const { Resvg } = require(resolve(process.argv[2], 'node_modules/@resvg/resvg-js'));
const source = resolve(process.argv[3]);
const destination = resolve(process.argv[4]);
const svg = readFileSync(source);
const png = new Resvg(svg, { fitTo: { mode: 'zoom', value: 2 } }).render();
if (png.width !== 1080 || png.height !== 492) throw new Error('Unexpected email card dimensions.');
writeFileSync(`${destination}.tmp`, png.asPng());
renameSync(`${destination}.tmp`, destination);
console.log(`Rendered ${destination}: ${png.width} x ${png.height}`);
