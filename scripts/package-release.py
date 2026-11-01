#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Package an audited macOS preview and its complete companion sources.

This creates local artifacts only. It never publishes, changes Gatekeeper,
registers login items, or starts the user's VM.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return stream_digest(stream)


def stream_digest(stream) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def run(*args: str | Path) -> None:
    subprocess.run([str(arg) for arg in args], check=True)


def load_auditor():
    spec = importlib.util.spec_from_file_location("keybridge_archive", ROOT / "scripts/source-archive.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package_inventory(app: Path, kind: str) -> set[tuple[str, str, str]]:
    resources = app / "Contents/Resources"
    if kind == "runtime":
        return {("runtime", p["name"], p["version"])
                for p in json.loads((resources / "ThirdParty/packages.json").read_text())}
    expected = set()
    for line in (resources / "base/alpine-packages.txt").read_text().splitlines():
        value = line.split(" - ", 1)[0]
        match = re.fullmatch(r"(.+)-([0-9][^-]*-r[0-9]+)", value)
        if not match:
            raise ValueError("Unrecognized Alpine package: " + value)
        expected.add(("alpine", match[1], match[2]))
    for line in (resources / "base/notices/debian-packages.txt").read_text().splitlines():
        name, version = line.split()
        expected.add(("debian", name, version))
    return expected


def validate_sources(path: Path, kind: str, expected: set[tuple[str, str, str]]) -> dict:
    """Check coverage, file integrity and package-to-source links independently."""
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate source archive entries")
        for name in names:
            parts = PurePosixPath(name)
            if parts.is_absolute() or ".." in parts.parts or "\\" in name:
                raise ValueError("Unsafe source archive path")
        manifest = json.loads(archive.read("manifest.json"))
        if manifest.get("schema") != 1 or manifest.get("kind") != kind or manifest.get("complete") is not True:
            raise ValueError("Incomplete corresponding sources: " + kind)
        packages = manifest.get("packages", [])
        actual = {(p.get("distribution", "runtime"), p["name"], p["version"]) for p in packages}
        if actual != expected or len(packages) != len(actual):
            raise ValueError("Corresponding-source coverage differs from the application: " + kind)
        files = manifest.get("files", [])
        file_names = {entry["path"] for entry in files}
        present = {name for name in names if not name.endswith("/")}
        if len(file_names) != len(files) or present != file_names | {"manifest.json"}:
            raise ValueError("Unrecorded or missing source archive files")
        for package in packages:
            sources = package.get("source_files", [])
            if not sources or not set(sources) <= file_names:
                raise ValueError("Package has no delivered sources: " + package["name"])
        for entry in files:
            info = archive.getinfo(entry["path"])
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("Source archive links are not accepted")
            with archive.open(info) as stream:
                checksum = stream_digest(stream)
            if info.file_size != entry["bytes"] or checksum != entry["sha256"]:
                raise ValueError("Corrupt corresponding source: " + entry["path"])
    return {"kind": kind, "packages": len(packages), "files": len(files), "complete": True}


def validate_source_binding(path: Path, kind: str, app: Path) -> None:
    """Bind source provenance to this base image, firmware and installed recipes."""
    resources = app / "Contents/Resources"
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        if kind == "guest":
            base = resources / "base"
            built = json.loads((base / "manifest.json").read_text())
            if manifest.get("base_build_id") != built["build_id"]:
                raise ValueError("Guest sources belong to a different base build")
            for name in ("manifest.json", "alpine-packages.txt", "alpine-package-details.txt"):
                if archive.read("metadata/base-" + name) != (base / name).read_bytes():
                    raise ValueError("Guest source inventory differs from the packaged base")
        else:
            firmware = resources / "runtime/share/qemu"
            evidence = manifest.get("firmware_evidence", {})
            if set(evidence) != {p.name for p in firmware.iterdir() if p.is_file()}:
                raise ValueError("Firmware source coverage differs from the application")
            delivered = {entry["path"] for entry in manifest["files"]}
            for name, entry in evidence.items():
                if (entry["binary_sha256"] != sha256(firmware / name)
                        or entry.get("source_archive") not in delivered or not entry.get("source_paths")):
                    raise ValueError("Firmware source evidence belongs to different binaries")
            notices = resources / "ThirdParty"
            for folder in notices.iterdir():
                if folder.is_dir():
                    for source in folder.iterdir():
                        if archive.read("recipes/" + folder.name + "/" + source.name) != source.read_bytes():
                            raise ValueError("Source recipe or receipt differs from the packaged runtime")


def instructions(version: str) -> str:
    return f"""KeyBridge {version}

Для Mac с Apple Silicon и macOS 27 или новее.

1. Перетащите KeyBridge в папку «Программы».
2. Извлеките образ диска и откройте KeyBridge из «Программ».
3. Если macOS заблокирует первый запуск, откройте «Системные настройки» →
   «Конфиденциальность и безопасность» и разрешите открытие KeyBridge.
   Это предварительный выпуск без Developer ID и нотариализации Apple.
   Инструкция Apple: https://support.apple.com/102445
4. Выберите в KeyBridge свои установщики: полный дистрибутив 1С для Linux
   x86-64 (.run) и драйвер HASP aksusbd для Debian/Ubuntu amd64 (.deb).
   Ссылки на сайты производителей есть в приложении.
5. Подключите USB-ключ. Клиент 1С для macOS должен быть установлен отдельно.

Homebrew, Docker и Python на вашем Mac не нужны.
Запуск KeyBridge при входе в систему в этой сборке недоступен.
Автоматическая проверка пока не подтверждает, что именно её запуск 1С
получил аппаратную лицензию. Проверяйте работу в своей базе 1С.

Код, лицензии и соответствующие исходники внешних компонентов:
https://github.com/IngvarConsulting/keybridge/releases/tag/v{version}

Если заменяете прежнюю сборку, сначала выберите в ней «Выключить и выйти».
Ваши установщики, настройки и рабочий диск хранятся отдельно от приложения.
"""


def boot_open_base(app: Path, directory: Path) -> None:
    """Exercise bundled TCG/kernel/disk at 128 MiB, without USB or networking."""
    resources = app / "Contents/Resources"
    base = resources / "base"
    log = directory / "boot.log"
    args = [str(resources / "runtime/bin/qemu-system-x86_64"),
            "-L", str(resources / "runtime/share/qemu"),
            "-machine", "q35", "-accel", "tcg", "-m", "128", "-smp", "1",
            "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none",
            "-snapshot", "-drive", f"file={base / 'alpine.qcow2'},if=virtio,format=qcow2",
            "-kernel", str(base / "vmlinuz-virt"), "-initrd", str(base / "initramfs-virt"),
            "-append", "root=/dev/vda rw console=ttyS0 modules=ext4,virtio_blk"]
    with log.open("wb") as output:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                contents = log.read_bytes()
                if b"keybridge-alpine login:" in contents:
                    return
                if process.poll() is not None:
                    break
                time.sleep(0.25)
            raise ValueError("Bundled Alpine did not reach its login prompt at 128 MiB: " +
                             log.read_text(errors="replace")[-3000:])
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--version", required=True, help="Preview tag version, e.g. 0.1.0-beta.1")
    parser.add_argument("--runtime-sources", type=Path, required=True)
    parser.add_argument("--guest-sources", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-beta\.[1-9][0-9]*", args.version):
        raise ValueError("This packager creates explicit beta releases only")
    app, output = args.app.expanduser().resolve(), args.output.expanduser().resolve()
    if output == ROOT or ROOT in output.parents or output.exists():
        raise ValueError("Output must be a new directory outside the repository")
    dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)
    if dirty.strip():
        raise ValueError("Commit the reviewed release sources before packaging")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"] != args.version.split("-", 1)[0]
            or info["LSMinimumSystemVersion"] != "27.0"
            or info.get("KeyBridgeLoginLaunchSupported") is not False):
        raise ValueError("Application version, minimum macOS or signing mode differs from preview instructions")
    auditor = load_auditor()
    audit = auditor.audit_app(app)
    if not audit["passed"]:
        raise ValueError("Application audit failed: " + json.dumps(audit))
    build = json.loads((app / "Contents/Resources/build-inventory.json").read_text())
    for name, expected_hash in build["sources_sha256"].items():
        if sha256(ROOT / name) != expected_hash:
            raise ValueError("Application was built from different source: " + name)
    for name in ("LICENSE", "THIRD_PARTY.md"):
        if (ROOT / name).read_bytes() != (app / "Contents/Resources" / name).read_bytes():
            raise ValueError("Bundled notice differs from published source: " + name)
    coverage = [validate_sources(args.runtime_sources, "runtime", package_inventory(app, "runtime")),
                validate_sources(args.guest_sources, "guest", package_inventory(app, "guest"))]
    validate_source_binding(args.runtime_sources, "runtime", app)
    validate_source_binding(args.guest_sources, "guest", app)
    output.mkdir(parents=True)
    stem = "KeyBridge-" + args.version
    dmg = output / (stem + "-macOS-arm64.dmg")
    with tempfile.TemporaryDirectory(prefix="keybridge-dmg-", dir=output.parent) as temporary:
        stage = Path(temporary) / "content"
        stage.mkdir()
        run("/usr/bin/ditto", app, stage / "KeyBridge.app")
        (stage / "Applications").symlink_to("/Applications")
        (stage / "Установка.txt").write_text(instructions(args.version))
        run("/usr/bin/hdiutil", "create", "-volname", "KeyBridge " + args.version,
            "-srcfolder", stage, "-format", "UDZO", "-ov", dmg)
        run("/usr/bin/hdiutil", "verify", dmg)
        mount = Path(temporary) / "mounted"
        mount.mkdir()
        run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
        try:
            installed = Path(temporary) / "installed/KeyBridge.app"
            run("/usr/bin/ditto", mount / "KeyBridge.app", installed)
            installed_audit = auditor.audit_app(installed)
            if not installed_audit["passed"] or installed_audit["tree_sha256"] != audit["tree_sha256"]:
                raise ValueError("Application changed during DMG installation")
            for binary in ("qemu-system-x86_64", "qemu-img"):
                run(installed / "Contents/Resources/runtime/bin" / binary, "--version")
            boot_open_base(installed, Path(temporary))
            with tempfile.TemporaryDirectory(prefix="keybridge-empty-runtime-") as runtime:
                environment = dict(os.environ, KEYBRIDGE_RUNTIME=runtime, PATH="/usr/bin:/bin:/usr/sbin:/sbin")
                result = subprocess.run([str(installed / "Contents/MacOS/KeyBridgeControl"), "status"],
                                        env=environment, check=True, text=True, capture_output=True, timeout=30)
                state = json.loads(result.stdout)
                if state.get("stale") is not True:
                    raise ValueError("Isolated first-run check did not use an empty runtime")
        finally:
            run("/usr/bin/hdiutil", "detach", mount)
    source = auditor.export_source(output / (stem + "-source.zip"))
    for kind, path in (("runtime", args.runtime_sources), ("guest", args.guest_sources)):
        shutil.copyfile(path, output / (stem + "-" + kind + "-sources.zip"))
    # GitHub normalizes non-ASCII asset filenames; keep published names stable.
    (output / "INSTALL.txt").write_text(instructions(args.version))
    report = {"version": args.version, "source_revision": revision,
              "application": audit, "corresponding_sources": coverage,
              "source": {k: source[k] for k in ("file_count", "bytes", "sha256")},
              "dmg_verified": True, "installed_copy_verified": True,
              "isolated_control_launch": True, "open_guest_boot_128_mib": True,
              "hardware_license_tested": False, "signature": "ad-hoc", "notarized": False}
    (output / "release-audit.json").write_text(json.dumps(report, indent=2) + "\n")
    artifacts = sorted(p for p in output.iterdir() if p.is_file())
    (output / "SHA256SUMS.txt").write_text("".join(f"{sha256(p)}  {p.name}\n" for p in artifacts))
    print(json.dumps({"output": str(output), "version": args.version,
                      "artifacts": [{"name": p.name, "bytes": p.stat().st_size} for p in artifacts]}, indent=2))


if __name__ == "__main__":
    main()
