#! /bin/bash

# Written 2015 by Mario Kicherer (dev@kicherer.org)
#
# This script creates a disk image with an almost minimal Ubuntu Linux that
# boots on a Raspberry Pi 2 system.
#
# To use this script you need a few other tools, e.g., a static qemu binary
# for ARM (from package qemu-user-static on Ubuntu). Please see the
# "check_tool" lines below.
#
# You can configure the image using environment variables. For example,
# to directly write to a SD card known as /dev/sdX, execute:
#
#	LODEV=/dev/sdX create_rpibuntu.sh
#
# Or, to create an image with a (16 GB - 200 MB) root partition, a 200 MB boot
# partition and a wifi-ready setup for common wifi hardware, call:
#
#   IMG_SIZE_MB=16000 BOOT_SIZE_MB=200 \
#     ADDITIONAL_PKGS="ssh linux-firmware connman" create_rpibuntu.sh

[ -f create_rpibuntu.cfg ] && source create_rpibuntu.cfg

### choose the Ubuntu release
RELEASE=${RELEASE-16.04}
RELEASE_NAME=${RELEASE_NAME-xenial}
RPIBUNTU_REVISION=${RPIBUNTU_REVISION-0}

RPIBUNTU_ARCH=${RPIBUNTU_ARCH-armhf}
UBUNTU_MIRROR=${UBUNTU_MIRROR-http://ports.ubuntu.com}
UBUNTU_MIRROR_PATH=${UBUNTU_MIRROR_PATH-ubuntu-ports/}

### default size of the complete image and the boot partition
IMG_SIZE_MB=${IMG_SIZE_MB-800}
BOOT_SIZE_MB=${BOOT_SIZE_MB-100}

### additional packages that will be installed
ADDITIONAL_PKGS=${ADDITIONAL_PKGS-ssh}

### execute this script in the chroot before starting the shell and finishing
### the image
# USER_SCRIPT=/path/to/script

### if set to 0, do not start a shell inside the new installation
START_SHELL=${START_SHELL-1}

# name of the resulting image (default: rpibuntu_15.10.img)
[ ${RPIBUNTU_REVISION} -gt 0 ] && REV=".${RPIBUNTU_REVISION}"
IMG_PATH=${IMG_PATH-rpibuntu_${RELEASE}${REV}.img}

function errcheck() {
	LAST=$?
	if [ "${LAST}" != "0" ]; then
		echo "error, \"$1\" failed with return value ${LAST}. output:"
		echo "$2"
		caller
		exit 1
	fi
}

function check_tool {
	which $1 >/dev/null; errcheck "tool $1 not found"
}

QEMU_ARM=${QEMU_ARM-qemu-arm}

if [ "${USER}" != "root" ]; then
	echo "This script must be run as root user."
	exit 1
fi

check_tool debootstrap
check_tool mkfs.vfat
check_tool mkfs.btrfs
check_tool kpartx
check_tool btrfs
check_tool "${QEMU_ARM}"

UBUNTU_KEYRING=${UBUNTU_KEYRING-/usr/share/keyrings/ubuntu-archive-keyring.gpg}
if [ ! -f ${UBUNTU_KEYRING} ]; then
	echo "Ubuntu keyring (${UBUNTU_KEYRING}) not found. To verify"
	echo "the downloaded files, please get this file or pass its location using"
	echo "UBUNTU_KEYRING environment variable."
	exit 1
fi

echo "Creating an Ubuntu ${RELEASE} ${RELEASE_NAME} image"

if [ "${LODEV}" == "" ]; then
	if [ ! -f ${IMG_PATH} ]; then
		echo "Create sparse image file"
		dd of=${IMG_PATH} bs=1000k seek=${IMG_SIZE_MB} count=0 status=none || errcheck "sparse dd"
	fi

	LODEV=$(losetup -a | grep ${IMG_PATH} | cut -d ":" -f1)
	if [ "${LODEV}" == "" ]; then
		LODEV=$(losetup -f --show ${IMG_PATH}); errcheck "losetup"
		echo "Created new loopback device ${LODEV}"
	fi
	DIRECT_WRITE=0
else
	DIRECT_WRITE=1
	echo "using device file ${LODEV}"
fi

# TODO check both partition
echo "check if partition table exists"
PARTTABLE=$(sfdisk -d ${LODEV} | grep "Id=83")

if [ "${PARTTABLE}" == "" ]; then
	echo "create new partition table"
	OUTPUT=$(fdisk ${LODEV} 2>&1 <<EOF
o
n
p
1

+${BOOT_SIZE_MB}M
t
c
n
p
2


w
EOF
)
# TODO fdisk always returns an error code as the new partition table will not
#      be used automatically
# 	errcheck "fdisk" "${OUTPUT}"
fi

LOBASE=$(basename ${LODEV})
[[ ${LOBASE:(-1)} =~ [0-9] ]] && LOBASE="${LOBASE}p"
BOOTDEV=/dev/mapper/${LOBASE}1
ROOTDEV=/dev/mapper/${LOBASE}2

if [ ! -b ${BOOTDEV} ] || [ ! -b ${ROOTDEV} ]; then
	echo "creating device files"
	kpartx -as ${LODEV} || errcheck "kpartx"
fi

ROOTDIR=$(mktemp -d)/
BOOTDIR=${ROOTDIR}/boot/

echo "trying to mount ${ROOTDEV} to ${ROOTDIR}"
mount "${ROOTDEV}" "${ROOTDIR}" 2>/dev/null
RES=$?

if [ "${RES}" == "32" ]; then
	echo "creating new BTRFS on ${ROOTDEV}"
	OUTPUT=$(mkfs.btrfs ${ROOTDEV} 2>&1)
	errcheck "mkfs.btrfs" "${OUTPUT}"
	mount "${ROOTDEV}" "${ROOTDIR}" 2>/dev/null || errcheck "mount ${ROOTDEV}"
fi

SUBVOL=$(btrfs subvolume list "${ROOTDIR}" | grep " @root$")
if [ "${SUBVOL}" == "" ]; then
	echo "Creating new root subvolume"
	btrfs subvolume create "${ROOTDIR}"/@root || errcheck "subvolume create"
	ID=$(btrfs subvolume list "${ROOTDIR}" | grep "@root$" | sed -r 's/ID ([[:digit:]]+).*/\1/g')
	btrfs subvolume set-default ${ID} "${ROOTDIR}" || errcheck "subvolume set-default"
	
	umount "${ROOTDIR}"
	mount "${ROOTDEV}" "${ROOTDIR}" || errcheck "final mount root"
fi



if [ ! -d ${BOOTDIR} ]; then
	mkdir ${BOOTDIR} || errcheck "mkdir ${BOOTDIR} failed"
fi

echo "mounting ${BOOTDEV} to ${BOOTDIR}"
mount "${BOOTDEV}" "${BOOTDIR}" 2>/dev/null
RES=$?

if [ "${RES}" == "32" ]; then
	echo "creating new FAT32 on ${BOOTDEV}"
	OUTPUT=$(mkfs.vfat -F 32 ${BOOTDEV} 2>&1)
	errcheck "mkfs.vfat" "${OUTPUT}"
	mount "${BOOTDEV}" "${BOOTDIR}" 2>/dev/null || errcheck "mount ${BOOTDEV}"
fi

if [ ! -f "${ROOTDIR}"/tmp/.debootstrap_foreign ]; then
	echo "Starting first debootstrap stage"
	debootstrap --arch=${RPIBUNTU_ARCH} --foreign \
		--keyring="${UBUNTU_KEYRING}" \
		${RELEASE_NAME} "${ROOTDIR}" ${UBUNTU_MIRROR}/${UBUNTU_MIRROR_PATH}
	# Do not abort as debootstrap sometimes fails to install all packages for
	# some reason. This is fixed by an "apt-get -f install" later.
	#errcheck "first stage debootstrap"
	touch "${ROOTDIR}"/tmp/.debootstrap_foreign
else
	echo "First deboostrap stage already run"
fi

echo "Preparing for chroot"
cp "$(which ${QEMU_ARM})" "${ROOTDIR}"/usr/bin || errcheck
cp "${UBUNTU_KEYRING}" "${ROOTDIR}"/tmp/ || errcheck

if [ ! -f /proc/sys/fs/binfmt_misc/arm ]; then
	modprobe binfmt_misc
	echo   ':arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\x00\xff\xfe\xff\xff\xff:/usr/bin/qemu-arm:'"${QEMU_BINFMT_FLAGS}" > /proc/sys/fs/binfmt_misc/register
fi

# disable device file creation in recent debootstrap versions as we bind mount /dev
if [ -f "${ROOTDIR}"/debootstrap/functions ]; then
	sed -ri "s/^\s+setup_devices_simple\s*$/echo disabled_mknod/" "${ROOTDIR}"/debootstrap/functions
fi

mount -o bind /dev "${ROOTDIR}"/dev || errcheck
mount -o bind /dev/pts "${ROOTDIR}"/dev/pts || errcheck
mount -t sysfs /sys "${ROOTDIR}"/sys || errcheck
mount -t proc /proc "${ROOTDIR}"/proc || errcheck
cp /proc/mounts "${ROOTDIR}"/etc/mtab || errcheck

# we do not pass --keyring as gpgv is not available in the chroot yet
echo "
#! /bin/sh

echo \"Entered deboostrap chroot\"
if [ -f /debootstrap/debootstrap ]; then
	/debootstrap/debootstrap --second-stage
else
	echo \"Second deboostrap stage already ran\"
fi
" > "${ROOTDIR}"/tmp/chroot_script
chmod +x "${ROOTDIR}"/tmp/chroot_script

echo "Starting deboostrap chroot"
LC_ALL=C chroot "${ROOTDIR}" /tmp/chroot_script

echo "Preparing system configuration"

echo "Initializing sources.list"
echo "
deb ${UBUNTU_MIRROR}/${UBUNTU_MIRROR_PATH} ${RELEASE_NAME} main restricted universe multiverse
deb ${UBUNTU_MIRROR}/${UBUNTU_MIRROR_PATH} ${RELEASE_NAME}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR}/${UBUNTU_MIRROR_PATH} ${RELEASE_NAME}-security main restricted universe multiverse

