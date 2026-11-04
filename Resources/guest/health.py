#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""One read-only observation, using this app's existing safety checkers.

The host supplies the checker sources so already-prepared VMs need no update.
No module executes its command-line entry point and no extra process is started.
"""
import ctypes
import json
import os
import select
import sys
import struct
from pathlib import Path


def observe(sources):
    modules = {}
    for name in ('sentinel_guard', 'key_info', 'alpine_ready'):
        scope = {'__name__': name}
        exec(compile(sources[name], name + '.py', 'exec'), scope)
        modules[name] = scope
    guard = modules['sentinel_guard']
    try:
        value = guard['read_config']()
        guard['require_guard'](value)
    except Exception:
        return {'status': 'unsafe', 'no_auto_fwup': None}
    services = set()
    for path in Path('/proc').glob('[0-9]*/comm'):
        try:
            services.add(path.read_text().strip())
        except OSError:
            pass
    hotplug = Path('/run/keybridge/usb-events.log').read_text() if Path('/run/keybridge/usb-events.log').exists() else ''
    missing = [name for name in ('aksusbd_x86_64', 'hasplmd_x86_64', 'rmlic') if name not in services]
    keys = []
    if 'hasplmd_x86_64' not in missing:
        try:
            keys = modules['key_info']['read_keys']()
        except (Exception, SystemExit):
            # The runtime API has failed, independently of the firmware setting.
            missing.append('hasplmd_x86_64')
    manager_ready = modules['alpine_ready']['manager_ready']()
    if not manager_ready and 'rmlic' not in missing:
        missing.append('rmlic')
    return {'status': 'ok', 'no_auto_fwup': value, 'keys': keys, 'failedServices': missing,
            'services': not missing,
            'managerReady': manager_ready,
            'hotplug': any(p.is_symlink() for p in Path('/dev/aks/hasp').glob('*')) and
                       any(line.startswith(('add ', 'bind ', 'change ')) for line in hotplug.splitlines())}


def watch_protection():
    """Watch the directory so replacement of hasplm.ini is observed too."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_init1.restype = ctypes.c_int
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    libc.inotify_add_watch.restype = ctypes.c_int
    descriptor = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
    if descriptor < 0:
        raise OSError(ctypes.get_errno(), 'inotify unavailable')
    # MODIFY, ATTRIB, CLOSE_WRITE, MOVED_FROM/TO, CREATE/DELETE, DELETE/MOVE_SELF.
    mask = 0x2 | 0x4 | 0x8 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800
    if libc.inotify_add_watch(descriptor, b'/etc/hasplm', mask) < 0:
        os.close(descriptor)
        raise OSError(ctypes.get_errno(), 'protection directory unavailable')
    return descriptor


def protection_changed(events):
    offset = 0
    while offset + 16 <= len(events):
        _, mask, _, length = struct.unpack_from('iIII', events, offset)
        name = events[offset + 16:offset + 16 + length].split(b'\0', 1)[0]
        if mask & (0x400 | 0x800 | 0x4000 | 0x8000) or name == b'hasplm.ini':
            return True
        offset += 16 + length
    return False


def watch_services():
    """Subscribe once to actual process exits; do not periodically run checks."""
    required = {'aksusbd_x86_64', 'hasplmd_x86_64', 'rmlic'}
    descriptors = []
    found = set()
    poller = select.poll()
    try:
        for path in Path('/proc').glob('[0-9]*/comm'):
            try:
                name = path.read_text().strip()
                if name not in required:
                    continue
                descriptor = os.pidfd_open(int(path.parent.name))
                descriptors.append(descriptor)
                poller.register(descriptor, select.POLLIN)
                found.add(name)
            except FileNotFoundError:
                continue
        if found != required:
            print(json.dumps({'failedServices': sorted(required - found)}), flush=True)
            return
        protection = watch_protection()
        descriptors.append(protection)
        poller.register(protection, select.POLLIN)
        print(json.dumps({'watching': True}), flush=True)
        while True:
            for descriptor, events in poller.poll():
                if descriptor != protection or events & (select.POLLERR | select.POLLHUP | select.POLLNVAL):
                    return
                if protection_changed(os.read(protection, 65536)):
                    return
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


if __name__ == '__main__':
    if sys.argv[1:] == ['--watch-services']:
        watch_services()
        sys.exit(0)
    try:
        print(json.dumps(observe(SOURCES), separators=(',', ':')))
    except Exception:
        print(json.dumps({'status': 'unknown'}))
