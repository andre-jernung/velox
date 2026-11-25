#!/bin/sh
# Run Velox in FS-UAE (A1200, Kickstart 3.1, Workbench 3.1 from a host
# folder), with build/ mounted as VELOX: and FS-UAE's bsdsocket.library
# emulation using the host network.
#
#   test/emu.sh                    boot Workbench interactively
#   test/emu.sh --auto [TEST...]   run test/amiga/TEST.script for each TEST
#                                  (default: all) in one boot, then check
#                                  the results with test/amiga/TEST.check
#
# test/server.py runs on 127.0.0.1:8080 (and https on 8443), and
# tools/velox-proxy.py on 8888, for the duration.
# Needs: fs-uae, Xvfb (automated runs), xwininfo + import (ImageMagick),
# tools/venv (amitools, python-xlib).
# OS=3.1 (default): AMIGA_DIR (default ~/amiga) must hold a1200.rom,
# wb31-02-workbench.adf and wb31-06-fonts.adf.
# OS=3.2: OS32_DIR (default ~/amiga/os32/cd, the AmigaOS 3.2 CD) must hold
# ROM/kicka1200.rom and ADF/{Workbench3.2,Classes3.2,Fonts}.adf.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AMIGA_DIR=${AMIGA_DIR:-$HOME/amiga}
OS32_DIR=${OS32_DIR:-$AMIGA_DIR/os32/cd}
OS=${OS:-3.1}
case "$OS" in
	3.1)	ROM=$AMIGA_DIR/a1200.rom
		SYS=$ROOT/tools/amiga/Workbench3.1 ;;
	3.2)	ROM=$OS32_DIR/ROM/kicka1200.rom
		SYS=$ROOT/tools/amiga/Workbench3.2 ;;
	*)	echo "OS must be 3.1 or 3.2"; exit 2 ;;
esac
B=$ROOT/build
AUTO=0
if [ "${1:-}" = "--auto" ]; then
	AUTO=1
	shift
fi
# default: every test whose script is not marked "(manual)" on line 1
TESTS=${*:-$(cd "$ROOT/test/amiga" && for f in *.script; do
	head -1 "$f" | grep -q '(manual)' || basename "$f" .script; done)}