deb http://rpibuntu.kicherer.org/repos/${RELEASE_NAME}/ ${RPIBUNTU_ARCH}/
#deb http://rpibuntu.kicherer.org/repos/${RELEASE_NAME}/ ${RPIBUNTU_ARCH}-testing/
" > "${ROOTDIR}"/etc/apt/sources.list

if [ "$(grep "/boot" "${ROOTDIR}"/etc/fstab)" == "" ]; then
	echo "Creating /etc/fstab"
	BOOT_UUID=$(blkid ${BOOTDEV} -o value -s UUID)
	ROOT_UUID=$(blkid ${ROOTDEV} -o value -s UUID)
	
	echo "
UUID=${BOOT_UUID}  /boot   vfat    defaults        0       2
UUID=${ROOT_UUID}       /       btrfs   defaults,relatime     0       1
"> "${ROOTDIR}"/etc/fstab
fi

echo "rpibuntu" > "${ROOTDIR}"/etc/hostname
sed -i "s/localhost/localhost rpibuntu/" "${ROOTDIR}"/etc/hosts

echo "[Network]
DHCP=both
" > "${ROOTDIR}"/etc/systemd/network/dhcp.network


# make sure these directories are mounted (again)
# mount -o bind /dev/pts "${ROOTDIR}"/dev/pts || errcheck
# mount -t sysfs /sys "${ROOTDIR}"/sys || errcheck
# mount -t proc /proc "${ROOTDIR}"/proc || errcheck
cp /proc/mounts "${ROOTDIR}"/etc/mtab || errcheck

