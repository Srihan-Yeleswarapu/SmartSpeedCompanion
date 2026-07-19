#!/usr/bin/env python3
"""Find xcresulttool output + any actual errors in run-9 log."""
import re, sys

p = '.buildlogs/ci_run9_full.txt'
raw = open(p, 'r', encoding='utf-8', errors='replace').read()
n = raw.count('\n')
print(f'# {p}: {n} lines', flush=True)

def strip_ansi(s):
    s = re.sub(r'\x1b\[[0-9;]*[mGKHF]', '', s)
    s = re.sub(r'\x1b\[\?25[lh]', '', s)
    s = re.sub(r'\x1b\[\?2004[h]', '', s)
    s = re.sub(r'\x1b\]0;[^\x07]*\x07', '', s)
    s = re.sub(r'\x1b', '', s)
    return s

lines = [strip_ansi(l) for l in raw.split('\n')]

# Anchors
anchors_we_want = [
    'xcrun xcresulttool',
    'SILENT COMPILE FAILURE REVEAL',
    'SmartSpeedCompanion',
    'ARCHIVE FAILED',
    '** CLEAN SUCCEEDED **',
    '** BUILD FAILED **',
    'error:',
    'note:',
    'warning:',
    'exited with',
    'invalid',  # SwiftCompile errors often contain "invalid"
    'cannot find',
    'expected',
    'use of',
    'SwiftCompile',
]

# Map lineidx -> (anchor, snippet up to 600 chars)
hits = {}
for i, l in enumerate(lines):
    for a in anchors_we_want:
        if a in l:
            hits.setdefault(a, []).append((i, l))

print()
for a in anchors_we_want:
    items = hits.get(a, [])
    print(f'### anchor {a!r}: {len(items)} hits')
    if a == 'SmartSpeedCompanion' and len(items) > 30:
        # Most lines are target deps; only print the LATEST 10
        for i, l in items[-10:]:
            print(f'   L{i+1}: {l[:240]}')
    elif len(items) > 100:
        print(f'   (suppressed; {len(items)} hits)')
    else:
        for i, l in items[:60]:
            print(f'   L{i+1}: {l[:600]}')
    print()
