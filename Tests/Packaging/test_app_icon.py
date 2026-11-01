# SPDX-License-Identifier: MIT
import importlib.util
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


build = module("build-app")
audit = module("source-archive")


class ApplicationIconTests(unittest.TestCase):
    def test_approved_image_is_accepted_and_brand_dimensions_stay_distinct(self):
        icon = (ROOT / "Resources/app-icon.png").read_bytes()
        brand = (ROOT / "Resources/interface/ingvar-consulting.png").read_bytes()
        for validator, error in ((build, RuntimeError), (audit, ValueError)):
            validator.validate_png(icon, maximum=8 * 1024 * 1024)
            validator.validate_brand_png(brand)
            with self.assertRaises(error):
                validator.validate_brand_png(icon)
            with self.assertRaises(error):
                validator.validate_png(brand, maximum=8 * 1024 * 1024)

    def test_corrupt_or_appended_icon_data_is_rejected(self):
        icon = (ROOT / "Resources/app-icon.png").read_bytes()
        corrupt = bytearray(icon)
        corrupt[40] ^= 1
        for validator, error in ((build, RuntimeError), (audit, ValueError)):
            for data in (bytes(corrupt), icon[:-1], icon + b"unexpected trailing payload"):
                with self.subTest(validator=validator.__name__, length=len(data)), self.assertRaises(error):
                    validator.validate_png(data, maximum=8 * 1024 * 1024)

    def test_only_named_bundle_icon_and_image_container_are_allowed(self):
        self.assertEqual(audit.approved_category("Contents/Resources/AppIcon.icns"), "app-icon")
        self.assertIsNone(audit.approved_category("Contents/Resources/other.icns"))
        self.assertIsNone(audit.approved_category("Contents/Resources/app-icon.png"))
        for data in (b"\x7fELF" + b"\0" * 100, b"icns" + struct.pack(">I", 8),
                     b"icns" + struct.pack(">I", 20) + b"ELF!" + struct.pack(">I", 12) + b"junk"):
            with self.assertRaises(ValueError):
                audit.validate_app_icns(data)


if __name__ == "__main__":
    unittest.main()
