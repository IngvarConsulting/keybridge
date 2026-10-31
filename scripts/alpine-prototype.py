#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Isolated Alpine/glibc experiment. Never writes to the installed KeyBridge VM.
Uses the existing loopback client configuration at port 15441 without modifying it.
All generated images, private keys, databases and logs belong in --runtime, outside sources.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def command(args, timeout=30, check=True):
    r = subprocess.run([str(x) for x in args], stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} exited {r.returncode}: {r.stdout[-2000:]}')
    return r


class Experiment:
    def __init__(self, root, memory):
        self.root = root.resolve()
        sources = Path(__file__).resolve().parents[1]
        if self.root == sources or sources in self.root.parents:
            raise RuntimeError('Keep VM images, imports, keys and logs outside the source directory')
        self.memory = memory
        self.folder = self.root / f'runs/{memory}-{int(time.time())}'
        self.folder.mkdir(parents=True, mode=0o700)
        self.socket_dir = Path('/tmp') / f'kba-{os.getpid()}'
        self.socket_dir.mkdir(mode=0o700)
        self.qmp_path = self.socket_dir / 'qmp.sock'
        self.process = None
        self.samples = []
        self.end_sampling = threading.Event()
        self.result = {'requested_memory_mib': memory, 'cpus': 1, 'tcg_cache_mib': 16,
                       'started_at': time.time(), 'success': False}
        # Pin the key exported directly from the built root filesystem, not from the network.
        (self.root / 'known_hosts').write_text('[127.0.0.1]:22423 ' + (self.root / 'guest-host-key.pub').read_text())
        self.ssh_args = ['ssh', '-F', '/dev/null', '-i', str(self.root / 'id_ed25519'),
                         '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                         '-o', 'StrictHostKeyChecking=yes',
                         '-o', f'UserKnownHostsFile={self.root / "known_hosts"}',
                         '-o', 'LogLevel=ERROR', '-p', '22423', 'root@127.0.0.1']

    def ssh(self, script, timeout=30, check=True):
        return command(self.ssh_args + [script], timeout, check)

    def qmp(self, operation, args=None):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(10)
            s.connect(str(self.qmp_path))
            stream = s.makefile('rwb', buffering=0)
            assert 'QMP' in json.loads(stream.readline())
            for index, (op, arguments) in enumerate([('qmp_capabilities', {}), (operation, args or {})]):
                stream.write((json.dumps({'execute': op, 'arguments': arguments, 'id': index}) + '\n').encode())
                while True:
                    line = stream.readline()
                    if not line:
                        raise RuntimeError('QMP closed')
                    response = json.loads(line)
                    if response.get('id') == index:
                        if 'error' in response:
                            raise RuntimeError(str(response['error']))
                        break
            return response.get('return')

    def sample_host(self):
        while not self.end_sampling.is_set():
            try:
                value = command(['ps', '-p', str(self.process.pid), '-o', 'rss='], check=False).stdout.strip()
                if value:
                    self.samples.append({'time': time.time(), 'qemu_rss_kib': int(value)})
            except Exception:
                pass
            self.end_sampling.wait(1)

    def metrics(self, label):
        script = '''echo MEMINFO; cat /proc/meminfo; echo SWAPS; cat /proc/swaps
echo PROCESSES
for p in /proc/[0-9]*; do
  name=$(cat "$p/comm" 2>/dev/null) || continue
  case "$name" in rmlic|aksusbd*|hasplmd*)
    echo "PROCESS=$name"
    grep -E 'VmRSS:|VmHWM:|VmSwap:' "$p/status"
    grep -E '^Pss:' "$p/smaps_rollup" 2>/dev/null || true;;
  esac
done
echo DISK; df -k /
echo OOM; dmesg | grep -i -E 'out of memory|killed process|oom-kill' || true
'''
        output = self.ssh(script).stdout
        (self.folder / f'{label}-metrics.txt').write_text(output)
        mem = {}
        for line in output.split('SWAPS')[0].splitlines():
            if ':' in line:
                key, value = line.split(':', 1)
                if value.strip().endswith('kB'):
                    mem[key] = int(value.split()[0])
        value = {'mem_total_kib': mem.get('MemTotal'), 'mem_available_kib': mem.get('MemAvailable'),
                 'mem_used_excluding_reclaimable_kib': mem.get('MemTotal', 0) - mem.get('MemAvailable', 0)}
        self.result.setdefault('guest_metrics', {})[label] = value
        return value

    def evidence(self):
        return json.loads(self.ssh('python3 /usr/local/lib/keybridge/license_evidence.py').stdout)

    def restart_manager(self):
        debug = 'env LD_DEBUG=files,libs ' if os.environ.get('KEYBRIDGE_ALPINE_LD_DEBUG') == '1' else ''
        if os.environ.get('KEYBRIDGE_ALPINE_STRACE') == '1':
            debug = ('env LD_LIBRARY_PATH=/tmp/debugtools/lib /tmp/debugtools/strace -f -s 128 '
                     '-e trace=file,network,ioctl -o /tmp/rmlic.trace /usr/bin/env -u LD_LIBRARY_PATH ')
        self.ssh('for p in $(pidof rmlic); do kill "$p"; done; sleep 1; '
                 'nohup ' + debug + '/opt/1cv8/x86_64/8.5.4.1878/rmlic -rmlic -porttcp 1544 -portudp 1544 '
                 '</dev/null >>/var/log/rmlic.log 2>&1 &')
        for _ in range(30):
            if self.ssh("netstat -ltn | grep -q ':1544 '", check=False).returncode == 0:
                return
            time.sleep(1)
        raise RuntimeError('License manager did not open its listener after restart')

    def debug_tools(self):
        if os.environ.get('KEYBRIDGE_ALPINE_STRACE') != '1':
            return
        tar = subprocess.Popen(['tar', '-cf', '-', '-C', str(self.root / 'debugtools'), '.'], stdout=subprocess.PIPE)
        try:
            subprocess.run(self.ssh_args + ['mkdir -p /tmp/debugtools; tar -xf - -C /tmp/debugtools'],
                           stdin=tar.stdout, check=True, timeout=30)
        finally:
            tar.stdout.close()
            tar.wait(timeout=5)
        self.ssh('nohup env LD_LIBRARY_PATH=/tmp/debugtools/lib /tmp/debugtools/strace -f '
                 '-p $(pidof aksusbd aksusbd_x86_64 | cut -d " " -f 1) -s 128 '
                 '-e trace=file,network,ioctl -o /tmp/aksusbd.trace </dev/null >/tmp/strace.log 2>&1 &')

    def await_hotplug_notification(self):
        if self.ssh('test -x /usr/local/sbin/keybridge-hasp-hotplug', check=False).returncode:
            return  # Debian uses the vendor's udev rule instead.
        for _ in range(20):
            ready = self.ssh('tail -n 1 /run/keybridge/usb-events.log 2>/dev/null | grep -Eq "^(add|bind|change) "', check=False)
            if ready.returncode == 0:
                self.result['usb_hotplug_events'] = self.ssh('tail -n 16 /run/keybridge/usb-events.log').stdout.splitlines()
                return
            time.sleep(0.5)
        raise RuntimeError('mdev did not confirm automatic HASP registration')

    def exercise_replug(self):
        self.qmp('device_del', {'id': 'physical_hasp'})
        for _ in range(20):
            key = json.loads(self.ssh('python3 /usr/local/lib/keybridge/key_info.py').stdout)
            removed = self.ssh('tail -n 1 /run/keybridge/usb-events.log | grep -q "^remove "', check=False)
            if not key.get('keys') and removed.returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError('USB removal or mdev unregister callback was not confirmed')
        self.restart_manager()
        self.result['detached_control'] = self.client('detached-control')
        if self.result['detached_control']['exit_code'] == 0:
            raise RuntimeError('Client succeeded with the key physically detached')
        self.ssh("python3 -c \"import sys; sys.path.insert(0,'/usr/local/lib/keybridge'); import sentinel_guard as g; g.require_no_sentinel_usb(); g.require_guard(g.read_config())\"")
        self.qmp('device_add', {'driver': 'usb-host', 'id': 'physical_hasp', 'bus': 'xhci.0', 'vendorid': 0x0529, 'productid': 1})
        self.await_hotplug_notification()
        self.restart_manager()
        self.result['replugged_control'] = self.client('replugged-control')
        if not self.result['replugged_control']['confirmed']:
            raise RuntimeError('License issuance failed after automatic USB re-registration')
        # Validate the same scan used during service startup for an already-present key.
        self.ssh('for p in $(pidof aksusbd_x86_64); do kill "$p"; done; sleep 1; '
                 '/usr/sbin/aksusbd_x86_64; /usr/local/sbin/keybridge-hasp-hotplug --scan')
        self.restart_manager()
        self.result['scan_control'] = self.client('scan-control')
        if not self.result['scan_control']['confirmed']:
            raise RuntimeError('License issuance failed after driver restart and coldplug scan')
        self.result['usb_hotplug_events'] = self.ssh('tail -n 16 /run/keybridge/usb-events.log').stdout.splitlines()

    def client(self, label):
        target = self.folder / label
        target.mkdir(mode=0o700)
        platform = '/opt/1cv8/8.5.4.1878/1cv8'
        create = command(['arch', '-arm64', platform, 'CREATEINFOBASE', f'File="{target / "ib"}";',
                          '/DisableStartupDialogs', '/DisableStartupMessages', '/Out', target / 'create.log'],
                         timeout=150, check=False)
        (target / 'create-stdout.txt').write_text(create.stdout)
        if create.returncode:
            raise RuntimeError(f'CREATEINFOBASE failed: {create.returncode}')
        before = self.evidence()
        begin = time.time()
        argv = ['arch', '-arm64', platform, 'DESIGNER', '/F', target / 'ib',
                '/DisableStartupDialogs', '/DisableStartupMessages', '/DisableUnrecoverableErrorMessage',
                '/DumpCfg', target / 'probe.cf', '/Out', target / 'client.log', '/DumpResult', target / 'result.txt']
        with (target / 'client-stdout.txt').open('w') as output:
            proc = subprocess.Popen([str(x) for x in argv], stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
            try:
                self.metrics(label + '-during')
                code = proc.wait(timeout=150)
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
        dump_path = target / 'result.txt'
        dump = dump_path.read_text(encoding='utf-8-sig').strip() if dump_path.exists() else ''
        size = (target / 'probe.cf').stat().st_size if (target / 'probe.cf').exists() else 0
        after = self.evidence()
        for _ in range(15):
            if code != 0 or after['hardwareLocal'] > before['hardwareLocal']:
                break
            time.sleep(1)
            after = self.evidence()
        value = {'exit_code': code, 'dump_result': dump, 'configuration_bytes': size,
                 'elapsed_seconds': round(time.time() - begin, 2), 'before': before, 'after': after,
                 'hardware_local_delta': after['hardwareLocal'] - before['hardwareLocal'],
                 'issuance_delta': after['seize'] + after['reuse'] - before['seize'] - before['reuse']}
        value['confirmed'] = code == 0 and dump == '0' and size > 0 and value['hardware_local_delta'] > 0 and value['issuance_delta'] > 0
        save(target / 'result.json', value)
        return value

    def start(self):
        for port in (22423, 15441):
            with socket.socket() as s:
                s.bind(('127.0.0.1', port))
        disk = self.folder / 'guest.qcow2'
        base = Path(os.environ.get('KEYBRIDGE_ALPINE_BASE_IMAGE', str(self.root / 'base.qcow2'))).resolve()
        self.result['base_image'] = str(base)
        command(['/opt/homebrew/bin/qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', base, disk])
        args = ['/opt/homebrew/bin/qemu-system-x86_64', '-name', f'keybridge-alpine-{self.memory}',
                '-machine', 'q35', '-accel', 'tcg,thread=single,tb-size=16', '-cpu', 'max', '-smp', '1', '-m', str(self.memory),
                '-nodefaults', '-display', 'none', '-monitor', 'none', '-serial', f'file:{self.folder / "console.log"}',
                '-qmp', f'unix:{self.qmp_path},server=on,wait=off', '-kernel', self.root / 'vmlinuz-virt',
                '-initrd', self.root / 'initramfs-virt', '-append', 'root=/dev/vda rw console=ttyS0 modules=ext4,virtio_blk',
                '-drive', f'file={disk},if=virtio,format=qcow2',
                '-netdev', 'user,id=lan,restrict=on,hostfwd=tcp:127.0.0.1:22423-:22,hostfwd=tcp:127.0.0.1:15441-:1544',
                '-device', 'virtio-net-pci,netdev=lan', '-device', 'qemu-xhci,id=xhci']
        save(self.folder / 'qemu-arguments.json', [str(x) for x in args])
        with (self.folder / 'qemu.log').open('w') as log:
            self.process = subprocess.Popen([str(x) for x in args], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        self.sampler = threading.Thread(target=self.sample_host, daemon=True)
        self.sampler.start()
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('QEMU exited before SSH readiness')
            try:
                ready = self.ssh('true', timeout=10, check=False).returncode == 0
            except subprocess.TimeoutExpired:
                ready = False
            if ready:
                self.result['boot_to_ssh_seconds'] = round(time.time() - self.result['started_at'], 2)
                return
            time.sleep(1)
        raise RuntimeError('SSH readiness timed out; see console.log')

    def run(self):
        try:
            self.start()
            self.debug_tools()
            self.result['guest_os'] = self.ssh('cat /etc/alpine-release; uname -r').stdout.strip()
            self.metrics('boot')
            self.ssh("python3 -c \"import sys; sys.path.insert(0,'/usr/local/lib/keybridge'); import sentinel_guard as g; g.require_no_sentinel_usb(); g.wait_for_config(); g.require_admin_success(g.request_xml('adminapi/set', g.SET_GUARD)); g.require_guard(g.read_config())\"", timeout=60)
            self.ssh('for p in $(pidof hasplmd hasplmd_x86_64); do kill "$p"; done; sleep 1; /usr/sbin/hasplmd_x86_64 -s')
            guard = json.loads(self.ssh('python3 /usr/local/lib/keybridge/sentinel_guard.py check', timeout=100).stdout)
            if guard.get('status') != 'ok' or guard.get('no_auto_fwup') != '1':
                raise RuntimeError('Firmware guard not confirmed after restart; refusing USB')
            self.result['guard_before_usb'] = guard
            self.restart_manager()
            self.result['negative_control'] = self.client('without-usb')
            if self.result['negative_control']['exit_code'] == 0:
                raise RuntimeError('Negative control succeeded without USB; licensing source is ambiguous')
            host_devices = self.qmp('human-monitor-command', {'command-line': 'info usbhost'})
            if host_devices.count('0529:0001') != 1:
                raise RuntimeError('Expected exactly one physical Sentinel USB device')
            self.qmp('device_add', {'driver': 'usb-host', 'id': 'physical_hasp', 'bus': 'xhci.0', 'vendorid': 0x0529, 'productid': 1})
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                key = json.loads(self.ssh('python3 /usr/local/lib/keybridge/key_info.py', timeout=15).stdout)
                if len(key.get('keys', [])) == 1:
                    self.result['key'] = key
                    break
                time.sleep(1)
            else:
                raise RuntimeError('Sentinel did not detect the physical USB key')
            self.await_hotplug_notification()
            self.metrics('idle-with-key')
            self.restart_manager()
            self.result['positive_control'] = self.client('with-usb')
            if self.result['positive_control']['confirmed'] and os.environ.get('KEYBRIDGE_ALPINE_REPLUG') == '1':
                self.exercise_replug()
            if not self.result['positive_control']['confirmed'] and os.environ.get('KEYBRIDGE_ALPINE_DIAGNOSE') == '1':
                self.result['diagnostic_trials'] = {}
                trials = {
                    'restart-usb-daemons': 'for p in $(pidof hasplmd hasplmd_x86_64 aksusbd aksusbd_x86_64); do kill "$p"; done; sleep 1; /usr/sbin/aksusbd_x86_64; /usr/sbin/hasplmd_x86_64 -s',
                    'hostname-resolution': "printf '127.0.0.1 localhost keybridge-alpine\\n::1 localhost\\n' > /etc/hosts",
                }
                for trial, script in trials.items():
                    self.ssh(script)
                    self.restart_manager()
                    self.result['diagnostic_trials'][trial] = self.client(trial)
                    if self.result['diagnostic_trials'][trial]['confirmed']:
                        break
            self.metrics('after-client')
            self.result['guard_after_client'] = json.loads(self.ssh('python3 /usr/local/lib/keybridge/sentinel_guard.py check', timeout=100).stdout)
            self.result['success'] = self.result['positive_control']['confirmed'] and self.result['guard_after_client'].get('no_auto_fwup') == '1'
            if not self.result['success']:
                raise RuntimeError('Client did not prove a hardware license from this VM')
        except Exception as error:
            self.result['error'] = str(error)
            if self.process and self.process.poll() is None:
                try:
                    diagnostic = self.ssh('dmesg; cat /var/log/rmlic.log /var/log/hasplmd.log /var/log/aksusbd.log 2>/dev/null', timeout=15, check=False)
                    (self.folder / 'failure-diagnostics.txt').write_text(diagnostic.stdout)
                    raw = self.ssh('find /var/log/keybridge-lic -type f -name "*.log" -exec cat {} \\;', timeout=15, check=False)
                    (self.folder / 'private-license.log').write_text(raw.stdout)
                    if os.environ.get('KEYBRIDGE_ALPINE_STRACE') == '1':
                        for name in ('rmlic.trace', 'aksusbd.trace', 'strace.log'):
                            trace = self.ssh('cat /tmp/' + name, timeout=15, check=False)
                            (self.folder / name).write_text(trace.stdout)
                except Exception:
                    pass
        finally:
            if self.process and self.process.poll() is None:
                try:
                    self.ssh('sync; poweroff', timeout=5, check=False)
                    self.process.wait(timeout=15)
                except Exception:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait()
            self.end_sampling.set()
            if hasattr(self, 'sampler'):
                self.sampler.join(timeout=3)
            save(self.folder / 'host-memory-samples.json', self.samples)
            self.result['host_qemu_rss_peak_kib'] = max((x['qemu_rss_kib'] for x in self.samples), default=0)
            self.result['finished_at'] = time.time()
            save(self.folder / 'result.json', self.result)
            try:
                self.qmp_path.unlink(missing_ok=True)
                self.socket_dir.rmdir()
            except OSError:
                pass
        print(json.dumps({'folder': str(self.folder), **self.result}, indent=2))
        return 0 if self.result['success'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--memory', type=int, choices=(128, 256), required=True)
    args = parser.parse_args()
    os.umask(0o077)
    raise SystemExit(Experiment(args.runtime, args.memory).run())
