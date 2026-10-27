import { createPreviewSandbox } from '../Web/preview-engine/src/browser/client.js';
import { renderWidget } from '../Web/preview-engine/src/render/renderer.js';
import { newProjectFiles, exportPackage } from '../Web/preview-engine/src/package/index.js';

// These permission-free examples are the exact source executed by the shared
// sandbox and exported to Studio. Sample data never writes check-in history.
const examples = [
  {
    name: 'Reading habit', family: 'small', label: 'Reading habit · sample check-ins',
    source: (color) => `const accent = "${color}";
const days = Array.from({ length: 49 }, (_, i) => i % 5 !== 1 || i >= 37);
$render(
  <vstack spacing="8" padding="14" frame="max" background="#f1f8f4">
    <text font="headline">Read every day</text>
    <hstack spacing="3">
      {Array.from({ length: 7 }, (_, week) => <vstack spacing="3">
        {days.slice(week * 7, week * 7 + 7).map(done =>
          <rect frame="14,8" corner="2" color={done ? accent : "#dfe8e2"} />)}
      </vstack>)}
    </hstack>
    <text font="caption" color={accent}>12 day streak</text>
  </vstack>
);`,
  },
  {
    name: 'Weather', family: 'small', label: 'Weather · sample forecast',
    source: (color) => `const accent = "${color}";
const forecast = { city: "London", temperature: "18°" };
$render(
  <vstack alignment="leading" spacing="8" padding="18" frame="max" background="#f1f8f4">
    <text font="caption" color={accent}>{forecast.city}</text>
    <icon systemName="cloud.sun.fill" size="28" color={accent} />
    <text font="largeTitle">{forecast.temperature}</text>
    <text font="caption">Partly cloudy</text>
  </vstack>
);`,
  },
  {
    name: 'Countdown', family: 'small', label: 'Countdown · sample event',
    source: (color) => `const accent = "${color}";
const trip = { name: "Next adventure", days: 18 };
$render(
  <vstack alignment="leading" spacing="8" padding="18" frame="max" background="#f1f8f4">
    <icon systemName="airplane" size="24" color={accent} />
    <spacer />
    <text font="largeTitle" color={accent}>{trip.days} days</text>
    <text font="caption">{trip.name}</text>
  </vstack>
);`,
  },
];
const colors = ['#258557', '#5468cf', '#bd6633'];
const code = document.getElementById('hero-source');
const preview = document.getElementById('hero-preview');
const status = document.getElementById('hero-status');
const link = document.getElementById('hero-open');
const studio = new URL('studio/', document.baseURI);
let selected = 0;
let theme = 0;
let generation = 0;
const sandbox = createPreviewSandbox({ sandboxURL: new URL('sandbox.html', studio), assetBaseURL: new URL('runtime/', studio), startupTimeoutMilliseconds: 10000 });

function highlight(source) {
  code.replaceChildren();
  // Tokenize only for display; never insert source as HTML or evaluate it in
  // the landing page. JSX is compiled/executed inside the existing sandbox.
  const tokens = /("[^"\n]*"|\b(?:const|true|false)\b|\$render|<\/?[a-z]+|\b\d+\b)/g;
  let offset = 0;
  for (const match of source.matchAll(tokens)) {
    code.append(document.createTextNode(source.slice(offset, match.index)));
    const token = match[0];
    const node = document.createElement(token === `"${colors[theme]}"` ? 'button' : 'span');
    node.textContent = token;
    node.className = token.startsWith('"') ? 'syntax-string' : 'syntax-keyword';
    if (node.tagName === 'BUTTON') {
      node.type = 'button';
      node.className += ' theme-token';
      node.style.setProperty('--swatch', colors[theme]);
      node.setAttribute('aria-label', 'Change widget color');
      node.addEventListener('click', () => { theme = (theme + 1) % colors.length; void update(true); });
    }
    code.append(node);
    offset = match.index + token.length;
  }
  code.append(document.createTextNode(source.slice(offset)));
}

async function update(restoreFocus = false) {
  const current = ++generation;
  const example = examples[selected];
  const source = example.source(colors[theme]);
  highlight(source);
  if (restoreFocus) code.querySelector('button').focus({ preventScroll: true });
  document.querySelectorAll('[data-hero-example]').forEach((button, index) => {
    button.setAttribute('aria-pressed', String(index === selected));
  });
  const files = newProjectFiles(`Homepage ${example.name}`, source);
  const archive = exportPackage(files);
  if (archive.error) throw new Error(archive.error);
  const payload = btoa(String.fromCharCode(...archive.bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  link.href = `${studio}#sw-preview=v1.${payload}`;
  status.textContent = 'Rendering JSX…';
  preview.setAttribute('aria-busy', 'true');
  try {
    await sandbox.ready;
    const result = await sandbox.execute({ files, manifest: archive.manifest, environments: { 'widget-size': example.family } });
    if (current !== generation) return;
    if (result.error || !result.tree) throw new Error(result.error?.message ?? 'No widget output.');
    const rendered = await renderWidget(result.tree, { family: example.family, profile: 'iphone-393', appearance: 'light' });
    if (current !== generation) return;
    const scale = example.family === 'medium' ? 0.61 : 1;
    const frame = document.createElement('div');
    frame.className = 'hero-widget-frame';
    frame.style.width = `${rendered.size.width * scale}px`;
    frame.style.height = `${rendered.size.height * scale}px`;
    rendered.element.style.transformOrigin = 'top left';
    rendered.element.style.transform = `scale(${scale})`;
    frame.append(rendered.element);
    preview.replaceChildren(frame);
    preview.setAttribute('aria-label', example.label);
    preview.dataset.example = example.name;
    status.textContent = example.label;
  } catch {
    if (current !== generation) return;
    preview.textContent = 'Preview unavailable. Open this example in Web Studio to try it.';
    status.textContent = 'The browser could not render the preview.';
  } finally {
    if (current === generation) preview.setAttribute('aria-busy', 'false');
  }
}

document.querySelectorAll('[data-hero-example]').forEach((button, index) => {
  button.addEventListener('click', () => { selected = index; void update(); });
});
void update();
