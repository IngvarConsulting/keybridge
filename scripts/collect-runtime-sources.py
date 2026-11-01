#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Collect the corresponding sources of the app's actual Homebrew runtime.

No installed binary is substituted for a source archive. Every source download
must match the digest in the installed recipe. Unrecognised recipe constructs
fail closed, rather than silently producing an incomplete release attachment.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import time
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CACHE = Path.home() / "Library/Caches/KeyBridgeDevelopment/runtime-sources/downloads"
# This patch is supplied as a separate file by Homebrew. Its checksum is from
# the installed formula's Homebrew API metadata, not a checksum of a new patch.
# A changed recipe/patch needs a new provenance review.
LOCAL_PATCHES = {
    ("glib", "2.90.1", "Patches/glib/hardcoded-paths.diff"): {
        "sha256": "d846efd0bf62918350da94f850db33b0f8727fece9bfaf8164566e3094e80c97",
        "formula_sha256": "7352a67a6a1a15554d996d38886812e858bebbbcbf3985901724cab444ee3b3b",
        "url": "https://raw.githubusercontent.com/Homebrew/homebrew-core/1cf441a09f572566b1b7c4695a4d169d1177248a/Patches/glib/hardcoded-paths.diff",
    },
}
FIRMWARE_SOURCES = {
    "bios.bin": ["roms/seabios/Makefile", "roms/seabios/src/post.c", "roms/seabios/COPYING", "roms/seabios/.version", "roms/config.seabios-128k", "roms/Makefile"],
    "bios-256k.bin": ["roms/seabios/Makefile", "roms/seabios/src/post.c", "roms/seabios/COPYING", "roms/seabios/.version", "roms/config.seabios-256k", "roms/Makefile"],
    "vgabios-stdvga.bin": ["roms/seabios/Makefile", "roms/seabios/vgasrc/vgabios.c", "roms/seabios/COPYING", "roms/config.vga-stdvga", "roms/Makefile"],
    "efi-virtio.rom": ["roms/ipxe/src/Makefile", "roms/ipxe/src/drivers/net/virtio-net.c", "roms/ipxe/COPYING", "roms/Makefile"],
    "kvmvapic.bin": ["pc-bios/optionrom/kvmvapic.S", "pc-bios/optionrom/Makefile", "COPYING"],
    "linuxboot_dma.bin": ["pc-bios/optionrom/linuxboot_dma.c", "pc-bios/optionrom/Makefile", "COPYING"],
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def parse_source(text: str) -> tuple[list[str], str]:
    url = re.search(r'^\s*url "([^"\n]+)"', text, re.M)
    checksum = re.search(r'^\s*sha256 "([a-f0-9]{64})"', text, re.M)
    if not url or not checksum or url.start() > checksum.start():
        raise ValueError("Source recipe must have a literal URL and SHA-256")
    urls = [url[1]] + re.findall(r'^\s*mirror "([^"\n]+)"', text[url.end():checksum.start()], re.M)
    if any("#{" in value for value in urls):
        raise ValueError("Interpolated source URL needs explicit review")
    return [url for url in urls if url.startswith("https://")], checksum[1]


def recipe_downloads(name: str, version: str, formula: bytes) -> list[dict]:
    text = formula.decode("utf-8")
    urls, checksum = parse_source(text)
    records = [{"kind": "upstream", "urls": urls, "sha256": checksum}]
    # Resource and patch blocks have the same indentation at their closing end.
    for match in re.finditer(r'(?ms)^([ \t]*)resource "([^"\n]+)" do\n(.*?)^\1end\b', text):
        urls, checksum = parse_source(match[3])
        records.append({"kind": "resource", "resource": match[2], "urls": urls, "sha256": checksum})
    blocks = list(re.finditer(r'(?ms)^([ \t]*)patch do\n(.*?)^\1end\b', text))
    for block in blocks:
        local = re.search(r'^\s*file "([^"\n]+)"', block[2], re.M)
        if local:
            pin = LOCAL_PATCHES.get((name, version, local[1]))
            if not pin or hashlib.sha256(formula).hexdigest() != pin["formula_sha256"]:
                raise ValueError(f"Unreviewed Homebrew local patch for {name}: {local[1]}")
            records.append({"kind": "patch", "urls": [pin["url"]], "sha256": pin["sha256"], "recipe_path": local[1]})
        else:
            urls, checksum = parse_source(block[2])
            records.append({"kind": "patch", "urls": urls, "sha256": checksum})
    patch_lines = re.findall(r'^\s*patch\b[^\n]*', text, re.M)
    if len(patch_lines) != len(blocks) + text.count("patch :DATA"):
        raise ValueError(f"Unrecognised patch declaration in {name}")
    if "patch :DATA" in text and "\n__END__\n" not in text:
        raise ValueError(f"Inline patch is missing from {name}")
    for record in records:
        filename = Path(urllib.parse.urlparse(record["urls"][0]).path).name
        if not filename or filename in (".", ".."):
            raise ValueError("Source URL has no safe filename")
        record["path"] = f"sources/{name}-{version}/{filename}"
    if len({item["path"] for item in records}) != len(records):
        raise ValueError(f"Colliding source filenames for {name}")
    return records


def download(record: dict, cache: Path) -> Path:
    filename = Path(record["path"]).name
    target = cache / (record["sha256"] + "-" + filename)
    # Reuse a hand-downloaded archive only after the exact recipe hash check.
    legacy = cache / filename
    if not target.exists() and legacy.is_file() and digest(legacy) == record["sha256"]:
        shutil.copyfile(legacy, target)
    if target.is_file() and digest(target) == record["sha256"]:
        record["source_url"] = record["urls"][0]
        return target
    errors = []
    for url in record["urls"]:
        for attempt in range(3):
            partial = target.with_suffix(target.suffix + ".partial")
            try:
                request = urllib.request.Request(url, headers={"User-Agent": "KeyBridge-source-collector/1"})
                with urllib.request.urlopen(request, timeout=90) as response, partial.open("wb") as output:
                    shutil.copyfileobj(response, output, 1024 * 1024)
                if digest(partial) != record["sha256"]:
                    raise ValueError("download does not match the installed recipe SHA-256")
                partial.replace(target)
                record["source_url"] = url
                print(f"Downloaded {record['path']} ({target.stat().st_size} bytes)", flush=True)
                return target
            except Exception as exc:
                partial.unlink(missing_ok=True)
                errors.append(f"{url}: {exc}")
                if attempt != 2:
                    time.sleep(attempt + 1)
    raise RuntimeError("Cannot collect source: " + "; ".join(errors))


def firmware_evidence(qemu_source: Path, resources: Path, source_path: str) -> dict:
    firmware = resources / "runtime/share/qemu"
    actual = {path.name: digest(path) for path in firmware.iterdir() if path.is_file()}
    if set(actual) != set(FIRMWARE_SOURCES):
        raise ValueError("Firmware selection changed; corresponding-source coverage needs review")
    required = {path for paths in FIRMWARE_SOURCES.values() for path in paths}
    wanted = required | {"pc-bios/" + name for name in actual}
    found = {}
    # Stream once: seeking repeatedly inside a 140 MB xz archive is expensive.
    with tarfile.open(qemu_source, "r|*") as archive:
        for member in archive:
            relative = member.name.partition("/")[2]
            if relative in wanted and member.isfile():
                data = archive.extractfile(member).read()
                if not data:
                    raise ValueError(f"Empty QEMU source file: {relative}")
                found[relative] = hashlib.sha256(data).hexdigest()
    if wanted - found.keys():
        raise ValueError("QEMU source archive lacks firmware sources: " + ", ".join(sorted(wanted - found.keys())))
    result = {}
    for name, checksum in actual.items():
        if checksum != found["pc-bios/" + name]:
            raise ValueError(f"Bundled firmware differs from the verified QEMU source distribution: {name}")
        result[name] = {"binary_sha256": checksum, "source_archive": source_path,
                        "upstream_binary_path": "pc-bios/" + name,
                        "source_paths": FIRMWARE_SOURCES[name]}
    return result


README = """# KeyBridge macOS runtime corresponding sources

This companion archive contains the full upstream source archives for each
Homebrew package whose code is bundled in KeyBridge, the exact installed recipes,
their additional resources and patches, installation receipts and license files.
manifest.json maps packages to actual archive entries and records their digests.

QEMU's full release source tarball includes the SeaBIOS and iPXE source trees,
configuration files and build rules. The selected binary firmware files were
compared byte-for-byte with pc-bios/ from that same verified source distribution.
firmware_evidence in the manifest gives each firmware's source paths and rules.

To rebuild a Homebrew component, extract its upstream archive, and follow the
install method in recipes/<package>/<formula>.rb, including the patches,
resources, dependencies and flags recorded there. Inline :DATA patches are in
the formula itself. Local patches retain their recipe_path in the manifest.
The receipts and SPDX files describe the compiler and build platform. Homebrew
itself is available at https://github.com/Homebrew/brew .

KeyBridge does not modify QEMU or library implementation source. Its build-app.py
copies selected executables and dylibs, rewrites Mach-O paths to @loader_path,
and signs the results. That script and all application source are in the release's
KeyBridge source attachment and the tagged public repository. Run that script to
repeat the relocation after rebuilding dependencies.

LGPL libraries remain separate dynamic libraries in Contents/Resources/runtime/lib.
You may replace them with compatible rebuilt libraries and re-sign your modified
local app using an ad-hoc signature. The application code is MIT licensed; it does
not prohibit reverse engineering for debugging your modifications. For local
relinking, use build-app.py with your rebuilt Homebrew dependencies and the
default ad-hoc signing identity. No Developer ID key is needed to build a modified
local copy. Third-party components retain their respective included licenses.

No 1C/Thales installers, user VM disks, credentials or private keys are included.
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    args = parser.parse_args()
    app, output, cache = args.app.expanduser().resolve(), args.output.expanduser().resolve(), args.cache.expanduser().resolve()
    for path in (output, cache):
        if path == ROOT or ROOT in path.parents:
            raise ValueError("Downloaded source archives must remain outside the project")
    resources = app / "Contents/Resources"
    notices = resources / "ThirdParty"
    packages = json.loads((notices / "packages.json").read_text())
    inventory = json.loads((resources / "build-inventory.json").read_text())
    package_ids = {f"{item['name']}-{item['version']}" for item in packages}
    runtime_ids = {item["package"] for item in inventory["runtime_files"]} - {"qemu-pc-bios"}
    if runtime_ids != package_ids:
        raise ValueError("Bundle inventory and Homebrew package inventory disagree")
    cache.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    files, downloaded, collected = {}, [], []
    for package in packages:
        name, version = package["name"], package["version"]
        identity = f"{name}-{version}"
        folder = notices / identity
        formulas = package["formula_files"]
        if len(formulas) != 1:
            raise ValueError(f"Expected one installed formula for {identity}")
        formula = folder / formulas[0]
        records = recipe_downloads(name, version, formula.read_bytes())
        for record in records:
            record["package"] = identity
        downloaded.extend(records)
        recipe_paths = []
        for path in sorted(folder.iterdir()):
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"Unexpected notice entry in {identity}")
            archive_path = f"recipes/{identity}/{path.name}"
            files[archive_path] = {"local": path, "kind": "recipe-or-notice", "package": identity}
            recipe_paths.append(archive_path)
        collected.append({"name": name, "version": version,
                          "source_files": [record["path"] for record in records] + [f"recipes/{identity}/{formulas[0]}"],
                          "notice_files": recipe_paths})
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda record: download(record, cache), downloaded))
    for record, path in zip(downloaded, results):
        files[record["path"]] = {"local": path, **{key: value for key, value in record.items() if key not in ("path", "urls")}}
    qemu = next(record for record in downloaded if record["package"].startswith("qemu-") and record["kind"] == "upstream")
    evidence = firmware_evidence(files[qemu["path"]]["local"], resources, qemu["path"])
    manifest = {"schema": 1, "kind": "runtime", "complete": True,
                "packages": collected, "firmware_evidence": evidence, "files": []}
    temporary = output.with_name(output.name + ".partial")
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
            for name, entry in sorted(files.items()):
                path = entry["local"]
                record = {key: value for key, value in entry.items() if key != "local"}
                record.update(path=name, bytes=path.stat().st_size, sha256=digest(path))
                manifest["files"].append(record)
                archive.write(path, name)
            readme = README.encode()
            archive.writestr("README.md", readme)
            manifest["files"].append({"path": "README.md", "bytes": len(readme), "sha256": hashlib.sha256(readme).hexdigest(), "kind": "build-instructions"})
            archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps({"archive": str(output), "sha256": digest(output), "bytes": output.stat().st_size,
                      "packages": len(collected), "firmware": len(evidence), "complete": True}))


if __name__ == "__main__":
    main()
