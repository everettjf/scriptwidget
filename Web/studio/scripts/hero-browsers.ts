// Verify the landing-page integration across the same browser engines as Studio.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium, firefox, webkit } from 'playwright';
import { serveDirectory } from '../../preview-engine/scripts/lib/chrome.mjs';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'scriptwidget-hero-browsers-'));
fs.cpSync(path.join(repository, 'site'), root, { recursive: true });
fs.cpSync(path.join(repository, 'Web/studio/dist'), path.join(root, 'studio'), { recursive: true });
const server = await serveDirectory(root);
const engines = { chromium, firefox, webkit };
const requested = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(engines);
try {
  for (const name of requested) {
    assert.ok(name in engines, `Unknown browser: ${name}`);
    const browser = await engines[name as keyof typeof engines].launch({ headless: true });
    try {
      const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
      const errors: string[] = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(server.origin);
      for (const example of ['Reading habit', 'Weather', 'Countdown']) {
        await page.getByRole('button', { name: example, exact: true }).click();
        await page.waitForFunction(name => document.getElementById('hero-preview')?.dataset.example === name
          && !!document.querySelector('#hero-preview .sw-widget')
          && document.getElementById('hero-preview')?.getAttribute('aria-busy') === 'false', example);
        const source = await page.locator('#hero-source').textContent();
        const link = await page.locator('#hero-open').getAttribute('href');
        await page.getByRole('button', { name: 'Change widget color' }).click();
        await page.waitForFunction(() => document.getElementById('hero-preview')?.getAttribute('aria-busy') === 'false');
        assert.notEqual(await page.locator('#hero-source').textContent(), source);
        assert.notEqual(await page.locator('#hero-open').getAttribute('href'), link);
      }
      await page.setViewportSize({ width: 375, height: 844 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      assert.deepEqual(errors, []);
      console.log(`${name}: three JSX previews, theme/source/link changes, mobile layout and zero page errors passed.`);
    } finally { await browser.close(); }
  }
} finally {
  server.close();
  fs.rmSync(root, { recursive: true, force: true });
}
