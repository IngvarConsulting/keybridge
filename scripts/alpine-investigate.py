#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Hold an isolated diagnostic VM; stop by creating stop.flag in its run folder.
USB is NOT attached automatically. The normal firmware guard remains mandatory.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--os', choices=('alpine', 'debian'), default='alpine')
    parser.add_argument('--source', type=Path)
    parser.add_argument('--hold-seconds', type=int, default=1800)
    args = parser.parse_args()
    os.umask(0o077)
    if args.os == 'alpine':
        e = load('alpine-prototype').Experiment(args.runtime, 256)
    else:
        if not args.source:
            parser.error('--source is required for the Debian control')
        e = load('alpine-debian-baseline').DebianControl(args.runtime, args.source)
    try:
        e.start()
        state = {'os': args.os, 'folder': str(e.folder), 'qmp': str(e.qmp_path),
                 'qemu_pid': e.process.pid, 'owner_pid': os.getpid(), 'ssh_args': e.ssh_args}
        (args.runtime / 'investigation-active.json').write_text(json.dumps(state, indent=2))
        print(json.dumps(state), flush=True)
        deadline = time.monotonic() + args.hold_seconds
        while time.monotonic() < deadline and not (e.folder / 'stop.flag').exists():
            if e.process.poll() is not None:
                break
            time.sleep(1)
    finally:
        if e.process and e.process.poll() is None:
            try:
                e.ssh('sync; poweroff', timeout=5, check=False)
                e.process.wait(timeout=15)
            except Exception:
                e.process.terminate()
                try:
                    e.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    e.process.kill()
                    e.process.wait()
        e.end_sampling.set()
        if hasattr(e, 'sampler'):
            e.sampler.join(timeout=3)
        (e.folder / 'host-memory-samples.json').write_text(json.dumps(e.samples))
        try:
            e.qmp_path.unlink(missing_ok=True)
            e.socket_dir.rmdir()
        except OSError:
            pass
        (args.runtime / 'investigation-active.json').unlink(missing_ok=True)
