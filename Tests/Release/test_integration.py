import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import licenses
import release

class Response:
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self): return self.body

class PreviousFeedTests(unittest.TestCase):
    def test_first_release_can_bootstrap_only_when_both_objects_are_missing(self):
        missing = HTTPError('url', 404, 'missing', {}, None)
        with tempfile.TemporaryDirectory() as directory, patch.object(release.urllib.request, 'urlopen', side_effect=[missing,missing]) as read:
            path = Path(directory)/'previous.xml'
            release.previous(path)
            self.assertEqual(read.call_count, 2)
            self.assertFalse(path.exists())
    def test_established_build_cannot_reset_a_missing_feed(self):
        data=release.config();data['build']=str(int(data['firstReleaseBuild'])+1)
        for error in [HTTPError('url',404,'missing',{},None), URLError('offline')]:
            with tempfile.TemporaryDirectory() as directory, patch.object(release,'config',return_value=data), patch.object(release.urllib.request,'urlopen',side_effect=error):
                with self.assertRaises((ValueError,URLError)):release.previous(Path(directory)/'previous.xml')
    def test_existing_release_prevents_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release.urllib.request,'urlopen',side_effect=[HTTPError('url',404,'missing',{},None),Response(b'{}')]):
            with self.assertRaisesRegex(ValueError,'published release'):release.previous(Path(directory)/'previous.xml')
    def test_previous_feed_records_exact_bytes(self):
        body=b'<rss><channel/></rss>'
        with tempfile.TemporaryDirectory() as directory, patch.object(release.urllib.request,'urlopen',return_value=Response(body)) as read:
            path=Path(directory)/'previous.xml';release.previous(path)
            self.assertEqual(path.read_bytes(),body)
            self.assertEqual(json.loads(path.with_suffix('.state.json').read_text())['previousFeedSHA256'],hashlib.sha256(body).hexdigest())
            self.assertEqual(read.call_args.args[0].full_url,release.config()['feedURL'])

class LicenseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for name in (*licenses.FILES,'release.json','Package.resolved'):shutil.copyfile(licenses.ROOT/name,self.root/name)
        vendor=self.root/'Vendor/libASPL';vendor.mkdir(parents=True)
        for name in ('LICENSE','LICENSE.apple2012','LICENSE.apple2020'):shutil.copyfile(licenses.ROOT/'Vendor/libASPL'/name,vendor/name)
        self.patch=patch.object(licenses,'ROOT',self.root);self.patch.start();self.addCleanup(self.patch.stop)
        self.image=self.root/'image';self.image.mkdir();self.app=self.image/'SoundLane.app'
        info=self.app/'Contents/Frameworks/Sparkle.framework/Resources/Info.plist';info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({'CFBundleShortVersionString':licenses.source_files()[1]}))
        self.upstream=self.root/'upstream'
        notice=(self.root/'THIRD_PARTY_NOTICES.md').read_text()
        self.upstream.write_text(notice.split('## Sparkle 2.10.1\n\nSource: https://github.com/sparkle-project/Sparkle\n\n')[1].split('\n## Release tooling')[0].rstrip()+'\n')
    def install(self):licenses.install(self.app,self.upstream)
    def test_notices_remain_after_app_only_install_and_image_removal(self):
        self.install();licenses.stage_distribution(self.app,self.image);licenses.verify_distribution(self.image,self.app.name)
        target=self.root/'Applications/SoundLane.app';shutil.copytree(self.app,target);shutil.rmtree(self.image)
        licenses.verify_bundle(target)
    def test_missing_or_stale_notices_in_app_driver_or_image_fail(self):
        for relative in ['Contents/Resources/Licenses/LICENSE','Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md']:
            self.install();path=self.app/relative;path.write_text('truncated')
            with self.assertRaises(ValueError):licenses.verify_bundle(self.app)
        self.install();licenses.stage_distribution(self.app,self.image);(self.image/'LICENSE').unlink()
        with self.assertRaises(FileNotFoundError):licenses.verify_distribution(self.image,self.app.name)
    def test_unapproved_project_license_is_rejected(self):
        data=json.loads((self.root/'release.json').read_text());data['license']='MIT';(self.root/'release.json').write_text(json.dumps(data))
        with self.assertRaises(ValueError):licenses.source_files()
    def test_removed_reserved_rights_or_dependency_terms_fail(self):
        path=self.root/'LICENSE';original=path.read_text();path.write_text(original.replace('All rights reserved.',''))
        with self.assertRaises(ValueError):licenses.source_files()
        path.write_text(original);notices=self.root/'THIRD_PARTY_NOTICES.md';notices.write_text(notices.read_text().replace('Copyright © 2020 Apple Inc.',''))
        with self.assertRaises(ValueError):licenses.source_files()
    def test_changed_upstream_sparkle_notice_fails(self):
        self.upstream.write_text('different terms')
        with self.assertRaises(ValueError):self.install()
    def test_dependency_upgrade_requires_updated_notices(self):
        path=self.root/'Package.resolved';data=json.loads(path.read_text());data['pins'][0]['state']['version']='999.0.0';path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):licenses.source_files()

if __name__=='__main__':unittest.main()

@unittest.skipUnless(sys.platform == 'darwin', 'pkgbuild requires macOS')
class ComponentInstallerTests(unittest.TestCase):
    def test_only_hal_payload_requires_privileged_installation(self):
        import subprocess
        import xml.etree.ElementTree as ET
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);driver=root/'SoundLane.driver'
            (driver/'Contents/MacOS').mkdir(parents=True)
            (driver/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'in.teren.SoundLane.Driver','CFBundleExecutable':'SoundLaneDriver','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','CFBundlePackageType':'BNDL'}))
            (driver/'Contents/MacOS/SoundLaneDriver').write_text('fixture')
            package=root/'component.pkg'
            script=Path(__file__).resolve().parents[2]/'scripts/package.py'
            subprocess.run([sys.executable,str(script),'driver',str(driver),str(package)],capture_output=True,check=True)
            expanded=root/'expanded'
            subprocess.run(['pkgutil','--expand-full',str(package),str(expanded)],capture_output=True,check=True)
            payload=expanded/'component.pkg/Payload'
            self.assertTrue((payload/'Library/Audio/Plug-Ins/HAL/SoundLane.driver').is_dir())
            self.assertFalse((payload/'Applications').exists())
            self.assertEqual(list(payload.iterdir()),[payload/'Library'])
            dist=ET.parse(expanded/'Distribution').getroot()
            self.assertTrue(any(x.attrib.get('onConclusion')=='RequireRestart' for x in dist.iter('pkg-ref')))
            failed=subprocess.run([sys.executable,str(script),'app',str(driver),str(root/'not-allowed.pkg')],capture_output=True)
            self.assertNotEqual(failed.returncode,0)
