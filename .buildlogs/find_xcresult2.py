#!/usr/bin/env python3
"""Find xcresulttool output + actual errors. Dump to UTF-8 files for reliable downstream reads."""
import re, os, sys

os.makedirs('.buildlogs/run9', exist_ok=True)
raw = open('.buildlogs/ci_run9_full.txt', 'r', encoding='utf-8', errors='replace').read()
print(f'raw lines: {raw.count(chr(10))}')

def strip_ansi(s):
    s = re.sub(r'\x1b\[[0-9;]*[mGKHF]', '', s)
    s = re.sub(r'\x1b\[\?25[lh]', '', s)
    s = re.sub(r'\x1b\[\?2004[h]', '', s)
    s = re.sub(r'\x1b\]0;[^\x07]*\x07', '', s)
    s = re.sub(r'\x1b', '', s)
    return s

lines = raw.split('\n')
clean = [strip_ansi(l) for l in lines]

# 1) Find exact line of "echo \"=== SILENT COMPILE FAILURE REVEAL ===\"" so we know where the xcrun output starts
reveal_exec_idx = None
for i, l in enumerate(clean):
    if 'echo "=== SILENT COMPILE FAILURE REVEAL ==="' in l:
        reveal_exec_idx = i
        break
print(f'reveal_exec_idx = {reveal_exec_idx}')

# Capture a generous window AFTER the echo (to encompass the xcrun xcresulttool output)
if reveal_exec_idx is not None:
    end = min(len(clean), reveal_exec_idx + 800)
    with open('.buildlogs/run9/xcresult_block.txt', 'w', encoding='utf-8') as fp:
        for l in clean[reveal_exec_idx:end]:
            fp.write(l + '\n')
    print(f'wrote xcresult_block.txt: {end - reveal_exec_idx} lines')

# 2) EVERY line in entire log containing "error:" not in standard noise
noisy = ('libtool', 'validates', 'will be ignored', 'cannot read', 'no such file',
         'error-handling', 'invalidates', 'error_handler', 'BUILD INTERRUPTED',
         'STRONG/weak', 'building.presentation', 'missing submodule',
         "Couldn't load", 'errors are being counted')
with open('.buildlogs/run9/all_error_lines.txt', 'w', encoding='utf-8') as fp:
    for i, l in enumerate(clean):
        if 'error:' in l and not any(s in l for s in noisy):
            fp.write(f'L{i+1}: {l}\n')

# 3) Every line mentioning "smartSpeedCompanion" or "fatal" or "ARCHIVE FAILED" or "BUILD FAILED"
with open('.buildlogs/run9/keyed_markers.txt', 'w', encoding='utf-8') as fp:
    for i, l in enumerate(clean):
        if any(k in l for k in ('ARCHIVE FAILED', 'BUILD FAILED', 'BUILD SUCCEEDED',
                                  '** CLEAN ', 'exited with', '** BUILD ',
                                  'fatal: ', 'FATAL', 'SwiftCompile',
                                  'swiftc', 'SwiftDriver', 'SwiftEmitModule',
                                  'Compilation timed out', 'Time limit', 'SIGKILL')):
            fp.write(f'L{i+1}: {l}\n')
            if 'ARCHIVE FAILED' in l or 'BUILD FAILED' in l or 'fatal:' in l or 'FATAL' in l:
                # Print context
                start = max(0, i - 3)
                end_ = min(len(clean), i + 30)
                fp.write('  -- context:\n')
                for j in range(start, end_):
                    fp.write(f'  L{j+1}: {clean[j]}\n')
                fp.write('  -- /context\n')

print('Wrote three artifact files under .buildlogs/run9/:')
for fn in sorted(os.listdir('.buildlogs/run9')):
    p = f'.buildlogs/run9/{fn}'
    sz = os.path.getsize(p)
    print(f'  {fn}: {sz} bytes')
