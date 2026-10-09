// Renders the README media from assets/src with Playwright driving the locally
// installed Google Chrome (no browser download). One browser for everything: the demo
// page is loaded once and `apply(t)` is called per frame.
//
//   node assets/render.mjs <frames-dir>
//
// Writes assets/banner.png and assets/social-preview.png directly, and the demo frames
// as PNGs into <frames-dir> for scripts/render-media.sh to turn into a GIF.
import { chromium } from "playwright-core";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const src = (page) => "file://" + join(here, "src", page);
const framesDir = process.argv[2];
if (!framesDir) throw new Error("usage: node assets/render.mjs <frames-dir>");
mkdirSync(framesDir, { recursive: true });

export const FPS = 15;
const DURATION = 17;

const browser = await chromium.launch({ channel: "chrome" });
const context = await browser.newContext({ deviceScaleFactor: 2 });
const page = await context.newPage();

async function still(url, width, height, out) {
  await page.setViewportSize({ width, height });
  // A hash-only change would not re-run the page's script, so load it fresh.
  await page.goto("about:blank");
  await page.goto(url);
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(here, out) });
  console.log(`rendered assets/${out}`);
}

await still(src("banner.html#banner"), 800, 280, "banner.png");
await still(src("banner.html#social"), 640, 320, "social-preview.png");

await page.setViewportSize({ width: 960, height: 600 });
await page.goto(src("demo.html#still"));
await page.evaluate(() => document.fonts.ready);
const total = FPS * DURATION;
for (let i = 0; i < total; i++) {
  await page.evaluate((t) => window.apply(t), i / FPS);
  await page.screenshot({ path: join(framesDir, `${String(i).padStart(4, "0")}.png`) });
}
console.log(`rendered ${total} demo frames`);
await browser.close();
