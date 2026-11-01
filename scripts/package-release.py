#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Package an audited macOS preview with links to its source repository.

This creates local artifacts only. It never publishes, changes Gatekeeper,
registers login items, or starts the user's VM.
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
import subprocess
import tempfile
import time

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


def load_source_links():
    spec = importlib.util.spec_from_file_location("keybridge_source_links", ROOT / "scripts/component-sources.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
   Можно выбрать скачанные ZIP/tar-архивы без ручной распаковки.
   KeyBridge проверит компоненты сразу после выбора, до установки.
   Проверка установщика 1С может занять около двух минут; её можно отменить.
   Ссылки на сайты производителей есть в приложении.
5. Подключите USB-ключ. Клиент 1С для macOS должен быть установлен отдельно.

Homebrew, Docker и Python на вашем Mac не нужны.
Запуск KeyBridge при входе в систему в этой сборке недоступен.
Автоматическая проверка пока не подтверждает, что именно её запуск 1С
получил аппаратную лицензию. Проверяйте работу в своей базе 1С.

Код и скрипты сборки опубликованы в репозитории KeyBridge:
https://github.com/IngvarConsulting/keybridge/tree/v{version}
Ссылки на исходники версий внешних компонентов — в COMPONENT-SOURCES.md
на странице выпуска:
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
    output.mkdir(parents=True)
    sources = load_source_links().write_catalog(app, revision, output / "COMPONENT-SOURCES.md")
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
    # GitHub normalizes non-ASCII asset filenames; keep published names stable.
    (output / "INSTALL.txt").write_text(instructions(args.version))
    report = {"version": args.version, "source_revision": revision,
              "application": audit,
              "source_repository": "https://github.com/IngvarConsulting/keybridge/tree/" + revision,
              "component_sources": sources,
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
