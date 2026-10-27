import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { launchChrome, serveDirectory, clickReady } from '../../preview-engine/scripts/lib/chrome.mjs';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const assembled = fs.mkdtempSync(path.join(os.tmpdir(), 'scriptwidget-hero-'));
// Exercise the deployed /scriptwidget/ prefix, including sandbox/support URLs.
const root = path.join(assembled, 'scriptwidget');
fs.cpSync(path.join(repository, 'site'), root, { recursive: true });
fs.cpSync(path.join(repository, 'Web/studio/dist'), path.join(root, 'studio'), { recursive: true });
const routes: Record<string, { type: string; body: string }> = {};
const server = await serveDirectory(assembled, routes);
const chrome = await launchChrome({ width: 1440, height: 1000, scale: 1 });
const screenshots = process.env.SCRIPTWIDGET_HERO_SCREENSHOTS;
if (screenshots) fs.mkdirSync(screenshots, { recursive: true });
try {
  const page = await chrome.newPage();
  await page.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  await page.goto(`${server.origin}/scriptwidget/`);
  await page.waitFor("!!document.querySelector('#hero-preview .sw-widget')", 20000);
  const originalSource = await page.evaluate("document.getElementById('hero-source').textContent");
  const links: Array<{ href: string; source: string; name: string }> = [];
  for (const [index, name] of ['Reading habit', 'Weather', 'Countdown'].entries()) {
    await clickReady(page, `document.querySelectorAll('[data-hero-example]')[${index}]`);
    await page.waitFor(`document.getElementById('hero-preview').dataset.example===${JSON.stringify(name)} && document.getElementById('hero-preview').getAttribute('aria-busy')==='false'`);
    assert.equal(await page.evaluate("document.querySelectorAll('[data-hero-example][aria-pressed=true]').length"), 1);
    const treeBefore = await page.evaluate("document.querySelector('#hero-preview .sw-widget').outerHTML");
    await clickReady(page, "document.querySelector('.theme-token')");
    await page.waitFor("document.getElementById('hero-preview').getAttribute('aria-busy')==='false'");
    const source = await page.evaluate<string>("document.getElementById('hero-source').textContent");
    assert.notEqual(await page.evaluate("document.querySelector('#hero-preview .sw-widget').outerHTML"), treeBefore, 'Changing source color must change rendered output');
    assert.equal(await page.evaluate("document.activeElement.classList.contains('theme-token')"), true);
    links.push({ href: await page.evaluate<string>("document.getElementById('hero-open').href"), source, name });
    assert.match(links.at(-1)!.href, /\/scriptwidget\/studio\/#sw-preview=v1\./);
    assert.match(await page.evaluate<string>("document.getElementById('hero-status').textContent"), /sample/);
    if (screenshots) {
      await page.evaluate('scrollTo(0,0)');
      fs.writeFileSync(path.join(screenshots, `desktop-${index}.png`), await page.screenshot());
    }
  }
  // Rapid changes must not let an older async render overwrite the latest.
  await page.evaluate("document.querySelectorAll('[data-hero-example]')[0].click();document.querySelector('.theme-token').click();document.querySelectorAll('[data-hero-example]')[2].click()");
  await page.waitFor("document.getElementById('hero-preview').dataset.example==='Countdown' && document.getElementById('hero-preview').getAttribute('aria-busy')==='false'");
  for (const width of [320, 375, 390, 768, 1024, 1440]) {
    await page.call('Emulation.setDeviceMetricsOverride', { width, height: 1000, deviceScaleFactor: 1, mobile: false });
    await page.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
    assert.equal(await page.evaluate('document.documentElement.scrollWidth<=innerWidth'), true, `Page overflow at ${width}`);
    assert.equal(await page.evaluate("document.getElementById('hero-preview').scrollWidth<=document.getElementById('hero-preview').clientWidth"), true, `Preview overflow at ${width}`);
    if (screenshots) { await page.evaluate('scrollTo(0,0)'); fs.writeFileSync(path.join(screenshots, `layout-${width}.png`), await page.screenshot()); }
  }
  await page.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  // Each link must import the exact visible code, with prior drafts preserved.
  let projectCount = 0;
  for (const { href, source, name } of links) {
    await page.goto(href);
    await page.waitFor("document.getElementById('save-state')?.textContent==='Saved in this browser' && !!document.querySelector('.sw-widget')", 20000);
    assert.equal(await page.evaluate('location.hash'), '');
    const saved = await page.evaluate<{ files: Record<string, string> }>(`(async()=>{
      const db=await new Promise(resolve=>{const r=indexedDB.open('scriptwidget-studio',1);r.onsuccess=()=>resolve(r.result)});
      try{return await new Promise(resolve=>{const r=db.transaction('projects').objectStore('projects').get(JSON.parse(localStorage.getItem('scriptwidget-studio.project')));r.onsuccess=()=>resolve(r.result)})}finally{db.close()}
    })()`);
    assert.equal(saved.files['main.jsx'], source, `${name} must open with the visible theme and full source`);
    if (screenshots) {
      const folder = path.join(screenshots, 'packages', name);
      fs.mkdirSync(folder, { recursive: true });
      for (const file of ['main.jsx', 'widget.json']) fs.writeFileSync(path.join(folder, file), saved.files[file]!);
    }
    const count = await page.evaluate<number>("document.querySelectorAll('#project-list li').length");
    assert.ok(count > projectCount, 'Handoff must create a project rather than overwrite the previous draft');
    projectCount = count;
  }
  await page.goto(`${server.origin}/scriptwidget/`);
  await page.waitFor("!!document.querySelector('#hero-preview .sw-widget')", 20000);
  assert.equal(await page.evaluate("document.getElementById('hero-source').textContent"), originalSource);
  // A blocked runtime offers an honest fallback and a working editing link.
  routes['/scriptwidget/studio/sandbox.html'] = { type: 'text/html', body: '<!doctype html><title>Runtime unavailable</title>' };
  await page.call('Network.enable');
  await page.call('Network.setCacheDisabled', { cacheDisabled: true });
  await page.goto(`${server.origin}/scriptwidget/?fallback-check`);
  await page.waitFor("document.getElementById('hero-status').textContent.includes('could not render')", 15000);
  assert.match(await page.evaluate<string>("document.getElementById('hero-preview').textContent"), /unavailable/);
  assert.match(await page.evaluate<string>("document.getElementById('hero-open').href"), /#sw-preview=v1\./);
  console.log('Hero: 3 real JSX previews, theme changes, rapid switching, 6 screen widths, exact Studio handoff, draft preservation, reload, blocked-runtime fallback passed.');
} finally {
  await chrome.close();
  server.close();
  fs.rmSync(assembled, { recursive: true, force: true });
}
