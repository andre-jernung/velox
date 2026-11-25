#!/bin/sh
# Fetch and build the Velox toolchain into tools/bin and tools/ndk.
# Needs: git, curl, gcc, make, 7z or lha, python3 with venv (python3.13-venv).
# The NDK is Commodore's NDK 3.1, from the Amiga Developer CD 2.1 archive
# in ndk/adcd.lha (not committed: copyrighted), or NDK31=DIR (the folder
# holding Includes&Libs).
set -eu
cd "$(dirname "$0")"
# unlha ARCHIVE: unpack into the current directory
unlha() { if command -v 7z >/dev/null; then 7z x -y "$1" >/dev/null; else lha xqf "$1"; fi; }
mkdir -p src bin ndk

[ -d src/vasm ]  || git clone --depth 1 https://github.com/StarWolf3000/vasm-mirror.git src/vasm
[ -d src/vlink ] || git clone --depth 1 https://github.com/Leffmann/vlink.git src/vlink

make -C src/vasm CPU=m68k SYNTAX=mot
mkdir -p src/vlink/objects
make -C src/vlink
cp src/vasm/vasmm68k_mot src/vasm/vobjdump src/vlink/vlink bin/

if [ ! -d ndk/Include_I ] && [ -z "${NDK31:-}" ] && [ -f ../ndk/adcd.lha ]; then
	# NDK 3.1 from the Developer CD archive
	if [ ! -d "src/adcd/NDK/NDK_3.1/Includes&Libs" ]; then
		mkdir -p src/adcd
		if command -v 7z >/dev/null; then
			(cd src/adcd && 7z x -y ../../../ndk/adcd.lha "NDK/NDK_3.1/*" >/dev/null)
		else
			(cd src/adcd && lha xqf ../../../ndk/adcd.lha "NDK/NDK_3.1/*")
		fi
	fi
	NDK31=src/adcd/NDK/NDK_3.1
fi
if [ ! -d ndk/Include_I ] && [ -n "${NDK31:-}" ]; then
	# a local Commodore NDK 3.1 (NDK31=path, the folder holding
	# Includes&Libs): it has .fd files but no lvo/*.i, so make those
	cp -R "$NDK31/Includes&Libs/include_i" ndk/Include_I
	cp -R "$NDK31/Includes&Libs/fd" ndk/FD
	find ndk -name '*.info' -delete
	chmod -R u+rwX,go-w ndk
	mkdir -p ndk/Include_I/lvo
	for f in ndk/FD/*_lib.fd; do
		python3 fd2lvo.py "$f" "ndk/Include_I/lvo/$(basename "$f" .fd).i"
	done
fi
if [ ! -d ndk/Include_I ]; then
	echo "no NDK 3.1: put the Amiga Developer CD 2.1 archive in ndk/adcd.lha" >&2
	echo "or give NDK31=DIR (the folder holding Includes&Libs)" >&2
	exit 1
fi
# AmiSSL 6 for the emulated test system (TLS tests)
if [ ! -d src/amissl/AmiSSL ]; then
	curl -L -o src/AmiSSL-6.1-OS3.lha \
		https://github.com/jens-maus/amissl/releases/download/6.1/AmiSSL-6.1-OS3.lha
	mkdir -p src/amissl
	(cd src/amissl && unlha ../AmiSSL-6.1-OS3.lha)
fi
if [ ! -x venv/bin/vamos ]; then
	python3 -m venv venv
	venv/bin/pip install amitools greenlet machine68k python-xlib
fi
echo "toolchain ready"
