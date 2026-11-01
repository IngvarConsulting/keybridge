#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Collect exact Alpine/Debian corresponding sources for a built KeyBridge app.

Downloads stay outside the checkout. Alpine APKBUILD files run only in a
disposable Docker container, never in the host shell. No application or user
VM is started. Missing versions or source checksums stop publication.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ALPINE = "https://dl-cdn.alpinelinux.org/alpine/v3.22"
DEBIAN = (
    ("https://deb.debian.org/debian", "bookworm"),
    ("https://deb.debian.org/debian", "bookworm-updates"),
    ("https://security.debian.org/debian-security", "bookworm-security"),
)


def digest(path: Path, algorithm: str = "sha256") -> str:
    h = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def download(url: str, destination: Path, expected: str | None = None,
             *, refresh: bool = False) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not refresh and destination.is_file() and (expected is None or digest(destination) == expected):
        return destination
    partial = destination.with_name(destination.name + ".partial")
    for attempt in range(4):
        try:
            request = urllib.request.Request(url, headers={"Cache-Control": "no-cache"} if refresh else {})
            with urllib.request.urlopen(request, timeout=90) as response, partial.open("wb") as out:
                shutil.copyfileobj(response, out)
            if expected is not None and digest(partial) != expected:
                raise ValueError(f"Source checksum mismatch: {url}")
            partial.replace(destination)
            return destination
        except Exception as error:
            partial.unlink(missing_ok=True)
            print(f"Download attempt {attempt + 1}: {url}: {error}", flush=True)
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def paragraphs(text: str):
    """Debian control paragraphs, retaining multiline checksum fields."""
    for block in text.split("\n\n"):
        record, field = {}, None
        for line in block.splitlines():
            if line[:1].isspace() and field:
                record[field] += "\n" + line.strip()
            elif ":" in line:
                field, value = line.split(":", 1)
                record[field] = value.strip()
        if record:
            yield record


def alpine_inventory(base: Path) -> dict[str, str]:
    result = {}
    for line in (base / "alpine-packages.txt").read_text().splitlines():
        match = re.fullmatch(r"(.+)-([0-9].*-r[0-9]+) - .+", line)
        if not match or match[1] in result:
            raise ValueError(f"Invalid or duplicate Alpine inventory line: {line}")
        result[match[1]] = match[2]
    if not result:
        raise ValueError("Empty Alpine inventory")
    return result


def debian_inventory(base: Path) -> dict[str, str]:
    result = {}
    for line in (base / "notices/debian-packages.txt").read_text().splitlines():
        name, version = line.split("\t")
        if name in result or not version:
            raise ValueError(f"Invalid or duplicate Debian inventory line: {line}")
        result[name] = version
    if not result:
        raise ValueError("Empty Debian inventory")
    return result


def copy(source: Path, tree: Path, relative: str) -> str:
    target = tree / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return relative


