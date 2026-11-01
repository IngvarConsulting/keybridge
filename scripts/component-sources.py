#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Write versioned component source links from a built app, without downloading sources."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/IngvarConsulting/keybridge"
APORTS = "https://github.com/alpinelinux/aports"


def cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def link(label: str, url: str) -> str:
    return f"[{cell(label)}](<{url}>)"


def runtime_rows(resources: Path) -> list[list[str]]:
    spec = importlib.util.spec_from_file_location("runtime_sources", ROOT / "scripts/collect-runtime-sources.py")
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)
    notices = resources / "ThirdParty"
    rows = []
    for package in json.loads((notices / "packages.json").read_text()):
        name, version = package["name"], package["version"]
        formulas = package["formula_files"]
        if len(formulas) != 1:
            raise ValueError("Expected one installed formula for " + name)
        formula = notices / f"{name}-{version}" / formulas[0]
        records = collector.recipe_downloads(name, version, formula.read_bytes())
        links = [link(record.get("resource", record["kind"]), url)
                 for record in records for url in record["urls"]]
        rows.append([cell(name), cell(version), " · ".join(links)])
    return sorted(rows)


def alpine_rows(base: Path) -> list[list[str]]:
    expected = {}
    for line in (base / "alpine-packages.txt").read_text().splitlines():
        match = re.fullmatch(r"(.+)-([0-9][^-]*-r[0-9]+)(?: - .*)?", line)
        if not match or match[1] in expected:
            raise ValueError("Invalid Alpine package inventory")
        expected[match[1]] = match[2]
    actual, rows = {}, []
    # Installed APK database: retain package identity and source origin/commit.
    for block in (base / "alpine-package-details.txt").read_text().split("\n\n"):
        fields = dict(line.split(":", 1) for line in block.splitlines()
                      if line[:2] in ("P:", "V:", "o:", "c:"))
        if not fields:
            continue
        name, version, origin, commit = (fields.get(key, "") for key in ("P", "V", "o", "c"))
        if (not name or name in actual or not origin
                or not re.fullmatch(r"[a-f0-9]{40}", commit)):
            raise ValueError("Alpine source origin or recipe revision is missing")
        actual[name] = version
        # The installed database has no main/community field. The immutable
        # tree plus origin identifies the recipe without guessing its directory.
        recipe = link(origin + " @ " + commit[:12], f"{APORTS}/tree/{commit}")
        rows.append([cell(name), cell(version), recipe])
    if not expected or actual != expected:
        raise ValueError("Alpine source metadata differs from installed package inventory")
    return sorted(rows)


def debian_rows(base: Path) -> list[list[str]]:
    notices = base / "notices"
    expected = dict(line.split() for line in (notices / "debian-packages.txt").read_text().splitlines())
    actual, rows = {}, []
    for line in (notices / "debian-source-packages.txt").read_text().splitlines():
        fields = line.split("\t")
        if len(fields) != 4 or not all(fields):
            raise ValueError("Debian source package identity is missing")
        name, version, source_name, source_version = fields
        if name in actual:
            raise ValueError("Duplicate Debian source package identity")
        actual[name] = version
        url = f"https://snapshot.debian.org/package/{quote(source_name, safe='')}/{quote(source_version, safe='')}/"
        rows.append([cell(name), cell(version), link(source_name + " " + source_version, url)])
    if not expected or actual != expected:
        raise ValueError("Debian source metadata differs from installed package inventory")
    return sorted(rows)


def write_catalog(app: Path, revision: str, output: Path) -> dict:
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ValueError("Use the exact KeyBridge source commit")
    resources = app / "Contents/Resources"
    base = resources / "base"
    groups = {"runtime": runtime_rows(resources), "alpine": alpine_rows(base), "debian": debian_rows(base)}
    manifest = json.loads((base / "manifest.json").read_text())
    branches = {match[1] for url in manifest["sources"]
                if (match := re.search(r"alpinelinux\.org/alpine/(v[0-9]+\.[0-9]+)/?", url))}
    if len(branches) != 1:
        raise ValueError("Alpine source branch is missing or ambiguous")
    mirror = "https://distfiles.alpinelinux.org/distfiles/" + branches.pop() + "/"
    lines = ["# Component source links", "",
             f"KeyBridge source and build scripts: {REPOSITORY}/tree/{revision}", "",
             "These links identify the versions used in this application. Downloads remain on upstream sites.",
             "No component source archives are attached to the KeyBridge release.", "",
             "## macOS runtime", "",
             "Exact installed Homebrew formulas, inline patches and receipts are included in the app under",
             "`Contents/Resources/ThirdParty/<package>-<version>/`. Use those recipes with the linked sources.",
             "QEMU's source archive also contains its bundled firmware source trees and build rules.", ""]
    for kind, heading in (("runtime", None), ("alpine", "Alpine Linux"), ("debian", "Debian libraries")):
        if heading:
            lines.extend(["## " + heading, ""])
        if kind == "alpine":
            lines.extend(["Each origin names a package directory under `main/` or `community/` in its pinned aports tree.",
                          "Its `APKBUILD` contains source URLs, patches and build instructions; fetch the exact inputs with `abuild fetch`.",
                          "Alpine source mirror: " + mirror, ""])
        if kind == "debian":
            lines.extend(["Links use source-package versions, which may differ from binary-package versions.",
                          "The inventory includes the Debian build stage; only selected libraries are copied into the app.", ""])
        lines.extend(["| Package | Binary version | Sources and recipes |", "| --- | --- | --- |"])
        lines.extend("| " + " | ".join(row) + " |" for row in groups[kind])
        lines.append("")
    data = ("\n".join(lines) + "\n").encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    return {"file": output.name, "sha256": hashlib.sha256(data).hexdigest(),
            "packages": {kind: len(rows) for kind, rows in groups.items()}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(write_catalog(args.app, args.revision, args.output), indent=2))