# the whole run's time limit: 40 s a test (at least 300 s)
set -- $TESTS
TIMEOUT=${TIMEOUT:-$(( $# * 40 > 300 ? $# * 40 : 300 ))}

make -s -C "$ROOT" ${PROFILE:+PROFILE=$PROFILE}	# (PROFILE=1: the profiling build)

XDF="$ROOT/tools/venv/bin/xdftool"
# unpack ADF $1 and copy its contents into directory $2
adf_into() {
	t=$(mktemp -d)
	"$XDF" "$1" unpack "$t" >/dev/null
	mkdir -p "$2"
	cp -r "$t"/*/. "$2/"
	rm -rf "$t"
}
# One-time setup: unpack Workbench and hook the autotest into it.
if [ ! -d "$SYS" ]; then
	mkdir -p "$ROOT/tools/amiga"
	if [ "$OS" = 3.1 ]; then
		adf_into "$AMIGA_DIR/wb31-02-workbench.adf" "$SYS"
		adf_into "$AMIGA_DIR/wb31-06-fonts.adf" "$SYS/Fonts"
	else
		adf_into "$OS32_DIR/ADF/Workbench3.2.adf" "$SYS"
		adf_into "$OS32_DIR/ADF/Classes3.2.adf" "$SYS"
		adf_into "$OS32_DIR/ADF/Fonts.adf" "$SYS/Fonts"
		# disk-based in 3.2 (on the Modules/Install disks)
		cp "$OS32_DIR/Libs/icon.library" "$OS32_DIR/Libs/workbench.library" "$SYS/Libs/"
	fi
	for f in "$SYS"/S/Startup-[Ss]equence; do
		sed -i 's/^EndCLI >NIL:$/IF EXISTS VELOX:autotest\n  Execute VELOX:autotest\nEndIF\nEndCLI >NIL:/' "$f"
	done
fi

# Test certificates: a local CA and a server certificate it signed
if [ ! -e "$B/tls/ca.pem" ]; then
	mkdir -p "$B/tls"
	(cd "$B/tls" &&
	 openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 3650 \
		-subj "/CN=Velox Test CA" 2>/dev/null &&
	 openssl req -newkey rsa:2048 -nodes -keyout key.pem -out server.csr \
		-subj "/CN=127.0.0.1" 2>/dev/null &&
	 printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\n' >san.ext &&
	 openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
		-out cert.pem -days 3650 -extfile san.ext 2>/dev/null)
fi
# AmiSSL 6 in the test system, trusting the test CA
if [ ! -d "$SYS/AmiSSL" ] && [ -d "$ROOT/tools/src/amissl/AmiSSL" ]; then
	# the layout Install-AmiSSL creates
	A="$ROOT/tools/src/amissl/AmiSSL"
	mkdir -p "$SYS/AmiSSL/Libs/AmiSSL"
	cp "$A/Libs/AmigaOS3/amisslmaster.library" "$SYS/AmiSSL/Libs/"
	cp "$A/Libs/AmigaOS3/AmiSSL/68020-40/"*.library "$SYS/AmiSSL/Libs/AmiSSL/"
	cp -r "$A/Certs" "$SYS/AmiSSL/Certs"
	printf 'Assign AmiSSL: SYS:AmiSSL\nAssign LIBS: AmiSSL:Libs ADD\n' >>"$SYS/S/User-Startup"
fi
export OS
if [ -d "$SYS/AmiSSL/Certs" ]; then
	cp "$B/tls/ca.pem" "$SYS/AmiSSL/Certs/$(openssl x509 -hash -noout -in "$B/tls/ca.pem").0"
fi

rm -rf "$B/r" "$B/t" "$B/Cache" "$B/shot.req" "$B/autotest" "$B/alldone" "$B/screenshot.png"
if [ $AUTO = 1 ]; then
	mkdir -p "$B/r" "$B/t"
	{
		echo "FailAt 21"
		echo "Wait 2"
		for t in $TESTS; do
			cp "$ROOT/test/amiga/$t.script" "$B/t/$t"
			# NAME.prep makes host-side files the test needs, in VELOX:t
			[ -x "$ROOT/test/amiga/$t.prep" ] && "$ROOT/test/amiga/$t.prep" "$B/t"
			echo "Execute VELOX:t/$t"
		done
		echo 'Echo >VELOX:alldone ""'
	} >"$B/autotest"
fi

mkdir -p "$B/fs-uae"
CPUSPEED=max
ACCURACY=-1
if [ "${SPEED:-}" = real ]; then
	CPUSPEED=real
	ACCURACY=1
fi
cat >"$B/velox.fs-uae" <<EOF
[fs-uae]
base_dir = $B/fs-uae
amiga_model = A1200/020
kickstart_file = $ROM
fast_memory = 8192
# and Zorro III RAM: AmiSSL 6 (a 3.9 MB library) must load again after
# each test's "Avail FLUSH"; in 8 MB fast RAM, fragmented by the tests
# before, OS 3.2 often has no block big enough
zorro_iii_memory = ${Z3MEM:-16384}
hard_drive_0 = $SYS
hard_drive_0_label = $(basename "$SYS")
hard_drive_1 = $B
hard_drive_1_label = VELOX
bsdsocket_library = 1
# cursor keys are keys, not an emulated joystick
joystick_port_0 = mouse
joystick_port_1 = none
# run the 68020 unthrottled (like an accelerated Amiga): TLS handshakes
# take ~15 s at the stock 14 MHz, too slow for some servers.  SPEED=real
# gives a stock A1200 (14 MHz 68020) for timing things.
uae_cpu_speed = $CPUSPEED
accuracy = $ACCURACY
automatic_input_grab = 0
floppy_drive_volume = 0
volume = 0
window_width = 960
window_height = 600
EOF

# test server: http on 8080, https on 8443; and the proxy
python3 "$ROOT/test/server.py" 8080 "$ROOT/test/www" 8443 "$B/tls/cert.pem" "$B/tls/key.pem" \
	2>"$B/server.log" &
SRV=$!
python3 "$ROOT/tools/velox-proxy.py" --port 8888 --insecure 2>"$B/proxy.log" &
SRV="$SRV $!"
XVFB=""
if [ $AUTO = 1 ]; then
	# automated runs use a private X display: nothing appears on the
	# user's screen and keyboard focus is never taken from them
	Xvfb :91 -screen 0 1280x1024x24 -nolisten tcp >"$B/xvfb.log" 2>&1 &
	XVFB=$!
	export DISPLAY=:91
	sleep 1
fi
fs-uae "$B/velox.fs-uae" >"$B/fs-uae.log" 2>&1 &
EMU=$!
trap 'kill $EMU $SRV $XVFB 2>/dev/null || true' EXIT INT TERM

if [ $AUTO = 0 ]; then
	wait $EMU
	exit 0
fi

t=0
started=""
DRIVERS=""
while [ $t -lt "$TIMEOUT" ] && [ ! -e "$B/alldone" ]; do
	# host-side drivers (test/amiga/NAME.host) start when NAME.start appears
	for n in $TESTS; do
		if [ -e "$B/r/$n.start" ] && [ -x "$ROOT/test/amiga/$n.host" ]; then
			case " $started " in *" $n "*) ;; *)
				started="$started $n"
				"$ROOT/tools/venv/bin/python" "$ROOT/test/amiga/$n.host" "$B/r" \
					>"$B/r/$n.host.log" 2>&1 &
				DRIVERS="$DRIVERS $!"
			esac
		fi
	done
	if [ -e "$B/shot.req" ] && [ ! -e "$B/screenshot.png" ]; then
		win=$(xwininfo -root -tree | grep -i 'fs-uae' | grep -v 'has no name' | head -1 | awk '{print $1}')
		if [ -n "$win" ]; then
			import -window "$win" "$B/screenshot.png" || echo "screenshot failed"
		fi
	fi
	sleep 1
	t=$((t + 1))
done
if [ ! -e "$B/alldone" ]; then
	echo "TIMEOUT after ${TIMEOUT}s (screen: $B/timeout.png)"
	win=$(xwininfo -root -tree | grep -i 'fs-uae' | grep -v 'has no name' | head -1 | awk '{print $1}')
	[ -n "$win" ] && import -window "$win" "$B/timeout.png"
fi
# let host drivers finish writing their results
for p in $DRIVERS; do
	n=0
	while kill -0 "$p" 2>/dev/null && [ $n -lt 30 ]; do sleep 1; n=$((n + 1)); done
	kill "$p" 2>/dev/null || true
done

fail=0
for t in $TESTS; do
	r="$B/r/$t.txt"
	if ! grep -q '^done' "$r" 2>/dev/null; then
		echo "FAIL $t: did not finish"
		[ -e "$r" ] && sed 's/^/  | /' "$r"
		fail=1
	elif "$ROOT/test/amiga/$t.check" "$r" >"$B/r/$t.check.log" 2>&1; then
		echo "PASS $t"
		sed 's/^/  /' "$B/r/$t.check.log"
	else
		echo "FAIL $t"
		sed 's/^/  /' "$B/r/$t.check.log"
		fail=1
	fi
done
[ -e "$B/screenshot.png" ] && echo "screenshot: $B/screenshot.png"
exit $fail
