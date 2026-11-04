# SPDX-License-Identifier: MIT
from contextlib import contextmanager, ExitStack, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[2] / "scripts/package-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleasePackagingTests(unittest.TestCase):
    @contextmanager
    def package(self, *, dirty=False, changed_source=False, initial_audit=True,
                installed_tree="same", stale=True, bundle_identifier="pro.keybridge.pilot",
                missing_source=False, reused_build=False, adhoc=True):
        """Run the packaging workflow with OS commands replaced, without a VM."""
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            folder = Path(temporary)
            checkout = folder / "checkout"
            checkout.mkdir()
            (checkout / "source.swift").write_text("reviewed code")
            expected = release.sha256(checkout / "source.swift")
            if changed_source:
                (checkout / "source.swift").write_text("unbuilt code")
            app = folder / "KeyBridge.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            info = {
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleShortVersionString": "0.1.0", "LSMinimumSystemVersion": "27.0",
                "KeyBridgeLoginLaunchSupported": True}
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            (resources / "build-inventory.json").write_text(json.dumps({
                "signature": "ad-hoc", "notarized": False, "compiled_from_sources": not reused_build,
                "sources_sha256": {} if missing_source else {"source.swift": expected}}))
            for name in ("LICENSE", "THIRD_PARTY.md"):
                (checkout / name).write_text(name)
                (resources / name).write_text(name)
            output = folder / "release"
            auditor = Mock()
            auditor.audit_app.side_effect = [
                {"passed": initial_audit, "tree_sha256": "same"},
                {"passed": True, "tree_sha256": installed_tree}]
            commands = []
            content = None

            def run(*args):
                nonlocal content
                commands.append(tuple(str(a) for a in args))
                if args[0] == "/usr/bin/ditto":
                    shutil.copytree(args[1], args[2])
                elif args[:2] == ("/usr/bin/hdiutil", "create"):
                    content = Path(args[args.index("-srcfolder") + 1])
                    Path(args[-1]).write_bytes(b"fixture disk image")
                elif args[:2] == ("/usr/bin/hdiutil", "attach"):
                    mount = Path(args[args.index("-mountpoint") + 1])
                    shutil.copytree(content / "KeyBridge.app", mount / "KeyBridge.app")

            def write_catalog(app, revision, destination):
                destination.write_text("# Component sources\nhttps://example.org/exact-source.tar.gz\n")
                return {"file": destination.name, "sha256": release.sha256(destination), "packages": 1}

            def git(args, **kwargs):
                return (" M source.swift\n" if dirty else "") if args[1] == "status" else "a" * 40 + "\n"

            stack.enter_context(patch.object(release, "ROOT", checkout))
            catalog = SimpleNamespace(write_catalog=Mock(side_effect=write_catalog))
            scripts = {"source-archive": auditor, "component-sources": catalog,
                       "build-app": SimpleNamespace(production_source_paths=lambda: [checkout / "source.swift"])}
            stack.enter_context(patch.object(release, "load_script", side_effect=scripts.__getitem__))
            stack.enter_context(patch.object(release, "is_adhoc_signed", return_value=adhoc))
            stack.enter_context(patch.object(release, "run", side_effect=run))
            boot = stack.enter_context(patch.object(release, "boot_open_base"))
            stack.enter_context(patch.object(release.subprocess, "check_output", side_effect=git))
            control = stack.enter_context(patch.object(release.subprocess, "run",
                return_value=SimpleNamespace(stdout=json.dumps({"stale": stale}))))
            stack.enter_context(patch("sys.argv", ["package-release.py", "--app", str(app),
                "--version", "0.1.0-rc.1", "--output", str(output)]))
            stack.enter_context(redirect_stdout(io.StringIO()))
            yield SimpleNamespace(output=output, auditor=auditor, commands=commands,
                                  boot=boot, control=control, catalog=catalog)

    def test_release_needs_no_source_archives_and_keeps_installation_checks(self):
        with self.package() as state:
            release.main()
            self.assertEqual({p.name for p in state.output.iterdir()}, {
                "KeyBridge-0.1.0-rc.1-macOS-arm64.dmg", "COMPONENT-SOURCES.md",
                "INSTALL.txt", "release-audit.json", "SHA256SUMS.txt"})
            report = json.loads((state.output / "release-audit.json").read_text())
            self.assertEqual(report["source_repository"],
                "https://github.com/IngvarConsulting/keybridge/tree/" + "a" * 40)
            self.assertEqual(report["component_sources"]["file"], "COMPONENT-SOURCES.md")
            state.auditor.export_source.assert_not_called()
            self.assertEqual(state.auditor.audit_app.call_count, 2)
            self.assertTrue(any(c[:2] == ("/usr/bin/hdiutil", "verify") for c in state.commands))
            self.assertTrue(any(c[:2] == ("/usr/bin/hdiutil", "detach") for c in state.commands))
            state.boot.assert_called_once()
            state.control.assert_called_once()
            for line in (state.output / "SHA256SUMS.txt").read_text().splitlines():
                checksum, filename = line.split("  ")
                self.assertEqual(hashlib.sha256((state.output / filename).read_bytes()).hexdigest(), checksum)

    def test_dirty_checkout_or_source_mismatch_still_blocks_packaging(self):
        for options, error in (({"dirty": True}, "Commit the reviewed"),
                               ({"changed_source": True}, "different source"),
                               ({"missing_source": True}, "different source"),
                               ({"reused_build": True}, "reused compiled binaries"),
                               ({"adhoc": False}, "ad-hoc signed preview")):
            with self.subTest(options=options), self.package(**options) as state:
                with self.assertRaisesRegex(ValueError, error):
                    release.main()
                self.assertFalse(state.output.exists())
                self.assertEqual(state.commands, [])
                state.boot.assert_not_called()

    def test_invalid_application_still_blocks_packaging(self):
        with self.package(initial_audit=False) as state:
            with self.assertRaisesRegex(ValueError, "Application audit failed"):
                release.main()
            self.assertFalse(state.output.exists())
            self.assertEqual(state.commands, [])

    def test_isolated_acceptance_identity_cannot_be_published_as_production(self):
        with self.package(bundle_identifier="pro.keybridge.acceptance") as state:
            with self.assertRaisesRegex(ValueError, "production application identity"):
                release.main()
            self.assertFalse(state.output.exists())
            state.auditor.audit_app.assert_not_called()

    def test_changed_installed_copy_detaches_image_and_blocks_release_report(self):
        with self.package(installed_tree="different") as state:
            with self.assertRaisesRegex(ValueError, "changed during DMG installation"):
                release.main()
            self.assertTrue(any(c[:2] == ("/usr/bin/hdiutil", "detach") for c in state.commands))
            self.assertFalse((state.output / "release-audit.json").exists())
            state.boot.assert_not_called()

    def test_first_run_must_use_empty_runtime(self):
        with self.package(stale=False) as state:
            with self.assertRaisesRegex(ValueError, "did not use an empty runtime"):
                release.main()
            state.boot.assert_called_once()
            self.assertTrue(any(c[:2] == ("/usr/bin/hdiutil", "detach") for c in state.commands))
            self.assertFalse((state.output / "release-audit.json").exists())


if __name__ == "__main__":
    unittest.main()
