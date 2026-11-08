#!/usr/bin/env python3
"""Install and verify the approved project and dependency notices before signing."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil

ROOT = Path(__file__).resolve().parent.parent
FILES = ('LICENSE', 'THIRD_PARTY_NOTICES.md')
# Standard MIT terms, whitespace-normalized; the owner's copyright is preserved separately.
MIT_TERMS_SHA256 = 'fe2a9817987f862eaced948f0468c7f51d2fedfc48c5c505b246a49a3870e9a5'


def source_files():
    if json.loads((ROOT / 'release.json').read_text()).get('license') != 'Proprietary':
        raise ValueError('The owner reserved all rights to SoundLane')
    files = {name: (ROOT / name).read_bytes() for name in FILES}
    expected = ('Copyright (c) 2026 Vitaly Terenin. All rights reserved.\n\n'
                'The original SoundLane source code and application are proprietary.\n'
                'No open-source license is granted for them. Third-party components retain\n'
                'their respective licenses, listed in THIRD_PARTY_NOTICES.md.\n')
    if files['LICENSE'] != expected.encode():
        raise ValueError('The owner-approved rights notice is missing or changed')
    for name in ('LICENSE', 'LICENSE.apple2012', 'LICENSE.apple2020'):
        upstream = (ROOT / 'Vendor/libASPL' / name).read_bytes()
        if not upstream.strip() or upstream not in files['THIRD_PARTY_NOTICES.md']:
            raise ValueError('Complete libASPL and Apple notices are required')
    pins = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    sparkle = next(p for p in pins if p['identity'] == 'sparkle')['state']['version']
    if f'## Sparkle {sparkle}\n'.encode() not in files['THIRD_PARTY_NOTICES.md']:
        raise ValueError('Third-party notices do not match the pinned Sparkle version')
    return files, sparkle


def verify_bundle(app):
    app = Path(app)
    files, sparkle = source_files()
    for name, expected in files.items():
        if (app / 'Contents/Resources/Licenses' / name).read_bytes() != expected:
            raise ValueError(f'Installed app is missing the exact {name}')
    driver = app / 'Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver'
    for name, expected in files.items():
        if (driver / 'Contents/Resources/Licenses' / name).read_bytes() != expected:
            raise ValueError(f'Bundled HAL component is missing the exact {name}')
    plist = app / 'Contents/Frameworks/Sparkle.framework/Resources/Info.plist'
    if plistlib.loads(plist.read_bytes()).get('CFBundleShortVersionString') != sparkle:
        raise ValueError('Bundled Sparkle differs from the reviewed third-party notices')


def install(app, dependency_license):
    files, _ = source_files()
    upstream = Path(dependency_license).read_bytes()
    if not upstream.strip() or upstream not in files['THIRD_PARTY_NOTICES.md']:
        raise ValueError('Complete upstream Sparkle license and external notices must be preserved')
    destination = Path(app) / 'Contents/Resources/Licenses'
    destination.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (destination / name).write_bytes(content)
    driver_notices = Path(app) / 'Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver/Contents/Resources/Licenses'
    driver_notices.mkdir(parents=True, exist_ok=True)
    for name, content in files.items(): (driver_notices / name).write_bytes(content)
    verify_bundle(app)


def stage_distribution(app, directory):
    verify_bundle(app)
    for name in FILES:
        shutil.copyfile(ROOT / name, Path(directory) / name)


def verify_distribution(directory, app_name):
    directory = Path(directory)
    verify_bundle(directory / app_name)
    for name, expected in source_files()[0].items():
        if (directory / name).read_bytes() != expected:
            raise ValueError(f'Disk image is missing the exact {name}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['install', 'verify'])
    parser.add_argument('--app', required=True)
    parser.add_argument('--sparkle-license')
    args = parser.parse_args()
    if args.command == 'install':
        if not args.sparkle_license: parser.error('--sparkle-license is required for install')
        install(args.app, args.sparkle_license)
    else:
        verify_bundle(args.app)
    print('Verified project license and complete third-party notices in the app bundle')
