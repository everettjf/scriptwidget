import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { launchChrome, serveDirectory } from '../../preview-engine/scripts/lib/chrome.mjs';
import { writeArchive } from '../../preview-engine/src/package/archive.js';
import { newProjectFiles } from '../../preview-engine/src/package/index.js';
const directory=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../dist');
const server=await serveDirectory(directory);
const chrome=await launchChrome({width:1450,height:1000,scale:1});
try {
  const page=await chrome.newPage();
  const base=process.env.SCRIPTWIDGET_STUDIO_URL || server.origin+'/index.html';
  await page.goto(base);
  // Measure the baseline only after the saved project UI is ready, and wait
  // for the imported project's list update as well as its asynchronous preview.
  await page.waitFor("!!document.querySelector('.sw-widget') && document.querySelectorAll('#project-list li').length>0 && document.getElementById('save-state')?.textContent==='Saved in this browser'",20000);
  const initial=await page.evaluate<number>("document.querySelectorAll('#project-list li').length");
  let fragment: string;
  if(process.env.SCRIPTWIDGET_CLI && process.env.SCRIPTWIDGET_PREVIEW_PACKAGE) {
    const report=JSON.parse(execFileSync(process.env.SCRIPTWIDGET_CLI,['preview',process.env.SCRIPTWIDGET_PREVIEW_PACKAGE,'--no-open','--format','json'],{encoding:'utf8'}));
    if(report.status!=='passed')throw Error('Native handoff failed');
    fragment=new URL(report.previewURL).hash;
  } else {
    const files={...newProjectFiles('Agent preview ✓','$import("lib/helper.js"); $render(<text>{agentGreeting()}</text>);'),'lib/helper.js':'function agentGreeting(){return "Hello ScriptWidget :)";}','image/binary.bin':new Uint8Array([0,255,42])};
    fragment='#sw-preview=v1.'+Buffer.from(writeArchive('Widget',files)).toString('base64url');
  }
  await page.goto(base+fragment);
  try { await page.waitFor("document.querySelector('.sw-widget')?.textContent.replaceAll(String.fromCharCode(160), ' ').includes('Hello ScriptWidget :)')",25000); }
  catch(error) { console.error(await page.evaluate("document.body.innerText.slice(-4500)"), page.consoleMessages); throw error; }
  await page.waitFor(`document.querySelectorAll('#project-list li').length===${initial+1} && document.getElementById('save-state')?.textContent==='Saved in this browser'`,20000);
  if(await page.evaluate("location.hash!==''"))throw Error('Payload remained in browser URL');
  if(await page.evaluate<number>("document.querySelectorAll('#project-list li').length")!==initial+1)throw Error('Existing project overwritten or handoff imported more than once');
  await page.goto(base);
  await page.waitFor("document.querySelector('.sw-widget')?.textContent.replaceAll(String.fromCharCode(160), ' ').includes('Hello ScriptWidget :)')",20000);
  if(await page.evaluate<number>("document.querySelectorAll('#project-list li').length")!==initial+1)throw Error('Reload duplicated import');
  await page.goto(base+'#sw-preview=v1.%%%');
  await page.waitFor("document.body.textContent.includes('Could not load the preview link')",20000);
  await page.waitFor("!!document.querySelector('.sw-widget')",20000);
  if(await page.evaluate<number>("document.querySelectorAll('#project-list li').length")!==initial+1)throw Error('Malformed link changed stored projects');
  if(await page.evaluate("location.hash!==''"))throw Error('Malformed payload not removed');
  const cold=await chrome.newPage();
  await cold.goto(base+fragment);
  await cold.waitFor("document.querySelector('.sw-widget')?.textContent.replaceAll(String.fromCharCode(160), ' ').includes('Hello ScriptWidget :)')",25000);
  if(await cold.evaluate("location.hash!==''") || await cold.evaluate<number>("document.querySelectorAll('#project-list li').length")!==initial+2)throw Error('Cold startup did not import exactly once');
  if(process.argv[2])fs.writeFileSync(process.argv[2],await cold.screenshot());
  const errors=page.consoleMessages.filter(line=>line.startsWith('exception')||line.startsWith('error'));
  if(errors.length)throw Error(errors.join('\n'));
  console.log('Preview handoff: automatic import/render, Unicode/helper/binary package, existing-project preservation, reload and malformed-link recovery passed.');
} finally {await chrome.close();server.close();}
