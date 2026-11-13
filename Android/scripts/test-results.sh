#!/bin/sh
# Prints a one-line summary and any failures from the latest connected test run of a module.
module="${1:-core}"
for f in "$module"/build/outputs/androidTest-results/connected/debug/TEST-*.xml; do
  python3 - "$f" <<'P'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
print(f"tests={r.get('tests')} failures={r.get('failures')} errors={r.get('errors')} skipped={r.get('skipped')} time={r.get('time')}s")
for c in r.iter('testcase'):
    for k in ('failure', 'error'):
        n = c.find(k)
        if n is not None:
            print(f"FAIL {c.get('classname').split('.')[-1]}.{c.get('name')}\n    " + (n.text or '')[:1500].replace('\n', '\n    '))
P
done
