# SPDX-License-Identifier: MIT
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("component_sources", Path(__file__).resolve().parents[2] / "scripts/component-sources.py")
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class ComponentSourceLinksTests(unittest.TestCase):
    def app(self, directory):
        app = Path(directory) / "KeyBridge.app"
        resources = app / "Contents/Resources"
        runtime = resources / "ThirdParty/fixture-1.2"
        runtime.mkdir(parents=True)
        (runtime.parent / "packages.json").write_text(json.dumps([
            {"name": "fixture", "version": "1.2", "formula_files": ["fixture.rb"]}]))
        (runtime / "fixture.rb").write_text('''class Fixture < Formula
  url "https://example.org/fixture-1.2.tar.xz"
  sha256 "%s"
  resource "build-data" do
    url "https://example.org/data-3.tar.xz"
    sha256 "%s"
  end
  patch do
    url "https://example.org/fix-4.patch"
    sha256 "%s"
  end
end
''' % ("0" * 64, "1" * 64, "2" * 64))
        base = resources / "base"
        (base / "notices").mkdir(parents=True)
        (base / "manifest.json").write_text(json.dumps({"sources": ["https://dl-cdn.alpinelinux.org/alpine/v3.22/"]}))
        (base / "alpine-packages.txt").write_text("libexample-2.1-r3 - Example library\n")
        (base / "alpine-package-details.txt").write_text("P:libexample\nV:2.1-r3\no:example\nc:" + "a" * 40 + "\n\n")
        (base / "notices/debian-packages.txt").write_text("libother:amd64\t1:3.2-1+b7\n")
        (base / "notices/debian-source-packages.txt").write_text("libother:amd64\t1:3.2-1+b7\tother\t1:3.2-1\n")
        return app, base

    def test_catalog_uses_exact_source_identity_not_binary_package_name_or_version(self):
        with tempfile.TemporaryDirectory() as directory:
            app, _ = self.app(directory)
            output = Path(directory) / "COMPONENT-SOURCES.md"
            result = catalog.write_catalog(app, "b" * 40, output)
            text = output.read_text()
            self.assertEqual(result["packages"], {"runtime": 1, "alpine": 1, "debian": 1})
            self.assertIn("https://snapshot.debian.org/package/other/1%3A3.2-1/", text)
            self.assertNotIn("/package/libother", text)
            self.assertIn("libother:amd64 | 1:3.2-1+b7", text)
            self.assertIn("https://github.com/alpinelinux/aports/tree/" + "a" * 40, text)
            self.assertIn("example @ aaaaaaaaaaaa", text)
            for filename in ("fixture-1.2.tar.xz", "data-3.tar.xz", "fix-4.patch"):
                self.assertIn("https://example.org/" + filename, text)
            self.assertEqual(set(Path(directory).iterdir()), {app, output})

    def test_version_characters_are_encoded_in_source_url(self):
        with tempfile.TemporaryDirectory() as directory:
            _, base = self.app(directory)
            (base / "notices/debian-source-packages.txt").write_text("libother:amd64\t1:3.2-1+b7\tother\t1:3.2+dfsg-1~deb12u1\n")
            rows = catalog.debian_rows(base)
            self.assertIn("1%3A3.2%2Bdfsg-1~deb12u1", rows[0][2])

    def test_unmatched_inventory_or_unpinned_alpine_recipe_is_not_mislabeled(self):
        with tempfile.TemporaryDirectory() as directory:
            _, base = self.app(directory)
            details = base / "alpine-package-details.txt"
            for content in ("P:libexample\nV:2.1-r3\no:example\nc:main\n", "P:libexample\nV:2.2-r0\no:example\nc:" + "a" * 40 + "\n"):
                details.write_text(content)
                with self.assertRaises(ValueError):
                    catalog.alpine_rows(base)
            (base / "notices/debian-source-packages.txt").write_text("libother:amd64\t1:3.2-1+b8\tother\t1:3.2-1\n")
            with self.assertRaises(ValueError):
                catalog.debian_rows(base)


if __name__ == "__main__":
    unittest.main()
