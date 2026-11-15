import fs from 'node:fs';
import path from 'node:path';

// The app repository is the only source and publisher for functional Web Studio.
const root = path.resolve(import.meta.dirname, '..');
const out = path.join(root, '_site');
const studio = path.join(root, 'Web/studio/dist');
if (!fs.existsSync(path.join(studio, 'index.html'))) throw new Error('Build Web/studio before assembling Pages');
fs.rmSync(out, {recursive: true, force: true});
fs.mkdirSync(out, {recursive: true});
fs.cpSync(studio, path.join(out, 'studio'), {recursive: true});
function redirect(route, target) {
  const file = path.join(out, route);
  fs.mkdirSync(path.dirname(file), {recursive: true});
  fs.writeFileSync(file, `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ScriptWidget</title><meta name="robots" content="noindex"><link rel="canonical" href="${target}"><meta http-equiv="refresh" content="0;url=${target}"></head><body><a href="${target}">Continue to ScriptWidget</a><script>location.replace(${JSON.stringify(target)}+location.search+location.hash)</script></body></html>`);
}
redirect('index.html', 'https://asp.run/scriptwidget/studio/');
for (const file of fs.readdirSync(path.join(root, 'site'), {recursive: true})) {
  if (!file.endsWith('.html') || file === 'index.html') continue;
  redirect(file, `https://atomsprout.com/scriptwidget/${file.replace(/index\.html$/, '')}`);
}
for (const suffix of ['support/', 'privacy/']) redirect(`${suffix}index.html`, `https://atomsprout.com/scriptwidget/${suffix}`);
if (fs.existsSync(path.join(root, 'site/schemas'))) fs.cpSync(path.join(root, 'site/schemas'), path.join(out, 'schemas'), {recursive: true});
fs.writeFileSync(path.join(out, '.nojekyll'), '');
console.log('Built personal Pages: functional Studio plus compatibility links to Company product pages.');
