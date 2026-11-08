import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import signing


class SigningIdentityTests(unittest.TestCase):
    def test_changed_certificate_cannot_silently_replace_the_release_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Resources').mkdir()
            (root / 'Resources/ReleaseSigning.cer').write_bytes(b'different identity')
            (root / 'release.json').write_text(json.dumps({
                'codeSigningCertificateSHA256': hashlib.sha256(b'approved identity').hexdigest()}))
            with patch.object(signing, 'ROOT', root), self.assertRaisesRegex(ValueError, 'pinned'):
                signing.certificate()

    def test_content_hash_or_identifier_only_requirements_are_rejected(self):
        der = signing.certificate()
        for requirement in ['cdhash H"1234"', f'identifier "{signing.APP_ID}"',
                            f'identifier "{signing.APP_ID}" or true']:
            with self.assertRaises(ValueError):
                signing.check_requirement('designated => ' + requirement, signing.APP_ID, der)

    def test_a_different_certificate_or_bundle_identifier_is_rejected(self):
        der = signing.certificate()
        for identifier, cert in [('another.app', der), (signing.APP_ID, b'another certificate')]:
            requirement = f'designated => identifier "{identifier}" and certificate root = H"{hashlib.sha1(cert).hexdigest()}"'
            with self.assertRaises(ValueError):
                signing.check_requirement(requirement, signing.APP_ID, der)

    def test_release_build_cannot_fall_back_to_ad_hoc_without_a_keychain(self):
        with patch.dict(signing.os.environ, {'SOUNDLANE_REQUIRE_RELEASE_SIGNING': '1', 'SOUNDLANE_SIGN_KEYCHAIN': ''}):
            with patch.object(signing, 'run') as command, self.assertRaisesRegex(ValueError, 'required'):
                signing.sign(Path('SoundLane.app'))
            command.assert_not_called()

    def test_missing_ci_secrets_cannot_create_a_keychain(self):
        with patch.dict(signing.os.environ, {'SOUNDLANE_SIGNING_P12': '', 'SOUNDLANE_SIGNING_PASSWORD': ''}):
            with patch.object(signing, 'run') as command, self.assertRaisesRegex(ValueError, 'secrets'):
                signing.import_ci('unused.keychain-db')
            command.assert_not_called()

    def test_chain_search_path_is_restored_on_success_and_failure(self):
        original = ['login.keychain-db', 'system.keychain']
        for fail in [False, True]:
            def command(*args):
                return '"login.keychain-db"\n"system.keychain"\n' if '-s' not in args else ''
            with patch.object(signing, 'run', side_effect=command) as run:
                try:
                    with signing.signing_keychain('release.keychain-db'):
                        if fail:
                            raise RuntimeError('Signing failed')
                except RuntimeError:
                    pass
                self.assertEqual(run.call_args_list[1].args,
                                 ('security', 'list-keychains', '-d', 'user', '-s', 'release.keychain-db', *original))
                self.assertEqual(run.call_args.args,
                                 ('security', 'list-keychains', '-d', 'user', '-s', *original))


if __name__ == '__main__':
    unittest.main()
