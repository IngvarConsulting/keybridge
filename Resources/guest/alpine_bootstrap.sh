#!/bin/sh
# SPDX-License-Identifier: MIT
# Per-generation credentials are supplied by the Mac, never baked into the base.
set -eu
test ! -f /var/lib/keybridge/bootstrapped || exit 0
mkdir -p /mnt/seed /home/hasp/.ssh /var/lib/keybridge
device=$(blkid -L cidata)
mount -o ro "$device" /mnt/seed
trap 'umount /mnt/seed' EXIT
install -m 600 /mnt/seed/authorized_keys /home/hasp/.ssh/authorized_keys
chown -R hasp:hasp /home/hasp/.ssh
chmod 700 /home/hasp/.ssh
install -m 600 /mnt/seed/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
install -m 644 /mnt/seed/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
touch /var/lib/keybridge/bootstrapped
