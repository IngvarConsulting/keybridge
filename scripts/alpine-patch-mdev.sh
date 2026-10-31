#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline patch of an isolated ext4 copy; run in the disposable Alpine tools container.
set -eu
test -f /.dockerenv && test -f /work/mdev-patch.ext4
test -f /scripts/alpine-hasp-hotplug.sh
apk add --no-cache e2fsprogs-extra >/dev/null
debugfs -R 'cat /etc/mdev.conf' /work/mdev-patch.ext4 > /work/mdev.conf.before
debugfs -R 'cat /etc/local.d/keybridge.start' /work/mdev-patch.ext4 > /work/keybridge.start.before
test -s /work/mdev.conf.before && test -s /work/keybridge.start.before
if grep -q keybridge-hasp-hotplug /work/mdev.conf.before; then
    echo 'This image already has the mdev callback' >&2
    exit 1
fi
{
    printf '%s\n' '$PRODUCT=529/1/.* 0:0 0664 */usr/local/sbin/keybridge-hasp-hotplug'
    cat /work/mdev.conf.before
} > /work/mdev.conf.patched
sed '/^\/usr\/sbin\/hasplmd_x86_64 -s/a /usr/local/sbin/keybridge-hasp-hotplug --scan' \
    /work/keybridge.start.before > /work/keybridge.start.patched
cat > /work/mdev-patch.debugfs <<'EOF'
mkdir /usr/local/sbin
write /scripts/alpine-hasp-hotplug.sh /usr/local/sbin/keybridge-hasp-hotplug
set_inode_field /usr/local/sbin/keybridge-hasp-hotplug mode 0100755
rm /etc/mdev.conf
write /work/mdev.conf.patched /etc/mdev.conf
set_inode_field /etc/mdev.conf mode 0100644
rm /etc/local.d/keybridge.start
write /work/keybridge.start.patched /etc/local.d/keybridge.start
set_inode_field /etc/local.d/keybridge.start mode 0100755
EOF
debugfs -w -f /work/mdev-patch.debugfs /work/mdev-patch.ext4 > /work/mdev-patch-output.txt 2>&1
debugfs -R 'stat /usr/local/sbin/keybridge-hasp-hotplug' /work/mdev-patch.ext4
debugfs -R 'cat /etc/local.d/keybridge.start' /work/mdev-patch.ext4