def alpine_sources(base: Path, cache: Path, tree: Path) -> list[dict]:
    wanted = alpine_inventory(base)
    packages = {}
    for repository in ("main", "community"):
        url = f"{ALPINE}/{repository}/x86_64/APKINDEX.tar.gz"
        path = download(url, cache / "indexes" / f"alpine-{repository}.tar.gz", refresh=True)
        copy(path, tree, f"metadata/alpine-{repository}-APKINDEX.tar.gz")
        with tarfile.open(path) as archive:
            text = archive.extractfile("APKINDEX").read().decode()
        for record in paragraphs(text):
            name = record.get("P")
            if name in wanted and record.get("V") == wanted[name]:
                record["repository"] = repository
                packages[name] = record
    missing = sorted(set(wanted) - packages.keys())
    if missing:
        raise ValueError(f"Exact Alpine versions absent from official index: {missing}")
    origins = {(p["repository"], p["o"], p["c"]) for p in packages.values()}

    def recipe(origin):
        repository, name, commit = origin
        if not re.fullmatch(r"[a-z0-9+_.-]+", name) or not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError("Invalid aports identity")
        url = (f"https://gitlab.alpinelinux.org/alpine/aports/-/archive/{commit}/"
               f"aports-{commit}.tar.gz?path={repository}/{name}")
        source = download(url, cache / "recipes" / f"{name}-{commit}.tar.gz")
        target = cache / "aports" / f"{name}-{commit}"
        # Only extract the requested package subtree. Alpine post-install
        # aliases may be relative symlinks, but they must stay in that subtree.
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True, exist_ok=True)
        with tarfile.open(source) as archive:
            for member in archive:
                parts = Path(member.name).parts
                if len(parts) < 4 or parts[1:3] != (repository, name):
                    continue
                relative = Path(*parts[3:])
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError("Unsafe aports archive path")
                destination = target / relative
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as inp, destination.open("wb") as out:
                        shutil.copyfileobj(inp, out)
                elif member.issym():
                    link = Path(member.linkname)
                    resolved = (destination.parent / link).resolve()
                    if link.is_absolute() or target.resolve() not in resolved.parents:
                        raise ValueError(f"Unsafe aports archive link: {member.name}")
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.symlink_to(link)
                else:
                    raise ValueError(f"Unexpected aports archive entry: {member.name}")
        print(f"Alpine recipe: {name} at {commit[:12]}", flush=True)
        return origin, source, target

    with ThreadPoolExecutor(max_workers=4) as pool:
        recipes = list(pool.map(recipe, sorted(origins)))
    print(f"Alpine: {len(wanted)} binary packages, {len(recipes)} exact aports recipes", flush=True)
    (cache / "distfiles").mkdir(exist_ok=True)
    # Four independent source packages at a time; each status is checked.
    # Capture checksums in the same disposable container after abuild verifies.
    (cache / "checksums").mkdir(exist_ok=True)
    commands = []
    ordered = sorted(origins)
    for offset in range(0, len(ordered), 4):
        commands.append("pids='' ")
        for _, name, commit in ordered[offset:offset + 4]:
            commands.append(
                f"(cd /work/aports/{name}-{commit}; abuild -F fetch verify; "
                "export CARCH=x86_64 CHOST=x86_64-alpine-linux-musl CBUILD=x86_64-alpine-linux-musl; "
                "set +u; . ./APKBUILD; "
                'if [ -n "${source:-}" ] && [ -z "${sha512sums:-}" ]; then exit 1; fi; '
                f'printf "%s\\n" "${{sha512sums:-}}" > /work/checksums/{name}-{commit}.txt) & pids="$pids $!"'
            )
        commands.append('failed=0; for pid in $pids; do wait "$pid" || failed=1; done; test "$failed" = 0')
    script = ("set -eu\napk add --no-cache abuild\n"
              "export SRCDEST=/work/distfiles\n"
              "export DISTFILES_MIRROR=https://distfiles.alpinelinux.org/distfiles/v3.22\n"
              + "\n".join(commands) + "\n")
    # The only writable mount is this source-download cache. The container has
    # no application state, home directory, credentials, or Docker socket.
    subprocess.run(["docker", "run", "--rm", "--platform", "linux/amd64",
                    "--label", "pro.keybridge.purpose=guest-source-fetch",
                    "--mount", f"type=bind,source={cache},target=/work",
                    "alpine:3.22", "sh", "-ec", script], check=True)
    references = {}
    for origin, source, recipe_path in recipes:
        repository, name, commit = origin
        paths = [copy(source, tree, f"alpine/recipes/{name}-{commit}.tar.gz")]
        # abuild's verified checksum list is also used to select the exact
        # downloaded source set, rather than exporting the entire cache.
        checksums = (cache / "checksums" / f"{name}-{commit}.txt").read_text()
        for line in checksums.splitlines():
            if not line.strip():
                continue
            checksum, filename = line.split(None, 1)
            filename = filename.strip()
            if not re.fullmatch(r"[0-9a-f]{128}", checksum) or Path(filename).name != filename:
                raise ValueError(f"Invalid Alpine source checksum entry in {name}")
            local = recipe_path / filename
            downloaded = cache / "distfiles" / filename
            selected = local if local.is_file() else downloaded
            if digest(selected, "sha512") != checksum:
                raise ValueError(f"Alpine verified source changed: {name}/{filename}")
            if not local.is_file():
                paths.append(copy(selected, tree, f"alpine/distfiles/{filename}"))
        references[origin] = paths
    return [dict(name=name, version=wanted[name], distribution="alpine",
                 source_name=p["o"], recipe_commit=p["c"], license=p.get("L"),
                 source_files=references[(p["repository"], p["o"], p["c"])])
            for name, p in sorted(packages.items())]


