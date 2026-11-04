#!/bin/sh
# SPDX-License-Identifier: MIT
# User import into the bundled, open-source Alpine base. No network/package fetch.
set -eu
phase=verify_imports
swap=/var/lib/keybridge/install.swap
oom_before=$(awk '$1=="oom_kill" {print $2}' /proc/vmstat)
free_kib() { df -Pk / | awk 'NR==2 {print $4}'; }
cleanup() {
  code=$?
  trap - EXIT
  if test "$code" -ne 0; then
    # Preserve the failure location before releasing temporary swap space.
    if test "$(free_kib)" -eq 0; then printf 'KEYBRIDGE_ERROR=guest_disk_full\n' >&2; fi
    oom_after=$(awk '$1=="oom_kill" {print $2}' /proc/vmstat)
    if test "${oom_after:-0}" -gt "${oom_before:-0}"; then printf 'KEYBRIDGE_ERROR=guest_memory\n' >&2; fi
  fi
  if test -f "$swap"; then swapoff "$swap" 2>/dev/null || true; rm -f "$swap"; fi
  if test "$code" -ne 0; then
    printf 'KEYBRIDGE_ERROR=stage_%s code=%s\n' "$phase" "$code" >&2
    tail -n 30 /var/log/hasplmd.log /var/log/keybridge-start.log 2>/dev/null || true
  fi
  exit "$code"
}
trap cleanup EXIT
milestone() { phase=$1; printf 'KEYBRIDGE_PHASE=%s\n' "$phase"; }
milestone verify_imports
test ! -d /opt/1cv8
test ! -e /usr/sbin/aksusbd_x86_64
test ! -e /usr/sbin/hasplmd_x86_64
for vendor in /sys/bus/usb/devices/*/idVendor; do
  test ! -f "$vendor" || test "$(cat "$vendor")" != 0529
done
echo KEYBRIDGE_CLEAN_BASE
mkdir -p /mnt/import /var/lib/keybridge
mount -o ro "$(blkid -L keybridge)" /mnt/import
cd /mnt/import
sha256sum -c sha256sums
# Reserve the known allocation (temporary swap and the driver). The vendor
# installer's final size is not advertised, so later allocation failures remain explicit.
driver_kib=$(dpkg-deb -f runtime.deb Installed-Size 2>/dev/null || true)
case "$driver_kib" in ''|*[!0-9]*) driver_kib=0 ;; esac
if test "$(free_kib)" -lt "$((524288 + driver_kib))"; then
  printf 'KEYBRIDGE_ERROR=guest_disk_full\n' >&2
  exit 1
fi
dd if=/dev/zero of="$swap" bs=1M count=512 2>/dev/null
chmod 600 "$swap"
mkswap "$swap" >/dev/null
swapon "$swap"
echo KEYBRIDGE_TEMPORARY_INSTALL_SWAP_MIB=512
sh ./verify_imports.sh
milestone driver
dpkg-deb -x runtime.deb /
ln -sfn aksusbd_x86_64 /usr/sbin/aksusbd
ln -sfn hasplmd_x86_64 /usr/sbin/hasplmd
printf '[SERVER]\nno_auto_fwup = 1\n' > /etc/hasplm/hasplm.ini
/usr/local/sbin/keybridge-services start
milestone firmware_guard
python3 /usr/local/lib/keybridge/sentinel_guard.py configure
milestone manager_install
# The vendor installer exceeds the working VM's RAM budget. Swap is temporary,
# keeps guest RAM at 128 MiB, and is removed before acceptance and license tests.
mkdir -p /opt/1cv8/common
./setup.run --mode unattended --unattendedmodeui none --installer-language en \
  --enable-components "$(cat /tmp/keybridge-enable-components)" \
  --disable-components "$(cat /tmp/keybridge-disable-components)"
swapoff "$swap"
rm "$swap"
milestone manager_configure
manager=$(sh ./verify_imports.sh --installed-manager)
set -- "$manager"
manager_dir=${1%/rmlic}
ln -s "$1" /usr/local/lib/keybridge/rmlic
for unexpected in 1cv8 ragent rphost; do test ! -e "$manager_dir/$unexpected"; done
mkdir -p /opt/1cv8/conf /var/log/keybridge-lic
printf '[NH_COMMON]\nNH_IPX=Disabled\nNH_NETBIOS=Disabled\nNH_TCPIP=Disabled\n' > /opt/1cv8/conf/nethasp.ini
cat > /opt/1cv8/conf/logcfg.xml <<'EOF'
<?xml version="1.0"?>
<config xmlns="http://v8.1c.ru/v8/tech-log"><log location="/var/log/keybridge-lic" history="4"><event><eq property="name" value="LIC"/></event><property name="all"/></log></config>
EOF
/lib64/ld-linux-x86-64.so.2 --list "$1"
python3 - "$manager_dir" <<'PY'
import json, pathlib, subprocess, sys
pathlib.Path('/var/lib/keybridge/imports.json').write_text(json.dumps({
 'managerVersion': pathlib.Path(sys.argv[1]).name,
 'installerDescription': pathlib.Path('/tmp/keybridge-installer-version').read_text().strip(),
 'runtimeVersion': subprocess.check_output(['dpkg-deb','-f','runtime.deb','Version'],text=True).strip(),
}))
PY
milestone manager_start
/usr/local/sbin/keybridge-services start
python3 /usr/local/lib/keybridge/sentinel_guard.py check-config
milestone manager_ready
/usr/local/bin/keybridge-rmlic-ready 90
test "$(wc -l < /proc/swaps)" -eq 1
sync
fstrim /
echo KEYBRIDGE_PREPARED
