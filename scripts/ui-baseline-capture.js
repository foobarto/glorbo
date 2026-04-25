// GEP-44 visual-regression capture helper.
// Invoked by scripts/ui-baseline.sh — drives Playwright to take
// one screenshot per Tier-1 page.
//
// Usage: node scripts/ui-baseline-capture.js <dest> "name|path|selector" ...
//
// Requires: npm exec --package=playwright (or playwright in PATH).

const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

(async () => {
  const [destArg, ...pageArgs] = process.argv.slice(2);
  if (!destArg) {
    console.error('usage: node ui-baseline-capture.js <dest> "name|path|selector" ...');
    process.exit(1);
  }
  const dest = path.resolve(destArg);
  fs.mkdirSync(dest, { recursive: true });

  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: 1400, height: 900 },
    deviceScaleFactor: 1,
  });
  const page = await context.newPage();

  for (const entry of pageArgs) {
    const [name, urlPath, waitSelector] = entry.split('|');
    if (!name || !urlPath) continue;
    const url = `http://localhost:4000${urlPath}`;
    console.log(`  → ${name}: ${url}`);
    await page.goto(url, { waitUntil: 'networkidle' });
    if (waitSelector) {
      await page.waitForSelector(waitSelector, { timeout: 10_000 });
    }
    // Small settle for any post-mount LV updates.
    await page.waitForTimeout(300);
    await page.screenshot({
      path: path.join(dest, `${name}.png`),
      fullPage: false,
    });
  }

  await browser.close();
})();
