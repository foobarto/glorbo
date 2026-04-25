// GEP-44 visual-regression diff helper.
// Compares two PNGs via pixelmatch; prints diff percentage on stdout.
//
// Usage: node scripts/ui-baseline-diff.js <baseline.png> <current.png> <diff-out.png>
//
// Exits 0 with the percentage on stdout; the calling shell decides
// whether the percentage exceeds the threshold.
//
// Deps live in scripts/node_modules (see scripts/package.json).

const fs = require('fs');
const { PNG } = require('pngjs');
const pixelmatch = require('pixelmatch');

const [, , basePath, curPath, diffPath] = process.argv;
if (!basePath || !curPath || !diffPath) {
  console.error('usage: node ui-baseline-diff.js <baseline.png> <current.png> <diff.png>');
  process.exit(2);
}

const base = PNG.sync.read(fs.readFileSync(basePath));
const cur = PNG.sync.read(fs.readFileSync(curPath));

if (base.width !== cur.width || base.height !== cur.height) {
  console.error(
    `dimension mismatch: baseline ${base.width}x${base.height} vs current ${cur.width}x${cur.height}`,
  );
  process.exit(2);
}

const diff = new PNG({ width: base.width, height: base.height });
const diffPx = pixelmatch(
  base.data,
  cur.data,
  diff.data,
  base.width,
  base.height,
  { threshold: 0.1 },
);

fs.writeFileSync(diffPath, PNG.sync.write(diff));

const totalPx = base.width * base.height;
const diffPct = ((diffPx / totalPx) * 100).toFixed(3);
console.log(diffPct);
