#!/usr/bin/env python3
"""Build metadata and package signed updates for the one stable feed."""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from licenses import source_files, stage_distribution, verify_bundle, verify_distribution
from signing import certificate, verify as verify_signing

ROOT = pathlib.Path(__file__).resolve().parent.parent
ACCOUNT = 'in.teren.SoundLane'
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
ARCHIVE_NAME = 'SoundLane.dmg'


def config():
    data = json.loads((ROOT / 'release.json').read_text())
    if not re.fullmatch(r'\d+\.\d+\.\d+', data['version']):
        raise ValueError('version must be three numeric components')
    if not re.fullmatch(r'[1-9]\d*', data['build']):
        raise ValueError('build must be a positive, increasing integer')
    if len(base64.b64decode(data['publicEDKey'], validate=True)) != 32:
        raise ValueError('publicEDKey must contain the Sparkle public key')
    if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', data['id']):
        raise ValueError('id must be a stable lowercase application slug')
    repository = data['githubRepository']
    if not re.fullmatch(r'[A-Za-z0-9-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Expected an owner/repository identity')
    owner, repo = repository.split('/')
    if data['downloadURL'] != f'https://github.com/{repository}/releases/latest/download/{ARCHIVE_NAME}':
        raise ValueError('Expected the permanent app-named GitHub Releases download')
    if data['feedURL'] != f'https://{owner.lower()}.github.io/{repo}/appcast.xml':
        raise ValueError('Expected this repository\'s GitHub Pages appcast')
    source_files()
    certificate()
    return data


def write_plist(path):
    data = config()
    values = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    values.update(
        CFBundleIdentifier=ACCOUNT, CFBundleExecutable='SoundLane',
        CFBundleShortVersionString=data['version'], CFBundleVersion=data['build'],
        SUFeedURL=data['feedURL'], SUPublicEDKey=data['publicEDKey'],
        SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True,
        SUScheduledCheckInterval=14400, SUEnableSystemProfiling=False,
        SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
        SUSignedFeedFailureExpirationInterval=0,
    )
    pathlib.Path(path).write_bytes(plistlib.dumps(values))


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def signing_args():
    # CI supplies its secret over stdin, never in command-line arguments or files.
    secret = os.environ.get('SPARKLE_PRIVATE_KEY')
    if secret:
        return ['--ed-key-file', '-'], {'input': secret.encode()}
    return ['--account', ACCOUNT], {}


def read_feed(content):
    root = ET.fromstring(content)
    if root.tag != 'rss' or root.find('channel') is None:
        raise ValueError('Expected a Sparkle RSS appcast')
    return root, [int(item.findtext('sparkle:version', namespaces=NS))
                  for item in root.findall('./channel/item')]


def create_disk_image(app, archive):
    # One image serves both Finder installation and Sparkle updates.
    with tempfile.TemporaryDirectory(prefix='soundlane-dmg-') as staging:
        staging = pathlib.Path(staging)
        run('ditto', app, staging / app.name)
        (staging / 'Applications').symlink_to('/Applications')
        stage_distribution(staging / app.name, staging)
        run('hdiutil', 'create', '-volname', 'SoundLane',
            '-srcfolder', staging, '-fs', 'APFS', '-format', 'ULFO',
            '-nospotlight', archive)
    run('hdiutil', 'verify', archive)
    with tempfile.TemporaryDirectory(prefix='license-image-check-') as mount:
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, archive)
        try:
            verify_distribution(mount, app.name)
            verify_signing(pathlib.Path(mount) / app.name)
        finally:
            run('hdiutil', 'detach', mount)



