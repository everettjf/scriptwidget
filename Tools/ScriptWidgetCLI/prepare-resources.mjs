import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { dataAPICatalog } from '../../Editor/editorfe/src/dataAPICatalog.js';
import { scriptWidgetAPI } from '../../Editor/editorfe/src/scriptWidgetAPI.js';
const directory=path.dirname(fileURLToPath(import.meta.url));
const root=path.resolve(directory,'../..');
const native=fs.readFileSync(path.join(root,'Shared/ScriptWidgetRuntime/Widget/Component/ScriptWidgetElementView.swift'),'utf8');
const tags=[...native.matchAll(/case "([A-Za-z]+)": return/g)].map(match=>match[1]);
const aliases={Rectangle:'rect',RoundedRectangle:'roundedrect'};
const properties={};
for(const [name,component] of Object.entries(scriptWidgetAPI.components)){
  const tag=aliases[name]??name.toLowerCase();
  properties[tag]=[...Object.keys(scriptWidgetAPI.globalProperties),...Object.keys(component.properties??{})];
}
fs.writeFileSync(path.join(directory,'Resources/api-catalog.json'),JSON.stringify(dataAPICatalog));
fs.writeFileSync(path.join(directory,'Resources/components.json'),JSON.stringify({tags,properties}));
for(const [source,target] of [['docs/scriptwidget-runtime-api.md','runtime-api.md'],['docs/package-format.md','package-format.md'],['docs/platform-support.md','platform-support.md']]){
 let text=fs.readFileSync(path.join(root,source),'utf8');
 text=text.replace(/\[([^\]]+)\]\(([^)]+)\)/g,(whole,label,url)=>/^(https?:|#)/.test(url)?whole:`[${label}](https://github.com/everettjf/scriptwidget/blob/main/${path.posix.normalize(path.posix.join(path.posix.dirname(source),url))})`);
 fs.writeFileSync(path.join(root,'Skills/scriptwidget-creator/references',target),text);
}
