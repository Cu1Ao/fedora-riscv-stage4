#!/bin/bash -

# Firstboot script to build the stage4.

hostname stage4-builder
echo stage4-builder.fedoraproject.org > /etc/hostname

echo
echo "This is the stage4 disk image automatic builder"
echo

exec >& /build.log

# Clean the dnf cache.
dnf clean all

# Cleanup function called on failure or exit.
cleanup ()
{
    set +e
    # Sync disks and shut down.
    sync
    sleep 5
    sync
    # systemd poweroff is buggy, force immediate poweroff instead:
    poweroff -f
}
trap cleanup INT QUIT TERM EXIT ERR

set -e
set -x

rm -f /var/tmp/stage4-disk.img
rm -f /var/tmp/stage4-disk.img-t
rm -rf /var/tmp/mnt

# Create a template disk image.
truncate -s 20G /var/tmp/stage4-disk.img-t
mkfs -t ext4 /var/tmp/stage4-disk.img-t

# Create the installroot.
mkdir /var/tmp/mnt
mount -o loop /var/tmp/stage4-disk.img-t /var/tmp/mnt
mkdir /var/tmp/mnt/{dev,proc,sys}
mount -o rbind /dev /var/tmp/mnt/dev
mount -o rbind /proc /var/tmp/mnt/proc
mount -o rbind /sys /var/tmp/mnt/sys
rpm --root /var/tmp/mnt --initdb

# Adding glibc-langpack-en avoids the huge glibc-all-langpacks
# being used.
#
# openrdate allows us to set the clock correctly on boot.
#
# systemd-udev is apparently needed for systemd-remount-fs
#
# strict=0 is like the old --skip-broken option in yum.  We can
# remove it when all @core packages are available.
dnf -y --releasever=28 --installroot=/var/tmp/mnt --setopt=strict=0 \
     install \
         @core \
         glibc-langpack-en \
         openrdate \
         /usr/sbin/sshd \
         /usr/bin/ssh-keygen \
         systemd-udev \
         lsof

# Do some configuration within the chroot.

# Write an fstab for the chroot.
cat > /var/tmp/mnt/etc/fstab <<EOF
/dev/root / ext4 defaults 0 0
EOF

# Set the hostname.
echo stage4.fedoraproject.org > /var/tmp/mnt/etc/hostname

# Set the welcome message.
i=/var/tmp/mnt/etc/issue
echo > $i
echo "Welcome to the Fedora/RISC-V stage4 disk image"      >> $i
echo "https://fedoraproject.org/wiki/Architectures/RISC-V" >> $i
echo >> $i
echo "Kernel \r on an \m (\l)" >> $i
echo >> $i
cp /var/tmp/mnt/etc/issue /var/tmp/mnt/etc/issue.net

# Copy local.repo in.
cp /var/tmp/local.repo /var/tmp/mnt/etc/yum.repos.d

# Enable systemd-networkd.
cp /var/tmp/50-wired.network /var/tmp/mnt/etc/systemd/network/
chroot /var/tmp/mnt \
       ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Enable some standard systemd services.
chroot /var/tmp/mnt \
       systemctl enable sshd systemd-networkd systemd-resolved

# systemd starts serial consoles on /dev/ttyS0 and /dev/hvc0.  The
# only problem is they are the same serial console.  Mask one.
chroot /var/tmp/mnt \
        systemctl mask serial-getty@hvc0.service

# Disable GSSAPI in sshd.
# [Temporarily required until we have krb5]
sed -i -e 's,^\(GSSAPI.*\),#\1,' /var/tmp/mnt/etc/ssh/sshd_config

# Disable public repos, they don't serve riscv64 packages anyway.
chroot /var/tmp/mnt \
       dnf config-manager --set-disabled rawhide updates updates-testing fedora

# Clean DNF cache in the chroot.  This forces the first run of DNF
# by the new machine to refresh the cache and not use the stale
# data from the build environment.
chroot /var/tmp/mnt \
       dnf clean all

# Set a root password ('riscv').
echo riscv |
chroot /var/tmp/mnt \
       passwd root --stdin --force

# List all the packages which were installed in the chroot
# so they appear in the build.log.
chroot /var/tmp/mnt rpm -qa | sort

# As a last resort, fail if certain commands or files are not
# installed in the chroot which are required to build the next stage4
# or for general basic operation.  This is just a backup in case
# things have gone very wrong above.
test -f /var/tmp/mnt/lib64/libc.so.6
test -f /var/tmp/mnt/usr/bin/dnf
test -f /var/tmp/mnt/usr/bin/mount
test -f /var/tmp/mnt/usr/sbin/init
test -f /var/tmp/mnt/usr/sbin/ip
test -f /var/tmp/mnt/usr/sbin/sshd

# Unmount the chroot.
sync
sleep 5
kill -HUP `lsof -t /var/tmp/mnt` ||:
umount -lR /var/tmp/mnt

# Disk image is built, so move it to the final filename.
# guestfish downloads this, but if it doesn't exist, guestfish
# fails indicating the earlier error.
mv /var/tmp/stage4-disk.img-t /var/tmp/stage4-disk.img

# cleanup() is called automatically here.
