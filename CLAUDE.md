# Velox

A web browser for classic AmigaOS 3.x / 68020+, in pure 68k assembly.
Read `docs/DESIGN.md` for the decisions and architecture. In particular,
keep the JavaScript-readiness rules: a persistent DOM, re-runnable layout,
and a single event dispatch point.

## Build

- `make`: assembles `src/*.s` into `build/velox` (Amiga hunk executable)
- `make size`: size against the 64 KB budget
- `make test`: headless golden tests. `build/vtest` runs each
  `test/unit/*.vt` script under vamos, and the output is diffed against
  `.expected`. It's fast, so use it for parser and logic code.
- `test/emu.sh --auto [TEST...]`: boots FS-UAE (A1200/020, Kickstart 3.1,
  Workbench 3.1 from `~/amiga`) with `build/` as `VELOX:` and the
  bsdsocket emulation on. It runs `test/amiga/TEST.script` on the Amiga,
  then `TEST.check` on the host. `test/server.py` serves on
  127.0.0.1:8080, from `test/www`. It saves `build/screenshot.png` when a
  script requests one. Run it after every change that touches the OS.
  `test/emu.sh` without arguments boots Workbench for manual testing.
  Automated runs use a private Xvfb display (`:91`), so they never show
  windows on the user's screen or take keyboard focus. A test can have a
  host driver, `test/amiga/NAME.host`. It starts when the Amiga script
  creates `VELOX:r/NAME.start`, drives the GUI with keys via
  `test/xdrive.py` (XTEST, US-layout physical keys), and reads Velox's
  `LOG=` event log.
- FS-UAE turns cursor keys into a joystick unless `joystick_port_1 = none`
  is set, which the test config does.
- Toolchain lives in `tools/` and is not committed. `tools/bootstrap.sh`
  rebuilds it (vasm, vlink, and the AmigaOS 3.2 NDK from Aminet).
  `tools/venv` holds amitools (xdftool, vamos).
- System packages needed: `fs-uae`, `python3.13-venv` and `xvfb` (apt).
  This is a Qubes AppVM, so they belong in the TemplateVM.

## Assembly conventions

- vasm Motorola syntax, `-m68020`, `-x` (undefined symbols are errors).
- Every module starts with `include "velox.i"`.
- **a4 always points to the global block `G`.** Globals are `g_Xxx(a4)`,
  defined with `rs` in `src/velox.i`. Never modify a4.
- **Scratch registers:** d0-d1/a0-a1/a6. Every routine preserves
  d2-d7/a2-a3/a5.
- Results come back in d0, with the CCR set from d0 unless the routine's
  header comment says otherwise. Failure is 0.
- Restore saved data registers with `movem.l (sp)+,dN`, never
  `move.l (sp)+,dN`. A `move` sets the CCR from the restored value and
  destroys the result flags the caller tests (this bug happened).
- Library calls use the `EXEC`/`DOS`/`INTUI`/`GFX` macros, which load a6
  themselves.
- OS calls take LONG arguments. Clear upper words (`moveq #0,dN`) before
  loading a `.w` or `.b` value into an argument register. The same goes for
  counters used by `dbf`, and for indexes: `move.b` into a register that
  still holds a code point made `dbf` copy 8 KB (this bug happened).
- vasm does not process `\` escapes in strings. Write special bytes as
  numbers, e.g. `dc.b 92,"n"`.
- Each routine gets a header comment stating In/Out.
- Cleanup routines must be safe to call when the resource was never
  acquired (test, clear, then free).