def debian_sources(base: Path, cache: Path, tree: Path) -> list[dict]:
    wanted = debian_inventory(base)
    binary_records, source_records = {}, {}
    for mirror, suite in DEBIAN:
        for kind, filename in (("binary-amd64", "Packages"), ("source", "Sources")):
            url = f"{mirror}/dists/{suite}/main/{kind}/{filename}.xz"
            downloaded = download(url, cache / "indexes" / f"debian-{suite}-{filename}.xz", refresh=True)
            copy(downloaded, tree, f"metadata/debian-{suite}-{filename}.xz")
            for record in paragraphs(lzma.decompress(downloaded.read_bytes()).decode()):
                if filename == "Packages":
                    for key in (record["Package"], record["Package"] + ":amd64"):
                        if wanted.get(key) == record.get("Version"):
                            binary_records[key] = record
                else:
                    source_records[(record["Package"], record["Version"])] = (mirror, record)
    missing = sorted(set(wanted) - binary_records.keys())
    if missing:
        raise ValueError(f"Exact Debian versions absent from official indexes: {missing}")
    identities = {}
    for name, binary in binary_records.items():
        source = binary.get("Source", binary["Package"])
        match = re.fullmatch(r"([^ ]+)(?: \(([^)]+)\))?", source)
        if not match:
            raise ValueError(f"Invalid Debian Source field: {source}")
        identity = (match[1], match[2] or binary["Version"])
        if identity not in source_records:
            raise ValueError(f"Exact Debian source unavailable: {identity}")
        identities[name] = identity

    def collect(identity):
        mirror, record = source_records[identity]
        package, version = identity
        references = []
        for line in record["Checksums-Sha256"].splitlines():
            if not line.strip():
                continue
            checksum, size, filename = line.split()
            if not re.fullmatch(r"[a-f0-9]{64}", checksum) or Path(filename).name != filename:
                raise ValueError("Invalid Debian source filename or digest")
            url = f"{mirror}/{record['Directory']}/{filename}"
            source = download(url, cache / "debian" / filename, checksum)
            if source.stat().st_size != int(size):
                raise ValueError(f"Debian source size mismatch: {filename}")
            references.append(copy(source, tree, f"debian/{package}/{filename}"))
        if not any(p.endswith(".dsc") for p in references) or len(references) < 2:
            raise ValueError(f"Incomplete Debian source package: {identity}")
        return identity, references

    with ThreadPoolExecutor(max_workers=4) as pool:
        references = dict(pool.map(collect, sorted(set(identities.values()))))
    print(f"Debian: {len(wanted)} binary packages, {len(references)} exact source packages", flush=True)
    return [dict(name=name, version=version, distribution="debian",
                 source_name=identities[name][0], source_version=identities[name][1],
                 source_files=references[identities[name]])
            for name, version in sorted(wanted.items())]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output == ROOT or ROOT in output.parents or output.suffix != ".zip":
        raise ValueError("Output must be a ZIP outside the source checkout")
    base = args.app.expanduser().resolve() / "Contents/Resources/base"
    base_manifest = json.loads((base / "manifest.json").read_text())
    for name, checksum in base_manifest["files"].items():
        if digest(base / name) != checksum:
            raise ValueError(f"Base inventory hash mismatch: {name}")
    output.parent.mkdir(parents=True, exist_ok=True)
    cache = output.parent / (output.stem + "-cache")
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="guest-sources-", dir=output.parent) as temporary:
        tree = Path(temporary)
        # Keep every original license/copyright notice already supplied with
        # the base, in addition to the licenses inside its complete sources.
        shutil.copytree(base / "notices", tree / "notices")
        for name in ("manifest.json", "alpine-packages.txt", "alpine-package-details.txt"):
            copy(base / name, tree, "metadata/base-" + name)
        for name in ("build-alpine-base.py", "configure-alpine-base.sh", "collect-guest-sources.py"):
            copy(ROOT / "scripts" / name, tree, "keybridge-build/scripts/" + name)
        shutil.copytree(ROOT / "Resources/guest", tree / "keybridge-build/Resources/guest")
        copy(ROOT / "LICENSE", tree, "keybridge-build/LICENSE")
        with ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(alpine_sources, base, cache, tree)
            d = pool.submit(debian_sources, base, cache, tree)
            packages = a.result() + d.result()
        (tree / "README.txt").write_text(
            "KeyBridge open guest corresponding sources\n\n"
            "Alpine sources: exact aports commit archives include APKBUILD, patches, "
            "configuration and notices. Upstream inputs are in alpine/distfiles; "
            "abuild fetch verify checked their APKBUILD SHA-512 digests. Rebuild "
            "with Alpine abuild for x86_64 using each supplied APKBUILD.\n\n"
            "Debian sources: complete .dsc, upstream archives and Debian packaging "
            "are in debian/<source>. Extract with dpkg-source -x package.dsc and "
            "build using dpkg-buildpackage; debian/control declares dependencies. "
            "Each file was verified against the official Sources SHA-256 entry.\n\n"
            "keybridge-build includes the open base assembly scripts and guest "
            "configuration. The Debian inventory deliberately covers the entire "
            "build stage, including packages not copied into the final base. "
            "The archive contains no proprietary 1C or Sentinel software.\n"
        )
        files = [dict(path=p.relative_to(tree).as_posix(), bytes=p.stat().st_size,
                      sha256=digest(p)) for p in sorted(tree.rglob("*")) if p.is_file()]
        manifest = dict(schema=1, kind="guest", complete=True, packages=packages,
                        base_build_id=base_manifest["build_id"], files=files)
        (tree / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        partial = output.with_suffix(".partial.zip")
        with zipfile.ZipFile(partial, "w", compression=zipfile.ZIP_STORED) as archive:
            for source in sorted(tree.rglob("*")):
                if source.is_file():
                    archive.write(source, source.relative_to(tree).as_posix())
        partial.replace(output)
        print(json.dumps({"archive": str(output), "bytes": output.stat().st_size,
                          "sha256": digest(output), "packages": len(packages),
                          "files": len(files), "complete": True}), flush=True)


if __name__ == "__main__":
    main()
