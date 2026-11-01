# Third-party components and source distribution

The application source is MIT licensed. That license covers our own code only.

The first public release is an **ad-hoc signed preview**, not notarized by Apple.
This signing limitation is disclosed in the installation instructions and is
separate from the licenses of redistributed components. The build copies only the application's Swift
executables, its text resources, application icon and the named developer logo, selected QEMU binaries/firmware and their
recursively discovered native dependencies. User installers and VM data remain
outside the source tree and application bundle.

## Ingvar Consulting logo

`Resources/interface/ingvar-consulting.png` is the unchanged
[primary logo (PNG)](https://ingvar.pro/brand/logos/wordmark-primary.png) from the
official [Ingvar Consulting brandbook](https://ingvar.pro/brand).

The logo belongs to Ingvar Consulting and follows the brandbook's usage rules.
The MIT license for KeyBridge's software is not a license grant for this logo.
It identifies the developer in Settings and is bundled in the app; displaying it
does not load content from the website.

## Included free-software runtime

The initial build uses the installed **QEMU 11.1.2 ARM64** Homebrew bottle.
The exact copied file hashes, packages and versions are recorded in the bundle's
`Contents/Resources/build-inventory.json` and `ThirdParty/packages.json`.
Per-package license files, Homebrew formulas, sanitized installation receipts
and available SPDX manifests are copied into `Contents/Resources/ThirdParty/`.
Relocation changes Mach-O load paths and signatures; original file hashes are
retained in the inventory. No QEMU implementation source is modified.

The installed QEMU formula records this upstream source:

- <https://download.qemu.org/qemu-11.1.2.tar.xz>
- SHA-256 `731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016`
- Formula license: GPL-2.0-only; the installed QEMU package additionally includes
  `COPYING`, `COPYING.LIB` and `LICENSE` explaining component licensing.
- The copied formula is the exact installed recipe, including configuration
  changes. The inspected QEMU recipe has no separate `patch do` blocks; do not
  infer this for a different installed version.

QEMU is a separate executable launched by the application. Its GPL terms and
those of dependencies remain in force independently of our MIT source license.
QEMU PC BIOS/option ROMs have their own upstream licensing and source history.
Only the x86 firmware needed by this pilot is copied. The tested local QEMU process uses hardened runtime with `allow-jit` and
`disable-library-validation` entitlements because ad-hoc signatures do not have
a shared Developer Team ID. A signed public build must reassess that exception.
The runtime does not need
Homebrew or Python on the end user's Mac; those are build-time tools only.

The release's `COMPONENT-SOURCES.md` lists the exact bundled package versions
and links to their upstream sources, distribution recipes and patches. Our own
code and build scripts are available in this repository; the release audit links
to the commit used to build the application. The exact installed Homebrew
formulas, receipts and license files are also included in
`Contents/Resources/ThirdParty/`. QEMU's source distribution includes the sources
and build rules for the bundled firmware.

`package-release.py` generates the link catalog from application metadata.
It does not download, require or attach external source archives. The optional
collection scripts can download sources for a developer who needs local copies.
Source links refer to the versions actually redistributed, rather than just the
projects' home pages. Maintain these links while distributing the binaries;
component licenses continue to apply regardless of where the sources are hosted.

The LGPL libraries are separate dynamically linked files. Users may rebuild
and replace them in a copy of the app, then re-sign the modified bundle ad-hoc
with `codesign --force --deep --sign - KeyBridge.app`. KeyBridge imposes no
additional restriction on modification or reverse engineering for debugging
those modifications. Replacing libraries invalidates the original signature;
the modified copy must be tested by its builder.

A future notarized release needs a Developer ID Application certificate,
appropriate hardened-runtime signing and clean-Mac USB/TCG validation. An Apple
Development certificate is not a substitute for Developer ID notarization.

## Excluded proprietary components

No 1C or Thales/Sentinel executable, shared library, driver package, installer,
prepared guest image or user license is part of this source project or build.
The owner imports their own Linux 1C `.run` and Sentinel `.deb` locally. Imports,
installation media, guest disks and SSH identities belong in the application's
private Application Support directory. Never copy them into source archives,
CI artifacts or application releases.

Importing one's own installer does not grant additional license rights or
establish the permissibility of every NFR or multi-user deployment. The pilot
uses the official manager with the owner's physical key and does not emulate,
patch, clone or alter the key.

## Rebuilding

From a native Apple Silicon process with Command Line Tools and native Homebrew
QEMU installed, run `scripts/build-app.sh`. The build verifies that every host
Mach-O is ARM64-only, copies all non-system dylibs and rewrites their references
to bundle-relative paths. It rejects remaining external dynamic linkage.

Output defaults to `~/Library/Caches/KeyBridgeDevelopment/build/KeyBridge.app`
outside this source project. Set `KEYBRIDGE_BUILD_ROOT` to choose another external
development directory. An existing generated bundle is retained as a timestamped previous
build; an unrelated bundle is never overwritten. Do not rebuild while the
app, its agent or its VM is running. `--runtime-only` builds a runtime smoke-test
bundle before Swift targets are ready; this is not a runnable application.

Useful upstream references:

- <https://www.qemu.org/docs/master/about/license.html>
- <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
- <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>
- <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>

The initial Homebrew `dtc` keg lacks a standalone license text; its `libfdt.h`
identifies `(GPL-2.0-or-later OR BSD-2-Clause)`. Its complete upstream source and
license texts are available through the release's source links. The bundle targets macOS 27 because this
installed QEMU bottle was built for that system; earlier macOS support is not
asserted by the Swift deployment setting.

## Open Alpine/glibc base

The bundle includes a clean Alpine 3.22 x86-64 filesystem and Linux kernel, with Debian 12 glibc and open library dependencies. No 1C/Thales binaries or private credentials are in this base. The build uses official Alpine and Debian packages. Package inventories, source-package metadata and Debian copyright notices are in `Contents/Resources/base/`. The release catalog links to the Alpine recipes at their recorded commits and the Debian source-package versions, including their distribution patches and build rules. Debian metadata describes the build-stage inventory, even where only some shared libraries are copied. Alpine package recipes/sources: https://gitlab.alpinelinux.org/alpine/aports/ ; Debian source packages: https://sources.debian.org/ .
