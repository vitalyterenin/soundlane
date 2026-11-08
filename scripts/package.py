#!/usr/bin/env python3
"""Local installer: one product containing app + our virtual microphone.

No postinstall process-killing. Installer schedules a restart to load the HAL driver.
"""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from xml.sax.saxutils import escape

kind, source, destination = sys.argv[1:]
source, destination = Path(source), Path(destination)
version = plistlib.loads((source / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
with tempfile.TemporaryDirectory(prefix='soundlane-package-') as temp:
    stage = Path(temp)
    payload = stage / 'payload'
    driver_target = payload / 'Library/Audio/Plug-Ins/HAL/SoundLane.driver'
    if kind != 'driver':
        raise ValueError('Only the one-time HAL component uses an installer; distribute the app as a DMG')
    driver_target.parent.mkdir(parents=True)
    subprocess.run(['ditto', str(source), str(driver_target)], check=True)
    component = stage / 'component.pkg'
    components = stage / 'components.plist'
    subprocess.run(['pkgbuild', '--analyze', '--root', str(payload), str(components)], check=True)
    metadata = plistlib.loads(components.read_bytes())
    def fixed_locations(items):
        for item in items:
            item['BundleIsRelocatable'] = False
            fixed_locations(item.get('ChildBundles', []))
    fixed_locations(metadata)
    components.write_bytes(plistlib.dumps(metadata))
    identifier = 'in.teren.SoundLane.AudioComponent'
    subprocess.run(['pkgbuild', '--root', str(payload), '--component-plist', str(components), '--identifier', identifier,
                    '--version', version, '--install-location', '/', '--ownership', 'recommended', str(component)], check=True)
    title = 'SoundLane Audio Component'
    conclusion = ' onConclusion="RequireRestart"'
    distribution = stage / 'Distribution.xml'
    distribution.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>{escape(title)}</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <allowed-os-versions><os-version min="14.2"/></allowed-os-versions>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <choices-outline><line choice="main"/></choices-outline>
  <choice id="main" title="{escape(title)}" visible="false"><pkg-ref id="{identifier}"/></choice>
  <pkg-ref id="{identifier}" version="{version}"{conclusion}>component.pkg</pkg-ref>
</installer-gui-script>
''')
    subprocess.run(['productbuild', '--distribution', str(distribution), '--package-path', str(stage), str(destination)], check=True)
