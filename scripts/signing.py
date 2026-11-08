#!/usr/bin/env python3
"""Keep released app identities bound to the same private signing certificate."""
import argparse
from contextlib import contextmanager
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'in.teren.SoundLane'


def certificate():
    der = (ROOT / 'Resources/ReleaseSigning.cer').read_bytes()
    expected = json.loads((ROOT / 'release.json').read_text())['codeSigningCertificateSHA256']
    if not re.fullmatch(r'[0-9a-f]{64}', expected) or hashlib.sha256(der).hexdigest() != expected:
        raise ValueError('Release certificate differs from the pinned signing identity')
    return der


def run(*args):
    # Never print command arguments: keychain tools receive private passwords.
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode:
        # codesign arguments contain only public identity/path data, never passwords.
        detail = ': ' + result.stderr.strip() if Path(args[0]).name == 'codesign' else ''
        raise ValueError(f'{args[0]} failed (exit {result.returncode}){detail}')
    return result.stdout + result.stderr


def components(app):
    app = Path(app)
    sparkle = app / 'Contents/Frameworks/Sparkle.framework'
    return [app / 'Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver', sparkle / 'Versions/B/Autoupdate', sparkle / 'Versions/B/Updater.app', sparkle, app]


def check_requirement(text, identifier, der):
    name = re.escape(identifier)
    expected = (rf'identifier (?:"{name}"|{name}) and certificate root = '
                rf'H"{hashlib.sha1(der).hexdigest()}"')
    match = re.search(r'^designated => (.+)$', text, re.M)
    if not match or not re.fullmatch(expected, match[1]):
        raise ValueError('Signature must bind the bundle identifier to the persistent certificate')


def verify_code(code, der, expected_identifier=None):
    details = run('codesign', '-d', '-r-', '--verbose=2', code)
    identity = re.search(r'^Identifier=([A-Za-z0-9_.-]+)$', details, re.M)
    if not identity or (expected_identifier and identity[1] != expected_identifier):
        raise ValueError('Unexpected code signing identifier')
    check_requirement(details, identity[1], der)
    with tempfile.TemporaryDirectory(prefix='soundlane-cert-check-') as directory:
        prefix = Path(directory) / 'certificate'
        run('codesign', '-d', '--extract-certificates=' + str(prefix), code)
        if prefix.with_name(prefix.name + '0').read_bytes() != der:
            raise ValueError('App or updater contains a different signing certificate')


def verify(app):
    der = certificate()
    run('codesign', '--verify', '--deep', '--strict', app)
    for code in components(app):
        verify_code(code, der, APP_ID if code == Path(app) else None)
    # The one-time installer must carry the same signed HAL payload, not a stale
    # ad hoc copy from an earlier staging step.
    with tempfile.TemporaryDirectory(prefix='soundlane-installer-check-') as directory:
        expanded = Path(directory) / 'expanded'
        run('pkgutil', '--expand-full', Path(app) / 'Contents/Resources/SoundLane Audio Component.pkg', expanded)
        payload = expanded / 'component.pkg/Payload/Library/Audio/Plug-Ins/HAL/SoundLane.driver'
        verify_code(payload, der, 'in.teren.SoundLane.Driver')
        installed = Path(app) / 'Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver'
        for relative in ('Contents/MacOS/SoundLaneDriver', 'Contents/Resources/Licenses/LICENSE', 'Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md'):
            if (payload / relative).read_bytes() != (installed / relative).read_bytes():
                raise ValueError('Component installer carries a stale driver or notices')


@contextmanager
def signing_keychain(keychain):
    if not keychain:
        yield
        return
    # --keychain selects the identity; codesign still builds its certificate
    # chain from the search list. Restore that list after the signing operation.
    previous = shlex.split(run('security', 'list-keychains', '-d', 'user'))
    try:
        run('security', 'list-keychains', '-d', 'user', '-s', keychain, *previous)
        yield
    finally:
        run('security', 'list-keychains', '-d', 'user', '-s', *previous)


def preflight(keychain):
    der = certificate()
    with tempfile.TemporaryDirectory(prefix='soundlane-signing-preflight-') as directory:
        source = Path(directory) / 'probe.c'
        source.write_text('int main(void) { return 0; }\n')
        executable = Path(directory) / 'soundlane-signing-probe'
        run('/usr/bin/cc', source, '-o', executable)
        with signing_keychain(keychain):
            run('codesign', '--force', '--sign', hashlib.sha1(der).hexdigest().upper(),
                '--keychain', keychain, '--timestamp=none', executable)
            run('codesign', '--verify', '--strict', executable)
            verify_code(executable, der, 'soundlane-signing-probe')
    print('Release private key and certificate-chain signing preflight passed')


