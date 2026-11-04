#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only manager readiness; also used by the combined health observer."""
import os
from pathlib import Path
import sys
import time

def manager_ready():
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
    return ready

def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) > 1 or (arguments and not arguments[0].isdigit()):
        print('KEYBRIDGE_ERROR=invalid_readiness_timeout', file=sys.stderr)
        return 2
    deadline = time.monotonic() + int(arguments[0] if arguments else 90)
    while not manager_ready():
        if time.monotonic() >= deadline:
            print('KEYBRIDGE_ERROR=rmlic_timeout', file=sys.stderr)
            return 1
        time.sleep(0.25)
    print('KEYBRIDGE_RMLIC_READY')
    return 0


if __name__ == "__main__":
    sys.exit(main())
