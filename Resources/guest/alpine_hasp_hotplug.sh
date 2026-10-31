#!/bin/sh
# SPDX-License-Identifier: MIT
# Equivalent of Sentinel's HASP udev add/remove notifications for Alpine mdev.
# No firmware or license updates: -c/-r register/unregister a local USB device.
set -eu
aks=/usr/sbin/aksusbd_x86_64
test -S /tmp/.aksusb || exit 0

notify() {
    action=$1
    kernel=$2
    node=$3
    case "$kernel" in
        ''|*[!0-9.-]*) return 0 ;;
        *-*) ;;
        *) return 0 ;;
    esac
    alias=/dev/aks/hasp/$kernel
    case "$action" in
        add|change|bind)
            test -c "$node" || return 0
            mkdir -p /dev/aks/hasp
            if test -e "$alias" && test ! -L "$alias"; then
                echo "Unexpected non-symlink at HASP device alias" >&2
                return 1
            fi
            ln -sfn "$node" "$alias"
            "$aks" -c "$alias"
            ;;
        remove)
            "$aks" -r "$alias"
            test ! -L "$alias" || rm -f "$alias"
            ;;
        *) return 0 ;;
    esac
    mkdir -p /run/keybridge
    printf '%s %s\n' "$action" "$kernel" >> /run/keybridge/usb-events.log
}

if test "${1:-}" = --scan; then
    # mdev coldplug runs before aksusbd. Register keys already present once the
    # daemon is running, without depending on udev database persistence.
    for d in /sys/bus/usb/devices/*; do
        test -f "$d/idVendor" && test -f "$d/idProduct" || continue
        test "$(cat "$d/idVendor")" = 0529 || continue
        test "$(cat "$d/idProduct")" = 0001 || continue
        node=$(printf '/dev/bus/usb/%03d/%03d' "$(cat "$d/busnum")" "$(cat "$d/devnum")")
        notify add "${d##*/}" "$node"
    done
    exit 0
fi

case "${PRODUCT:-}" in
    529/1/*|0529/0001/*) ;;
    *) exit 0 ;;
esac
devname=${DEVNAME:-${MDEV:-}}
case "$devname" in bus/usb/*) ;; *) exit 0 ;; esac
notify "${ACTION:-}" "${DEVPATH##*/}" "/dev/$devname"
