# SPDX-License-Identifier: MIT
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


build = module("build-app")
audit = module("source-archive")
HELPER = "Contents/MacOS/KeyBridgeAgent"


def icon():
    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))

    elements = []
    for kind, size in ((b"icp4", 16), (b"icp5", 32), (b"ic07", 128),
                       (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024)):
        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress((b"\0" + b"\0" * size * 4) * size))
               + chunk(b"IEND", b""))
        elements.append(kind + struct.pack(">I", len(png) + 8) + png)
    payload = b"".join(elements)
    return b"icns" + struct.pack(">I", len(payload) + 8) + payload


class NativeBundleTests(unittest.TestCase):
    def test_native_resources_copy_only_brand(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, resources = Path(temporary) / "source", Path(temporary) / "bundle"
            interface = source / "Resources/interface"
            interface.mkdir(parents=True)
            resources.mkdir()
            shutil.copy2(ROOT / "Resources/interface/ingvar-consulting.png", interface)
            shutil.copytree(ROOT / "Resources/probe", source / "Resources/probe")
            for name in ("keybridge.html", "keybridge.js", "keybridge.css", "unrelated.png"):
                (interface / name).write_bytes(b"not part of native production resources")
            with patch.object(build, "ROOT", source):
                build.bundle_source_resources(resources)
                inventory = {path.relative_to(source).as_posix() for path in build.production_source_paths()}
            self.assertEqual({p.relative_to(resources).as_posix() for p in resources.rglob("*") if p.is_file()},
                             {"interface/ingvar-consulting.png"} | {"probe/" + name for name in audit.PROBE})
            self.assertEqual({p for p in inventory if p.startswith("Resources/interface/")},
                             {"Resources/interface/ingvar-consulting.png"})
            self.assertIn("scripts/build-app.py", inventory)

    def test_brand_symlinks_and_binary_guest_files_still_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, resources = Path(temporary) / "source", Path(temporary) / "bundle"
            interface = source / "Resources/interface"
            interface.mkdir(parents=True)
            resources.mkdir()
            logo = interface / "ingvar-consulting.png"
            logo.symlink_to(ROOT / "Resources/interface/ingvar-consulting.png")
            with patch.object(build, "ROOT", source):
                with self.assertRaisesRegex(RuntimeError, "symlink"):
                    build.bundle_source_resources(resources)
                logo.unlink()
                shutil.copy2(ROOT / "Resources/interface/ingvar-consulting.png", logo)
                guest = source / "Resources/guest"
                guest.mkdir()
                (guest / "script.py").write_bytes(b"\x7fELF\0payload")
                with self.assertRaisesRegex(RuntimeError, "Binary guest"):
                    build.bundle_source_resources(resources)

    @contextmanager
    def bundle(self, *, identifier=None, signature=True, bundle_identifier="pro.keybridge.pilot"):
        """Supply file fixtures and tool observations; no signing, VM or native process is run."""
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "KeyBridge.app"

            def put(name, data=b"fixture text\n"):
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)

            for name in audit.ROOT_BUNDLE_FILES:
                put(name)
            put(audit.agent_plist_path(bundle_identifier), plistlib.dumps({
                "Label": bundle_identifier + ".agent", "BundleProgram": "Contents/MacOS/KeyBridgeAgent"}))
            for name in audit.PRODUCTS:
                put("Contents/MacOS/" + name, b"\xcf\xfa\xed\xfe" + b"fixture Mach-O")
            runtime = ({"runtime/bin/" + name for name in audit.RUNTIME_EXECUTABLES}
                       | {"runtime/lib/" + name for name in audit.RUNTIME_LIBRARIES}
                       | {"runtime/share/qemu/" + name for name in audit.FIRMWARE})
            for name in runtime:
                put("Contents/Resources/" + name, b"firmware" if "/share/" in name else b"\xcf\xfa\xed\xfe")
            for name in audit.GUEST:
                put("Contents/Resources/guest/" + name)
            for name in audit.PROBE:
                put("Contents/Resources/probe/" + name)
            for name in audit.BASE_IMAGES | audit.BASE_TEXT:
                put("Contents/Resources/base/" + name)
            base = app / "Contents/Resources/base"
            put("Contents/Resources/base/manifest.json", json.dumps({
                "proprietary_components_included": False, "private_keys_included": False,
                "files": {name: audit.digest((base / name).read_bytes())
                          for name in audit.BASE_IMAGES | (audit.BASE_TEXT - {"manifest.json"})}}).encode())
            put("Contents/Resources/build-inventory.json", json.dumps({
                "sources_sha256": {"Sources/KeyBridgeApp/KeyBridgeApp.swift": "fixture"},
                "runtime_files": [{"file": name} for name in sorted(runtime)],
                "proprietary_components_included": False}).encode())
            put("Contents/Info.plist", plistlib.dumps({"CFBundleIconFile": "AppIcon.icns",
                                                      "CFBundleIdentifier": bundle_identifier, "CFBundleExecutable": "KeyBridgeApp"}))
            put("Contents/Resources/AppIcon.icns", icon())
            put("Contents/Resources/interface/ingvar-consulting.png", (ROOT / "Resources/interface/ingvar-consulting.png").read_bytes())

            def execute(*args):
                return "arm64\n" if args[0] == "/usr/bin/lipo" else "fixture:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1)\n"

            def codesign(args, **kwargs):
                if "--display" in args:
                    name = Path(args[-1]).name
                    value = identifier if name == "KeyBridgeAgent" and identifier is not None else audit.product_identifiers(bundle_identifier)[name]
                    return SimpleNamespace(returncode=0, stderr="Identifier=" + value + "\n")
                return SimpleNamespace(returncode=0 if signature else 1)

            with patch.object(audit, "execute", side_effect=execute), patch.object(audit.subprocess, "run", side_effect=codesign) as signing:
                yield app, put, signing

    def test_native_bundle_passes_independent_audit_with_signed_agent(self):
        self.assertNotIn("KeyBridgeMaintenance", build.PRODUCTS)
        self.assertEqual(build.product_identifiers("pro.keybridge.pilot")["KeyBridgeAgent"], "pro.keybridge.pilot.agent")
        with self.bundle() as (app, _, signing):
            result = audit.audit_app(app)
            self.assertTrue(result["passed"], result)
            self.assertTrue(any("--verify" in call.args[0] and "--strict" in call.args[0]
                                for call in signing.call_args_list))
            self.assertEqual(result["categories"].get("interface-source", 0), 0)

    def test_isolated_bundle_uses_consistent_distinct_signing_and_registration_identity(self):
        identity = "pro.keybridge.acceptance-native"
        with self.bundle(bundle_identifier=identity) as (app, put, _):
            result = audit.audit_app(app)
            self.assertTrue(result["passed"], result)
            self.assertEqual(result["bundle_identifier"], identity)
            self.assertEqual(build.product_identifiers(identity), audit.product_identifiers(identity))
            path = audit.agent_plist_path(identity)
            put(path, plistlib.dumps({"Label": "pro.keybridge.pilot.agent", "BundleProgram": "Contents/MacOS/KeyBridgeAgent"}))
            result = audit.audit_app(app)
            self.assertFalse(result["passed"])
            self.assertTrue(any(item["file"] == path for item in result["bad_files"]))
        self.assertIsNone(audit.approved_category(audit.agent_plist_path("pro.keybridge.pilot"), identity))
        for invalid in ("", "single", "../escape", "pro.keybridge/escape", "pro..keybridge", "pro.1keybridge", "pro.key_bridge"):
            for validator in (build, audit):
                with self.subTest(identifier=invalid, validator=validator.__name__), self.assertRaises(ValueError):
                    validator.product_identifiers(invalid)

    def test_absent_agent_and_incorrect_signing_identity_block_audit(self):
        for missing in (HELPER,):
            with self.subTest(missing=missing), self.bundle() as (app, _, __):
                (app / missing).unlink()
                result = audit.audit_app(app)
                self.assertFalse(result["passed"])
                self.assertTrue(any(item["file"] == missing for item in result["bad_files"]))
        with self.bundle(identifier="pro.keybridge.pilot") as (app, _, __):
            result = audit.audit_app(app)
            self.assertFalse(result["passed"])
            self.assertIn({"file": HELPER, "reason": "unexpected product signing identifier"}, result["bad_files"])
        with self.bundle(signature=False) as (app, _, __):
            self.assertFalse(audit.audit_app(app)["passed"])

    def test_obsolete_web_files_and_inventory_cannot_pass_production_audit(self):
        for name in ("keybridge.html", "keybridge.js", "keybridge.css"):
            with self.subTest(name=name), self.bundle() as (app, put, _):
                path = "Contents/Resources/interface/" + name
                self.assertIsNone(audit.approved_category(path))
                put(path)
                result = audit.audit_app(app)
                self.assertFalse(result["passed"])
                self.assertTrue(any(item["file"] == path for item in result["bad_files"]))
        with self.bundle() as (app, put, _):
            path = "Contents/Resources/build-inventory.json"
            inventory = json.loads((app / path).read_text())
            inventory["sources_sha256"]["Resources/interface/keybridge.js"] = "old source"
            put(path, json.dumps(inventory).encode())
            result = audit.audit_app(app)
            self.assertFalse(result["passed"])
            self.assertIn({"file": path, "reason": "obsolete web interface in production source inventory"}, result["bad_files"])


if __name__ == "__main__":
    unittest.main()
