# Third-party components and local build boundary

The application source is MIT licensed. That license covers our own code only.

This is a **local pilot**, ad-hoc signed for development. It is not a notarized,
redistributable public release. The build copies only the application's Swift
executables, its text resources and the named developer logo, selected QEMU binaries/firmware and their
recursively discovered native dependencies. User installers and VM data remain
outside the source tree and application bundle.

## Ingvar Consulting logo

`Resources/interface/ingvar-consulting.png` is the unchanged
[primary logo (PNG)](https://ingvar.pro/brand/logos/wordmark-primary.png) from the
official [Ingvar Consulting brandbook](https://ingvar.pro/brand).

The logo belongs to Ingvar Consulting and follows the brandbook's usage rules.
The MIT license for KeyBridge's software is not a license grant for this logo.
It identifies the developer in Settings and is bundled locally; displaying it
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

Before a public **binary** release, assemble the complete corresponding sources,
firmware source revisions, relevant Homebrew patches/build instructions, and
required notices for every redistributed component under its actual license.
A list of source URLs is not itself that complete source delivery. Preserve the
ability to replace/relink LGPL components as required by their licenses. Also
use a Developer ID signature, verify hardened-runtime USB/TCG behavior on a clean
Mac, and notarize the complete bundle. The present script intentionally makes
no claim that these public-release obligations are completed.

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
identifies `(GPL-2.0-or-later OR BSD-2-Clause)`. The inventory records available
notices honestly; obtaining the corresponding upstream notices is one of the
public binary-release gates above. The bundle targets macOS 27 because this
installed QEMU bottle was built for that system; earlier macOS support is not
asserted by the Swift deployment setting.

## Open Alpine/glibc base

The bundle includes a clean Alpine 3.22 x86-64 filesystem and Linux kernel, with Debian 12 glibc and open library dependencies. No 1C/Thales binaries or private credentials are in this base. The build uses official Alpine and Debian packages. Package inventories and Debian copyright notices are in `Contents/Resources/base/`. Alpine package recipes/sources: https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.22-stable ; Debian source packages: https://sources.debian.org/ . This local pilot is not a completed public binary release; corresponding-source and redistribution obligations must be met before public distribution.