def package(app, output, tools, previous):
    data = config()
    output = pathlib.Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Use an empty package output directory')
    app = pathlib.Path(app).resolve()
    plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    for key, expected in [('CFBundleVersion', data['build']),
                          ('CFBundleShortVersionString', data['version']),
                          ('SUPublicEDKey', data['publicEDKey']),
                          ('SUFeedURL', data['feedURL'])]:
        if plist.get(key) != expected:
            raise ValueError(f'Built app has unexpected {key}; rebuild it')
    verify_bundle(app)
    verify_signing(app)
    run('codesign', '--verify', '--deep', '--strict', app)
    architectures = subprocess.check_output(
        ['lipo', '-archs', str(app / 'Contents/MacOS/SoundLane')], text=True).strip()
    if architectures != 'arm64':
        raise ValueError('Releases must contain only the arm64 app binary')
    archive = output / ARCHIVE_NAME
    if previous:
        previous = pathlib.Path(previous)
        content = previous.read_bytes()
        args, kwargs = signing_args()
        run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify', previous, **kwargs)
        _, versions = read_feed(content)
        if versions and int(data['build']) <= max(versions):
            raise ValueError('New build must be greater than every published build')
    state_file = pathlib.Path(previous).with_suffix('.state.json') if previous else None
    state = json.loads(state_file.read_text()) if state_file and state_file.exists() else {'previousFeedSHA256': None, 'sourceURL': data['feedURL']}
    create_disk_image(app, archive)
    prepare_feed(output, tools, data, state)


def prepare_feed(output, tools, data, state):
    archive = output / ARCHIVE_NAME
    args, kwargs = signing_args()
    run(pathlib.Path(tools) / 'bin/generate_appcast', *args,
        '--download-url-prefix', data['downloadURL'].removesuffix(ARCHIVE_NAME),
        '--maximum-deltas', '0', '--maximum-versions', '1',
        '--link', 'https://github.com/' + data['githubRepository'], '-o', output / 'appcast.xml', output, **kwargs)
    run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify',
        output / 'appcast.xml', **kwargs)
    root, _ = read_feed((output / 'appcast.xml').read_bytes())
    items = root.findall('./channel/item')
    if len(items) != 1 or items[0].findtext('sparkle:version', namespaces=NS) != data['build']:
        raise ValueError('Generated appcast must contain only the current build')
    item = items[0]
    if item.findtext('sparkle:hardwareRequirements', namespaces=NS) != 'arm64':
        raise ValueError('Generated appcast must require Apple Silicon')
    enclosure = item.find('enclosure')
    if enclosure.get('url') != data['downloadURL']:
        raise ValueError('Unexpected archive URL')
    signature = enclosure.get('{' + NS['sparkle'] + '}edSignature')
    run(pathlib.Path(tools) / 'bin/sign_update', *args, '--verify', archive, signature, **kwargs)
    # Keep the artifact manifest separate from the signed Sparkle feed.
    state['sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in (archive, output / 'appcast.xml')}
    (output / 'publication.json').write_text(json.dumps(state, indent=2) + '\n')
    print(f'Ready: {archive}\nFeed: {output / "appcast.xml"}')


def previous(path):
    data = config()
    path = pathlib.Path(path)
    url = data['feedURL']
    request = urllib.request.Request(url, headers={'Cache-Control': 'no-cache'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content = response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404 and data['build'] == data['firstReleaseBuild']:
            # Bootstrap only the explicitly pinned first build, and only when no
            # release exists in this repository. Later 404s must fail closed.
            try:
                urllib.request.urlopen('https://api.github.com/repos/' + data['githubRepository'] + '/releases/latest', timeout=30)
            except urllib.error.HTTPError as release_error:
                if release_error.code == 404:
                    print('First release: no prior feed or GitHub release')
                    return
                raise
            raise ValueError('A published release exists; refusing a feed reset')
        if error.code == 404:
            raise ValueError('An established application must have a reachable GitHub Pages feed') from error
        raise
    read_feed(content)
    path.write_bytes(content)
    path.with_suffix('.state.json').write_text(json.dumps({
        'previousFeedSHA256': hashlib.sha256(content).hexdigest(), 'sourceURL': url}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('plist')
    p.add_argument('path')
    p = commands.add_parser('previous')
    p.add_argument('path')
    p = commands.add_parser('package')
    p.add_argument('--app', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--tools', required=True)
    p.add_argument('--previous')
    commands.add_parser('validate')
    args = parser.parse_args()
    if args.command == 'plist': write_plist(args.path)
    elif args.command == 'previous': previous(args.path)
    elif args.command == 'package': package(args.app, args.output, args.tools, args.previous)
    else:
        data = config()
        tag = os.environ.get('RELEASE_TAG')
        if tag and tag != 'v' + data['version']:
            raise ValueError('Git tag must match release.json version')
        print(f'Validated SoundLane {data["version"]} (build {data["build"]})')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
