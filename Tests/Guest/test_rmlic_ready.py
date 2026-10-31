# SPDX-License-Identifier: MIT
"""Run the real POSIX helper with fake service/clock commands, never real systemd."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'Resources/guest/rmlic_ready.sh'
FAKE_COMMAND = '''import json,os,pathlib,sys
statepath=pathlib.Path(os.environ['FAKE_STATE'])
state=json.loads(statepath.read_text())
name=pathlib.Path(sys.argv[0]).name
mode=state['mode']
if name=='date':print(state['clock'])
elif name=='sleep':state['clock']+=int(sys.argv[1])
elif name=='ldd':print('libexample.so => not found' if mode=='missing' else 'libc.so.6 => /lib/libc.so.6')
elif name=='journalctl':print('Synthetic private service diagnostic')
elif name=='ss':
 if mode=='delayed' and state['clock']>=2:print('LISTEN 0 4096 0.0.0.0:1544 0.0.0.0:*')
elif name=='systemctl':
 if '--value' not in sys.argv:print('ActiveState=failed' if mode=='failed' else 'ActiveState=active')
 else:
  field=sys.argv[sys.argv.index('-p')+1]
  values={'ActiveState':'failed' if mode=='failed' else 'active','NRestarts':'1' if mode=='failed' else '0','ExecMainStatus':'1' if mode=='failed' else '0','MainPID':'123'}
  print(values[field])
statepath.write_text(json.dumps(state))
'''


class RmlicReadinessTests(unittest.TestCase):
    def check(self, mode, timeout=5):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state.json'
            state.write_text(json.dumps({'mode': mode, 'clock': 0}))
            for name in ('date', 'sleep', 'ldd', 'systemctl', 'journalctl', 'ss'):
                command = root / name
                command.write_text('#!' + sys.executable + '\n' + FAKE_COMMAND)
                command.chmod(0o700)
            env = dict(os.environ, PATH=str(root) + ':/usr/bin:/bin', FAKE_STATE=str(state))
            result = subprocess.run(['/bin/sh', str(SCRIPT), str(timeout)], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
            return result, json.loads(state.read_text())

    def test_service_active_before_listener_waits_until_tcp_ready(self):
        result, state = self.check('delayed')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('KEYBRIDGE_RMLIC_READY', result.stdout)
        self.assertEqual(state['clock'], 2)

    def test_missing_library_fails_before_poll_and_captures_diagnostics(self):
        result, state = self.check('missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('KEYBRIDGE_ERROR=missing_dependencies', result.stdout)
        self.assertIn('libexample.so => not found', result.stdout)
        self.assertIn('Synthetic private service diagnostic', result.stdout)
        self.assertEqual(state['clock'], 0)

    def test_service_crash_fails_without_waiting_full_deadline(self):
        result, state = self.check('failed')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('KEYBRIDGE_ERROR=rmlic_failed', result.stdout)
        self.assertIn('KEYBRIDGE_DIAGNOSTICS_END', result.stdout)
        self.assertEqual(state['clock'], 0)

    def test_active_process_without_port_reaches_bounded_timeout(self):
        result, state = self.check('timeout', timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('KEYBRIDGE_ERROR=rmlic_timeout', result.stdout)
        self.assertEqual(state['clock'], 3)


if __name__ == '__main__':
    unittest.main()
