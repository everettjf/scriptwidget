// Loads the built Studio in headless Chrome and checks that the sandboxed
// runtime renders the starter widget, a template, an imported .swt, and that
// phones show the preview before the editor.
// Usage: npm run build && node scripts/smoke.ts [screenshot.png]
//        SITE_ROOT=<assembled _site> node scripts/smoke.ts   (tests /studio/ like GitHub Pages)
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launchChrome, serveDirectory, clickReady, type ChromePage } from "../../preview-engine/scripts/lib/chrome.mjs";

const dist = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../dist");
const fixture = fs.readFileSync(path.resolve(dist, "../../preview-engine/test/fixtures/web-export.swt"));
const siteRoot = process.env.SITE_ROOT ? path.resolve(process.env.SITE_ROOT) : null;
const server = await serveDirectory(siteRoot ?? dist, { "/__fixture.swt": { type: "application/zip", body: fixture } });
const studioURL = `${server.origin}${siteRoot ? "/studio/index.html" : "/index.html"}`;
const exceptions = (page: ChromePage) => page.consoleMessages.filter((line) => line.startsWith("exception") || line.startsWith("error"));
let failed = false;


async function desktop(): Promise<void> {
  const chrome = await launchChrome({ width: 1400, height: 900, scale: 1 });
  try {
    const page = await chrome.newPage();
    await page.goto(studioURL);
    await page.waitFor("!!document.querySelector('.sw-widget')", 20000);
    console.log("starter:", await page.evaluate<string>("document.getElementById('preview-status').textContent"));
    const sandboxed = await page.evaluate<string>("document.querySelector('iframe').getAttribute('sandbox')");
    if (sandboxed !== "allow-scripts") throw new Error("runtime frame is not sandboxed");
    // Install without a share sheet: the file downloads and the dialog says
    // what to do with it on every system, with a link to each app.
    await page.evaluate("Object.defineProperty(navigator, 'canShare', { value: undefined, configurable: true }); document.getElementById('install-package').click()");
    await page.waitFor("!!document.getElementById('install-dialog')");
    const install = await page.evaluate<{ title: string; text: string; links: { title: string; href: string }[] }>("(() => { const dialog = document.getElementById('install-dialog'); return { title: dialog.querySelector('h2').textContent, text: dialog.textContent, links: [...dialog.querySelectorAll('a')].map((a) => ({ title: a.textContent, href: a.href })) }; })()");
    if (install.title !== "Install on your device") throw new Error(`install dialog title: ${install.title}`);
    for (const system of ["iPhone and iPad", "Android", "Mac", "Windows and Linux"]) if (!install.text.includes(`${system}:`)) throw new Error(`install dialog has no steps for ${system}`);
    const [platformSupport, ...appLinks] = install.links;
    if (platformSupport?.title !== "Check platform support" || !platformSupport.href.endsWith("/docs/platform-support.md")) throw new Error("install dialog has no platform support link");
    if (appLinks.map((link) => link.title).join(",") !== "iPhone and iPad,Mac,Android,Windows,Linux") throw new Error(`install dialog links: ${JSON.stringify(appLinks)}`);
    if (!install.text.includes("Edit Widgets") || !install.text.includes("iOS or iPadOS 18 or later")) throw new Error("install dialog does not give current Apple installation guidance");
    if (await page.evaluate<string>("document.getElementById('install-package').textContent") !== "Install on device") throw new Error("install button label");
    await page.evaluate("document.querySelector('#install-dialog button[data-slot=dialog-close], #install-dialog button').click()");
    await page.waitFor("!document.getElementById('install-dialog')");
    console.log("install dialog: platform-specific steps, compatibility guidance and five app links");
    // Open a template.
    await page.evaluate("document.getElementById('open-templates').click()");
    await page.waitFor("document.querySelectorAll('.template-card').length > 50");
    const count = await page.evaluate<number>("document.querySelectorAll('.template-card').length");
    await page.evaluate("[...document.querySelectorAll('.template-card')].find((card) => card.textContent.includes('Image Basic Usage') || card.textContent.includes('Image')).click()");
    // The detail view shows the source and a live preview; copy it into a project.
    await page.waitFor("!!document.getElementById('template-copy') && document.getElementById('template-source').textContent.includes('$render')");
    await page.evaluate("document.getElementById('template-copy').click()");
    await page.waitFor("!document.getElementById('template-detail') && document.getElementById('preview-status').textContent.startsWith('Web fast preview') && !!document.querySelector('.sw-widget img')", 20000);
    console.log(`templates: ${count}; image template rendered`);
    // Import a .swt through the file input, as a user would.
    await page.evaluate(`(async () => {
      const bytes = await (await fetch("/__fixture.swt")).arrayBuffer();
      const transfer = new DataTransfer();
      transfer.items.add(new File([bytes], "Web Export Fixture.swt", { type: "application/zip" }));
      const input = document.getElementById("import-input");
      input.files = transfer.files;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    })()`);
    await page.waitFor("document.getElementById('project-name').value === 'Web Export Fixture' && document.querySelector('.sw-widget')?.textContent.includes('From the web')", 20000);
    console.log("imported .swt renders");
    // Dropping the same package on the page imports another copy.
    const projectsBefore = await page.evaluate<number>("document.querySelectorAll('#project-list li').length");
    await page.evaluate(`(async () => {
      const bytes = await (await fetch("/__fixture.swt")).arrayBuffer();
      const transfer = new DataTransfer();
      transfer.items.add(new File([bytes], "Dropped Fixture.swt", { type: "application/zip" }));
      const target = document.getElementById("root").firstElementChild;
      target.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer: transfer }));
      target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: transfer }));
    })()`);
    await page.waitFor(`document.querySelectorAll('#project-list li').length === ${projectsBefore + 1} && !document.getElementById('drop-overlay')`, 20000);
    console.log("dropped .swt imports");
    // Binary assets stay outside the runtime realm, but their paths remain queryable.
    await page.evaluate("document.querySelector('.cm-content').focus(); document.execCommand('selectAll')");
    await page.call("Input.insertText", { text: '$render(<text>{"Binary files: " + $file.exists("image/dot.png") + ":" + $file.exists("image")}</text>);' });
    await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('Binary files: true:false')", 20000);
    console.log("binary file presence: sandbox sees PNG paths, not directories");
    // Editing the source updates the preview.
    await page.evaluate("document.querySelector('.cm-content').focus(); document.execCommand('selectAll')");
    await page.call("Input.insertText", { text: "$render(<text>Edited in the smoke test</text>)" });
    await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('Edited in the smoke test')", 20000);
    console.log("editing updates the preview");
    if (process.argv[2]) fs.writeFileSync(process.argv[2], await page.screenshot());
    console.log("problems:", (await page.evaluate<string>("document.getElementById('problems').textContent")).slice(0, 200));
    if (exceptions(page).length) { console.log(exceptions(page).join("\n")); failed = true; }
  } finally {
    await chrome.close();
  }
}

