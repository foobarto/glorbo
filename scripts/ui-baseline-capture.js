// GEP-44 visual-regression capture helper.
// Invoked by scripts/ui-baseline.sh — drives Playwright to take
// one screenshot per Tier-1 page.
//
// Usage: node scripts/ui-baseline-capture.js <dest> "name|path|selector" ...
//
// Deps live in scripts/node_modules (see scripts/package.json).

const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

// Capture viewport — 1400×900, but clip the topbar (path bar bakes
// the random tmp GLORBO_HOME path into pixels) and the bottom
// status row (live wall-clock + uptime) so per-run drift in those
// strings doesn't push the diff past the 0.5% threshold.
const VIEWPORT = { width: 1400, height: 900 };
const TOPBAR_PX = 30;
const STATUSBAR_PX = 30;
const CLIP = {
  x: 0,
  y: TOPBAR_PX,
  width: VIEWPORT.width,
  height: VIEWPORT.height - TOPBAR_PX - STATUSBAR_PX,
};

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
    viewport: VIEWPORT,
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
      clip: CLIP,
    });
  }

  await browser.close();
})();
