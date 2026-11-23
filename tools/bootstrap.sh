#!/bin/sh
# Fetch and build the Velox toolchain into tools/bin and tools/ndk.
# Needs: git, curl, gcc, make, 7z.
set -eu
cd "$(dirname "$0")"
mkdir -p src bin ndk

[ -d src/vasm ]  || git clone --depth 1 https://github.com/StarWolf3000/vasm-mirror.git src/vasm
[ -d src/vlink ] || git clone --depth 1 https://github.com/Leffmann/vlink.git src/vlink

make -C src/vasm CPU=m68k SYNTAX=mot
mkdir -p src/vlink/objects
make -C src/vlink
cp src/vasm/vasmm68k_mot src/vasm/vobjdump src/vlink/vlink bin/

if [ ! -d ndk/Include_I ]; then
	curl -L -o src/NDK3.2.lha https://aminet.net/dev/misc/NDK3.2.lha
	mkdir -p src/ndk
	(cd src/ndk && 7z x -y ../NDK3.2.lha >/dev/null)
	cp -r src/ndk/Include_I src/ndk/FD src/ndk/SFD ndk/
	cp -r "src/ndk/SANA+RoadshowTCP-IP/sfd" ndk/net_sfd
fi
echo "toolchain ready"