async function phone(): Promise<void> {
  const chrome = await launchChrome({ width: 390, height: 844, scale: 1 });
  try {
    const page = await chrome.newPage();
    await page.goto(studioURL);
    await page.waitFor("!!document.querySelector('.sw-widget')", 20000);
    const order = await page.evaluate<{ stage: number; editor: number; overflow: number }>(`({
      stage: document.getElementById('stage').getBoundingClientRect().top,
      editor: document.getElementById('editor').getBoundingClientRect().top,
      overflow: document.documentElement.scrollWidth - window.innerWidth,
    })`);
    if (!(order.stage < order.editor)) throw new Error(`on phones the preview should come before the editor (${JSON.stringify(order)})`);
    if (order.overflow > 1) throw new Error(`the phone layout scrolls horizontally by ${order.overflow}px`);
    if (process.argv[3]) fs.writeFileSync(process.argv[3], await page.screenshot());
    console.log("phone: preview first, no horizontal scroll");
    if (exceptions(page).length) { console.log(exceptions(page).join("\n")); failed = true; }
  } finally {
    await chrome.close();
  }
}

/// A content blocker that stops sandbox.html must produce a clear message
/// within seconds, not a 30-second spinner.
async function blockedSandbox(): Promise<void> {
  const chrome = await launchChrome({ width: 1200, height: 800, scale: 1 });
  try {
    const page = await chrome.newPage();
    // Fail sandbox.html the way a content-blocking extension does.
    page.onEvent("Fetch.requestPaused", (params: { requestId: string }) => void page.call("Fetch.failRequest", { requestId: params.requestId, errorReason: "BlockedByClient" }));
    await page.call("Fetch.enable", { patterns: [{ urlPattern: "*sandbox.html*" }] });
    const started = Date.now();
    await page.goto(studioURL);
    await page.waitFor("document.getElementById('runtime-unavailable')?.textContent.includes('blocked the preview sandbox')", 12000);
    console.log(`blocked sandbox: explained after ${((Date.now() - started) / 1000).toFixed(1)} s`);
  } finally {
    await chrome.close();
  }
}

