#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Export allowlisted source text and the developer logo; audit a local app.

Never traverses the project to decide what to export. Runtime directories and
user installers cannot be included through the source allowlist. The single
PNG exception is validated separately; it does not allow other binary sources.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
BUILD_ROOT = Path(os.environ.get("KEYBRIDGE_BUILD_ROOT", str(Path.home() / "Library/Caches/KeyBridgeDevelopment"))).expanduser().resolve()
SOURCE_FILES = ("Package.swift", "README.md", "LICENSE", "THIRD_PARTY.md", ".gitignore",
                "Resources/interface/ingvar-consulting.png")
SOURCE_GLOBS = ("Sources/**/*.swift", "Resources/guest/*.py", "Resources/guest/*.sh",
                "Resources/interface/*.html", "Resources/interface/*.js", "Resources/interface/*.css",
                "Tests/Interface/*.js", "Tests/Interface/*.cjs", "Tests/Interface/*.html",
                "Tests/**/*.swift", "Tests/**/*.py", "scripts/*.py", "scripts/*.sh",
                "arch/**/*.md", ".github/workflows/*.yml")
MACHO = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
FORBIDDEN_MAGICS = MACHO | {b"\x7fELF", b"QFI\xfb", b"!<ar"}
PRODUCTS = {"KeyBridgeApp", "KeyBridgeAgent", "KeyBridgeControl", "KeyBridgeConfigure"}
RUNTIME_EXECUTABLES = {"qemu-system-x86_64", "qemu-img"}
RUNTIME_LIBRARIES = set("""libcapstone.5.dylib libgnutls.30.dylib libpng16.16.dylib
libpixman-1.0.dylib libjpeg.8.3.2.dylib libsnappy.1.3.1.dylib liblzo2.2.dylib
libgio-2.0.0.dylib libgobject-2.0.0.dylib libglib-2.0.0.dylib libzstd.1.5.7.dylib
libslirp.0.dylib libvdeplug.3.dylib libfdt.1.dylib libncursesw.6.dylib libgmodule-2.0.0.dylib
libusb-1.0.0.dylib libssh.4.12.0.dylib libintl.8.dylib libp11-kit.0.dylib libidn2.0.dylib
libunistring.5.dylib libtasn1.6.dylib libhogweed.7.0.dylib libnettle.9.0.dylib
libgmp.10.dylib libpcre2-8.0.dylib libcrypto.4.dylib""".split())
BASE_IMAGES = {"alpine.qcow2", "vmlinuz-virt", "initramfs-virt"}
BASE_TEXT = {"manifest.json", "alpine-packages.txt", "alpine-package-details.txt"}
FIRMWARE = {"bios-256k.bin", "bios.bin", "kvmvapic.bin", "vgabios-stdvga.bin", "efi-virtio.rom", "linuxboot_dma.bin"}
GUEST = {"key_info.py", "license_evidence.py", "sentinel_guard.py",  "rmlic_ready.sh", "verify_imports.sh",  "alpine_service.sh", "alpine_hasp_hotplug.sh", "alpine_ready.py", "alpine_provision.sh", "alpine_bootstrap.sh"}
PACKAGES = set("""capstone-5.0.9 dtc-1.8.1 gettext-1.0 glib-2.90.1 gmp-6.3.0 gnutls-3.8.13_2
jpeg-turbo-3.2.0 libidn2-2.3.8 libpng-1.6.59 libslirp-4.9.5 libssh-0.12.2_1 libtasn1-4.21.0
libunistring-1.5 libusb-1.0.30 lzo-2.10 ncurses-6.6 nettle-4.0 openssl@4-4.0.3 p11-kit-0.26.5
pcre2-10.49 pixman-0.46.4 qemu-11.1.2 snappy-1.3.1 vde-2.3.3 zstd-1.5.7_1""".split())
ROOT_BUNDLE_FILES = {"Contents/Info.plist", "Contents/PkgInfo", "Contents/_CodeSignature/CodeResources",
    "Contents/Library/LaunchAgents/pro.keybridge.pilot.agent.plist", "Contents/Resources/LICENSE",
    "Contents/Resources/THIRD_PARTY.md", "Contents/Resources/build-inventory.json",
    "Contents/Resources/.keybridge-build-marker", "Contents/Resources/ThirdParty/packages.json"}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def validate_brand_png(data: bytes) -> None:
    """Independently validate the sole binary source/UI asset."""
    if len(data) > 1024 * 1024 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Invalid brand PNG signature or size")
    cursor = 8
    seen_header = seen_image = False
    while cursor + 12 <= len(data):
        size = int.from_bytes(data[cursor:cursor + 4], "big")
        tag = data[cursor + 4:cursor + 8]
        boundary = cursor + size + 12
        if boundary > len(data) or not re.fullmatch(rb"[A-Za-z]{4}", tag):
            raise ValueError("Malformed brand PNG chunk")
        body = data[cursor + 8:boundary - 4]
        crc = int.from_bytes(data[boundary - 4:boundary], "big")
        if zlib.crc32(tag + body) & 0xffffffff != crc:
            raise ValueError("Corrupt brand PNG chunk")
        if not seen_header:
            if tag != b"IHDR" or size != 13:
                raise ValueError("Missing brand PNG IHDR")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", body)
            valid_depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8}, 4: {8, 16}, 6: {8, 16}}
            if ((width, height) != (1240, 220) or depth not in valid_depths.get(color, set())
                    or compression or filtering or interlace not in (0, 1)):
                raise ValueError("Unexpected brand PNG dimensions or encoding")
            seen_header = True
        elif tag == b"IHDR":
            raise ValueError("Duplicate brand PNG IHDR")
        if tag == b"IDAT":
            seen_image = seen_image or size > 0
        if tag == b"IEND":
            if size or boundary != len(data) or not seen_image:
                raise ValueError("Invalid brand PNG IEND")
            return
        cursor = boundary
    raise ValueError("Incomplete brand PNG")


