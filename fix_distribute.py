import sys

with open('.github/workflows/distribute.yml', 'rb') as f:
    raw = f.read()

start_marker = b'python3 -c "'
start_idx = raw.find(start_marker)
if start_idx < 0:
    print('Start not found!')
    sys.exit(1)

# Find the end - the closing )" after the multi-line content
end_search_start = start_idx + len(start_marker)
end_idx = raw.find(b')"\r\n', end_search_start)
if end_idx < 0:
    end_idx = raw.find(b'")\r\n', end_search_start)
if end_idx < 0:
    end_idx = raw.find(b'"\r\n', end_search_start)

if end_idx < 0:
    print('End not found!')
    sys.exit(1)
end_idx += 3  # skip past the )"\r\n

print(f'Block: {start_idx} to {end_idx}')
print(f'Old content: {repr(raw[start_idx:end_idx])}')

# Build single-line replacement
replacement = (
    b'python3 -c "import plistlib; plistlib.dump({'
    b"'method': 'app-store-connect',"
    b"'signingStyle': 'manual',"
    b"'signingIdentity': 'Apple Distribution',"
    b"'provisioningProfileSpecifier': 'Speedio App Store',"
    b"'teamID': 'VCNBBG32P6',"
    b"'uploadBitcode': False,"
    b"'uploadSymbols': True"
    b"}, open('$PWD/exportOptions.plist', 'wb'))"'
    b'\r\n          echo "exportOptions.plist created"'
)

new_content = raw[:start_idx] + replacement + raw[end_idx:]
with open('.github/workflows/distribute.yml', 'wb') as f:
    f.write(new_content)
print(f'Done! New size: {len(new_content)} (was {len(raw)})')