async function scheduledTheme(): Promise<void> {
  const chrome = await launchChrome({ width: 1400, height: 1000, scale: 1 });
  try {
    const page = await chrome.newPage();
    await page.goto(studioURL);
    await page.waitFor("!!document.querySelector('.sw-widget')", 20000);
    await page.evaluate("document.getElementById('open-templates').click()");
    await page.waitFor("document.querySelectorAll('.template-card').length > 50");
    await page.evaluate("[...document.querySelectorAll('.template-card')].find((card) => card.textContent.includes('Day Rhythm')).click()");
    await page.waitFor("!!document.getElementById('template-copy')");
    await page.evaluate("document.getElementById('template-copy').click()");
    await page.waitFor("!document.getElementById('template-detail') && !!document.getElementById('timeline-date')", 20000);
    const choose = async (value: string) => page.evaluate(`(() => {
      const input = document.getElementById('timeline-date');
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,${JSON.stringify(value)});
      input.dispatchEvent(new Event('input',{bubbles:true}));
      input.dispatchEvent(new Event('change',{bubbles:true}));
    })()`);
    await choose("2026-01-01T13:00");
    await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('Afternoon flow')", 20000);
    if (process.env.SCRIPTWIDGET_TIMELINE_SCREENSHOT) fs.writeFileSync(process.env.SCRIPTWIDGET_TIMELINE_SCREENSHOT, await page.screenshot());
    await page.evaluate("[...document.getElementById('timeline-date').parentElement.parentElement.querySelectorAll('button')].find((button) => button.textContent !== 'Now').click()");
    await page.waitFor("document.getElementById('timeline-date').value === '2026-01-01T18:00' && document.querySelector('.sw-widget')?.textContent.includes('Evening reset')", 20000);
    await choose("2026-01-01T23:00");
    await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('Quiet hours')", 20000);
    await page.evaluate("[...document.querySelectorAll('button')].find((button) => button.textContent === 'Now').click()");
    await page.waitFor("document.getElementById('timeline-date').value === '' && document.getElementById('preview-status').textContent.startsWith('Web fast preview')", 20000);
    if (exceptions(page).length) throw new Error(exceptions(page).join("\n"));
    console.log("timeline: fixed afternoon, next transition, night and Now states render through preview controls");
  } finally { await chrome.close(); }
}

async function calendarScope(): Promise<void> {
  const chrome = await launchChrome({ width: 1400, height: 1000, scale: 1 });
  try {
    const page = await chrome.newPage();
    await page.goto(studioURL);
    await page.waitFor("!!document.querySelector('.sw-widget')", 20000);
    await page.evaluate("document.getElementById('open-templates').click()");
    await page.waitFor("document.querySelectorAll('.template-card').length > 50");
    await page.evaluate("[...document.querySelectorAll('.template-card')].find((card) => card.textContent.includes('Calendar Agenda')).click()");
    await page.waitFor("!!document.getElementById('template-copy')");
    await page.evaluate("document.getElementById('template-copy').click()");
    await page.waitFor("!document.getElementById('template-detail') && document.querySelector('.sw-widget')?.textContent.includes('Read and recharge')", 20000);
    await clickReady(page, "[...document.querySelectorAll('[role=tab]')].find(tab=>tab.textContent==='Mock Data')");
    await page.waitFor("document.querySelector('[role=tab][aria-selected=true]')?.textContent === 'Mock Data' && document.getElementById('mock-data-panel').offsetParent !== null");
    await page.waitFor("!!document.getElementById('mock-group')");
    await page.evaluate("(() => {const input=document.getElementById('mock-group');Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(input,'calendar');input.dispatchEvent(new Event('change',{bubbles:true}));})()");
    await page.waitFor("!!document.getElementById('mock-calendar-selection')");
    const choose = async (value: string) => {
      await page.evaluate(`(() => {const input=document.getElementById('mock-calendar-selection');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,${JSON.stringify(value)});input.dispatchEvent(new Event('input',{bubbles:true}));})()`);
      await page.evaluate("[...document.getElementById('mock-data-panel').querySelectorAll('button')].find((button) => button.textContent === 'Apply source selection').click()");
    };
    await choose("[]");
    await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('Choose Calendar sources')", 20000);
    if (!(await page.evaluate<boolean>("document.querySelector('[role=tab][aria-selected=true]')?.textContent === 'Mock Data'"))) throw new Error("Calendar mock editing must remain on its visible tab");
    if (process.env.SCRIPTWIDGET_CALENDAR_SCOPE_SCREENSHOT) {
      await page.evaluate("document.getElementById('mock-calendar-selection').scrollIntoView({block:'center'})");
      fs.writeFileSync(process.env.SCRIPTWIDGET_CALENDAR_SCOPE_SCREENSHOT, await page.screenshot());
    }
    await choose('["sample.personal"]');
    await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('Read and recharge')", 20000);
    await choose('["sample.personal","sample.personal"]');
    await page.waitFor("document.getElementById('mock-data-panel').textContent.includes('Calendar selection must')");
    const preserved = await page.evaluate<boolean>("document.getElementById('mock-calendar-selection').value === '[\"sample.personal\",\"sample.personal\"]' && document.querySelector('.sw-widget').textContent.includes('Read and recharge')");
    if (!preserved) throw new Error("Invalid Calendar scope must preserve the draft and previous valid preview");
    if (exceptions(page).length) throw new Error(exceptions(page).join("\n"));
    console.log("calendar: source scope blocks healthy mocks, restores a valid subset and preserves invalid drafts");
  } finally { await chrome.close(); }
}

