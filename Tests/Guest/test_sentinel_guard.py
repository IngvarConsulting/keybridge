# SPDX-License-Identifier: MIT
"""Offline regression tests: no VM, real USB, HTTP listener, or systemctl required."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import urllib.error

SCRIPT = Path(__file__).resolve().parents[2] / 'Resources/guest/sentinel_guard.py'
spec = importlib.util.spec_from_file_location('sentinel_guard_tested', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def config(value='1'):
    return ('<admin_response><admin_status><code>0</code></admin_status>'
            '<config><no_auto_fwup>' + value + '</no_auto_fwup></config></admin_response>').encode()


SUCCESS = b'<admin_response><admin_status><code>0</code></admin_status></admin_response>'
VERSION = (b'<ACCDiagnostics><RuntimeInfo><Driver><Name>Run-time Installer</Name>'
           b'<Version>10.33.1</Version></Driver></RuntimeInfo></ACCDiagnostics>')
UNAVAILABLE = urllib.error.URLError('not listening yet')


class Reply:
    status = 200
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *_): return False
    def read(self, limit): return self.body[:limit]


class FakeHTTP:
    def __init__(self, responses, after_request=None):
        self.responses = iter(responses)
        self.requests = []
        self.after_request = after_request

    def open(self, request, timeout):
        self.requests.append((request.full_url.rsplit('/', 1)[-1], request.data, timeout))
        response = next(self.responses, UNAVAILABLE)
        if self.after_request:
            self.after_request(len(self.requests))
        if isinstance(response, Exception):
            raise response
        return Reply(response)


class Clock:
    def __init__(self): self.now = 0
    def monotonic(self): return self.now
    def sleep(self, duration): self.now += duration


class SentinelGuardTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.usb_root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.stack.enter_context(mock.patch.object(guard, 'USB_DEVICES', self.usb_root))
        self.clock = Clock()
        self.stack.enter_context(mock.patch.object(guard.time, 'monotonic', self.clock.monotonic))
        self.stack.enter_context(mock.patch.object(guard.time, 'sleep', self.clock.sleep))
        self.restart = self.stack.enter_context(mock.patch.object(
            guard.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)))
        self.stack.enter_context(mock.patch.object(guard.sys, 'platform', 'linux'))
        self.http = None

    def use_http(self, responses, after_request=None):
        self.http = FakeHTTP(responses, after_request)
        self.stack.enter_context(mock.patch.object(guard, 'HTTP', self.http))

    def invoke(self, action='configure'):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = guard.main([action])
        return code, json.loads(output.getvalue())

    def add_key(self):
        device = self.usb_root / '1-1'
        device.mkdir(exist_ok=True)
        (device / 'idVendor').write_text('0529\n')

    def test_fresh_install_waits_for_http_before_persisting_guard(self):
        self.use_http([UNAVAILABLE, UNAVAILABLE, config('0'), SUCCESS,
                       config('1'), UNAVAILABLE, config('1'), VERSION])
        code, result = self.invoke()
        self.assertEqual((code, result['status'], result['no_auto_fwup']), (0, 'ok', '1'))
        self.assertEqual(result['runtime_version'], '10.33.1')
        self.assertEqual([request[0] for request in self.http.requests],
                         ['get', 'get', 'get', 'set', 'get', 'get', 'get', 'diagnostics.xml'])
        self.assertEqual(self.http.requests[3][1], guard.SET_GUARD)
        self.restart.assert_called_once()
        self.assertGreater(self.clock.now, 0)

    def test_alpine_configuration_restarts_runtime_through_its_own_service(self):
        self.use_http([config('0'), SUCCESS, config('1'), config('1'), VERSION])
        with mock.patch.object(guard.Path, 'is_file', return_value=True):
            code, result = self.invoke()
        self.assertEqual((code, result['status']), (0, 'ok'))
        self.assertEqual(self.restart.call_args.args[0],
                         ['sudo', '-n', '/usr/local/sbin/keybridge-services', 'restart-runtime'])

    def test_api_never_ready_is_bounded_and_does_not_write(self):
        self.use_http([])
        code, result = self.invoke()
        self.assertEqual((code, result['status']), (1, 'runtime_readiness_timeout'))
        self.assertGreaterEqual(self.clock.now, guard.READY_TIMEOUT)
        self.assertLessEqual(self.clock.now, guard.READY_TIMEOUT + 0.25)
        self.assertTrue(all(request[0] == 'get' for request in self.http.requests))
        self.restart.assert_not_called()

    def test_check_waits_for_diagnostics_after_configuration_is_ready(self):
        self.use_http([config('1'), UNAVAILABLE, VERSION])
        code, result = self.invoke('check')
        self.assertEqual((code, result['status'], result['runtime_version']), (0, 'ok', '10.33.1'))
        self.assertEqual([r[0] for r in self.http.requests], ['get', 'diagnostics.xml', 'diagnostics.xml'])
        self.assertGreater(self.clock.now, 0)
        self.restart.assert_not_called()

    def test_check_diagnostics_never_ready_is_bounded(self):
        self.use_http([config('1')])
        code, result = self.invoke('check')
        self.assertEqual((code, result['status'], result['runtime_version']), (1, 'runtime_readiness_timeout', None))
        self.assertGreaterEqual(self.clock.now, guard.READY_TIMEOUT)
        self.assertLessEqual(self.clock.now, guard.READY_TIMEOUT + 0.25)
        self.restart.assert_not_called()

    def test_invalid_diagnostics_is_not_retried(self):
        self.use_http([config('1'), b'bad XML', VERSION])
        code, result = self.invoke('check')
        self.assertEqual((code, result['status']), (1, 'invalid_xml'))
        self.assertEqual(len(self.http.requests), 2)
        self.assertEqual(self.clock.now, 0)

    def test_malformed_xml_is_not_retried_as_startup_delay(self):
        self.use_http([b'not XML', config('0'), SUCCESS])
        code, result = self.invoke()
        self.assertEqual((code, result['status']), (1, 'invalid_xml'))
        self.assertEqual(len(self.http.requests), 1)
        self.assertEqual(self.clock.now, 0)
        self.restart.assert_not_called()

    def test_ambiguous_guard_value_fails_closed(self):
        malformed = config('1').replace(b'</config>', b'<no_auto_fwup>0</no_auto_fwup></config>')
        self.use_http([malformed])
        code, result = self.invoke()
        self.assertEqual((code, result['status']), (1, 'firmware_guard_missing_or_invalid'))
        self.assertEqual(len(self.http.requests), 1)
        self.restart.assert_not_called()

    def test_connected_sentinel_refuses_configuration_before_any_http(self):
        self.add_key()
        self.use_http([config('0'), SUCCESS])
        code, result = self.invoke()
        self.assertEqual((code, result['status']), (1, 'sentinel_usb_present_configuration_refused'))
        self.assertEqual(self.http.requests, [])
        self.restart.assert_not_called()

    def test_key_arriving_during_readiness_prevents_write(self):
        self.use_http([config('0'), SUCCESS], after_request=lambda count: self.add_key() if count == 1 else None)
        code, result = self.invoke()
        self.assertEqual((code, result['status']), (1, 'sentinel_usb_present_configuration_refused'))
        self.assertEqual([request[0] for request in self.http.requests], ['get'])
        self.restart.assert_not_called()

    def test_successful_set_without_changed_value_is_not_success(self):
        self.use_http([config('0'), SUCCESS, config('0')])
        code, result = self.invoke()
        self.assertEqual((code, result['status']), (1, 'firmware_updates_not_disabled'))
        self.assertEqual(result['no_auto_fwup'], '0')
        self.restart.assert_not_called()

    def test_guard_must_survive_restart(self):
        self.use_http([config('0'), SUCCESS, config('1'), config('0')])
        code, result = self.invoke()
        self.assertEqual((code, result['status']), (1, 'firmware_updates_not_disabled'))
        self.assertEqual(result['no_auto_fwup'], '0')
        self.assertIsNone(result['runtime_version'])
        self.restart.assert_called_once()

    def test_unreadable_usb_inventory_refuses_configuration(self):
        self.stack.enter_context(mock.patch.object(guard, 'USB_DEVICES', self.usb_root / 'missing'))
        self.use_http([config('0')])
        code, result = self.invoke()
        self.assertEqual((code, result['status']), (1, 'usb_inventory_unavailable'))
        self.assertEqual(self.http.requests, [])
        self.restart.assert_not_called()

    def test_read_only_check_rejects_disabled_guard_without_mutation(self):
        self.use_http([config('0')])
        code, result = self.invoke('check')
        self.assertEqual((code, result['status']), (1, 'firmware_updates_not_disabled'))
        self.assertEqual([request[0] for request in self.http.requests], ['get'])
        self.restart.assert_not_called()

    def test_config_check_does_not_request_expensive_version_diagnostics(self):
        self.use_http([config('1')])
        code, result = self.invoke('check-config')
        self.assertEqual((code, result['status'], result['no_auto_fwup']), (0, 'ok', '1'))
        self.assertIsNone(result['runtime_version'])
        self.assertEqual([request[0] for request in self.http.requests], ['get'])
        self.restart.assert_not_called()

    def test_config_check_still_refuses_disabled_firmware_guard(self):
        self.use_http([config('0')])
        code, result = self.invoke('check-config')
        self.assertEqual((code, result['status']), (1, 'firmware_updates_not_disabled'))
        self.assertEqual([request[0] for request in self.http.requests], ['get'])
        self.restart.assert_not_called()


if __name__ == '__main__':
    unittest.main()
