# SPDX-License-Identifier: MIT
"""Exercise the real import policy using package/installer command doubles, without installation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'Resources/guest/verify_imports.sh'


class ImportPolicyTests(unittest.TestCase):
    def check(self, package='aksusbd', architecture='amd64', version='10.99-5',
              platform='1C:Enterprise 9.2.1.700 --- different build', components='lic_manager ru client_full future_component',
              payload=True, corrupt=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'dpkg-deb').write_text('''#!/bin/sh
if test "$1" = --contents; then
  test "$CORRUPT" != yes || exit 2
  test "$PAYLOAD" != yes || printf '%s\\n' '-rwxr-xr-x root/root 123 2026-01-01 00:00 ./usr/sbin/aksusbd' '-rwxr-xr-x root/root 123 2026-01-01 00:00 ./usr/sbin/hasplmd'
  exit 0
fi
case "$3" in Package) echo "$PACKAGE";; Architecture) echo "$ARCHITECTURE";; Version) echo "$VERSION";; esac
''')
            (root / 'setup.run').write_text('''#!/bin/sh
echo "$1" >> "$CALLS"
case "$1" in --version) echo "$PLATFORM";; --help) printf ' --enable-components <components>\\n Allowed: %s\\n' "$COMPONENTS";; *) exit 1;; esac
''')
            (root / 'timeout').write_text('#!/bin/sh\nshift\nexec "$@"\n')
            for name in ('dpkg-deb', 'setup.run', 'timeout'):
                (root / name).chmod(0o700)
            env = dict(os.environ, PATH=str(root) + ':/usr/bin:/bin', PACKAGE=package,
                       ARCHITECTURE=architecture, VERSION=version, PLATFORM=platform,
                       COMPONENTS=components, PAYLOAD='yes' if payload else 'no',
                       CORRUPT='yes' if corrupt else 'no', CALLS=str(root / 'calls'), TMPDIR=directory)
            result = subprocess.run(['/bin/sh', str(SCRIPT)], cwd=root, env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            if result.returncode == 0:
                self.assertEqual((root / 'keybridge-enable-components').read_text(), 'lic_manager,ru\n')
                self.assertEqual((root / 'keybridge-disable-components').read_text(), 'client_full,future_component\n')
            return result, calls

    def test_different_versions_and_packaging_are_accepted(self):
        for version in ('7.100-1', '10.33-1', '10.99-5'):
            result, calls = self.check(version=version)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('KEYBRIDGE_IMPORTS_VERIFIED', result.stdout)
            self.assertEqual(calls, '--version\n--help\n')

    def test_wrong_package_architecture_or_payload_is_rejected_before_installer_runs(self):
        for options, reason in [({'package': 'other'}, 'wrong_driver_package'),
                                ({'architecture': 'arm64'}, 'wrong_driver_architecture'),
                                ({'payload': False}, 'missing_driver_runtime'),
                                ({'corrupt': True}, 'invalid_driver_package')]:
            result, calls = self.check(**options)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(reason, result.stdout)
            self.assertEqual(calls, '')

    def test_installer_requires_product_identity_and_license_manager(self):
        for options, reason in [({'platform': 'Some other application'}, 'invalid_platform_installer'),
                                ({'components': 'client_full,server'}, 'missing_license_manager'),
                                ({'components': 'not_lic_manager'}, 'missing_license_manager')]:
            result, _ = self.check(**options)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(reason, result.stdout)


if __name__ == '__main__':
    unittest.main()
