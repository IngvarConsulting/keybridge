#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build a self-contained ARM64 application. Python/Homebrew are build tools only.

No user installer, VM, SSH identity, log, or 1C/Thales component is copied.
The default is ad-hoc signing; --sign-identity enables a Keychain identity.
Neither mode notarizes the app. Public previews disclose this limitation.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
BUILD_ROOT = Path(os.environ.get("KEYBRIDGE_BUILD_ROOT", str(Path.home() / "Library/Caches/KeyBridgeDevelopment"))).expanduser().resolve()
WORK = BUILD_ROOT / "build"
SYSTEM_PREFIXES = ("/System/Library/", "/usr/lib/")
PRODUCTS = ("KeyBridgeApp", "KeyBridgeAgent", "KeyBridgeControl", "KeyBridgeConfigure")
PRODUCT_IDENTIFIERS = {"KeyBridgeApp": "pro.keybridge.pilot", "KeyBridgeAgent": "pro.keybridge.pilot.agent",
                       "KeyBridgeControl": "pro.keybridge.pilot.control", "KeyBridgeConfigure": "pro.keybridge.pilot.configure"}


def run(*args: str | Path, capture: bool = False) -> str:
    result = subprocess.run([str(x) for x in args], check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else ""


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def assert_arm64(path: Path) -> None:
    archs = run("/usr/bin/lipo", "-archs", path, capture=True).strip().split()
    if archs != ["arm64"]:
        raise RuntimeError(f"Only native ARM64 is allowed: {path.name}: {archs}")


def dependencies(path: Path) -> list[str]:
    lines = run("/usr/bin/otool", "-L", path, capture=True).splitlines()[1:]
    return [line.strip().split(" (compatibility version", 1)[0] for line in lines]


def rpaths(path: Path) -> list[str]:
    return re.findall(r"cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.*?) \(offset",
                      run("/usr/bin/otool", "-l", path, capture=True))


def resolve_dependency(value: str, source: Path, executable: Path) -> Path:
    if value.startswith("@loader_path/"):
        return (source.parent / value[len("@loader_path/"):]).resolve(strict=True)
    if value.startswith("@executable_path/"):
        return (executable.parent / value[len("@executable_path/"):]).resolve(strict=True)
    if value.startswith("@rpath/"):
        suffix = value[len("@rpath/"):]
        for entry in rpaths(source) + rpaths(executable):
            entry = entry.replace("@loader_path", str(source.parent)).replace("@executable_path", str(executable.parent))
            candidate = Path(entry) / suffix
            if candidate.is_file():
                return candidate.resolve(strict=True)
        raise RuntimeError(f"Unresolved dependency {value} in {source}")
    if not value.startswith("/"):
        raise RuntimeError(f"Unexpected install name {value} in {source}")
    return Path(value).resolve(strict=True)


def keg_for(path: Path) -> Path:
    # Pin the actual installed package, not the mutable /opt/homebrew/opt symlink.
    for parent in path.parents:
        if (parent / "INSTALL_RECEIPT.json").is_file():
            return parent
    raise RuntimeError(f"Cannot establish Homebrew provenance for {path}")


def record_package(keg: Path, notices: Path) -> dict:
    name, version = keg.parent.name, keg.name
    target = notices / f"{name}-{version}"
    target.mkdir(parents=True, exist_ok=True)
    receipt = json.loads((keg / "INSTALL_RECEIPT.json").read_text())
    # Keep build provenance without the builder's home-directory cache location.
    receipt.get("source", {}).pop("path", None)
    (target / "INSTALL_RECEIPT.json").write_text(json.dumps(receipt, indent=2) + "\n")
    copied = []
    for source in sorted(keg.iterdir()):
        if source.is_file() and re.match(r"^(COPYING|LICENSE|LICENCE|NOTICE|AUTHORS|COPYRIGHT|LGPL|GPL|BSD)([.\-]|$)", source.name, re.I):
            shutil.copy2(source, target / source.name)
            copied.append(source.name)
    formulas = sorted((keg / ".brew").glob("*.rb"))
    for source in formulas:
        shutil.copy2(source, target / source.name)
    if (keg / "sbom.spdx.json").is_file():
        shutil.copy2(keg / "sbom.spdx.json", target / "sbom.spdx.json")
    return {"name": name, "version": version, "license_files": copied,
            "formula_files": [p.name for p in formulas],
            "receipt": str((target / "INSTALL_RECEIPT.json").relative_to(notices.parent))}


def bundle_runtime(resources: Path, source_qemu: Path, source_img: Path, entitlements: Path, identity: str) -> list[dict]:
    runtime = resources / "runtime"
    bin_dir, lib_dir = runtime / "bin", runtime / "lib"
    bin_dir.mkdir(parents=True)
    lib_dir.mkdir()
    notices = resources / "ThirdParty"
    notices.mkdir(exist_ok=True)
    sources: dict[Path, Path] = {}
    packages: dict[Path, dict] = {}
    queue: list[tuple[Path, Path, Path]] = []
    for executable in (source_qemu.resolve(strict=True), source_img.resolve(strict=True)):
        target = bin_dir / executable.name
        shutil.copy2(executable, target)
        target.chmod(0o755)
        sources[executable] = target
        queue.append((executable, target, executable))
    inventory = []
    while queue:
        source, target, executable = queue.pop(0)
        assert_arm64(source)
        # install_name_tool changes invalidate the original signature; re-sign after relocation.
        subprocess.run(["/usr/bin/codesign", "--remove-signature", str(target)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        keg = keg_for(source)
        if keg not in packages:
            packages[keg] = record_package(keg, notices)
        source_dependencies = dependencies(source)
        for value in source_dependencies:
            if value.startswith(SYSTEM_PREFIXES):
                continue
            dependency = resolve_dependency(value, source, executable)
            if dependency == source:
                continue  # dylib's own LC_ID_DYLIB
            if dependency not in sources:
                library_target = lib_dir / dependency.name
                if library_target.exists():
                    raise RuntimeError(f"Dylib basename collision: {dependency.name}")
                shutil.copy2(dependency, library_target)
                library_target.chmod(0o755)
                sources[dependency] = library_target
                queue.append((dependency, library_target, executable))
            relative = os.path.relpath(sources[dependency], target.parent)
            run("/usr/bin/install_name_tool", "-change", value, "@loader_path/" + relative, target)
        if target.suffix == ".dylib":
            run("/usr/bin/install_name_tool", "-id", "@loader_path/" + target.name, target)
        # Do not leave fallback search paths into the builder's Homebrew installation.
        for value in rpaths(target):
            if value.startswith("/opt/homebrew/") or value.startswith("/usr/local/"):
                run("/usr/bin/install_name_tool", "-delete_rpath", value, target)
        inventory.append({"file": str(target.relative_to(resources)),
                          "source_sha256": sha256(source),
                          "package": f"{keg.parent.name}-{keg.name}"})
    firmware_source = keg_for(source_qemu.resolve()) / "share" / "qemu"
    firmware_target = runtime / "share" / "qemu"
    # Only firmware used by this x86_64 q35 VM. Explicit list avoids shipping unrelated blobs.
    firmware_target.mkdir(parents=True)
    for name in ("bios-256k.bin", "bios.bin", "kvmvapic.bin", "vgabios-stdvga.bin", "efi-virtio.rom", "linuxboot_dma.bin"):
        source = firmware_source / name
        if source.is_file():
            shutil.copy2(source, firmware_target / name)
            inventory.append({"file": str((firmware_target / name).relative_to(resources)),
                              "source_sha256": sha256(source), "package": "qemu-pc-bios"})
    if not (firmware_target / "bios-256k.bin").is_file():
        raise RuntimeError("QEMU SeaBIOS firmware is missing")
    for source, target in sources.items():
        assert_arm64(target)
        for value in dependencies(target):
            if not value.startswith(SYSTEM_PREFIXES + ("@loader_path/",)):
                raise RuntimeError(f"External runtime linkage remains: {target.name}: {value}")
        arguments = ["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none"]
        if target.name == "qemu-system-x86_64":
            arguments += ["--options", "runtime", "--entitlements", str(entitlements)]
        run(*arguments, target)
    (notices / "packages.json").write_text(json.dumps(list(packages.values()), indent=2) + "\n")
    return inventory


def validate_png(data: bytes, *, dimensions: tuple[int, int] | None = None,
                 maximum: int = 1024 * 1024) -> None:
    """Validate the two explicitly named image sources before bundling."""
    if len(data) > maximum or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("Invalid PNG")
    offset, chunks, image_data = 8, [], False
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data) or not re.fullmatch(rb"[A-Za-z]{4}", kind):
            raise RuntimeError("Invalid brand PNG chunk")
        payload = data[offset + 8:end - 4]
        if zlib.crc32(kind + payload) & 0xffffffff != struct.unpack_from(">I", data, end - 4)[0]:
            raise RuntimeError("Invalid brand PNG checksum")
        if not chunks:
            if kind != b"IHDR" or length != 13:
                raise RuntimeError("Missing brand PNG header")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8}, 4: {8, 16}, 6: {8, 16}}
            valid_size = ((width, height) == dimensions if dimensions is not None
                          else width == height and 1024 <= width <= 4096)
            if (not valid_size or depth not in depths.get(color, set())
                    or compression != 0 or filtering != 0 or interlace not in (0, 1)):
                raise RuntimeError("Unexpected brand PNG header")
        elif kind == b"IHDR":
            raise RuntimeError("Duplicate brand PNG header")
        chunks.append(kind)
        if kind == b"IDAT" and length:
            image_data = True
        offset = end
        if kind == b"IEND":
            if length or offset != len(data) or not image_data:
                raise RuntimeError("Invalid brand PNG ending")
            return
    raise RuntimeError("Incomplete brand PNG")


