#!/bin/bash

RUN_ID=`hexdump -n 4 -e '"%08x"' /dev/urandom`
OUTPUT="arch-install_${RUN_ID}.img"
FILE="/root/arch-install.img"
SSH_KEY="${HOME}/.ssh/id_rsa_desktop"
DEVICE="/dev/nvme0n1"
EFIUUID=`echo "${RUN_ID::4}-${RUN_ID:4}" | tr "[:lower:]" "[:upper:]"`
CRYPTUUID=`uuidgen | tr "[:upper:]" "[:lower:]"`

# Restart Docker Desktop on macOS to fix a bug with leaking loop devices
if [ `uname` = "Darwin" ]; then
	osascript - <<-EOF
	tell application "Docker"
	  if it is running then quit it
	end tell
	EOF

	sleep 1

	HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask docker 2> /dev/null
	open -ga /Applications/Docker.app

	while ! docker system info &> /dev/null; do
	  sleep 3
	done
fi

set -x

# Initialize the output img file with 10 GB free space
rm -f arch-install_*.img
touch "${OUTPUT}"
truncate -s 10G "${OUTPUT}"

# Start an Arch Docker container
docker rm -f arch-install &> /dev/null
docker run -d --name arch-install -v "$(pwd)/${OUTPUT}":"${FILE}" --privileged archlinux sleep infinity > /dev/null

# Update package databases and install required packages
docker exec -i arch-install bash -c "cat > /etc/pacman.d/mirrorlist" <<EOF || exit
Server = https://europe.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
Server = https://mirrors.gandi.net/archlinux/\$repo/os/\$arch
Server = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch
Server = https://mirrors.mit.edu/archlinux/\$repo/os/\$arch
EOF
docker exec arch-install pacman -Syy || exit
docker exec arch-install pacman -S --noconfirm parted lvm2 multipath-tools dosfstools xfsprogs arch-install-scripts || exit

# Format img file as GPT disk
docker exec arch-install parted -s "${FILE}" mklabel gpt || exit
docker exec arch-install parted -s "${FILE}" mkpart ESP 2048s 256MiB || exit
docker exec arch-install parted -s "${FILE}" mkpart LVM 256MiB 100% || exit
docker exec arch-install parted -s "${FILE}" set 1 boot on || exit

# Mount img file as loopback device
docker exec arch-install kpartx -asf "${FILE}" || exit
LOOP_DEV=`docker exec arch-install losetup --list | grep "${FILE}" | cut -d " " -f1 || exit`
LOOP_DEV_MAP=`sed "s|^/dev/loop|/dev/mapper/loop|" <<< "${LOOP_DEV}"`
docker exec arch-install ln "${LOOP_DEV}" "${DEVICE}" || exit
docker exec arch-install ln "${LOOP_DEV_MAP}p1" "${DEVICE}p1" || exit
docker exec arch-install ln "${LOOP_DEV_MAP}p2" "${DEVICE}p2" || exit

# Create LVM encrypted volumes
docker exec -it arch-install cryptsetup -q --pbkdf pbkdf2 --hash sha512 --uuid "$CRYPTUUID" luksFormat "${DEVICE}p2" || exit
docker exec arch-install dd bs=512 count=4 if=/dev/urandom of=/root/encrypted-lvm.keyfile iflag=fullblock || exit
docker exec -it arch-install cryptsetup -v --pbkdf pbkdf2 --hash sha512 luksAddKey "${DEVICE}p2" /root/encrypted-lvm.keyfile || exit
docker exec arch-install cryptsetup --key-file /root/encrypted-lvm.keyfile open "${DEVICE}p2" cryptlvm || exit
docker exec arch-install pvcreate /dev/mapper/cryptlvm || exit
docker exec arch-install vgcreate arch /dev/mapper/cryptlvm || exit
docker exec arch-install lvcreate -Z n -n boot -L 512M arch || exit
docker exec arch-install lvcreate -Z n -n swap -L 4G arch || exit
docker exec arch-install lvcreate -Z n -n root -l 100%FREE arch || exit
docker exec arch-install vgscan --mknodes || exit

# Format ESP partition and LVM volumes
docker exec arch-install mkfs.fat -F32 "${DEVICE}p1" -i "$(echo "$EFIUUID" | tr -d -)" || exit
docker exec arch-install mkfs.ext4 -L boot /dev/arch/boot || exit
docker exec arch-install mkswap /dev/arch/swap || exit
docker exec arch-install mkfs.xfs -L root /dev/arch/root || exit

# Mount volumes to /mnt
docker exec arch-install mount /dev/arch/root /mnt || exit
docker exec arch-install mkdir /mnt/boot || exit
docker exec arch-install mount /dev/arch/boot /mnt/boot || exit
docker exec arch-install mkdir /mnt/boot/efi || exit
docker exec arch-install mount "${DEVICE}p1" /mnt/boot/efi || exit
docker exec arch-install swapon /dev/arch/swap || exit

# Install Arch packages on the img disk
docker exec arch-install pacstrap /mnt base linux linux-firmware efibootmgr xfsprogs lvm2 grub || exit
docker exec -i arch-install bash -c "cat >> /mnt/etc/fstab" <<EOF || exit
/dev/arch/root	/         	xfs       	rw,relatime,attr2,inode64,logbufs=8,logbsize=32k,noquota	0 1
/dev/arch/boot	/boot     	ext4      	rw,relatime	0 2
UUID=$EFIUUID 	/boot/efi 	vfat      	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=utf8,shortname=mixed,errors=remount-ro	0 2
/dev/arch/swap 	none      	swap      	defaults  	0 0
EOF

