import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

// The app repository is the only source and publisher for functional Web Studio.
const root = path.resolve(import.meta.dirname, '..');
const out = path.join(root, '_site');
const studio = path.join(root, 'Web/studio/dist');
if (!fs.existsSync(path.join(studio, 'index.html'))) throw new Error('Build Web/studio before assembling Pages');
fs.rmSync(out, {recursive: true, force: true});
fs.mkdirSync(out, {recursive: true});
fs.cpSync(studio, path.join(out, 'studio'), {recursive: true});
const appIcon = fs.readFileSync(path.join(root, 'iOS/ScriptWidget/Assets/Assets.xcassets/AppIcon.appiconset/icon-64@2x.png'));
const iconName = `app-icon-${createHash('sha256').update(appIcon).digest('hex').slice(0, 12)}.png`;
fs.writeFileSync(path.join(out, iconName), appIcon);
const entry = fs.readFileSync(path.join(root, 'Web/entry/index.html'), 'utf8').replaceAll('__APP_ICON__', iconName);
fs.writeFileSync(path.join(out, 'index.html'), entry);
if (fs.existsSync(path.join(root, 'site/schemas'))) fs.cpSync(path.join(root, 'site/schemas'), path.join(out, 'schemas'), {recursive: true});
fs.writeFileSync(path.join(out, '.nojekyll'), '');
console.log('Built ScriptWidget entry page, functional Studio and public schemas.');
