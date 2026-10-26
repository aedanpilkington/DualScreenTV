#!/usr/bin/env python3
"""Audit files selected for the public Git repository (including binary metadata)."""
import argparse
from pathlib import Path
import re
import subprocess
import struct
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--private-term', action='append', default=[], help='Additional private text to reject; repeat as needed')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
try:
    names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
except subprocess.CalledProcessError:
    sys.exit('Initialize and stage the distribution repository before auditing.')
if not any(names):
    sys.exit('No tracked files to audit; stage the distribution source first.')
forbidden = {'.nds', '.3ds', '.cci', '.cxi', '.3dsx', '.gb', '.gbc', '.gba', '.iso', '.cso', '.pbp',
             '.sav', '.srm', '.dsv', '.state', '.dstvsave', '.dstvbackup', '.ipa', '.dylib',
             '.p12', '.p8', '.mobileprovision', '.provisionprofile', '.cer', '.rom', '.bios'}
failures = []
for name in filter(None, names):
    p = root / name
    if not p.is_file():
        failures.append(f'{name}: missing tracked file')
        continue
    if p.is_symlink():
        failures.append(f'{name}: symbolic link requires review')
        continue
    if p.suffix.lower() in forbidden or any(part.startswith(('DerivedData', 'xcuserdata')) or part in {'.build', 'build', 'LocalROMs', 'Docs', 'ConsoleModels'} for part in p.relative_to(root).parts):
        failures.append(f'{name}: private/runtime/build artifact')
    if p.stat().st_size > 90 * 1024 * 1024:
        failures.append(f'{name}: exceeds source repository file-size budget')
    data = p.read_bytes()
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        offset = 8
        while offset + 12 <= len(data):
            length = struct.unpack('>I', data[offset:offset + 4])[0]
            if data[offset + 4:offset + 8] == b'eXIf':
                failures.append(f'{name}: EXIF metadata requires removal/review')
            offset += length + 12
    if re.search(rb'/(?:Users|home)/[^/\x00\r\n]+/|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', data):
        failures.append(f'{name}: absolute personal path or private key')
    # Also inspect UTF-16 strings found in some image/archive metadata.
    for term in args.private_term:
        if any(term.casefold().encode(enc) in data.lower() for enc in ('utf-8', 'utf-16-le', 'utf-16-be')):
            failures.append(f'{name}: contains a supplied private term')
    if p.suffix == '.pbxproj':
        if re.search(rb'DEVELOPMENT_TEAM\s*=\s*[^;\s][^;]*;', data.replace(b'DEVELOPMENT_TEAM = "";', b'')):
            failures.append(f'{name}: signing team is configured')
if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'Distribution audit passed: {len(list(filter(None, names)))} tracked source/resource files; no game dumps, saves, signing keys, team IDs or personal paths detected.')
