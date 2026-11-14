"""Regression checks for DAT attestation configuration (Apple PlistBuddy required)."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
@unittest.skipUnless(Path('/usr/libexec/PlistBuddy').exists(), 'requires Apple plist tooling')
class IOSConfigurationTests(unittest.TestCase):
    def prepare(self, app_id, token='', team=''):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        result = subprocess.run(['sh',str(ROOT/'ios/Scripts/prepare-info.sh')],env=dict(os.environ,SRCROOT=str(ROOT/'ios'),DERIVED_FILE_DIR=temp.name,META_APP_ID=app_id,META_CLIENT_TOKEN=token,DEVELOPMENT_TEAM=team),capture_output=True,text=True)
        output = plistlib.loads((Path(temp.name)/'GuardianInfo.plist').read_bytes())
        return result, output
    def test_developer_mode_omits_all_attestation_keys_even_with_an_apple_team(self):
        result, info = self.prepare('0',team='TESTTEAM00'); self.assertEqual(result.returncode,0)
        self.assertTrue(info['MWDAT']['Analytics']['OptOut'])
        for key in ['MetaAppID','ClientToken','TeamID']: self.assertNotIn(key,info['MWDAT'])
    def test_partial_registered_configuration_fails_the_build(self):
        result,_ = self.prepare('12345'); self.assertNotEqual(result.returncode,0); self.assertIn('Registered Meta apps need',result.stderr)
    def test_complete_registered_configuration_preserves_build_substitutions(self):
        result,info = self.prepare('12345','test-client-value','TESTTEAM00'); self.assertEqual(result.returncode,0)
        self.assertEqual(info['MWDAT']['MetaAppID'],'$(META_APP_ID)'); self.assertEqual(info['MWDAT']['TeamID'],'$(DEVELOPMENT_TEAM)')