def reject_symlink_chain(path: Path, base: Path) -> None:
    current = path
    while current != base:
        if current.is_symlink():
            raise ValueError("Symlinks are forbidden: " + str(current.relative_to(base)))
        if base not in current.parents:
            raise ValueError("Path escapes the source directory")
        current = current.parent
    if base.is_symlink():
        raise ValueError("Source root must not be a symlink")


def export_source(destination: Path) -> dict:
    resolved = destination.resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        raise ValueError("Source archive must be outside the project")
    selected = {ROOT / name for name in SOURCE_FILES}
    for pattern in SOURCE_GLOBS:
        selected.update(ROOT.glob(pattern))
    payload = []
    for path in sorted(selected):
        reject_symlink_chain(path, ROOT)
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError("Expected source file: " + path.name)
        data = path.read_bytes()
        if path.relative_to(ROOT).as_posix() == "Resources/interface/ingvar-consulting.png":
            validate_brand_png(data)
        else:
            if data[:4] in FORBIDDEN_MAGICS or data[:2] == b"MZ" or b"\x00" in data:
                raise ValueError("Binary source input rejected: " + path.name)
            data.decode("utf-8")
        if re.search(rb"(?m)^-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----", data):
            raise ValueError("Private key rejected: " + path.name)
        payload.append((path.relative_to(ROOT).as_posix(), data, path.stat().st_mode))
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    if temporary.is_symlink() or destination.is_symlink():
        raise ValueError("Archive output must not be a symlink")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data, mode in payload:
            info = zipfile.ZipInfo("keybridge/" + name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | (0o755 if mode & 0o111 else 0o644)) << 16
            archive.writestr(info, data)
    temporary.replace(destination)
    return {"file": destination.name, "file_count": len(payload), "bytes": destination.stat().st_size,
            "sha256": digest(destination.read_bytes()), "paths": [name for name, _, _ in payload]}


