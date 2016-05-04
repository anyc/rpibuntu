#! /bin/bash

# create a uboot logo from a jpg or png image
#
# Written by Mario Kicherer (http://kicherer.org)

IN=$1
OUT=splash.bmp

EXT=${IN##*.}

case "${EXT}" in
	png) CONV=pngtopnm ;;
	jpg) CONV=jpegtopnm ;;
esac

if ! which "${CONV}" > /dev/null; then
	echo "error, ${CONV} not found"
	exit 1
fi

CONVBIN=$(which "${CONV}")

# uncompressed images seem to be more reliable
#"${CONVBIN}" "${IN}" | ppmquant 220 | ppmtobmp -bpp 8 | gzip -9 > "${OUT}"

"${CONVBIN}" "${IN}" | ppmquant 220 | ppmtobmp -bpp 8 > "${OUT}"
