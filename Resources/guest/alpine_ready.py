#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bounded Alpine readiness: live manager process and its TCP listener."""
import os
from pathlib import Path
import sys
import time

deadline = time.monotonic() + int(sys.argv[1] if len(sys.argv) > 1 else 90)
while True:
    processes = []
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            try:
                if (entry / 'comm').read_text().strip() == 'rmlic':
                    processes.append(entry)
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                pass
    sockets = set()
    for entry in processes:
        try:
            for fd in (entry / 'fd').iterdir():
                try:
                    link = os.readlink(fd)
                    if link.startswith('socket:['):
                        sockets.add(link[8:-1])
                except OSError:
                    pass
        except FileNotFoundError:
            pass
    ready = False
    for name in ('tcp', 'tcp6'):
        for line in (Path('/proc/net') / name).read_text().splitlines()[1:]:
            fields = line.split()
            if fields[1].endswith(':0608') and fields[3] == '0A' and fields[9] in sockets:
                ready = True
    if ready:
        print('KEYBRIDGE_RMLIC_READY')
        break
    if time.monotonic() >= deadline:
        print('KEYBRIDGE_ERROR=rmlic_timeout', file=sys.stderr)
        sys.exit(1)
    time.sleep(0.25)