def approved_category(name: str) -> str | None:
    if name.startswith("Contents/Resources/base/"):
        relative = name[len("Contents/Resources/base/"):]
        if relative in BASE_IMAGES: return "linux-image"
        if relative in BASE_TEXT or (relative.startswith("notices/") and Path(relative).name in {"copyright", "debian-packages.txt", "debian-source-packages.txt"}): return "linux-base-text"
    if name in ROOT_BUNDLE_FILES:
        return "metadata"
    p = Path(name)
    if p.parent.as_posix() == "Contents/MacOS" and p.name in PRODUCTS:
        return "host-macho"
    if p.parent.as_posix() == "Contents/Resources/runtime/bin" and p.name in RUNTIME_EXECUTABLES:
        return "host-macho"
    if p.parent.as_posix() == "Contents/Resources/runtime/lib" and p.name in RUNTIME_LIBRARIES:
        return "host-macho"
    if p.parent.as_posix() == "Contents/Resources/runtime/share/qemu" and p.name in FIRMWARE:
        return "firmware"
    if p.parent.as_posix() == "Contents/Resources/guest" and p.name in GUEST:
        return "guest-source"
    if p.parent.as_posix() == "Contents/Resources/interface" and p.name in {"keybridge.html", "keybridge.js"}:
        return "interface-source"
    if name == "Contents/Resources/interface/ingvar-consulting.png":
        return "brand-image"
    parts = p.parts
    if len(parts) == 5 and parts[:3] == ("Contents", "Resources", "ThirdParty") and parts[3] in PACKAGES:
        if (p.name in {"INSTALL_RECEIPT.json", "sbom.spdx.json"}
            or re.match(r"^(COPYING|LICENSE|LICENCE|NOTICE|AUTHORS|COPYRIGHT|LGPL|GPL|BSD)([.\-]|$)", p.name, re.I)
            or (p.suffix == ".rb" and p.stem in {x.rsplit("-", 1)[0] for x in PACKAGES})):
            return "third-party-text"
    return None


