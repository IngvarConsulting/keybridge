#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only backing-disk Debian control for the Alpine experiment.
Only the new overlay in --runtime is writable. The source VM must be stopped.
"""
import argparse
import importlib.util
from pathlib import Path
import shlex
import socket
import subprocess
import threading
import time

spec = importlib.util.spec_from_file_location('alpine_prototype', Path(__file__).with_name('alpine-prototype.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class DebianControl(m.Experiment):
    def __init__(self, runtime, source):
        super().__init__(runtime, 1024)
        self.source = source.resolve()
        self.result.update(cpus=2, tcg_cache_mib=64, control='Debian original disk with disposable overlay')
        self.ssh_args = ['ssh', '-F', '/dev/null', '-i', str(self.source / 'id_ed25519'),
                         '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                         '-o', 'StrictHostKeyChecking=accept-new',
                         '-o', f'UserKnownHostsFile={self.root / "baseline-known_hosts"}',
                         '-o', 'LogLevel=ERROR', '-p', '22423', 'hasp@127.0.0.1']

    def ssh(self, script, timeout=30, check=True):
        script = script.replace('cat /etc/alpine-release', 'cat /etc/debian_version')
        script = script.replace('/usr/sbin/hasplmd -s', '/usr/sbin/hasplmd_x86_64 -s')
        return m.command(self.ssh_args + ['sudo sh -c ' + shlex.quote(script)], timeout, check)

    def restart_manager(self):
        self.ssh('systemctl restart keybridge-rmlic')

    def start(self):
        for port in (22423, 15441):
            with socket.socket() as s:
                s.bind(('127.0.0.1', port))
        disk = self.folder / 'guest.qcow2'
        m.command(['/opt/homebrew/bin/qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2',
                   '-b', self.source / 'guest.qcow2', disk])
        args = ['/opt/homebrew/bin/qemu-system-x86_64', '-name', 'keybridge-debian-control',
                '-machine', 'q35', '-accel', 'tcg,thread=multi,tb-size=64', '-cpu', 'max', '-smp', '2', '-m', '1024',
                '-nodefaults', '-display', 'none', '-monitor', 'none', '-serial', f'file:{self.folder / "console.log"}',
                '-qmp', f'unix:{self.qmp_path},server=on,wait=off',
                '-drive', f'file={disk},if=virtio,format=qcow2',
                '-drive', f'file={self.source / "seed.iso"},if=ide,media=cdrom,readonly=on',
                '-netdev', 'user,id=lan,restrict=on,hostfwd=tcp:127.0.0.1:22423-:22,hostfwd=tcp:127.0.0.1:15441-:1544',
                '-device', 'virtio-net-pci,netdev=lan', '-device', 'qemu-xhci,id=xhci']
        m.save(self.folder / 'qemu-arguments.json', [str(x) for x in args])
        with (self.folder / 'qemu.log').open('w') as log:
            self.process = subprocess.Popen([str(x) for x in args], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        self.sampler = threading.Thread(target=self.sample_host, daemon=True)
        self.sampler.start()
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('Debian control QEMU exited')
            try:
                ready = self.ssh('true', timeout=20, check=False).returncode == 0
            except subprocess.TimeoutExpired:
                ready = False
            if ready:
                self.result['boot_to_ssh_seconds'] = round(time.time() - self.result['started_at'], 2)
                helpers = Path(__file__).resolve().parents[1] / 'Resources/guest'
                self.ssh('mkdir -p /usr/local/lib/keybridge')
                for name in ('sentinel_guard.py', 'key_info.py', 'license_evidence.py'):
                    self.ssh('printf %s ' + shlex.quote((helpers / name).read_text()) +
                             ' > /usr/local/lib/keybridge/' + name)
                return
            time.sleep(1)
        raise RuntimeError('Debian control SSH readiness timed out')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    m.os.umask(0o077)
    raise SystemExit(DebianControl(args.runtime, args.source).run())
