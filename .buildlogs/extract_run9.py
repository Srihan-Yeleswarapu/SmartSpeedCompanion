#!/usr/bin/env python3
"""Extract run-9 CI log and pull out the xcresulttool diagnostic block."""
import re
import sys
import subprocess

LOG_DIR = '.buildlogs'
RUN_ID = '29353778564'

print(f'# Pulling run {RUN_ID} log...', flush=True)
failed_rc = subprocess.run(
    ['gh', 'run', 'view', RUN_ID, '--log-failed'],
    stdout=open(f'{LOG_DIR}/ci_failed_log_9.txt', 'wb'),
    stderr=subprocess.STDOUT, shell=False,
).returncode
print(f'# gh --log-failed -> {failed_rc}')

full_rc = subprocess.run(
    ['gh', 'run', 'view', RUN_ID, '--log'],
    stdout=open(f'{LOG_DIR}/ci_run9_full.txt', 'wb'),
    stderr=subprocess.STDOUT, shell=False,
).returncode
print(f'# gh --log      -> {full_rc}')

# Quick line counts
for fn in ('ci_failed_log_9.txt', 'ci_run9_full.txt'):
    p = f'{LOG_DIR}/{fn}'
    n = sum(1 for _ in open(p, 'rb'))
    print(f'# {fn}: {n} lines')

# Locate SILENT COMPILE FAILURE REVEAL block
raw = open(f'{LOG_DIR}/ci_run9_full.txt', 'r', encoding='utf-8', errors='replace').read()
lines = raw.split('\n')

def ansi_strip(s):
    s = re.sub(r'\x1b\[[0-9;]*[mGKHF]', '', s)
    s = re.sub(r'\x1b\[\?25[lh]', '', s)
    s = re.sub(r'\x1b\[\?2004[h]', '', s)
    s = re.sub(r'\x1b\]0;[^\x07]*\x07', '', s)
    s = re.sub(r'\x1b', '', s)
    return s

clean = [ansi_strip(l) for l in lines]

anchor_idx = None
for i, l in enumerate(clean):
    if 'SILENT COMPILE FAILURE REVEAL' in l:
        anchor_idx = i
        break

out_path = f'{LOG_DIR}/ci9_xcresult.txt'
with open(out_path, 'w', encoding='utf-8') as fp:
    if anchor_idx is None:
        fp.write('# NO xcresulttool block found in run 9 log.\n')
        fp.write('# Showing last 200 lines of full log instead:\n')
        fp.write('\n'.join(clean[-200:]))
        fp.write('\n\n# ALL \"error:\" lines in the full log (excluding noise):\n')
        for i, l in enumerate(clean):
            if 'error:' in l and not any(
                skip in l for skip in (
                    'libtool', 'validates', 'will be ignored', 'cannot read',
                    'no such file', 'error-handling', 'invalidates'
                )
            ):
                fp.write(f'L{i+1}: {l[:300]}\n')
    else:
        fp.write(f'# SILENT COMPILE FAILURE REVEAL block (run {RUN_ID}) starts at clean-line {anchor_idx+1}\n')
        fp.write('# Showing up to 800 lines from the anchor.\n\n')
        end = min(len(clean), anchor_idx + 800)
        for j in range(anchor_idx, end):
            fp.write(f'L{j+1}: {clean[j]}\n')
        fp.write('\n\n# Also: all distinct error:/fail markers anywhere in log (filtered):\n')
        for i, l in enumerate(clean):
            if any(k in l for k in ('error:', 'FAIL', 'failed ', 'archived nothing',
                                     'missing:', 'cannot find', 'unresolved', 'expected')) and not any(
                skip in l for skip in (
                    'libtool', 'validates', 'will be ignored', 'cannot read',
                    'no such file', 'error-handling', 'invalidates',
                    'Building for', '.c:', '.h:', 'error_handler'
                )
            ):
                fp.write(f'L{i+1}: {l[:280]}\n')

# Show contents in stdout too
print(f'\n# Extracted diagnostic -> {out_path}')
with open(out_path, 'r') as fp:
    body = fp.read()
print('===== START OF EXTRACT =====')
print(body[:8000])
print('===== END OF EXTRACT (first 8KB) =====')
