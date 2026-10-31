#!/bin/sh
# SPDX-License-Identifier: MIT
# Experimental guest builder. Run only in the disposable Alpine build container.
# /work contains user-owned imports outside the source tree; /helpers is read-only.
set -eu
test -f /.dockerenv && test -d /work && test -d /helpers
test -f /prototype-scripts/alpine-hasp-hotplug.sh
test -f /work/vendor-opt.tar && test -f /work/glibc-libraries.tar && test -f /work/sentinel.tar
apk add --no-cache lsblk
tar -xf /work/vendor-opt.tar -C /
mkdir -p /lib/x86_64-linux-gnu /lib64
tar -xf /work/glibc-libraries.tar -C /lib
ln -sf /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
tar -xf /work/sentinel.tar -C /
cp -a /sentinel/. /
rm -rf /sentinel
# The amd64 DEB also carries 32-bit entry points; Debian's postinst normally
# selects the suffixed 64-bit daemons. Alpine has no 32-bit glibc loader.
rm /usr/sbin/aksusbd /usr/sbin/hasplmd
ln -s aksusbd_x86_64 /usr/sbin/aksusbd
ln -s hasplmd_x86_64 /usr/sbin/hasplmd

mkdir -p /root/.ssh /usr/local/lib/keybridge /var/log/keybridge-lic /opt/1cv8/conf
cp /work/id_ed25519.pub /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A
cp /etc/ssh/ssh_host_ed25519_key.pub /work/guest-host-key.pub
cat > /etc/ssh/sshd_config.d/keybridge.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UseDNS no
EOF
echo keybridge-alpine > /etc/hostname
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
EOF
cat > /etc/fstab <<'EOF'
/dev/vda / ext4 defaults,noatime 0 1
EOF
cat > /etc/modules <<'EOF'
virtio_net
xhci_pci
EOF
sed -i 's/^#\?ttyS0::.*/ttyS0::respawn:\/sbin\/getty -L ttyS0 115200 vt100/' /etc/inittab
grep -q '^ttyS0::' /etc/inittab || echo 'ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100' >> /etc/inittab
for service in devfs dmesg mdev; do rc-update add "$service" sysinit; done
for service in modules hostname bootmisc networking; do rc-update add "$service" boot; done
for service in sshd local; do rc-update add "$service" default; done
for service in killprocs mount-ro; do rc-update add "$service" shutdown; done

cp /helpers/sentinel_guard.py /helpers/key_info.py /helpers/license_evidence.py /usr/local/lib/keybridge/
cat > /opt/1cv8/conf/nethasp.ini <<'EOF'
[NH_COMMON]
NH_IPX=Disabled
NH_NETBIOS=Disabled
NH_TCPIP=Disabled
EOF
cat > /opt/1cv8/conf/logcfg.xml <<'EOF'
<?xml version="1.0"?>
<config xmlns="http://v8.1c.ru/v8/tech-log">
  <log location="/var/log/keybridge-lic" history="1">
    <event><eq property="name" value="LIC"/></event>
    <property name="all"/>
  </log>
</config>
EOF
mkdir -p /etc/hasplm
cat > /etc/hasplm/hasplm.ini <<'EOF'
[SERVER]
no_auto_fwup = 1
EOF
cat > /etc/local.d/keybridge.start <<'EOF'
#!/bin/sh
mkdir -p /var/log/keybridge-lic /run/keybridge
/usr/sbin/aksusbd_x86_64 >> /var/log/aksusbd.log 2>&1
/usr/sbin/hasplmd_x86_64 -s >> /var/log/hasplmd.log 2>&1
sleep 1
/opt/1cv8/x86_64/8.5.4.1878/rmlic -rmlic -porttcp 1544 -portudp 1544 >> /var/log/rmlic.log 2>&1 &
echo $! > /run/keybridge/rmlic.pid
EOF
chmod 755 /etc/local.d/keybridge.start
mkdir -p /usr/local/sbin
cp /prototype-scripts/alpine-hasp-hotplug.sh /usr/local/sbin/keybridge-hasp-hotplug
chmod 755 /usr/local/sbin/keybridge-hasp-hotplug
{ printf '%s\n' '$PRODUCT=529/1/.* 0:0 0664 */usr/local/sbin/keybridge-hasp-hotplug'; cat /etc/mdev.conf; } > /etc/mdev.conf.keybridge
mv /etc/mdev.conf.keybridge /etc/mdev.conf
sed -i '/^\/usr\/sbin\/hasplmd_x86_64 -s/a /usr/local/sbin/keybridge-hasp-hotplug --scan' /etc/local.d/keybridge.start

# The build tools and kernel are not needed in the root volume at run time.
kernel=$(ls /lib/modules)
mkinitfs -F 'base ext4 scsi usb virtio' -o /work/initramfs-virt "$kernel"
cp /boot/vmlinuz-virt /work/vmlinuz-virt
apk info -vv > /work/alpine-packages.txt
cat /boot/config-* > /work/kernel-config.txt
rm -rf /boot/* /var/cache/apk/* /tmp/* /var/log/*
mkdir -p /var/log/keybridge-lic /rootfs
cd /
tar --exclude=./work --exclude=./helpers --exclude=./rootfs --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./.dockerenv -cf - . | tar -xf - -C /rootfs
mkdir -p /rootfs/proc /rootfs/sys /rootfs/dev /rootfs/run
du -sh /rootfs > /work/rootfs-size.txt
truncate -s 1G /work/rootfs.ext4
mkfs.ext4 -F -m 0 -L keybridge-alpine -d /rootfs /work/rootfs.ext4
echo KEYBRIDGE_ALPINE_IMAGE_BUILT