def execute(*args: str | Path) -> str:
    return subprocess.run([str(a) for a in args], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def audit_app(app: Path) -> dict:
    if app.is_symlink() or not app.is_dir():
        raise ValueError("Application must be a regular directory")
    inventory = []
    bad_files = []
    bad_links = []
    architectures = {}
    categories = {}
    # This is a read-only audit of a specific app, not a source-export traversal.
    for path in sorted(app.rglob("*")):
        name = path.relative_to(app).as_posix()
        if path.is_symlink():
            bad_files.append({"file": name, "reason": "symlink"})
            continue
        if path.is_dir():
            continue
        if not path.is_file():
            bad_files.append({"file": name, "reason": "not a regular file"})
            continue
        data = path.read_bytes()
        category = approved_category(name)
        inventory.append({"file": name, "bytes": len(data), "sha256": digest(data)})
        if category is None:
            bad_files.append({"file": name, "reason": "not on independent bundle allowlist"})
            continue
        categories[category] = categories.get(category, 0) + 1
        if category == "host-macho":
            if data[:4] not in MACHO:
                bad_files.append({"file": name, "reason": "expected host Mach-O"})
                continue
            arch = execute("/usr/bin/lipo", "-archs", path).strip()
            architectures[arch] = architectures.get(arch, 0) + 1
            if arch != "arm64":
                bad_files.append({"file": name, "reason": "not ARM64-only"})
            for line in execute("/usr/bin/otool", "-L", path).splitlines()[1:]:
                dependency = line.strip().split(" (compatibility version", 1)[0]
                if dependency.startswith(("/System/Library/", "/usr/lib/")):
                    continue
                if dependency.startswith("@loader_path/"):
                    target = (path.parent / dependency[len("@loader_path/"):]).resolve()
                    if app.resolve() not in target.parents or not target.is_file():
                        bad_links.append({"file": name, "dependency": dependency, "reason": "missing or outside app"})
                else:
                    # Avoid storing private builder paths in the shareable audit report.
                    bad_links.append({"file": name, "dependency_name": Path(dependency).name,
                                      "reason": "external non-system install name"})
        elif category == "brand-image":
            try:
                validate_brand_png(data)
            except ValueError as exc:
                bad_files.append({"file": name, "reason": str(exc)})
        elif category not in {"firmware", "linux-image"}:
            if data[:4] in FORBIDDEN_MAGICS or data[:2] == b"MZ" or b"\x00" in data:
                bad_files.append({"file": name, "reason": "binary in text/metadata allowlist"})
            if re.search(rb"(?m)^-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----", data):
                bad_files.append({"file": name, "reason": "private key material"})
    required = ROOT_BUNDLE_FILES | {"Contents/MacOS/" + x for x in PRODUCTS}
    required |= {"Contents/Resources/interface/keybridge.html", "Contents/Resources/interface/keybridge.js",
                 "Contents/Resources/interface/ingvar-consulting.png"}
    required |= {"Contents/Resources/runtime/bin/" + x for x in RUNTIME_EXECUTABLES}
    required |= {"Contents/Resources/runtime/lib/" + x for x in RUNTIME_LIBRARIES}
    required |= {"Contents/Resources/runtime/share/qemu/" + x for x in FIRMWARE}
    required |= {"Contents/Resources/guest/" + x for x in GUEST}
    required |= {"Contents/Resources/base/" + x for x in BASE_IMAGES | BASE_TEXT}
    present = {entry["file"] for entry in inventory}
    for name in sorted(required - present):
        bad_files.append({"file": name, "reason": "required bundle file missing"})
    manifest_path = app / "Contents/Resources/build-inventory.json"
    manifest = json.loads(manifest_path.read_text())
    expected_runtime = {name[len("Contents/Resources/"):] for name in required if "/runtime/" in name}
    recorded_runtime = {item["file"] for item in manifest.get("runtime_files", [])}
    if recorded_runtime != expected_runtime:
        bad_files.append({"file": "Contents/Resources/build-inventory.json", "reason": "runtime manifest differs from independent allowlist"})
    if manifest.get("proprietary_components_included") is not False:
        bad_files.append({"file": "Contents/Resources/build-inventory.json", "reason": "unexpected proprietary-components flag"})
    base_manifest = json.loads((app/"Contents/Resources/base/manifest.json").read_text())
    if base_manifest.get("proprietary_components_included") is not False or base_manifest.get("private_keys_included") is not False:
        bad_files.append({"file":"base/manifest.json", "reason":"base must contain only open components and no private keys"})
    for name in BASE_IMAGES | (BASE_TEXT - {"manifest.json"}):
        if base_manifest.get("files", {}).get(name) != digest((app/"Contents/Resources/base"/name).read_bytes()):
            bad_files.append({"file":"base/"+name, "reason":"base inventory mismatch"})
    signature = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    tree = "".join(entry["file"] + "\0" + entry["sha256"] + "\n" for entry in inventory).encode()
    return {"app": app.name, "passed": not bad_files and not bad_links and signature,
            "read_only": True, "file_count": len(inventory), "bytes": sum(x["bytes"] for x in inventory),
            "categories": categories, "architectures": architectures, "bad_links": bad_links,
            "bad_files": bad_files, "code_signature_valid": signature,
            "tree_sha256": digest(tree),
            "audit_scope": "independent path/type/architecture/linkage allowlist; only bundled open Linux preimage; no installers, proprietary binaries, user VM disks, private keys or user logs permitted"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=BUILD_ROOT / "artifacts/keybridge-source.zip")
    parser.add_argument("--app", type=Path, default=Path.home() / "Applications/KeyBridge.app")
    parser.add_argument("--audit-output", type=Path, default=BUILD_ROOT / "artifacts/keybridge-audit.json")
    parser.add_argument("--source-only", action="store_true", help="Export source without claiming an application audit")
    args = parser.parse_args()
    if BUILD_ROOT == ROOT or ROOT in BUILD_ROOT.parents:
        raise ValueError("KEYBRIDGE_BUILD_ROOT must remain outside the source directory")
    args.audit_output = args.audit_output.expanduser().absolute()
    resolved_audit = args.audit_output.resolve()
    if resolved_audit == ROOT or ROOT in resolved_audit.parents:
        raise ValueError("Audit output must remain outside the source directory")
    archive = export_source(args.output.expanduser().absolute())
    app = None if args.source_only else audit_app(args.app.expanduser().absolute())
    result = {"source_archive": archive, "application_audit": app}
    args.audit_output.parent.mkdir(parents=True, exist_ok=True)
    if args.audit_output.is_symlink():
        raise ValueError("Audit output must not be a symlink")
    args.audit_output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"archive": {key: archive[key] for key in ("file", "file_count", "bytes", "sha256")},
                     "app": None if app is None else {key: app[key] for key in ("app", "passed", "file_count", "architectures", "bad_links", "bad_files", "code_signature_valid", "tree_sha256")}}, indent=2))
    if app is not None and not app["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print("Archive/audit failed: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
