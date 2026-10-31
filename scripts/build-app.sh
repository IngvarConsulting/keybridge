#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
exec python3 "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/build-app.py" "$@"