async function connectedServices(): Promise<void> {
  const chrome = await launchChrome({width:1400,height:1000,scale:1});
  try {
    const page = await chrome.newPage();
    await page.call("Emulation.setEmulatedMedia",{features:[{name:"prefers-color-scheme",value:"light"}]});
    const openMocks = async () => {
      await clickReady(page, "[...document.querySelectorAll('[role=tab]')].find(tab=>tab.textContent==='Mock Data')");
      await page.waitFor("document.querySelector('[role=tab][aria-selected=true]')?.textContent==='Mock Data' && document.getElementById('mock-data-panel').offsetParent!==null");
    };
    await page.goto(studioURL);
    await page.waitFor("!!document.querySelector('.sw-widget')",20000);
    await clickReady(page, "document.getElementById('open-templates')");
    await page.waitFor("[...document.querySelectorAll('.template-card')].some(card=>card.textContent.includes('GitHub Profile'))");
    await page.evaluate("[...document.querySelectorAll('.template-card')].find(card=>card.textContent.includes('GitHub Profile')).click()");
    await page.waitFor("!!document.getElementById('template-copy')");
    await page.evaluate("document.getElementById('template-copy').click()");
    await page.waitFor("document.getElementById('project-name').value==='GitHub Profile' && document.querySelector('.sw-widget')?.textContent.includes('Mona')",20000);
    await openMocks();
    await page.waitFor("!!document.getElementById('mock-group')");
    await page.evaluate("(() => {const input=document.getElementById('mock-group');Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(input,'services');input.dispatchEvent(new Event('change',{bubbles:true}));})()");
    await page.waitFor("document.getElementById('mock-data-panel').textContent.includes('GitHub sample data only')");
    await page.evaluate("(() => {const input=document.getElementById('mock-api');Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(input,'$services.profile');input.dispatchEvent(new Event('change',{bubbles:true}));})()");
    await page.waitFor("!!document.getElementById('mock-result.publicRepositories')");
    await page.evaluate("(() => {const input=document.getElementById('mock-result.publicRepositories');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,'47');input.dispatchEvent(new Event('input',{bubbles:true}));})()");
    await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('47')",20000);
    const scenario = async (label: string, expected: string) => {
      await page.evaluate(`[...document.getElementById('mock-data-panel').querySelectorAll('button')].find(button=>button.textContent===${JSON.stringify(label)}).click()`);
      await page.waitFor(`document.querySelector('.sw-widget')?.textContent.includes(${JSON.stringify(expected)})`,20000);
      if (!(await page.evaluate<boolean>("document.querySelector('[role=tab][aria-selected=true]')?.textContent==='Mock Data'"))) throw new Error("Service editing must keep its visible Mock Data panel");
    };
    await scenario("Disconnected","Connect GitHub");
    await scenario("No widget access","Allow this widget");
    await scenario("Private count not shared","Private repository count not shared");
    await scenario("Rate limited","Try again later");
    await scenario("Offline","Unable to refresh");
    await page.waitFor("document.getElementById('save-state').textContent==='Saved in this browser'");
    await page.goto(studioURL);
    await page.waitFor("document.getElementById('project-name').value==='GitHub Profile' && document.querySelector('.sw-widget')?.textContent.includes('Unable to refresh')",20000);
    await openMocks();
    await page.waitFor("!!document.getElementById('mock-group')");
    await page.evaluate("(() => {const input=document.getElementById('mock-group');Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(input,'services');input.dispatchEvent(new Event('change',{bubbles:true}));})()");
    await scenario("Sample success","Mona");
    await page.evaluate("(() => {const input=document.getElementById('mock-api');Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(input,'$services.profile');input.dispatchEvent(new Event('change',{bubbles:true}));})()");
    await page.waitFor("document.getElementById('mock-result.publicRepositories')?.offsetParent!==null && document.getElementById('save-state').textContent==='Saved in this browser'");
    if (process.env.SCRIPTWIDGET_SERVICES_SCREENSHOT) {
      await page.evaluate("document.getElementById('mock-result.publicRepositories').scrollIntoView({block:'end'})");
      fs.writeFileSync(process.env.SCRIPTWIDGET_SERVICES_SCREENSHOT,await page.screenshot());
    }
    if (exceptions(page).length) throw new Error(exceptions(page).join("\n"));
    console.log("services: healthy GitHub template, editable counts, revoked/missing/private/limited/offline states and persisted mocks passed");
  } finally { await chrome.close(); }
}

