#!/bin/sh
# SPDX-License-Identifier: MIT
# Runs at developer build time in an open-source-only Alpine container.
set -eu
mkdir -p /usr/local/lib/keybridge /usr/local/bin /usr/local/sbin /etc/local.d /etc/hasplm /base-export
cp /helpers/*.py /usr/local/lib/keybridge/
cp /helpers/alpine_service.sh /usr/local/sbin/keybridge-services
cp /helpers/alpine_hasp_hotplug.sh /usr/local/sbin/keybridge-hasp-hotplug
cp /helpers/alpine_bootstrap.sh /usr/local/sbin/keybridge-bootstrap
cp /helpers/rmlic_ready.sh /usr/local/bin/keybridge-rmlic-ready
chmod 755 /usr/local/sbin/* /usr/local/bin/keybridge-rmlic-ready
adduser -D -s /bin/sh hasp
sed -i 's/^hasp:[^:]*:/hasp:*:/' /etc/shadow
mkdir -p /etc/sudoers.d /etc/ssh/sshd_config.d
echo 'hasp ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/keybridge
chmod 440 /etc/sudoers.d/keybridge
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nUseDNS no\n' > /etc/ssh/sshd_config.d/keybridge.conf
cat > /etc/init.d/keybridge-bootstrap <<'EOF'
#!/sbin/openrc-run
description="Initialize credentials from this generation's seed"
depend() { need modules localmount; before sshd; }
start() { /usr/local/sbin/keybridge-bootstrap; }
EOF
chmod 755 /etc/init.d/keybridge-bootstrap
printf '#!/bin/sh\n/usr/local/sbin/keybridge-services start >>/var/log/keybridge-start.log 2>&1\n' > /etc/local.d/keybridge.start
chmod 755 /etc/local.d/keybridge.start
{ printf '%s\n' '$PRODUCT=529/1/.* 0:0 0664 */usr/local/sbin/keybridge-hasp-hotplug'; cat /etc/mdev.conf; } > /etc/mdev.conf.new
mv /etc/mdev.conf.new /etc/mdev.conf
printf '[SERVER]\nno_auto_fwup = 1\n' > /etc/hasplm/hasplm.ini
echo keybridge-alpine > /etc/hostname
printf 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet dhcp\n' > /etc/network/interfaces
printf '/dev/vda / ext4 defaults,noatime 0 1\n' > /etc/fstab
printf 'virtio_net\nxhci_pci\nahci\nsr_mod\n' > /etc/modules
echo 'ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100' >> /etc/inittab
for service in devfs dmesg mdev; do rc-update add "$service" sysinit; done
for service in modules hostname bootmisc networking keybridge-bootstrap; do rc-update add "$service" boot; done
for service in sshd local; do rc-update add "$service" default; done
for service in killprocs mount-ro; do rc-update add "$service" shutdown; done
kernel=$(ls /lib/modules)
mkinitfs -F 'base ext4 ata scsi usb virtio cdrom' "$kernel"
cp /boot/vmlinuz-virt /base-export/vmlinuz-virt
cp /boot/initramfs-virt /base-export/initramfs-virt
apk info -vv > /base-export/alpine-packages.txt
apk info -a > /base-export/alpine-package-details.txt
rm -f /etc/ssh/ssh_host_* /etc/machine-id
test ! -d /opt/1cv8
test ! -e /usr/sbin/aksusbd_x86_64
test ! -e /usr/sbin/hasplmd_x86_64
test ! -f /home/hasp/.ssh/authorized_keys
rm -rf /boot/* /var/cache/apk/* /tmp/* /var/log/*
