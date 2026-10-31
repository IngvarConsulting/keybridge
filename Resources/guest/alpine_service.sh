#!/bin/sh
# SPDX-License-Identifier: MIT
# Runtime services for the Alpine guest. Invoked as root by OpenRC or the owner.
set -eu
case "${1:-start}" in
  restart-runtime)
    for pid in $(pidof hasplmd_x86_64 || true); do kill "$pid"; done
    for i in $(seq 1 20); do
      pidof hasplmd_x86_64 >/dev/null || break
      sleep 0.25
    done
    if pidof hasplmd_x86_64 >/dev/null; then exit 1; fi
    /usr/sbin/hasplmd_x86_64 -s >>/var/log/hasplmd.log 2>&1
    ;;
  start)
    mkdir -p /run/keybridge /var/log/keybridge-lic
    test -x /usr/sbin/aksusbd_x86_64 && test -x /usr/sbin/hasplmd_x86_64 || exit 0
    pidof aksusbd_x86_64 >/dev/null || /usr/sbin/aksusbd_x86_64 >>/var/log/aksusbd.log 2>&1
    pidof hasplmd_x86_64 >/dev/null || /usr/sbin/hasplmd_x86_64 -s >>/var/log/hasplmd.log 2>&1
    /usr/local/sbin/keybridge-hasp-hotplug --scan
    if test -x /usr/local/lib/keybridge/rmlic && ! pidof rmlic >/dev/null; then
      start-stop-daemon --start --background --make-pidfile --pidfile /run/keybridge/rmlic.pid \
        --startas /usr/local/lib/keybridge/rmlic -- -rmlic -porttcp 1544 -portudp 1544
    fi
    ;;
  *) echo 'Unsupported service operation' >&2; exit 2 ;;
esac
