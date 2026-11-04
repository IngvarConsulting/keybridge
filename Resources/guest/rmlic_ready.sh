#!/bin/sh
# SPDX-License-Identifier: MIT
# Read-only readiness of the Alpine manager and its own listening socket.
set -eu
exec sudo -n python3 /usr/local/lib/keybridge/alpine_ready.py "${1:-90}"