def sign(app):
    der = certificate()
    keychain = os.environ.get('SOUNDLANE_SIGN_KEYCHAIN')
    required = os.environ.get('SOUNDLANE_REQUIRE_RELEASE_SIGNING') == '1'
    if required and not keychain:
        raise ValueError('Persistent signing is required; no release keychain was provided')
    identity = hashlib.sha1(der).hexdigest().upper() if keychain else '-'
    args = ['codesign', '--force', '--sign', identity, '--timestamp=none']
    if keychain:
        args += ['--keychain', keychain]
    with signing_keychain(keychain):
        for code in components(app):
            if str(code).endswith("SoundLane.driver"):
                continue  # Signed before its one-time installer is packaged.
            run(*args, code)
        if keychain:
            verify(app)
            print('Signed app and updater with the persistent release identity')
        else:
            run('codesign', '--verify', '--deep', '--strict', app)
            print('Ad hoc development build; release packaging will reject this identity')


def sign_driver(driver):
    der = certificate()
    keychain = os.environ.get('SOUNDLANE_SIGN_KEYCHAIN')
    if os.environ.get('SOUNDLANE_REQUIRE_RELEASE_SIGNING') == '1' and not keychain:
        raise ValueError('Persistent driver signing requires the release keychain')
    identity = hashlib.sha1(der).hexdigest().upper() if keychain else '-'
    args = ['codesign', '--force', '--sign', identity, '--timestamp=none']
    if keychain: args += ['--keychain', keychain]
    with signing_keychain(keychain):
        run(*args, driver)
    if keychain: verify_code(Path(driver), der, 'in.teren.SoundLane.Driver')


def import_ci(keychain):
    """Import only the pinned identity into a disposable, isolated CI keychain."""
    encoded = os.environ.get('SOUNDLANE_SIGNING_P12')
    password = os.environ.get('SOUNDLANE_SIGNING_PASSWORD')
    if not encoded or not password:
        raise ValueError('Both persistent code signing secrets are required')
    der = certificate()
    payload = base64.b64decode(encoded, validate=True)
    if not payload or Path(keychain).exists():
        raise ValueError('Use a fresh temporary keychain and a nonempty signing identity')
    with tempfile.TemporaryDirectory(prefix='soundlane-key-import-') as directory:
        archive = Path(directory) / 'identity.p12'
        archive.write_bytes(payload)
        archive.chmod(0o600)
        pem = Path(directory) / 'certificate.pem'
        run('/usr/bin/openssl', 'pkcs12', '-in', archive, '-nokeys', '-passin',
            'env:SOUNDLANE_SIGNING_PASSWORD', '-out', pem)
        actual = Path(directory) / 'certificate.der'
        run('/usr/bin/openssl', 'x509', '-in', pem, '-outform', 'DER', '-out', actual)
        if actual.read_bytes() != der:
            raise ValueError('Signing secret contains an unexpected certificate')
        search = shlex.split(run('security', 'list-keychains', '-d', 'user'))
        try:
            run('security', 'create-keychain', '-p', password, keychain)
            run('security', 'import', archive, '-k', keychain, '-P', password, '-T', '/usr/bin/codesign')
            run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
                '-s', '-k', password, keychain)
            run('security', 'set-keychain-settings', '-t', '3600', keychain)
            run('security', 'unlock-keychain', '-p', password, keychain)
        finally:
            run('security', 'list-keychains', '-d', 'user', '-s', *search)
    preflight(keychain)
    with open(os.environ['GITHUB_ENV'], 'a') as environment:
        environment.write(f'SOUNDLANE_SIGN_KEYCHAIN={keychain}\nSOUNDLANE_REQUIRE_RELEASE_SIGNING=1\n')
    print('Imported the pinned release identity; system certificate trust is unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ['sign', 'verify']:
        commands.add_parser(name).add_argument('--app', required=True)
    commands.add_parser('sign-driver').add_argument('--driver', required=True)
    commands.add_parser('import-ci').add_argument('--keychain', required=True)
    args = parser.parse_args()
    if args.command == 'sign-driver':
        sign_driver(args.driver)
    elif args.command == 'import-ci':
        import_ci(args.keychain)
    elif args.command == 'sign':
        sign(args.app)
    else:
        verify(args.app)
        print('Verified the persistent app and updater signing identity')
