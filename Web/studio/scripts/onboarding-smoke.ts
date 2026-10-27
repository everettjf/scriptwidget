import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launchChrome, serveDirectory, clickReady } from "../../preview-engine/scripts/lib/chrome.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const assembled = fs.mkdtempSync(path.join(os.tmpdir(), "scriptwidget-onboarding-"));
fs.cpSync(path.join(repository, "site"), assembled, { recursive: true });
fs.cpSync(path.join(repository, "Web/studio/dist"), path.join(assembled, "studio"), { recursive: true });
const server = await serveDirectory(assembled);
const chrome = await launchChrome({ width: 1440, height: 1000, scale: 1 });
try {
  const page = await chrome.newPage();
  async function savedProject(projectID?: string) {
    await page.waitFor("document.getElementById('save-state')?.textContent==='Saved in this browser'");
    return page.evaluate<{ id: string; files: Record<string, unknown> }>(`(async()=>{
      const db=await new Promise((resolve,reject)=>{const request=indexedDB.open('scriptwidget-studio',1);request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error)});
      try {
        const id=${projectID ? JSON.stringify(projectID) : "JSON.parse(localStorage.getItem('scriptwidget-studio.project'))"};
        return await new Promise((resolve,reject)=>{const request=db.transaction('projects').objectStore('projects').get(id);request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error)});
      } finally {db.close()}
    })()`);
  }
  await page.call("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }, { name: "prefers-reduced-motion", value: "reduce" }] });
  await page.goto(`${server.origin}/`);
  await page.waitFor("!!document.querySelector('#hero-preview .sw-widget')");
  assert.equal(await page.evaluate("document.querySelectorAll('.hero .actions a').length"), 3);
  assert.equal(await page.evaluate("document.querySelector('.hero .actions a:first-child').classList.contains('primary')"), true);
  assert.equal(await page.evaluate("document.querySelector('.hero .actions a:first-child').href"), "https://apps.apple.com/us/app/scriptwidget/id1555600758");
  assert.equal(await page.evaluate("document.querySelectorAll('[data-hero-example]').length"), 3);
  assert.equal(await page.evaluate("new URL(document.querySelector('.hero .actions a:last-child').href).pathname"), "/studio/");
  const output = process.env.SCRIPTWIDGET_ONBOARDING_SCREENSHOTS;
  if (output) { fs.mkdirSync(output, { recursive: true }); fs.writeFileSync(path.join(output, "home-desktop.png"), await page.screenshot()); }
  await page.call("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 1, mobile: false });
  assert.equal(await page.evaluate("document.documentElement.scrollWidth<=innerWidth"), true);
  if (output) fs.writeFileSync(path.join(output, "home-mobile.png"), await page.screenshot());
  await page.goto(`${server.origin}/creator/`);
  // Page.navigate returns before the new document and its stylesheet are ready.
  // Wait for the destination, fonts and layout before measuring mobile overflow.
  await page.waitFor("!!document.getElementById('install-command') && document.readyState==='complete'");
  await page.evaluate("(async()=>{await document.fonts.ready;await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))})()");
  assert.equal(await page.evaluate("document.documentElement.scrollWidth<=innerWidth"), true);
  // Deterministic clipboard success/denial, including exact multiline payload.
  await page.evaluate("window.copied=[]; Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>window.copied.push(text)}})");
  for (const id of ["install-command", "creator-prompt"]) {
    await clickReady(page, `document.querySelector('[data-copy="${id}"]')`);
    await page.waitFor(`document.querySelector('[data-copy="${id}"]').closest('.copy-block').nextElementSibling.textContent.startsWith('Copied.')`);
    assert.equal(await page.evaluate("window.copied.at(-1)"), await page.evaluate(`document.getElementById('${id}').textContent`));
  }
  assert.equal(await page.evaluate("window.copied[0].includes('\\nmkdir -p ~/.claude/skills\\n')"), true);
  await page.evaluate("Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async()=>{throw Error('denied')}}})");
  await clickReady(page, "document.querySelector('[data-copy=creator-prompt]')");
  await page.waitFor("document.querySelector('[data-copy=creator-prompt]').closest('.copy-block').nextElementSibling.textContent.startsWith('Could not copy.')");
  if (output) fs.writeFileSync(path.join(output, "creator-mobile.png"), await page.screenshot());
  await page.call("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await page.goto(`${server.origin}/studio/`);
  await page.waitFor("!!document.querySelector('#starter-guide') && !!document.querySelector('.sw-widget')", 20000);
  const starter = await savedProject();
  if (output) fs.writeFileSync(path.join(output, "studio-starter.png"), await page.screenshot());
  for (const name of ["Habit Heatmap", "Countdown", "Reading Goal"]) {
    await clickReady(page, `[...document.querySelectorAll('#starter-guide button')].find(b=>b.textContent===${JSON.stringify(name)})`);
    await page.waitFor(`document.getElementById('template-search')?.value===${JSON.stringify(name)} && document.querySelectorAll('.template-card').length>0`);
    assert.equal(await page.evaluate(`[...document.querySelectorAll('.template-card')].some(c=>c.textContent.includes(${JSON.stringify(name)}))`), true);
    if (name !== "Reading Goal") {
      await clickReady(page, "document.querySelector('[role=dialog] button[data-slot=dialog-close]')");
      await page.waitFor("!document.querySelector('[role=dialog]')");
    }
  }
  await clickReady(page, "document.querySelector('.template-card')");
  await page.waitFor("!!document.getElementById('template-copy')");
  await clickReady(page, "document.getElementById('template-copy')");
  await page.waitFor("!document.querySelector('[role=dialog]') && document.querySelector('.sw-widget')?.textContent.includes('READING GOAL')", 20000);
  // Text wrapping and ellipsizing vary with browser fonts. The stable heading
  // proves rendering; byte-for-byte source comparison below proves the full
  // template and its 7/12 values, without asserting a particular truncation.
  console.log("Reading preview:", await page.evaluate("document.querySelector('.sw-widget')?.innerText"));
  const copied = await savedProject();
  const catalog = JSON.parse(fs.readFileSync(path.join(repository, "Web/studio/dist/templates.json"), "utf8"));
  const expected = catalog.templates.find((item: { id: string }) => item.id === "template/Reading Goal");
  assert.equal(copied.files["main.jsx"], expected.files["main.jsx"]);
  assert.notEqual(copied.id, starter.id);
  assert.equal(await page.evaluate("!!document.querySelector('#starter-guide')"), false);
  assert.equal(await page.evaluate("document.querySelectorAll('#project-list li').length"), 2);
  await page.goto(`${server.origin}/studio/`);
  await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('READING GOAL')", 20000);
  assert.equal(await page.evaluate("!!document.querySelector('#starter-guide')"), false);
  assert.deepEqual(await savedProject(), copied);
  assert.deepEqual(await savedProject(starter.id), starter, "The original draft and all its files must remain byte-for-byte unchanged");
  // The generic Gallery entry must not retain the starter shortcut's filter.
  await clickReady(page, "document.getElementById('open-templates')");
  await page.waitFor("document.getElementById('template-search')?.value==='' && document.querySelectorAll('.template-card').length>3");
  console.log("Website onboarding: home/mobile, exact clipboard payload + denial, all three starter shortcuts, draft preservation, reload and Gallery reset passed.");
} finally { await chrome.close(); server.close(); fs.rmSync(assembled, { recursive: true, force: true }); }
