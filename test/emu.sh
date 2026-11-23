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
# test/server.py runs on 127.0.0.1:8080 for the duration.
# Needs: fs-uae, xwininfo + import (ImageMagick), tools/venv (amitools).
# AMIGA_DIR (default ~/amiga) must hold a1200.rom, wb31-02-workbench.adf and
# wb31-06-fonts.adf.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AMIGA_DIR=${AMIGA_DIR:-$HOME/amiga}
ROM=$AMIGA_DIR/a1200.rom
SYS=$ROOT/tools/amiga/Workbench3.1
B=$ROOT/build
AUTO=0
if [ "${1:-}" = "--auto" ]; then
	AUTO=1
	shift
fi
TESTS=${*:-$(cd "$ROOT/test/amiga" && ls *.script | sed 's/\.script$//')}
TIMEOUT=${TIMEOUT:-300}

make -s -C "$ROOT"

# One-time setup: unpack Workbench 3.1 and hook the autotest into it.
if [ ! -d "$SYS" ]; then
	mkdir -p "$ROOT/tools/amiga"
	"$ROOT/tools/venv/bin/xdftool" "$AMIGA_DIR/wb31-02-workbench.adf" unpack "$ROOT/tools/amiga"
	sed -i 's/^EndCLI >NIL:$/IF EXISTS VELOX:autotest\n  Execute VELOX:autotest\nEndIF\nEndCLI >NIL:/' \
		"$SYS/S/Startup-Sequence"
fi
# Fonts from the Workbench 3.1 fonts disk (Velox uses helvetica/courier)
if [ ! -d "$SYS/Fonts" ]; then
	t=$(mktemp -d)
	"$ROOT/tools/venv/bin/xdftool" "$AMIGA_DIR/wb31-06-fonts.adf" unpack "$t"
	cp -r "$t"/*/ "$SYS/Fonts"
	rm -rf "$t"
fi

rm -rf "$B/r" "$B/t" "$B/shot.req" "$B/autotest" "$B/alldone" "$B/screenshot.png"
if [ $AUTO = 1 ]; then
	mkdir -p "$B/r" "$B/t"
	{
		echo "FailAt 21"
		echo "Wait 2"
		for t in $TESTS; do
			cp "$ROOT/test/amiga/$t.script" "$B/t/$t"
			echo "Execute VELOX:t/$t"
		done
		echo 'Echo >VELOX:alldone ""'
	} >"$B/autotest"
fi

mkdir -p "$B/fs-uae"
cat >"$B/velox.fs-uae" <<EOF
[fs-uae]
base_dir = $B/fs-uae
amiga_model = A1200/020
kickstart_file = $ROM
fast_memory = 8192
hard_drive_0 = $SYS
hard_drive_0_label = Workbench3.1
hard_drive_1 = $B
hard_drive_1_label = VELOX
bsdsocket_library = 1
automatic_input_grab = 0
floppy_drive_volume = 0
volume = 0
window_width = 960
window_height = 600
EOF

python3 "$ROOT/test/server.py" 8080 "$ROOT/test/www" 2>"$B/server.log" &
SRV=$!
fs-uae "$B/velox.fs-uae" >"$B/fs-uae.log" 2>&1 &
EMU=$!
trap 'kill $EMU $SRV 2>/dev/null || true' EXIT INT TERM

if [ $AUTO = 0 ]; then
	wait $EMU
	exit 0
fi

t=0
started=""
while [ $t -lt "$TIMEOUT" ] && [ ! -e "$B/alldone" ]; do
	# host-side drivers (test/amiga/NAME.host) start when NAME.start appears
	for n in $TESTS; do
		if [ -e "$B/r/$n.start" ] && [ -x "$ROOT/test/amiga/$n.host" ]; then
			case " $started " in *" $n "*) ;; *)
				started="$started $n"
				"$ROOT/tools/venv/bin/python" "$ROOT/test/amiga/$n.host" "$B/r" \
					>"$B/r/$n.host.log" 2>&1 &
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
[ -e "$B/alldone" ] || echo "TIMEOUT after ${TIMEOUT}s"

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
