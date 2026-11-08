import copy
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import publish


class Client:
    def __init__(self):
        self.calls = []
        self.latest = None
        self.existing = None
        self.releases = []

    def request(self, path, method='GET', data=None):
        self.calls.append((path, method, data))
        if path.startswith('/git/ref/'):
            return {'object': {'type': 'commit', 'sha': 'checked'}}
        if path == '/releases/latest': return self.latest
        if path.startswith('/releases/tags/'): return self.existing
        if path.startswith('/releases?'): return self.releases
        if method == 'POST': return {'id': 42, 'assets': [], 'draft': True}
        return None

    def upload(self, release_id, name, body):
        self.calls.append(('upload', release_id, name))

    @property
    def mutations(self):
        return [c for c in self.calls if c[0] == 'upload' or c[1] != 'GET']


class Clock:
    def __init__(self):
        self.now = 0
        self.sleeps = []

    def __call__(self): return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = publish.config()
        self.archive = b'verified signed disk image'
        self.old = b'<rss><channel><item xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><s:version>1</s:version></item></channel></rss>'
        self.feed = f'''<rss xmlns:sparkle="{publish.NS['sparkle']}"><channel><item>
<sparkle:version>{self.data['build']}</sparkle:version>
<sparkle:shortVersionString>{self.data['version']}</sparkle:shortVersionString>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="{self.data['downloadURL']}" length="{len(self.archive)}" sparkle:edSignature="verified-by-build"/>
</item></channel></rss>'''.encode()
        self.state = {'previousFeedSHA256': hashlib.sha256(self.old).hexdigest(),
                      'sourceURL': self.data['feedURL'], 'sha256': {
                          publish.ARCHIVE_NAME: hashlib.sha256(self.archive).hexdigest(),
                          'appcast.xml': hashlib.sha256(self.feed).hexdigest()}}
        (self.root / publish.ARCHIVE_NAME).write_bytes(self.archive)
        (self.root / 'appcast.xml').write_bytes(self.feed)
        self.save_state()
        self.client = Client()
        self.environ = patch.dict(os.environ, {'GITHUB_SHA': 'checked',
            'GITHUB_REF': 'refs/tags/v' + self.data['version'],
            'GITHUB_REPOSITORY': self.data['githubRepository']})
        self.environ.start(); self.addCleanup(self.environ.stop)

    def save_state(self):
        (self.root / 'publication.json').write_text(json.dumps(self.state))

    def fetch(self, url):
        return self.old if url == self.data['feedURL'] else self.archive

    def test_publish_verifies_download_before_staging_pages(self):
        publish.publish(self.root, self.client, self.fetch)
        self.assertEqual((self.root / 'pages/appcast.xml').read_bytes(), self.feed)
        self.assertIn(('upload', 42, publish.ARCHIVE_NAME), self.client.calls)
        self.assertEqual(self.client.mutations[-1][2], {'draft': False, 'make_latest': 'true'})

    def test_corrupt_artifact_cannot_mutate_github(self):
        (self.root / publish.ARCHIVE_NAME).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'differs'):
            publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.calls)

    def test_non_github_previous_feed_cannot_be_fetched_or_published(self):
        self.state['sourceURL'] = 'https://example.invalid/appcast.xml'
        self.save_state()
        with patch.object(publish, 'public_bytes') as fetch:
            with self.assertRaisesRegex(ValueError, 'previous feed source'):
                publish.publish(self.root, self.client, fetch)
            fetch.assert_not_called()
        self.assertFalse(self.client.mutations)

    def test_stale_feed_cannot_mutate_release(self):
        with self.assertRaisesRegex(ValueError, 'feed changed'):
            publish.publish(self.root, self.client, lambda url: b'changed')
        self.assertFalse(self.client.mutations)

    def test_wrong_tag_commit_is_rejected(self):
        with patch.dict(os.environ, {'GITHUB_SHA': 'another'}):
            with self.assertRaisesRegex(ValueError, 'checked commit'):
                publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.mutations)

    def test_wrong_repository_and_branch_are_rejected(self):
        for env in [{'GITHUB_REPOSITORY': 'other/repo'}, {'GITHUB_REF': 'refs/heads/main'}]:
            with patch.dict(os.environ, env), self.assertRaises(ValueError):
                publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.calls)

    def test_newer_release_is_preserved(self):
        self.client.latest = {'tag_name': 'v999.0.0'}
        with self.assertRaisesRegex(ValueError, 'newer'):
            publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.mutations)

    def test_cached_pages_cannot_allow_reusing_latest_github_build(self):
        self.client.latest = {'tag_name': 'v0.0.1', 'body': f"Build {self.data['build']}."}
        with self.assertRaisesRegex(ValueError, 'latest GitHub release'):
            publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.mutations)

    def test_existing_release_can_only_reuse_exact_bytes(self):
        self.client.existing = {'id': 42, 'draft': False, 'assets': [
            {'name': publish.ARCHIVE_NAME, 'browser_download_url': 'https://example.test/dmg'}]}
        publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(any(c[0] == 'upload' for c in self.client.calls))
        with self.assertRaisesRegex(ValueError, 'different archive'):
            publish.publish(self.root, self.client, lambda u: self.old if u == self.data['feedURL'] else b'other')

    def test_failed_pages_verification_never_deletes_assets(self):
        with self.assertRaisesRegex(ValueError, 'did not converge'):
            publish.verify(self.root, self.client, self.fetch, attempts=1)
        self.assertFalse(self.client.mutations)

    def verification_fixture(self):
        self.client.latest = {'tag_name': 'v' + self.data['version']}
        self.client.releases = [{'tag_name': 'v0.0.1', 'draft': False,
                                 'assets': [{'id': 1, 'name': publish.ARCHIVE_NAME}]}]
        return Clock()

    def current_bytes(self, url):
        return self.feed if url == self.data['feedURL'] else self.archive

    def test_transient_download_errors_retry_before_cleanup(self):
        errors = [URLError(ConnectionResetError()), TimeoutError(),
                  http.client.IncompleteRead(b'partial'),
                  URLError(socket.gaierror(socket.EAI_AGAIN, 'temporary DNS failure')),
                  HTTPError('url', 408, 'timeout', {}, None),
                  HTTPError('url', 429, 'throttled', {}, None),
                  HTTPError('url', 500, 'server error', {}, None),
                  HTTPError('url', 502, 'bad gateway', {}, None),
                  HTTPError('url', 503, 'unavailable', {}, None),
                  HTTPError('url', 504, 'gateway timeout', {}, None)]
        for error in errors:
            with self.subTest(error=error):
                clock = self.verification_fixture()
                self.client.calls.clear()
                reads = []
                def fetch(url):
                    self.assertFalse(self.client.mutations)
                    reads.append(url)
                    if len(reads) == 2: raise error
                    return self.current_bytes(url)
                publish.verify(self.root, self.client, fetch, attempts=3,
                               sleep=clock.sleep, clock=clock)
                self.assertEqual(len(reads), 4)
                self.assertEqual(clock.sleeps, [5])
                self.assertEqual(self.client.mutations, [('/releases/assets/1', 'DELETE', None)])

    def test_persistent_transient_errors_exhaust_attempts_without_cleanup(self):
        clock = self.verification_fixture()
        with patch.object(publish, 'public_bytes', side_effect=URLError(ConnectionResetError())) as fetch:
            with self.assertRaisesRegex(ValueError, 'did not converge'):
                publish.verify(self.root, self.client, attempts=3, sleep=clock.sleep, clock=clock)
            self.assertEqual(fetch.call_count, 3)
        self.assertEqual(clock.sleeps, [5, 5])
        self.assertFalse(self.client.calls)

    def test_permanent_errors_fail_immediately_without_cleanup(self):
        errors = [HTTPError('url', 403, 'forbidden', {}, None),
                  URLError(ssl.SSLCertVerificationError('invalid certificate')),
                  ValueError('malformed response')]
        for error in errors:
            with self.subTest(error=error):
                clock = self.verification_fixture()
                with patch.object(publish, 'public_bytes', side_effect=error) as fetch:
                    with self.assertRaises(type(error)):
                        publish.verify(self.root, self.client, sleep=clock.sleep, clock=clock)
                    self.assertEqual(fetch.call_count, 1)
                self.assertFalse(clock.sleeps)
                self.assertFalse(self.client.calls)

    def test_deadline_limits_sleep_and_prevents_new_requests(self):
        clock = self.verification_fixture()
        with patch.object(publish, 'public_bytes', return_value=None) as fetch:
            with self.assertRaisesRegex(ValueError, 'did not converge'):
                publish.verify(self.root, self.client, timeout=7, sleep=clock.sleep, clock=clock)
            self.assertEqual(fetch.call_count, 2)
            self.assertEqual([call.kwargs['timeout'] for call in fetch.call_args_list], [7, 2])
        self.assertEqual(clock.sleeps, [5, 2])
        self.assertFalse(self.client.calls)

    def test_late_matching_response_cannot_authorize_cleanup(self):
        clock = self.verification_fixture()
        def fetch(url):
            clock.now += 4
            return self.current_bytes(url)
        with self.assertRaisesRegex(ValueError, 'did not converge'):
            publish.verify(self.root, self.client, fetch, timeout=7, sleep=clock.sleep, clock=clock)
        self.assertEqual(clock.now, 8)
        self.assertFalse(clock.sleeps)
        self.assertFalse(self.client.calls)

    def test_byte_mismatch_can_converge_but_changed_latest_prevents_cleanup(self):
        clock = self.verification_fixture()
        self.client.latest = {'tag_name': 'v999.0.0'}
        reads = []
        def fetch(url):
            reads.append(url)
            return b'old feed' if len(reads) == 1 else self.current_bytes(url)
        with self.assertRaisesRegex(ValueError, 'Latest release changed'):
            publish.verify(self.root, self.client, fetch, sleep=clock.sleep, clock=clock)
        self.assertEqual(clock.sleeps, [5])
        self.assertFalse(self.client.mutations)

    def test_verification_requires_positive_attempt_and_time_budgets(self):
        for kwargs in [{'attempts': 0}, {'timeout': 0}, {'timeout': float('nan')}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                publish.verify(self.root, self.client, self.current_bytes, **kwargs)
        self.assertFalse(self.client.calls)

    def test_cleanup_preserves_current_drafts_tags_and_unrelated_assets(self):
        self.client.latest = {'tag_name': 'v' + self.data['version']}
        self.client.releases = [
            {'tag_name': 'v0.0.1', 'draft': False, 'assets': [
                {'id': 1, 'name': publish.ARCHIVE_NAME}, {'id': 2, 'name': 'notes.txt'}]},
            {'tag_name': 'v' + self.data['version'], 'draft': False, 'assets': [{'id': 3, 'name': publish.ARCHIVE_NAME}]},
            {'tag_name': 'v0.0.2', 'draft': True, 'assets': [{'id': 4, 'name': publish.ARCHIVE_NAME}]}]
        publish.verify(self.root, self.client, lambda u: self.feed if u == self.data['feedURL'] else self.archive, attempts=1)
        self.assertEqual(self.client.mutations, [('/releases/assets/1', 'DELETE', None)])

    def test_publication_does_not_reuse_a_build(self):
        self.old = self.feed.replace(b'arm64', b'arm64 ')
        self.state['previousFeedSHA256'] = hashlib.sha256(self.old).hexdigest(); self.save_state()
        with self.assertRaisesRegex(ValueError, 'Build numbers'):
            publish.publish(self.root, self.client, self.fetch)
        self.assertFalse(self.client.mutations)


if __name__ == '__main__': unittest.main()
