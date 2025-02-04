#!/bin/bash
set -ex
#### install required packages if host debian
if [[ -d /var/lib/apt/ ]] ; then
    apt update
    apt install qemu-user-static binfmt-support debootstrap wget unzip qemu-utils -y
fi
mkdir -p work
cd work
#### fetch device firmware (prebuilt)
[[ -f firmware.zip ]] || wget -c https://github.com/raspberrypi/firmware/archive/refs/heads/master.zip -O firmware.zip
yes "A" | unzip firmware.zip
cd ..
mkdir -p rootfs/boot
cp -rvf work/firmware-master/boot/* rootfs/boot/
cat > rootfs/boot/cmdline.txt << EOF
console=ttyS1,115200 console=tty0 root=/dev/mmcblk0p2 rootfstype=ext4 rw net.ifnames=0 rootwait fbcon=map:10 quiet
EOF
cat > rootfs/boot/config.txt << EOF
# For more options and information see
# http://rpf.io/configtxt
# Some settings may impact device functionality. See link above for details

# uncomment if you get no picture on HDMI for a default "safe" mode
#hdmi_safe=1

# uncomment the following to adjust overscan. Use positive numbers if console
# goes off screen, and negative if there is too much border
#overscan_left=16
#overscan_right=16
#overscan_top=16
#overscan_bottom=16

# uncomment to force a console size. By default it will be display's size minus
# overscan.
#framebuffer_width=1280
#framebuffer_height=720

# uncomment if hdmi display is not detected and composite is being output
#hdmi_force_hotplug=1

# uncomment to force a specific HDMI mode (this will force VGA)
#hdmi_group=1
#hdmi_mode=1

# uncomment to force a HDMI mode rather than DVI. This can make audio work in
# DMT (computer monitor) modes
#hdmi_drive=2

# uncomment to increase signal to HDMI, if you have interference, blanking, or
# no display
#config_hdmi_boost=4

# uncomment for composite PAL
#sdtv_mode=2

#uncomment to overclock the arm. 700 MHz is the default.
#arm_freq=800

#overclock
arm_freq=2000
gpu_freq=750

# Uncomment some or all of these to enable the optional hardware interfaces
#dtparam=i2c_arm=on
#dtparam=i2s=on
#dtparam=spi=on

# Uncomment this to enable infrared communication.
#dtoverlay=gpio-ir,gpio_pin=17
#dtoverlay=gpio-ir-tx,gpio_pin=18

# Additional overlays and parameters are documented /boot/overlays/README

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

# Automatically load overlays for detected cameras
camera_auto_detect=1

# Automatically load overlays for detected DSI displays
display_auto_detect=1

# Enable DRM VC4 V3D driver
dtoverlay=vc4-kms-v3d
max_framebuffers=2

# Run in 64-bit mode
arm_64bit=1

# Disable compensation for displays with overscan
disable_overscan=1

[cm4]
# Enable host mode on the 2711 built-in XHCI USB controller.
# This line should be removed if the legacy DWC2 controller is required
# (e.g. for USB device mode) or if USB support is not required.
otg_mode=1

[all]

[pi4]
# Run as fast as firmware / board allows
arm_boost=1

[all]

EOF
##### create rootfs
uri=$(wget -O - https://dl-cdn.alpinelinux.org/alpine/edge/releases/aarch64/ | grep -v "sha" | grep "alpine-minirootfs" | sort -V | tail -n 1 | cut -f2 -d"\"")
wget -O $uri https://dl-cdn.alpinelinux.org/alpine/edge/releases/aarch64/$uri
mkdir -p work/rootfs
cd work/rootfs
tar -xf ../../$uri
cd ../..
##### copy qemu-aarch64-static
cp $(which qemu-aarch64-static) work/rootfs/usr/bin/qemu-aarch64-static
if which service ; then
    service binfmt-support start
fi
#### Configure system
echo "nameserver 1.1.1.1" > work/rootfs/etc/resolv.conf
##### install firmware and packages
mkdir -p work/rootfs/lib/modules/
cp -rvf work/firmware-master/modules/* work/rootfs/lib/modules/
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "apk update"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "apk add kmod networkmanager eudev dbus openrc shadow openssh"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "rc-update add dbus"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "rc-update add networkmanager"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "rc-update add udev"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "rc-update add udev-trigger"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "rc-update add udev-settle"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "rc-update add sshd"
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "rc-update add swclock"
#### create default user
chmod u+s work/rootfs/bin/su
chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "useradd user -m -U"
echo -e "alpine\nalpine\n" | chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "passwd root"
echo -e "alpine\nalpine\n" | chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "passwd user"
find work/rootfs/var/log/ -type f | xargs rm -f
for i in $(ls work/rootfs/lib/modules) ; do
    chroot work/rootfs /usr/bin/qemu-aarch64-static /bin/ash -c "depmod -a $i"
done
#### create image and partitons
size=$(du -s "work/rootfs" | cut -f 1)
qemu-img create "alpine.img" $(($size*1080+(600*1024*1024)))
parted "alpine.img" mklabel msdos
echo Ignore | parted "alpine.img" mkpart primary fat32 0 300M 
echo Ignore | parted "alpine.img" mkpart primary ext2 301M 100%
#### format image
losetup -d /dev/loop0 || true
loop=$(losetup --partscan --find --show "alpine.img" | grep "/dev/loop")
mkfs.vfat ${loop}p1
yes | mkfs.ext4 ${loop}p2 -L "ROOTFS"
#### copy boot partition
mount ${loop}p1 /mnt
cp -prfv rootfs/boot/* /mnt/
sync
umount -f /mnt
#### copy rootfs partition
mount ${loop}p2 /mnt
cp -prfv work/rootfs/* /mnt/
sync
umount /mnt
xz alpine.img
#### done
