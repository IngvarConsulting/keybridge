#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Actions against the explicitly running disposable diagnostic VM only."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('action', choices=('ssh', 'guard', 'attach', 'detach', 'probe', 'restart-manager', 'stop'))
    parser.add_argument('--command')
    parser.add_argument('--label', default='diagnostic-client')
    args = parser.parse_args()
    root = args.runtime.resolve()
    state = json.loads((root / 'investigation-active.json').read_text())
    actual = subprocess.check_output(['ps', '-p', str(state['qemu_pid']), '-o', 'command='], text=True)
    if 'qemu-system-x86_64' not in actual or state['qmp'] not in actual:
        raise RuntimeError('Diagnostic VM ownership check failed')
    mod = load('alpine-prototype')
    cls = mod.Experiment if state['os'] == 'alpine' else load('alpine-debian-baseline').DebianControl
    e = cls.__new__(cls)
    e.root = root
    e.folder = Path(state['folder'])
    e.qmp_path = Path(state['qmp'])
    e.ssh_args = state['ssh_args']
    e.result = {}
    if args.action == 'stop':
        (e.folder / 'stop.flag').touch()
    elif args.action == 'detach':
        print(e.qmp('device_del', {'id': 'physical_hasp'}))
    elif args.action == 'restart-manager':
        e.restart_manager()
    elif args.action == 'ssh':
        if not args.command:
            parser.error('--command is required')
        print(e.ssh(args.command, timeout=120).stdout, end='')
    elif args.action == 'guard':
        e.ssh("python3 -c \"import sys; sys.path.insert(0,'/usr/local/lib/keybridge'); import sentinel_guard as g; g.require_no_sentinel_usb(); g.wait_for_config(); g.require_admin_success(g.request_xml('adminapi/set',g.SET_GUARD)); g.require_guard(g.read_config())\"", timeout=90)
        e.ssh('for p in $(pidof hasplmd hasplmd_x86_64); do kill "$p"; done; sleep 1; /usr/sbin/hasplmd_x86_64 -s')
        value = json.loads(e.ssh('python3 /usr/local/lib/keybridge/sentinel_guard.py check', timeout=100).stdout)
        if value.get('status') != 'ok' or value.get('no_auto_fwup') != '1':
            raise RuntimeError('Firmware guard failed')
        (e.folder / 'guard.json').write_text(json.dumps(value))
        print(json.dumps(value))
    elif args.action == 'attach':
        # Fresh strict Admin API check; diagnostics/version generation is unrelated
        # to the persisted firmware-update prohibition and can be expensive in TCG.
        e.ssh("python3 -c \"import sys; sys.path.insert(0,'/usr/local/lib/keybridge'); import sentinel_guard as g; g.require_no_sentinel_usb(); g.require_guard(g.read_config())\"")
        hosts = e.qmp('human-monitor-command', {'command-line': 'info usbhost'})
        if hosts.count('0529:0001') != 1:
            raise RuntimeError('Expected one physical key')
        print(e.qmp('device_add', {'driver': 'usb-host', 'id': 'physical_hasp', 'bus': 'xhci.0', 'vendorid': 0x0529, 'productid': 1}))
    elif args.action == 'probe':
        if not args.label.replace('-', '').replace('_', '').isalnum():
            raise RuntimeError('Invalid probe label')
        print(json.dumps(e.client(args.label), indent=2))