async function musicPlayback(): Promise<void> {
  const chrome = await launchChrome({width:1400,height:1000,scale:1});
  try {
    const page = await chrome.newPage();
    // Make the closing Gallery overlay outlive its fast widget preview so the
    // real pointer test consistently exercises the transition, including CI.
    await page.call("Animation.enable");
    await page.call("Animation.setPlaybackRate",{playbackRate:0.1});
    await page.call("Emulation.setEmulatedMedia",{features:[{name:"prefers-color-scheme",value:"light"}]});
    const click = (expression: string) => clickReady(page, expression);
    const select = async (id: string, value: string) => page.evaluate(`(() => {const input=document.getElementById(${JSON.stringify(id)});Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(input,${JSON.stringify(value)});input.dispatchEvent(new Event('change',{bubbles:true}));})()`);
    await page.goto(studioURL);
    await page.waitFor("!!document.querySelector('.sw-widget')",20000);
    await click("document.getElementById('open-templates')");
    await page.waitFor("[...document.querySelectorAll('.template-card')].some(card=>card.textContent.includes('Music Playback'))");
    await page.evaluate("[...document.querySelectorAll('.template-card')].find(card=>card.textContent.includes('Music Playback')).click()");
    await page.waitFor("!!document.getElementById('template-copy')");
    await page.evaluate("document.getElementById('template-copy').click()");
    await page.waitFor("document.getElementById('project-name').value==='Music Playback' && document.querySelector('.sw-widget')?.textContent.includes('Morning Light')",20000);
    await click("[...document.querySelectorAll('[role=tab]')].find(tab=>tab.textContent==='Mock Data')");
    await page.waitFor("document.querySelector('[role=tab][aria-selected=true]')?.textContent==='Mock Data' && document.getElementById('mock-data-panel').offsetParent!==null");
    await select("mock-group","music"); await select("mock-api","$music.current");
    await page.waitFor("!!document.getElementById('mock-result.title')");
    await page.evaluate("(() => {const input=document.getElementById('mock-result.title');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,'Evening Walk');input.dispatchEvent(new Event('input',{bubbles:true}));})()");
    await page.waitFor("document.querySelector('.sw-widget')?.textContent.includes('Evening Walk')",20000);
    for (const [label,expected] of [["Paused","Paused"],["Stopped","No current track"],["Track details withheld","Track details unavailable"],["Permission denied","Allow Music access"],["Unavailable","Music unavailable"],["Playing","Morning Light"]]) {
      await page.evaluate(`[...document.getElementById('mock-data-panel').querySelectorAll('button')].find(button=>button.textContent===${JSON.stringify(label)}).click()`);
      await page.waitFor(`document.querySelector('.sw-widget')?.textContent.includes(${JSON.stringify(expected)})`,20000);
    }
    await page.waitFor("document.getElementById('save-state').textContent==='Saved in this browser'");
    if (process.env.SCRIPTWIDGET_MUSIC_SCREENSHOT) {
      await page.evaluate("document.getElementById('mock-result.title').scrollIntoView({block:'end'})");
      fs.writeFileSync(process.env.SCRIPTWIDGET_MUSIC_SCREENSHOT,await page.screenshot());
    }
    await page.goto(studioURL);
    await page.waitFor("document.getElementById('project-name').value==='Music Playback' && document.querySelector('.sw-widget')?.textContent.includes('Morning Light')",20000);
    if (exceptions(page).length) throw new Error(exceptions(page).join("\n"));
    console.log("music: editable track, six playback/permission states and persisted mocks passed");
  } finally { await chrome.close(); }
}

try {
  await desktop();
  await phone();
  await blockedSandbox();
  await scheduledTheme();
  await calendarScope();
  await connectedServices();
  await musicPlayback();
} catch (error) {
  console.error((error as Error).message);
  failed = true;
} finally {
  server.close();
}
if (failed) process.exit(1);
console.log("✓ Studio smoke test passed");