def validate_brand_png(data: bytes) -> None:
    validate_png(data, dimensions=(1240, 220))


def bundle_app_icon(resources: Path) -> None:
    source = ROOT / "Resources/app-icon.png"
    if source.is_symlink():
        raise RuntimeError("Application icon must not be a symlink")
    validate_png(source.read_bytes(), maximum=8 * 1024 * 1024)
    with tempfile.TemporaryDirectory(prefix="keybridge-icon-", dir=resources.parent) as folder:
        iconset = Path(folder) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                run("/usr/bin/sips", "-z", str(size * scale), str(size * scale), source,
                    "--out", iconset / f"icon_{size}x{size}{suffix}.png", capture=True)
        run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns")


def bundle_source_resources(resources: Path) -> None:
    # Source scripts/manifests only. The broad project tree is never copied into the app.
    interface = ROOT / "Resources" / "interface"
    if not (interface / "keybridge.html").is_file():
        raise RuntimeError("Missing KeyBridge application interface")
    for source in sorted(interface.rglob("*")):
        if source.is_symlink():
            raise RuntimeError(f"Interface resource symlinks are not allowed: {source}")
        if source.is_file():
            data = source.read_bytes()
            if source.relative_to(interface).as_posix() == "ingvar-consulting.png":
                validate_brand_png(data)
            elif source.suffix not in (".html", ".css", ".js") or b"\x00" in data:
                raise RuntimeError(f"Unexpected interface resource: {source.name}")
            target = resources / "interface" / source.relative_to(interface)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    guest = ROOT / "Resources" / "guest"
    if guest.exists():
        for source in sorted(guest.rglob("*")):
            if source.is_symlink():
                raise RuntimeError(f"Resource symlinks are not allowed: {source}")
            if source.is_file():
                if source.suffix not in (".sh", ".py", ".json", ".xml", ".service", ".conf", ".cfg", ".txt"):
                    raise RuntimeError(f"Unexpected guest resource: {source.name}")
                if b"\x00" in source.read_bytes():
                    raise RuntimeError(f"Binary guest resource is forbidden: {source.name}")
                target = resources / "guest" / source.relative_to(guest)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
    for name in ("image.json",):
        source = ROOT / "Resources" / name
        if source.is_file():
            shutil.copy2(source, resources / name)
    for name in ("LICENSE", "THIRD_PARTY.md"):
        source = ROOT / name
        if source.is_file():
            shutil.copy2(source, resources / name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--runtime-only", action="store_true", help="Build/test relocated QEMU before Swift targets are ready")
    parser.add_argument("--output", type=Path, default=WORK / "KeyBridge.app")
    parser.add_argument("--sign-identity", default="-", help="Local Keychain signing identity; default ad-hoc does not support login launch")
    parser.add_argument("--version", default="0.1.0", help="Three-part application version")
    parser.add_argument("--build-number", default="1", help="Positive application build number")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version) or not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        raise RuntimeError("Expected --version major.minor.patch and a positive --build-number")
    if BUILD_ROOT == ROOT or ROOT in BUILD_ROOT.parents:
        raise RuntimeError("KEYBRIDGE_BUILD_ROOT must remain outside the source directory")
    if os.uname().machine != "arm64" or sys.platform != "darwin":
        raise RuntimeError("Run the build natively on an Apple Silicon Mac")
    destination = args.output.expanduser().resolve()
    if destination.suffix != ".app":
        raise RuntimeError("Output must be an .app bundle")
    if ROOT in destination.parents or destination == ROOT:
        raise RuntimeError("Build output must remain outside the source directory")
    destination.parent.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    source_paths = ([ROOT / "Package.swift", ROOT / "Resources/app-icon.png"] + sorted((ROOT / "Sources").rglob("*.swift"))
                    + sorted((ROOT / "Resources/guest").glob("*.*"))
                    + sorted((ROOT / "Resources/interface").rglob("*.*")))
    source_hashes = {str(path.relative_to(ROOT)): sha256(path) for path in source_paths if path.is_file()}
    if not args.runtime_only and not args.skip_build:
        run("/usr/bin/xcrun", "swift", "build", "--package-path", ROOT,
            "--scratch-path", WORK / "swift", "-c", "release", "--arch", "arm64", "-debug-info-format", "none")
    bin_path = Path(run("/usr/bin/xcrun", "swift", "build", "--package-path", ROOT,
                        "--scratch-path", WORK / "swift", "-c", "release", "--arch", "arm64",
                        "--show-bin-path", capture=True).strip()) if not args.runtime_only else WORK / "swift"
    if not args.runtime_only:
        for name in PRODUCTS:
            if not (bin_path / name).is_file():
                raise RuntimeError(f"Missing Swift product: {bin_path / name}")
    if source_hashes != {str(path.relative_to(ROOT)): sha256(path) for path in source_paths if path.is_file()}:
        raise RuntimeError("Source files changed during compilation; refusing an ambiguous build")
    base_spec = importlib.util.spec_from_file_location("keybridge_base_builder", ROOT/"scripts/build-alpine-base.py")
    base_module = importlib.util.module_from_spec(base_spec)
    base_spec.loader.exec_module(base_module)
    base_folder = base_module.build()
    stage_parent = Path(tempfile.mkdtemp(prefix=".keybridge-stage-", dir=destination.parent))
    app = stage_parent / destination.name
    contents = app / "Contents"
    resources = contents / "Resources"
    (contents / "MacOS").mkdir(parents=True)
    resources.mkdir()
    entitlements = stage_parent / "qemu-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.allow-jit": True, "com.apple.security.cs.disable-library-validation": True}))
    info = {"CFBundleIdentifier": "pro.keybridge.pilot", "CFBundleName": "KeyBridge",
            "CFBundleDisplayName": "KeyBridge", "CFBundleExecutable": "KeyBridgeApp",
            "CFBundleIconFile": "AppIcon.icns",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": args.version,
            "CFBundleVersion": args.build_number, "LSMinimumSystemVersion": "27.0",
            "LSUIElement": False, "NSHighResolutionCapable": True,
            "KeyBridgeLoginLaunchSupported": args.sign_identity != "-",
            "NSPrincipalClass": "NSApplication", "NSHumanReadableCopyright": "KeyBridge contributors; own code MIT"}
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (contents / "PkgInfo").write_bytes(b"APPL????")
    agent = contents / "Library" / "LaunchAgents" / "pro.keybridge.pilot.agent.plist"
    agent.parent.mkdir(parents=True)
    agent.write_bytes(plistlib.dumps({"Label": "pro.keybridge.pilot.agent",
          "BundleProgram": "Contents/MacOS/KeyBridgeAgent", "RunAtLoad": True,
          # Licensing RPCs and user-requested checks must stay responsive.
          # This file-queue pilot cannot use XPC-driven Adaptive promotion.
          "ProcessType": "Interactive", "ThrottleInterval": 10,
          "ExitTimeOut": 30}))
    inventory = bundle_runtime(resources, Path("/opt/homebrew/bin/qemu-system-x86_64"),
                               Path("/opt/homebrew/bin/qemu-img"), entitlements, args.sign_identity)
    bundle_source_resources(resources)
    bundle_app_icon(resources)
    shutil.copytree(base_folder, resources/"base")
    if not args.runtime_only:
        for name in PRODUCTS:
            target = contents / "MacOS" / name
            shutil.copy2(bin_path / name, target)
            target.chmod(0o755)
            assert_arm64(target)
            run("/usr/bin/codesign", "--force", "--sign", args.sign_identity,
                "--identifier", PRODUCT_IDENTIFIERS[name], "--timestamp=none", target)
    (resources / "build-inventory.json").write_text(json.dumps({"local_pilot": True,
        "signature": "ad-hoc" if args.sign_identity == "-" else "keychain-identity", "notarized": False, "runtime_only": args.runtime_only,
        "architecture": "arm64", "runtime_files": inventory, "sources_sha256": source_hashes,
        "proprietary_components_included": False}, indent=2) + "\n")
    (resources / ".keybridge-build-marker").write_text("Generated by KeyBridge build-app.py\n")
    if not args.runtime_only:
        run("/usr/bin/codesign", "--force", "--sign", args.sign_identity, "--timestamp=none", app)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    # Headless executable smoke tests require no VM or physical key.
    run(resources / "runtime/bin/qemu-system-x86_64", "--version")
    run(resources / "runtime/bin/qemu-img", "--version")
    if destination.exists():
        marker = destination / "Contents/Resources/.keybridge-build-marker"
        if not marker.is_file():
            raise RuntimeError("Refusing to replace a bundle not created by this script")
        commands = run("/bin/ps", "-axo", "command=", capture=True)
        if str(destination / "Contents") in commands:
            raise RuntimeError("Quit this application and its agent/VM before replacing the bundle")
        backup = destination.with_name(destination.name + f".previous-{time.time_ns()}")
        destination.rename(backup)
    app.rename(destination)
    entitlements.unlink()
    stage_parent.rmdir()
    print(f"Built KeyBridge {args.version} ({args.build_number}): {destination}")
    print("Included open Alpine base; no 1C/Thales, private key, user VM or user log.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        print(f"Build failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
