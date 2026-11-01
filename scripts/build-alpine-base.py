#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the redistributable open Linux base. No user installers are mounted."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(os.environ.get('KEYBRIDGE_BUILD_ROOT', str(Path.home()/'Library/Caches/KeyBridgeDevelopment'))).resolve()
OUT = BUILD/'alpine-base'

def run(*args):
    subprocess.run([str(x) for x in args], check=True)

def build():
    assert ROOT != BUILD and ROOT not in BUILD.parents
    context = BUILD/'alpine-base-context'
    context.mkdir(parents=True, exist_ok=True)
    # Deleted helpers must not survive in a cached build context or its identity.
    if (context/'helpers').exists(): shutil.rmtree(context/'helpers')
    shutil.copytree(ROOT/'Resources/guest', context/'helpers')
    shutil.copy2(ROOT/'scripts/configure-alpine-base.sh', context/'configure.sh')
    dockerfile = '''FROM debian:12-slim AS glibc
RUN apt-get update && apt-get install -y --no-install-recommends libfontconfig1 libfreetype6 libglib2.0-0 libgssapi-krb5-2 libstdc++6 libusb-1.0-0
RUN mkdir -p /glibc/lib/x86_64-linux-gnu /glibc/lib64 /glibc/etc /notices/debian && find -L /usr/lib/x86_64-linux-gnu -maxdepth 1 -type f -name '*.so*' -exec cp -L {} /glibc/lib/x86_64-linux-gnu/ \\; && ln -s /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /glibc/lib64/ld-linux-x86-64.so.2 && ldconfig -r /glibc && dpkg-query -W > /notices/debian-packages.txt && dpkg-query -W -f='${binary:Package}\\t${Version}\\t${source:Package}\\t${source:Version}\\n' > /notices/debian-source-packages.txt && find /usr/share/doc -name copyright -exec cp --parents {} /notices/debian/ \\;
FROM alpine:3.22
RUN apk add --no-cache alpine-base openssh python3 linux-virt e2fsprogs sudo lsblk blkid findmnt dpkg util-linux
COPY --from=glibc /glibc/ /
COPY --from=glibc /notices/ /base-notices/
COPY helpers/ /helpers/
COPY configure.sh /configure.sh
RUN sh /configure.sh
CMD ["sh", "-c", "mkdir /rootfs; tar --exclude=./rootfs --exclude=./export --exclude=./helpers --exclude=./base-export --exclude=./base-notices --exclude=./configure.sh --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./.dockerenv --exclude=./etc/hosts --exclude=./etc/hostname --exclude=./etc/resolv.conf -cf - . | tar -xf - -C /rootfs; mkdir -p /rootfs/dev /rootfs/proc /rootfs/sys /rootfs/run; echo keybridge-alpine > /rootfs/etc/hostname; printf '127.0.0.1 localhost keybridge-alpine\\n' > /rootfs/etc/hosts; truncate -s 2G /export/rootfs.ext4; mkfs.ext4 -F -m 0 -d /rootfs /export/rootfs.ext4; cp /base-export/* /export/; cp -a /base-notices /export/notices"]
'''
    (context/'Dockerfile').write_text(dockerfile)
    # Rebuild when configuration or helper sources change; docker caches packages.
    identity = hashlib.sha256(dockerfile.encode()+(context/'configure.sh').read_bytes()+b''.join(p.read_bytes() for p in sorted((context/'helpers').glob('*')) if p.is_file())).hexdigest()
    if (OUT/'manifest.json').exists() and json.loads((OUT/'manifest.json').read_text()).get('build_id') == identity:
        print('Using matching open Alpine base:', OUT)
        return OUT
    OUT.mkdir(parents=True, exist_ok=True)
    run('docker', 'build', '--platform', 'linux/amd64', '-t', 'keybridge-open-base:local', context)
    stage = BUILD/'alpine-base-export'
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir()
    run('docker', 'run', '--rm', '--platform', 'linux/amd64', '--network', 'none', '-v', str(stage)+':/export', '-w', '/', 'keybridge-open-base:local')
    run('/opt/homebrew/bin/qemu-img','convert','-c','-f','raw','-O','qcow2',stage/'rootfs.ext4',OUT/'alpine.qcow2')
    names = ['alpine.qcow2','vmlinuz-virt','initramfs-virt','alpine-packages.txt','alpine-package-details.txt']
    for name in names[1:]: shutil.copy2(stage/name, OUT/name)
    if (OUT/'notices').exists(): shutil.rmtree(OUT/'notices')
    shutil.copytree(stage/'notices',OUT/'notices')
    files = {name:hashlib.sha256((OUT/name).read_bytes()).hexdigest() for name in names}
    (OUT/'manifest.json').write_text(json.dumps({'build_id':identity,'files':files,'proprietary_components_included':False,'private_keys_included':False,'sources':['https://dl-cdn.alpinelinux.org/alpine/v3.22/','https://deb.debian.org/debian/']},indent=2)+'\n')
    (stage/'rootfs.ext4').unlink()
    print('Built open Alpine base:',OUT)
    return OUT

if __name__ == '__main__': build()
