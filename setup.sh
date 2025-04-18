#!/bin/bash

set -e

### --- CONFIG ---
RAID_DEV="/dev/md0"
DISK1="/dev/sdb"
DISK2="/dev/sdc"
PART="${RAID_DEV}p1"
MOUNTPOINT="/mnt/mdroot"

HOSTNAME="raidboot"
ROOT_PASS="123456"
STATIC_IP="10.0.0.173"
GATEWAY="10.0.0.1"
INTERFACE="eth0"
CMDLINE="console=ttyS0,115200n8 no_timer_check crashkernel=auto net.ifnames=0 biosdevname=0 root=${PART} ro"

### --- 1. RAID SETUP ---
echo "[+] Creating RAID0..."
mdadm --zero-superblock --force "$DISK1" "$DISK2"
yes | mdadm --create "$RAID_DEV" --level=0 --raid-devices=2 "$DISK1" "$DISK2"

sleep 5

echo "[+] Partitioning RAID..."
parted -s "$RAID_DEV" mklabel gpt mkpart primary ext4 0% 100%
sleep 2
mkfs.ext4 "$PART"

mkdir -p "$MOUNTPOINT"
mount "$PART" "$MOUNTPOINT"

### --- 2. INSTALL BASE SYSTEM ---
echo "[+] Installing Debian base with debootstrap..."
debootstrap --arch amd64 stable "$MOUNTPOINT" http://deb.debian.org/debian

for dir in dev proc sys run; do
    mount --bind /$dir "$MOUNTPOINT/$dir"
done

### --- 3. CHROOT AND CONFIGURE ---
cat <<EOF | chroot "$MOUNTPOINT" /bin/bash

echo "[+] Set hostname"
echo "$HOSTNAME" > /etc/hostname

echo "[+] Set root password"
echo "root:$ROOT_PASS" | chpasswd

echo "[+] Network config"
cat > /etc/network/interfaces <<NET
auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address $STATIC_IP
    netmask 255.255.255.0
    gateway $GATEWAY
NET

echo "[+] Install packages"
apt update
apt install -y linux-image-amd64 initramfs-tools openssh-server sudo mdadm kexec-tools net-tools iproute2

echo "[+] Enable SSH login as root"
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl enable ssh

echo "[+] Configure mdadm"
echo "DEVICE partitions" > /etc/mdadm/mdadm.conf
mdadm --detail --scan >> /etc/mdadm/mdadm.conf

echo "[+] Ensure RAID modules load early"
echo raid0 >> /etc/initramfs-tools/modules
echo md_mod >> /etc/initramfs-tools/modules

echo "[+] Update initramfs"
update-initramfs -u
EOF

### --- 4. LOAD KERNEL AND BOOT ---
KERNEL=$(ls "$MOUNTPOINT"/boot/vmlinuz-* | sort | tail -n1)
INITRD=$(ls "$MOUNTPOINT"/boot/initrd.img-* | sort | tail -n1)

echo "[+] Load kernel with kexec..."
kexec -l "$KERNEL" --initrd="$INITRD" --command-line="$CMDLINE"

echo "[+] Syncing and rebooting into RAID system via kexec..."
sync
sleep 3
kexec -e