echo "#! /bin/bash
echo \"Entered chroot\"

echo \"adding gpg key to verify rpibuntu repo signature\"
echo \"-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1

mQENBFcbqjMBCADA7XregAr0FoPE9WN34PBH1ALN6HJFPi36yO53KMoS4xzTOYy/
3vJBoLOkGmL5aaEsJn6+67Yktee9I1c0Pxp0mRhO5bs/ggClW2Aoba7tzo3SvKVV
8KKfpAaXofNy0ltooxZEJkDF6Rcjw+T5bSWWAiaGv09s5c6IFJ5Tse5H1OXZ0r78
fxyjOwB17RiZfBR+NuZpJkrNYRXcgbe9N3clPlyTEageIS3KuvUT47v4aKv59ISm
tjFf+NUSZXvY62fZwsDCym+pke0CxE2LPkSlnhIBQ4oX1ByWe5HZsO3h4Dg3cEfN
NWB8kvxvuNmNriqpugP4kp5KbIHA4Mq86mq7ABEBAAG0IU1hcmlvIEtpY2hlcmVy
IDxkZXZAa2ljaGVyZXIub3JnPokBPQQTAQgAJwUCVxuqMwIbAwUJA8JnAAULCQgH
AwUVCgkICwUWAgMBAAIeAQIXgAAKCRDPAXqTidsEdI2nB/9ROc02IZIH1rvuhZ26
k5STlbmPPMvygU7OJTl35075YvAG4/kdcc18OK8UbzdBl9YF9xLHCx2A1zD+tiTQ
88+jZGBWofsYD7DUBowVyMxw2M+Q34EJ62xNPdHxvbneLq+KLPe211i1rBgsvIRB
g0qHDQkgfgavXe+XKLBoOtX3YulR3xG+2Cpev1zUUDNuU4xpyg2+OiJuZmjq3WkI
dIP9swOpNGseuI7uwa6Tb945ffWXfbIgIzDaVPTH2uNI/hny6qOhXJ1fENf2/rSM
DSGk0ukhxS/ROn0cTC7FReck0DrPJW3te2FypAWeo0pRnxl6OqoqSMrt8NGPbsxO
edZZuQENBFcbqjMBCAC6GXQJaETpVfikQAT6fy0hcdWZ8Wb/Sk3N0DxaVVx2Dhtv
4TqzIFH+foy8p92xS8RFYG0HTFPt5DPoFyC0iV8a0aHPaXvUhkySwNXNQhR18Wbx
7zC9sa/k2zB20tlSVRNOiNifZOqX0DaOvHnogJFMPHxlnY/u0HJSgUmqu3VK38b8
N8SFRGD0Ng10+PaXqemWbIEr7jUSTemm5gkEPketdNflTQkjegFKQ6pRCwuc2chY
dORo+FzxxsZ9aaNY0iKQ0AEsOkUbTugpOEWL4YEA9+fzxGStPsbrH4ouvNbJss9q
PUaAY2HnXHomSIeVbT+JWAFJ129HeqPxaOD3V0cbABEBAAGJASUEGAEIAA8FAlcb
qjMCGwwFCQPCZwAACgkQzwF6k4nbBHTX2wf/acDQczdIa1te6g6a6VNH/Pv+CCX1
E6mYOe22w70Fr/5VRlQOlNIxdlCvCPPSRLg6b10AyKQuY4+LRtVSh2lrBTxVOtLe
wNxkihauzcFTq2vteuBEs2rkaDJZurXq1y16q+0kre2mesUoQecC3LJhdSiEMs2w
R5QSrp10/Bd33OTdfZFgrJsAUTZpaH6iSpsuN+NC9U1J6QTM87o6+zWV1pJqVQnF
cq7qpi1bx1Pb22iN/rdXSmN+Xk/ymCk4n6aHisB/g0ML5svJxTyI6sX2tNQh1k1m
+mjI/hIvs4WDxlFGG3OA4mVYx96RIgRpp5F9dJQ0sohb6PORzhgWrowxNQ==
=P0Ky
-----END PGP PUBLIC KEY BLOCK-----\" | apt-key add -

