# SPDX-License-Identifier: MIT
"""Exercise Control against an owned native sleeper, never a virtual machine.

Run on macOS with KEYBRIDGE_TEST_CONTROL pointing to a freshly built executable.
The child has QEMU's process name/argv solely for production ownership checks.
Control runs with all networking denied, so its SSH attempt cannot reach a VM.
"""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import threading
import unittest
import uuid


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("KEYBRIDGE_TEST_CONTROL"),
                     "requires macOS and an explicit freshly built KEYBRIDGE_TEST_CONTROL")
class StopAfterAgentCrashTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.control = Path(os.environ["KEYBRIDGE_TEST_CONTROL"]).resolve(strict=True)
        if not cls.control.is_file() or not os.access(cls.control, os.X_OK):
            raise RuntimeError("KEYBRIDGE_TEST_CONTROL must be an executable file")
        cls.sandbox = Path("/usr/bin/sandbox-exec")
        if not cls.sandbox.is_file():
            raise RuntimeError("Network isolation is required; sandbox-exec is unavailable")
        cls.build = tempfile.TemporaryDirectory(prefix="keybridge-stop-fixture-")
        cls.addClassCleanup(cls.build.cleanup)
        folder = Path(cls.build.name)
        source = folder / "sleeper.c"
        source.write_text("""#include <unistd.h>
#include <errno.h>
int main(void) {
    char byte;
    if (write(STDOUT_FILENO, "ready\\n", 6) != 6) return 2;
    for (;;) {
        ssize_t count = read(STDIN_FILENO, &byte, 1);
        if (count == 0) return 0;
        if (count < 0 && errno != EINTR) return 3;
    }
}
""")
        cls.fixture = folder / "qemu-system-x86_64"
        subprocess.run(["/usr/bin/clang", str(source), "-o", str(cls.fixture)],
                       check=True, capture_output=True, text=True, timeout=15)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="keybridge-stop-runtime-")
        self.addCleanup(self.directory.cleanup)
        self.runtime = Path(self.directory.name).resolve()
        self.children = []
        self.reapers = []
        self.addCleanup(self.close_children)
        self.original = {"schema": 2, "want": True, "autoInhibit": False,
                         "autostart": True, "remaining": 2, "sessionID": "fixture-session", "revision": 7}
        (self.runtime / "intent.json").write_text(json.dumps(self.original))

    def close_children(self):
        # These are exact unreaped Popen children. EOF cooperatively releases
        # only their private stdin pipes; cleanup never signals a numeric PID.
        for child in self.children:
            if child.stdin:
                child.stdin.close()
            child.wait(timeout=3)
            if child.stdout:
                child.stdout.close()
        for reaper in self.reapers:
            reaper.join(timeout=3)
            self.assertFalse(reaper.is_alive())

    def spawn_fixture(self, runtime=None):
        runtime = runtime or self.runtime
        generation, run = str(uuid.uuid4()), str(uuid.uuid4())
        folder = runtime / "generations" / generation
        folder.mkdir(parents=True)
        (folder / "guest.qcow2").write_bytes(b"not a VM disk")
        (folder / "known_hosts").write_bytes(b"")
        child = subprocess.Popen([str(self.fixture), "-qmp", f"unix:{runtime}/qmp.sock,server=on,wait=off",
                                  "-drive", f"file={folder}/guest.qcow2,if=virtio,format=qcow2",
                                  "-name", f"keybridge-{run}"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.children.append(child)
        self.assertTrue(select.select([child.stdout], [], [], 3)[0], "fixture did not start")
        self.assertEqual(child.stdout.readline(), b"ready\n")
        self.assertIsNone(child.poll())
        # A crashed agent's children are reaped by launchd. Reap promptly here
        # too, rather than inventing a surviving VM by retaining our own zombie.
        reaper = threading.Thread(target=child.wait, daemon=True)
        self.reapers.append(reaper)
        reaper.start()
        return child

    def control_stop(self, action):
        env = dict(os.environ, KEYBRIDGE_RUNTIME=str(self.runtime))
        started = time.monotonic()
        result = subprocess.run([str(self.sandbox), "-p", "(version 1)(allow default)(deny network*)",
                                 str(self.control), action], env=env, capture_output=True, text=True, timeout=42)
        elapsed = time.monotonic() - started
        print(f"{self.id()}: {elapsed:.2f}s, exit={result.returncode}", flush=True)
        self.assertLess(elapsed, 42)
        self.assertFalse((self.runtime / "agent.pid").exists(), "Stop must not bootstrap an agent")
        return result

    def assert_stopped(self, child):
        self.assertIn(child.wait(timeout=2), (-signal.SIGTERM, -signal.SIGKILL),
                      "production audit-token escalation must stop the owned fixture")

    def test_explicit_stop_terminates_owned_fixture_and_saves_inhibit(self):
        owned = self.spawn_fixture()
        other = self.spawn_fixture(self.runtime / "another-runtime")
        result = self.control_stop("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_stopped(owned)
        self.assertIsNone(other.poll(), "another runtime's fixture must remain alive")
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["ownership"], "absent")
        self.assertTrue(receipt["stopSaved"])
        self.assertTrue(receipt["agentExited"])
        intent = json.loads((self.runtime / "intent.json").read_text())
        self.assertFalse(intent["want"])
        self.assertTrue(intent["autoInhibit"])
        self.assertTrue(intent["autostart"])
        self.assertEqual(intent["remaining"], self.original["remaining"])

    def test_session_shutdown_terminates_owned_fixture_without_changing_intent(self):
        before = (self.runtime / "intent.json").read_bytes()
        owned = self.spawn_fixture()
        result = self.control_stop("session-shutdown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_stopped(owned)
        self.assertEqual(json.loads(result.stdout)["ownership"], "absent")
        self.assertEqual((self.runtime / "intent.json").read_bytes(), before,
                         "system session end must preserve want, autostart and inhibit separately from physical stop")

    def test_broken_intent_storage_still_stops_owned_fixture_and_reports_failure(self):
        intent = self.runtime / "intent.json"
        intent.unlink()
        intent.mkdir()
        owned = self.spawn_fixture()
        result = self.control_stop("stop")
        self.assertNotEqual(result.returncode, 0)
        self.assert_stopped(owned)
        self.assertTrue(intent.is_dir(), "failed storage must not be silently replaced")
        self.assertIn("Намерение остановки не сохранено", result.stderr)
        self.assertNotIn("Остановка не подтверждена", result.stderr)
        self.assertEqual(result.stdout.strip(), "", "failed persistence must not produce a success receipt")


if __name__ == "__main__":
    unittest.main(verbosity=2)
