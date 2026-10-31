#!/bin/sh
# SPDX-License-Identifier: MIT
# Read-only readiness check. Called after systemd starts the imported manager.
set -eu
export LC_ALL=C
if test -f /etc/alpine-release; then
  exec sudo -n python3 /usr/local/lib/keybridge/alpine_ready.py "${1:-90}"
fi
limit=${1:-90}
case "$limit" in ''|*[!0-9]*) printf 'KEYBRIDGE_ERROR=invalid_readiness_timeout\n' >&2; exit 2 ;; esac
binary=/usr/local/lib/keybridge/rmlic
# Existing prepared VMs predate the stable path; they remain usable on app update.
if test ! -x "$binary"; then binary=/opt/1cv8/x86_64/8.5.4.1878/rmlic; fi
service=keybridge-rmlic.service
report() {
  printf 'KEYBRIDGE_DIAGNOSTICS_BEGIN\n' >&2
  systemctl show "$service" -p ActiveState -p SubState -p MainPID -p ExecMainCode -p ExecMainStatus -p Result -p NRestarts >&2 || true
  journalctl -u "$service" -b --no-pager -n 100 >&2 || true
  ldd "$binary" >&2 || true
  printf 'KEYBRIDGE_DIAGNOSTICS_END\n' >&2
}
dependencies=$(ldd "$binary" 2>&1 || true)
if printf '%s\n' "$dependencies" | grep -q 'not found'; then
  printf 'KEYBRIDGE_ERROR=missing_dependencies\n' >&2
  report
  exit 1
fi
deadline=$(($(date +%s) + limit))
while :; do
  active=$(systemctl show "$service" -p ActiveState --value)
  restarts=$(systemctl show "$service" -p NRestarts --value)
  status=$(systemctl show "$service" -p ExecMainStatus --value)
  pid=$(systemctl show "$service" -p MainPID --value)
  if test "$active" = failed || test "${restarts:-0}" -gt 0 || test "${status:-0}" -ne 0; then
    printf 'KEYBRIDGE_ERROR=rmlic_failed\n' >&2
    report
    exit 1
  fi
  if test "$active" = active && test "${pid:-0}" -gt 0 && test -n "$(ss -H -lnt '( sport = :1544 )')"; then
    printf 'KEYBRIDGE_RMLIC_READY\n'
    exit 0
  fi
  if test "$(date +%s)" -ge "$deadline"; then
    printf 'KEYBRIDGE_ERROR=rmlic_timeout\n' >&2
    report
    exit 1
  fi
  sleep 1
done
