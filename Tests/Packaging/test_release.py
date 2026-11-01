# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[2] / "scripts/package-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class CorrespondingSourcesTests(unittest.TestCase):
    def test_uploaded_parts_restore_the_exact_source_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "original.zip"
            source.write_bytes(bytes(range(256)) * 37)
            record = release.split_source_archive(source, root, "published.zip", part_bytes=1024)
            restored = b"".join((root / part["name"]).read_bytes() for part in record["parts"])
            self.assertEqual(restored, source.read_bytes())
            self.assertEqual(record["sha256"], hashlib.sha256(restored).hexdigest())
            self.assertTrue(all(part["bytes"] <= 1024 for part in record["parts"]))
            self.assertEqual([part["name"] for part in record["parts"]],
                             sorted(part["name"] for part in record["parts"]))

    def archive(self, folder, *, complete=True, version="1", linked=True, corrupt=False, extra=False):
        data = b"upstream source fixture"
        manifest = {"schema": 1, "kind": "runtime", "complete": complete,
                    "packages": [{"name": "fixture", "version": version,
                                  "source_files": ["source.tar"] if linked else []}],
                    "files": [{"path": "source.tar", "bytes": len(data),
                               "sha256": hashlib.sha256(data).hexdigest()}]}
        path = Path(folder) / "sources.zip"
        with zipfile.ZipFile(path, "w") as output:
            output.writestr("manifest.json", json.dumps(manifest))
            output.writestr("source.tar", b"different" if corrupt else data)
            if extra:
                output.writestr("unrecorded", b"not inspected")
        return path

    def test_complete_matching_sources_are_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            result = release.validate_sources(self.archive(folder), "runtime", {("runtime", "fixture", "1")})
            self.assertTrue(result["complete"])

    def test_missing_wrong_unlinked_or_corrupt_sources_block_release(self):
        for options in ({"complete": False}, {"version": "2"}, {"linked": False},
                        {"corrupt": True}, {"extra": True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(ValueError):
                    release.validate_sources(self.archive(folder, **options), "runtime", {("runtime", "fixture", "1")})

    def test_same_packages_do_not_allow_sources_for_another_base(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "KeyBridge.app"
            base = app / "Contents/Resources/base"
            base.mkdir(parents=True)
            (base / "manifest.json").write_text(json.dumps({"build_id": "current", "files": {"disk": "new"}}))
            for name in ("alpine-packages.txt", "alpine-package-details.txt"):
                (base / name).write_text("same package version")
            path = Path(folder) / "guest.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("manifest.json", json.dumps({"base_build_id": "current"}))
                archive.writestr("metadata/base-manifest.json", json.dumps({"build_id": "current", "files": {"disk": "old"}}))
            with self.assertRaisesRegex(ValueError, "inventory differs"):
                release.validate_source_binding(path, "guest", app)

    def test_same_runtime_packages_do_not_allow_another_firmware(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "KeyBridge.app"
            firmware = app / "Contents/Resources/runtime/share/qemu"
            firmware.mkdir(parents=True)
            (firmware / "bios.bin").write_bytes(b"new firmware")
            path = Path(folder) / "runtime.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("manifest.json", json.dumps({"files": [{"path": "qemu.tar"}],
                    "firmware_evidence": {"bios.bin": {"binary_sha256": hashlib.sha256(b"old firmware").hexdigest(),
                        "source_archive": "qemu.tar", "source_paths": ["firmware/source.c"]}}}))
            with self.assertRaisesRegex(ValueError, "different binaries"):
                release.validate_source_binding(path, "runtime", app)


if __name__ == "__main__":
    unittest.main()
