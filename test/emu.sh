#!/bin/sh
# Run Velox in FS-UAE (A1200, Kickstart 3.1, Workbench 3.1 from a host
# folder), with build/ mounted as VELOX:.
#
#   test/emu.sh          boot Workbench interactively; run VELOX:velox yourself
#   test/emu.sh --auto   run test/amiga/autotest, save build/screenshot.png,
#                        print the results and exit non-zero on failure
#
# Needs: fs-uae, xwininfo + import (ImageMagick), tools/venv (amitools).
# AMIGA_DIR (default ~/amiga) must hold a1200.rom and wb31-02-workbench.adf.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AMIGA_DIR=${AMIGA_DIR:-$HOME/amiga}
ROM=$AMIGA_DIR/a1200.rom
SYS=$ROOT/tools/amiga/Workbench3.1
B=$ROOT/build
AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1
TIMEOUT=${TIMEOUT:-120}

make -s -C "$ROOT"

# One-time setup: unpack Workbench 3.1 and hook the autotest into it.
if [ ! -d "$SYS" ]; then
	mkdir -p "$ROOT/tools/amiga"
	"$ROOT/tools/venv/bin/xdftool" "$AMIGA_DIR/wb31-02-workbench.adf" unpack "$ROOT/tools/amiga"
	sed -i 's/^EndCLI >NIL:$/IF EXISTS VELOX:autotest\n  Execute VELOX:autotest\nEndIF\nEndCLI >NIL:/' \
		"$SYS/S/Startup-Sequence"
fi

rm -f "$B/result.txt" "$B/shot.req" "$B/autotest" "$B/screenshot.png"
[ $AUTO = 1 ] && cp "$ROOT/test/amiga/autotest" "$B/autotest"

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
automatic_input_grab = 0
floppy_drive_volume = 0
volume = 0
window_width = 960
window_height = 600
EOF

fs-uae "$B/velox.fs-uae" >"$B/fs-uae.log" 2>&1 &
EMU=$!
trap 'kill $EMU 2>/dev/null || true' EXIT INT TERM

if [ $AUTO = 0 ]; then
	wait $EMU
	exit 0
fi

t=0
while [ $t -lt "$TIMEOUT" ]; do
	if [ -e "$B/shot.req" ] && [ ! -e "$B/screenshot.png" ]; then
		xwininfo -root -tree | grep -i 'fs-uae' >"$B/windows.txt" || true
		win=$(grep -v 'has no name' "$B/windows.txt" | head -1 | awk '{print $1}')
		if [ -n "$win" ]; then
			import -window "$win" "$B/screenshot.png" || echo "screenshot failed"
		else
			echo "screenshot: emulator window not found"
		fi

	fi
	grep -q '^done' "$B/result.txt" 2>/dev/null && break
	sleep 1
	t=$((t + 1))
done

echo "--- result.txt"
cat "$B/result.txt" 2>/dev/null || echo "(no result file)"
echo "---"

fail=0
grep -q '^done' "$B/result.txt" 2>/dev/null || { echo "FAIL: autotest did not finish in ${TIMEOUT}s"; fail=1; }
grep -q '^running: yes' "$B/result.txt" 2>/dev/null || { echo "FAIL: velox was not running"; fail=1; }
grep -q '^after_break: exited' "$B/result.txt" 2>/dev/null || { echo "FAIL: velox did not exit on Ctrl-C"; fail=1; }
before=$(sed -n 's/^mem_before *//p' "$B/result.txt" 2>/dev/null | tr -dc 0-9)
after=$(sed -n 's/^mem_after *//p' "$B/result.txt" 2>/dev/null | tr -dc 0-9)
if [ -n "$before" ] && [ -n "$after" ]; then
	echo "memory: before=$before after=$after diff=$((before - after))"
	[ "$before" = "$after" ] || { echo "FAIL: memory not fully returned"; fail=1; }
fi
[ -e "$B/screenshot.png" ] && echo "screenshot: $B/screenshot.png"
[ $fail = 0 ] && echo "PASS"
exit $fail
