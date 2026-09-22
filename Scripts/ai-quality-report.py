#!/usr/bin/env python3
"""Make an offline, inspectable visual report; no uploads or external resources."""
import html
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
samples = json.loads((root / "quality.json").read_text())
vision_path = root / "vision.json"
vision = {x["image"]: x for x in json.loads(vision_path.read_text())} if vision_path.exists() else {}
config_path = root / "config.json"
config = json.loads(config_path.read_text()) if config_path.exists() else {"status": "run incomplete"}
escape = lambda value: html.escape(str(value), quote=True)
cards = []
for item in samples:
    figures = []
    for filename in item["screenshots"]:
        if pathlib.Path(filename).name != filename or ".." in filename or not filename.endswith(".png"):
            raise ValueError("Invalid screenshot filename")
        finding = vision.get(filename, {})
        missing = finding.get("unrecognizedExpectedText", [])
        review = ", ".join(missing) or ("no missing expected text flagged" if finding else "not run")
        figures.append(f'<figure><img loading="lazy" src="{escape(filename)}" alt="{escape(filename)}"><figcaption>{escape(filename)}<br>OCR review: {escape(review)}</figcaption></figure>')
    cards.append(f'<article><h2>{escape(item["id"])} · attempt {item["attempt"]}</h2><p>{escape(item["prompt"])}</p><p>Runtime: {item["runtimePassed"]} · Missing text: {escape(item["missingText"])} · Missing components: {escape(item.get("missingComponents", []))} · Tokens: {item["tokens"]}</p><div class="images">{"".join(figures)}</div></article>')
page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ScriptWidget AI quality review</title><style>body{font:16px system-ui;margin:32px;background:#eef1f5;color:#17202e}main{max-width:1400px;margin:auto}article{background:white;border-radius:16px;padding:24px;margin:24px 0}h1,h2{line-height:1.2}.images{display:flex;gap:24px;align-items:start;flex-wrap:wrap}figure{margin:0;max-width:100%;flex:1 1 320px}img{max-width:100%;height:auto;border:1px solid #aaa}figcaption{font-size:13px;margin-top:8px;overflow-wrap:anywhere}code{white-space:pre-wrap}</style><main><h1>ScriptWidget AI quality review</h1><p>Native macOS snapshots of synthetic offline prompts. Runtime/text checks do not prove readability. OCR flags require visual review; it can miss small text or punctuation. WidgetKit device behavior is not certified by this report.</p>'''
page += f'<p>Configuration: {escape(config)}</p>' + "".join(cards) + "</main></html>"
(root / "index.html").write_text(page)
print(root / "index.html")
