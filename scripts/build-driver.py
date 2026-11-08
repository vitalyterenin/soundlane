#!/usr/bin/env python3
"""Build our bundled Core Audio driver from the pinned, vendored libASPL sources."""
import concurrent.futures
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
out = Path(os.environ.get('SOUNDLANE_OUTPUT_DIR', Path.home() / 'Library/Developer/SoundLane'))
build = out / 'DriverBuild'
build.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
flags = ['-std=c++17', '-O2', '-fPIC', '-fvisibility=hidden', '-mmacosx-version-min=14.2',
         '-arch', 'arm64', '-isysroot', sdk, '-I' + str(root / 'Vendor/libASPL/include'),
         '-Wno-unused-parameter', '-Wno-reorder-init-list', '-Wno-invalid-offsetof']
sources = sorted((root / 'Vendor/libASPL/src').glob('*.cpp')) + [root / 'Driver/Driver.cpp']
headers = list((root / 'Vendor/libASPL/include').rglob('*.hpp')) + list((root / 'Vendor/libASPL/src').glob('*.hpp')) + list((root / 'Common').glob('*.hpp'))
newest_header = max(p.stat().st_mtime for p in headers)
def compile(source):
    obj = build / (('SoundLane-' if source.parent.name == 'Driver' else '') + source.stem + '.o')
    if not obj.exists() or obj.stat().st_mtime < max(source.stat().st_mtime, newest_header):
        subprocess.run(['xcrun', 'clang++', *flags, '-c', str(source), '-o', str(obj)], check=True)
    return obj
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    objects = list(pool.map(compile, sources))
driver = out / 'SoundLane.driver'
(driver / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
subprocess.run(['xcrun', 'clang++', '-bundle', '-arch', 'arm64', '-mmacosx-version-min=14.2',
                *map(str, objects), '-framework', 'CoreFoundation', '-framework', 'CoreAudio',
                '-o', str(driver / 'Contents/MacOS/SoundLaneDriver')], check=True)
factory = '9986C6BE-6BB5-4D77-9332-4A2EDC100F10'
info = dict(CFBundleIdentifier='in.teren.SoundLane.Driver', CFBundleExecutable='SoundLaneDriver',
            CFBundleName='SoundLane Microphone', CFBundlePackageType='BNDL', CFBundleVersion='1',
            CFBundleShortVersionString='0.1.0', CFBundleSupportedPlatforms=['MacOSX'],
            CFPlugInFactories={factory:'SoundLaneDriverFactory'},
            CFPlugInTypes={'443ABAB8-E7B3-491A-B985-BEB9187030DB':[factory]},
            sandboxSafe=True, AudioServerPlugIn_MachServices=[],
            NSHumanReadableCopyright='SoundLane. Includes libASPL (MIT), Victor Gaydov and contributors.')
with (driver / 'Contents/Info.plist').open('wb') as f: plistlib.dump(info, f)
subprocess.run(['codesign', '--force', '--sign', '-', str(driver)], check=True)
print(driver)
