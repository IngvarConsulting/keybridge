# SPDX-License-Identifier: MIT
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("runtime_sources", Path(__file__).resolve().parents[2] / "scripts/collect-runtime-sources.py")
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class RuntimeSourcesTests(unittest.TestCase):
    def test_recipe_includes_remote_resource_patch_and_inline_patch(self):
        recipe = '''class Example < Formula
  url "https://example.test/source.tar.xz"
  mirror "https://mirror.test/source.tar.xz"
  sha256 "aaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd"
  resource "extra" do
    url "https://example.test/extra.tar.gz"
    sha256 "bbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaa"
  end
  patch do
    url "https://example.test/fix.diff"
    sha256 "ccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbb"
  end
  patch :DATA
end
__END__
--- old
+++ new
'''.encode()
        sources = collector.recipe_downloads("example", "1.0", recipe)
        self.assertEqual([item["kind"] for item in sources], ["upstream", "resource", "patch"])
        self.assertEqual(len(sources[0]["urls"]), 2)
        self.assertEqual(sources[2]["path"], "sources/example-1.0/fix.diff")

    def test_unknown_local_patch_refuses_complete_archive(self):
        recipe = '''url "https://example.test/source.tar.xz"
sha256 "aaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd"
patch do
  file "Patches/unknown.diff"
end
'''.encode()
        with self.assertRaisesRegex(ValueError, "Unreviewed"):
            collector.recipe_downloads("unknown", "1", recipe)

    def test_interpolated_download_needs_review(self):
        with self.assertRaisesRegex(ValueError, "Interpolated"):
            collector.parse_source('url "https://example.test/#{version}.tar.xz"\nsha256 "' + "a" * 64 + '"')

    def firmware_fixture(self, directory, *, changed_binary=False, missing_source=False):
        resources = directory / "resources"
        firmware = resources / "runtime/share/qemu"
        firmware.mkdir(parents=True)
        entries = {}
        for name, sources in collector.FIRMWARE_SOURCES.items():
            binary = ("binary-" + name).encode()
            (firmware / name).write_bytes(binary + (b"changed" if changed_binary else b""))
            entries["pc-bios/" + name] = binary
            for source in sources:
                entries[source] = ("source-" + source).encode()
        if missing_source:
            entries.pop("roms/seabios/src/post.c")
        archive = directory / "qemu.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for name, data in entries.items():
                member = tarfile.TarInfo("qemu-1/" + name)
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
        return archive, resources

    def test_firmware_requires_actual_sources_and_same_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, resources = self.firmware_fixture(Path(tmp))
            evidence = collector.firmware_evidence(archive, resources, "sources/qemu.tar.gz")
            self.assertEqual(set(evidence), set(collector.FIRMWARE_SOURCES))
            self.assertEqual(evidence["bios.bin"]["source_archive"], "sources/qemu.tar.gz")

    def test_changed_firmware_cannot_claim_source_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, resources = self.firmware_fixture(Path(tmp), changed_binary=True)
            with self.assertRaisesRegex(ValueError, "differs"):
                collector.firmware_evidence(archive, resources, "sources/qemu.tar.gz")

    def test_empty_submodule_cannot_claim_source_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive, resources = self.firmware_fixture(Path(tmp), missing_source=True)
            with self.assertRaisesRegex(ValueError, "lacks firmware sources"):
                collector.firmware_evidence(archive, resources, "sources/qemu.tar.gz")


if __name__ == "__main__":
    unittest.main()
