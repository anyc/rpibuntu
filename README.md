RPiBuntu
========

RPiBuntu is an almost minimal Ubuntu image with the necessary packages to boot
on a [Raspberry Pi 2](https://en.wikipedia.org/wiki/Raspberry_Pi). After
installing this image, you can choose to install
your favorite desktop enviroment, network services or media center, for example.

Features:

* [Official RaspberryPi kernel](https://github.com/raspberrypi/linux) with
  [Ubuntu-specific patches](http://kernel.ubuntu.com/~kernel-ppa/mainline/v4.0.9-wily/)
* U-Boot bootloader with boot menu
* BTRFS root filesystem
* systemd init system
* RPi2-specific Kodi and tvheadend packages
* Regular packages come from [http://ports.ubuntu.com/](http://ports.ubuntu.com/)

This repo contains:

* create_rpibuntu.sh: a script to create and customize your own rpibuntu image
* MD5SUMS: the MD5 hashes of the [RPiBuntu images](http://rpibuntu.kicherer.org/images/)

See [rpibuntu.kicherer.org](http://rpibuntu.kicherer.org) for further information
and image downloads.


