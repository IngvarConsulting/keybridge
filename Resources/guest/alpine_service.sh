#!/bin/sh
# SPDX-License-Identifier: MIT
# Runtime services for the Alpine guest. Invoked as root by OpenRC or the owner.
set -eu
case "${1:-start}" in
  restart-runtime|restart-service)
    service=${2:-hasplmd_x86_64}
    case "$service" in aksusbd_x86_64|hasplmd_x86_64|rmlic) ;; *) exit 2 ;; esac
    for pid in $(pidof "$service" || true); do kill "$pid"; done
    for i in $(seq 1 20); do
      pidof "$service" >/dev/null || break
      sleep 0.25
    done
    if pidof "$service" >/dev/null; then exit 1; fi
    case "$service" in
      hasplmd_x86_64) /usr/sbin/hasplmd_x86_64 -s >>/var/log/hasplmd.log 2>&1 ;;
      aksusbd_x86_64) /usr/sbin/aksusbd_x86_64 >>/var/log/aksusbd.log 2>&1 ;;
      rmlic)
        start-stop-daemon --start --background --make-pidfile --pidfile /run/keybridge/rmlic.pid \
          --startas /usr/local/lib/keybridge/rmlic -- -rmlic -porttcp 1544 -portudp 1544 ;;
    esac
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
