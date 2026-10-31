# SPDX-License-Identifier: MIT
"""LIC framing fixtures contain invented data and no real key/license identities."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / 'Resources/guest/license_evidence.py'
CODE = compile(SCRIPT.read_text(), str(SCRIPT), 'exec')


def collect(root):
    namespace={'__name__':'license_evidence_test'}
    exec(CODE,namespace)
    return namespace['collect_logs'](root)


class LicenseEvidenceTests(unittest.TestCase):
    def test_multiline_records_and_reuse_are_counted_without_identifying_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = root / 'rmlic_123'
            process.mkdir()
            (process / '26102902.log').write_text(
                '\ufeff00:01.000123-10,LIC,0,process=rmlic,Func=getLicenses,res=seize,License=\'hard, local, client,\n'
                'synthetic multiline license description\'\n'
                '00:02.000123-20,LIC,0,process=rmlic,Func=getLicenses,res=seize,License=\'hard, local, client, reuse, example\'\n'
                '00:03.000123-30,LIC,0,process=rmlic,Func=getLicenses,res=error\n'
                '00:04.000123-40,LIC,0,process=rmlic,Func=getLicenses,res=reuse,License=\'hard, local, client, example\'\n'
                '00:05.000123-50,CALL,0,process=rmlic,Func=getLicenses,res=seize,License=\'hard, local, client\'\n'
                '00:06.000123-60,LIC,0,process=rmlic,Func=initialize,res=seize\n', encoding='utf-8')
            result = collect(root)
            self.assertEqual({k:v for k,v in result.items() if k!='sources'}, {'seize': 2, 'reuse': 2, 'error': 1, 'hardwareLocal': 3, 'files': 1, 'available': True})
            self.assertEqual(len(result['sources']),1)
            self.assertIsNotNone(result['sources'][0]['digest'])
            self.assertNotIn('License', json.dumps(result))
            self.assertNotIn('rmlic_123', json.dumps(result))

    def test_missing_directory_means_unavailable_not_a_confirmed_empty_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            result = collect(Path(directory) / 'missing')
            self.assertFalse(result['available'])
            self.assertEqual(result['files'], 0)

    def test_initialize_event_alone_does_not_prove_a_license(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'initialization.log').write_text('00:01.001000-12,LIC,0,process=rmlic,Func=initialize,res=ok\n')
            result = collect(root)
            self.assertTrue(result['available'])
            self.assertEqual(result['seize'], 0)
            self.assertEqual(result['reuse'], 0)
            self.assertEqual(result['hardwareLocal'], 0)


if __name__ == '__main__':
    unittest.main()