# Set up Arch installation
docker exec arch-install pacstrap /mnt intel-ucode sudo nano openssh libvirt qemu edk2-ovmf bridge-utils || exit

# Set up time and locale
docker exec arch-install ln -sf /mnt/usr/share/zoneinfo/Europe/Paris /mnt/etc/localtime || exit
docker exec arch-install arch-chroot /mnt hwclock --systohc || exit
docker exec arch-install sed -i -E 's|^#(en_US\.UTF-8 UTF-8\s*)$|\1|' /mnt/etc/locale.gen || exit
docker exec arch-install arch-chroot /mnt locale-gen || exit
docker exec arch-install bash -c 'echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf' || exit

# Set up networking
docker exec arch-install bash -c 'echo "host.desktop.local" > /mnt/etc/hostname' || exit
docker exec arch-install bash -c 'echo "127.0.0.1	localhost" >> /mnt/etc/hosts' || exit
docker exec arch-install bash -c 'echo "::1		localhost" >> /mnt/etc/hosts' || exit
docker exec arch-install bash -c 'echo "127.0.1.1	host.desktop.localdomain host.desktop.local host.desktop host" >> /mnt/etc/hosts' || exit
docker exec arch-install bash -c 'echo -e "[Match]\nType=ether\nName=en*\n\n[Network]\nDHCP=yes" > /mnt/etc/systemd/network/wired.network' || exit
docker exec arch-install arch-chroot /mnt systemctl enable systemd-networkd || exit
docker exec arch-install arch-chroot /mnt systemctl enable systemd-resolved || exit
docker exec arch-install rm /mnt/etc/resolv.conf || exit
docker exec arch-install arch-chroot /mnt ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf || exit

# Set up GRUB with automatic disk decryption
docker exec arch-install cp /root/encrypted-lvm.keyfile /mnt/root/encrypted-lvm.keyfile || exit
docker exec arch-install chmod 000 /mnt/root/encrypted-lvm.keyfile || exit
docker exec arch-install sed -i -E 's|^FILES=\(\)$|FILES=(/root/encrypted-lvm.keyfile)|' /mnt/etc/mkinitcpio.conf || exit
docker exec arch-install sed -i -E 's|^HOOKS=\(.*\)$|HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems fsck)|' /mnt/etc/mkinitcpio.conf || exit
docker exec arch-install arch-chroot /mnt mkinitcpio -p linux || exit
docker exec arch-install bash -c "chmod 600 /mnt/boot/initramfs-linux*" || exit
docker exec arch-install sed -i -E 's|^GRUB_TIMEOUT=.+$|GRUB_TIMEOUT=0|' /mnt/etc/default/grub || exit
docker exec arch-install sed -i -E 's|^#(GRUB_ENABLE_CRYPTODISK=y)$|\1|' /mnt/etc/default/grub || exit
docker exec arch-install sed -i -E 's|^GRUB_CMDLINE_LINUX_DEFAULT="(.+)"$|GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_iommu=on iommu=pt"|' /mnt/etc/default/grub || exit
docker exec arch-install sed -i -E "s|^GRUB_CMDLINE_LINUX=\".*\"\$|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$CRYPTUUID:cryptlvm cryptkey=rootfs:/root/encrypted-lvm.keyfile root=/dev/arch/root\"|" /mnt/etc/default/grub || exit

# Install GRUB
docker exec arch-install mount -o bind /dev /mnt/dev || exit
docker exec arch-install mount -o bind /proc /mnt/proc || exit
docker exec arch-install mount -o bind /sys /mnt/sys || exit
docker exec arch-install mkdir /mnt/boot/grub || exit
docker exec arch-install chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg || exit
docker exec arch-install chroot /mnt grub-install --target=x86_64-efi --boot-directory=/boot --efi-directory=/boot/efi --modules="part_gpt luks2 cryptodisk gcry_rijndael pbkdf2 gcry_sha512 lvm xfs ext2" --bootloader-id=Arch --removable --recheck || exit
docker exec -i arch-install bash -c "cat > /mnt/tmp/grub-pre.cfg" <<EOF || exit
set crypto_uuid=$(echo "$CRYPTUUID" | tr -d -)
cryptomount -u \$crypto_uuid
set root=lvm/arch-root
set prefix=(lvm/arch-boot)/grub
insmod normal
normal
EOF
docker exec arch-install chroot /mnt grub-mkimage -O x86_64-efi -p /boot/grub -c /tmp/grub-pre.cfg -o /tmp/grubx64.efi part_gpt luks2 cryptodisk gcry_rijndael pbkdf2 gcry_sha512 lvm xfs ext2 || exit
docker exec arch-install chroot /mnt install -v /tmp/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI || exit
docker exec arch-install rm /mnt/tmp/grub-pre.cfg /mnt/tmp/grubx64.efi || exit
docker exec arch-install umount /mnt/dev /mnt/proc /mnt/sys || exit
docker exec arch-install chmod 700 /mnt/boot || exit

# Set up SSH and root password
docker exec -it arch-install arch-chroot /mnt passwd || exit
docker exec arch-install arch-chroot /mnt systemctl enable sshd || exit
docker exec arch-install mkdir /mnt/root/.ssh || exit
docker exec arch-install touch /mnt/root/.ssh/authorized_keys || exit
docker exec arch-install bash -c "echo '$(cat "${SSH_KEY}.pub")' >> /mnt/root/.ssh/authorized_keys" || exit

# Clean Docker container and exit
docker exec arch-install umount /mnt/boot/efi /mnt/boot /mnt || exit
docker exec arch-install swapoff /dev/arch/swap || exit
docker exec arch-install losetup -D || exit
docker rm -f arch-install &> /dev/null || exit
