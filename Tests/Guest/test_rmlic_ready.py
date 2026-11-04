# SPDX-License-Identifier: MIT
"""Read-only Alpine readiness against private proc fixtures, no actual services."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'Resources/guest/alpine_ready.py'
spec = importlib.util.spec_from_file_location('alpine_ready', SCRIPT)
ready = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ready)


class RmlicReadinessTests(unittest.TestCase):
    def observed(self, process='rmlic', inode='123', listening=True):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'123/fd').mkdir(parents=True)
            (root/'123/comm').write_text(process)
            (root/'123/fd/3').symlink_to('socket:[123]')
            (root/'net').mkdir()
            state='0A' if listening else '01'
            fields=['0:','00000000:0608','00000000:0000',state,'0','0','0','0','0',inode]
            (root/'net/tcp').write_text('header\n'+' '.join(fields)+'\n')
            (root/'net/tcp6').write_text('header\n')
            with patch.object(ready,'Path',side_effect=lambda value: root/str(value).removeprefix('/proc/').removeprefix('/proc')):
                return ready.manager_ready()

    def testManagerOwnListeningSocketIsReady(self):
        self.assertTrue(self.observed())

    def testUnrelatedProcessPortDoesNotProveManagerReadiness(self):
        self.assertFalse(self.observed(process='unrelated'))
        self.assertFalse(self.observed(inode='456'))

    def testConnectedSocketIsNotAListener(self):
        self.assertFalse(self.observed(listening=False))

    def testReadinessWaitsForObservedListener(self):
        with patch.object(ready,'manager_ready',side_effect=[False,True]),patch.object(ready.time,'sleep') as sleep,patch('builtins.print'):
            self.assertEqual(ready.main(['2']),0)
        sleep.assert_called_once_with(0.25)

    def testNoListenerHasFiniteDeadline(self):
        with patch.object(ready,'manager_ready',return_value=False),patch.object(ready.time,'monotonic',side_effect=[0,1]),patch.object(ready.time,'sleep') as sleep,patch('builtins.print'):
            self.assertEqual(ready.main(['1']),1)
        sleep.assert_not_called()

    def testInvalidTimeoutDoesNotObserveServices(self):
        with patch.object(ready,'manager_ready') as observe,patch('builtins.print'):
            self.assertEqual(ready.main(['unbounded']),2)
        observe.assert_not_called()


if __name__ == '__main__':
    unittest.main()
