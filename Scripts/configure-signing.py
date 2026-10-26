#!/usr/bin/env python3
"""Set public template identifiers; no account credentials or signing keys are used."""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle_id', help='Unique reverse-DNS app ID, e.g. com.yourhandle.DualScreenTV')
args = parser.parse_args()
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*){2,}', args.bundle_id):
    parser.error('Use at least three reverse-DNS components, with letters, digits and hyphens.')
root = Path(__file__).resolve().parents[1]
project = root / 'Apps/tvOS/DualScreenTV/DualScreenTV.xcodeproj/project.pbxproj'
match = re.search(r'PRODUCT_BUNDLE_IDENTIFIER = ([A-Za-z0-9.-]+);', project.read_text())
if not match:
    parser.error('Cannot find the TV app identifier.')
old = match.group(1)
# These are the only places identifiers are shared between targets at runtime.
paths = [project,
    root / 'Apps/tvOS/DualScreenTV/Config/DualScreenTV.entitlements',
    root / 'Apps/tvOS/DualScreenTV/Config/TopShelf.entitlements',
    root / 'Apps/tvOS/DualScreenTV/TopShelf/ContentProvider.swift',
    root / 'Apps/tvOS/DualScreenTV/DualScreenTV/LibraryView.swift']
for path in paths:
    path.write_text(path.read_text().replace(old, args.bundle_id))
print(f'TV: {args.bundle_id}\nTop Shelf: {args.bundle_id}.TopShelf\nCompanion: {args.bundle_id}.Companion\nMac: {args.bundle_id}.Companion.Mac\nApp Group: group.{args.bundle_id}')
print('Select your team for all targets in Xcode; enable this App Group on TV and Top Shelf.')
