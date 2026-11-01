#!/bin/sh
# SPDX-License-Identifier: MIT
# Read package identity in the candidate VM before installing anything or attaching USB.
# These checks establish compatibility, not publisher authenticity.
set -eu
export LC_ALL=C
fail() {
  printf 'KEYBRIDGE_ERROR=%s\n' "$1" >&2
  exit 1
}

if test "${1:-}" = --installed-manager; then
  # Check the actual installation as well as the installer's advertised list.
  # A fixture root allows this same check to run without a VM or installation.
  manager_root=${2:-/opt/1cv8/x86_64}
  set -- "$manager_root"/*/rmlic
  test "$#" -eq 1 || fail ambiguous_license_manager
  test -f "$1" && test -x "$1" || fail missing_license_manager
  printf '%s\n' "$1"
  exit 0
fi

case "${1:-}" in ""|--installer-only) ;; *) fail invalid_validation_mode ;; esac

if test "${1:-}" != --installer-only; then
package=$(dpkg-deb -f runtime.deb Package) || fail invalid_driver_package
architecture=$(dpkg-deb -f runtime.deb Architecture) || fail invalid_driver_package
version=$(dpkg-deb -f runtime.deb Version) || fail invalid_driver_package
test "$package" = aksusbd || fail wrong_driver_package
test "$architecture" = amd64 || fail wrong_driver_architecture
test -n "$version" || fail invalid_driver_package
# Read the complete archive so a truncated data member cannot pass on metadata alone.
contents=$(dpkg-deb --contents runtime.deb) || fail invalid_driver_package
for binary in aksusbd_x86_64 hasplmd_x86_64; do
  printf '%s\n' "$contents" | grep -Eq "[[:space:]][.]/usr/sbin/$binary$" || fail missing_driver_runtime
done
fi

version=$(timeout 300 ./setup.run --version --installer-language en) || fail invalid_platform_installer
printf '%s\n' "$version" | grep -Eq '^1C:Enterprise[[:space:]]' || fail invalid_platform_installer
printf '%s\n' "$version" > "${TMPDIR:-/tmp}/keybridge-installer-version"
components=$(timeout 300 ./setup.run --help --installer-language en) || fail invalid_platform_installer
allowed=$(printf '%s\n' "$components" | awk '
  /^[[:space:]]*--enable-components[[:space:]]/ { section=1; next }
  section && /Allowed:/ { sub(/^.*Allowed:[[:space:]]*/, ""); print; exit }
')
printf '%s\n' "$allowed" | grep -Eq '(^|[[:space:],])lic_manager([[:space:],]|$)' || fail missing_license_manager
# Disable the actual advertised components, including future additions. Do not pass
# a release-specific option list or allow defaults to install an unwanted client.
enable=lic_manager
disable=
for component in $allowed; do
  case "$component" in
    lic_manager) ;;
    ru) enable=$enable,ru ;;
    *[!A-Za-z0-9_]*) fail invalid_platform_installer ;;
    *) disable=${disable:+$disable,}$component ;;
  esac
done
printf '%s\n' "$enable" > "${TMPDIR:-/tmp}/keybridge-enable-components"
printf '%s\n' "$disable" > "${TMPDIR:-/tmp}/keybridge-disable-components"
printf 'KEYBRIDGE_IMPORTS_VERIFIED\n'