# prevent service startup in chroot
echo 'exit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

echo \"finalize package installation\"
apt-get -y -f install
apt-get update
apt-get -y dist-upgrade

# install additional packages required for RPiBuntu
apt-get install -y u-boot-tools btrfs-tools dosfstools

echo \"setup locales\"
if [ \"\$(locale -a | grep en_US)\" == \"\" ]; then
	locale-gen en_US.UTF-8
	update-locale LANG=en_US.UTF-8
	dpkg-reconfigure locales
fi

echo \"enable DHCP\"
systemctl enable systemd-networkd
systemctl enable systemd-resolved

mkdir -p /run/systemd/resolve/
ln -s ../../resolvconf/resolv.conf /run/systemd/resolve/
rm /etc/resolv.conf; ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

echo \"setup rpibuntu user\"
useradd -m -U -G sudo,video,audio,users -s /bin/bash rpibuntu
echo \"rpibuntu:rpibuntu\" | chpasswd

echo \"installing RPI2 packages\"
apt-get install -y rpi-configs rpi-firmware rpi-tools uboot-bin-rpi

# install kernel later to ensure the update-uboot script is in place
apt-get install -y linux-image-rpi

# setup the firmware config
cp /usr/share/doc/rpi2-configs/config.txt /boot/

echo -e \"\n
# We attach the bluetooth chip to the miniUART port to use the main UART for
# for the serial console.
dtoverlay=pi3-miniuart-bt
enable_uart=1

# Uncomment to signal the firmware that we will use the opensource graphics driver
#dtoverlay=vc4-kms-v3d
#avoid_warnings=2

# RPi2-specific settings
[pi2]
kernel=u-boot-rpi2.bin

# RPi3-specific settings
[pi3]
kernel=u-boot-rpi3_32.bin

# reset filter
[all]
\" >> /boot/config.txt

touch /tmp/.config_chroot

if [ \"${ADDITIONAL_PKGS}\" != \"\" ]; then
	# install requested packages by user
	apt-get install -y ${ADDITIONAL_PKGS}
fi

" > "${ROOTDIR}"/tmp/chroot_script
chmod +x "${ROOTDIR}"/tmp/chroot_script

if [ ! -f /tmp/.config_chroot ]; then
	echo "Starting config chroot"
	LC_ALL=C chroot "${ROOTDIR}" /tmp/chroot_script
fi

if [ "${USER_SCRIPT}" != "" ]; then
	BASE="$(basename ${USER_SCRIPT})"
	cp "${USER_SCRIPT}" "${ROOTDIR}"/tmp/
	chmod +x "${ROOTDIR}/tmp/${BASE}"
	LC_ALL=en_US.UTF-8 chroot "${ROOTDIR}" /tmp/"${BASE}"
fi

echo ""
echo "Setup finished."
echo ""

if [ "${START_SHELL}" == "1" ]; then
	echo "Starting a shell inside the chroot environment. You can make further"
	echo "modifications now like installing additional packages."
	echo ""
	echo "To finish the installation, please enter \"exit\"."
	echo ""

	LC_ALL=en_US.UTF-8 chroot "${ROOTDIR}" /bin/bash
fi






echo "Cleaning up..."

# LC_ALL=en_US.UTF-8 chroot "${ROOTDIR}" rm /tmp/*

# remove service startup prevention
rm "${ROOTDIR}"/usr/sbin/policy-rc.d

sync && sleep 1

umount -R ${ROOTDIR}

rmdir ${ROOTDIR}

kpartx -d ${LODEV}

if [ "${DIRECT_WRITE}" == "0" ]; then
	losetup -d ${LODEV}
fi

echo "Installation finished."

echo
echo "To compress image for publication:"
echo "zip ${IMG_PATH}.zip ${IMG_PATH}"

echo
echo "To decompress and write to card:"
echo "cat ${IMG_PATH}.zip | gunzip -d | dd of=/dev/sdX"
