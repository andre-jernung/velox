# Velox

A web browser for classic AmigaOS 3.x / 68020+, in pure 68k assembly.
Read `docs/DESIGN.md` for the decisions and architecture. In particular,
keep the JavaScript-readiness rules: a persistent DOM, re-runnable layout,
and a single event dispatch point.

## Build

- `make`: assembles `src/*.s` into `build/velox` (Amiga hunk executable)
- `make size`: size against the 64 KB target. The target can be raised
  when a feature needs it. Keep the code small and optimized, but don't
  give up a realistic solution (correctness, responsiveness) to stay
  under it.
- `make lint`: static checks of the register conventions below (d1/a1/a6
  used after a call, routines whose callers test flags not set from d0).
  It must stay clean. A routine that keeps or returns d1/a1 says so in
  its header ("Out: ... d1 = ...", "(d1 kept)"), which the lint reads.
- `make test`: headless golden tests. `build/vtest` runs each
  `test/unit/*.vt` script under vamos, and the output is diffed against
  `.expected`. It's fast, so use it for parser and logic code.
- `test/emu.sh --auto [TEST...]`: boots FS-UAE (A1200/020 with 8 MB fast
  and 16 MB Zorro III RAM, `Z3MEM=` in KB; Kickstart 3.1,
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
  `test/xdrive.py` (XTEST, US-layout physical keys; `amiga+k` is right
  Amiga), and reads Velox's `LOG=` event log. `test/amiga/NAME.prep`, if
  present, runs on the host before boot to create files in `VELOX:t`.
  `build/wbrun PROG` starts a program as Workbench does (with its icon's
  tool types). `build/mouse X Y [DOWN|DRAG|UP]` moves the Amiga pointer
  and uses the left button through input.device (host-side XTEST mouse
  moves are relative in FS-UAE); Velox logs `pagex`/`pagey`, the page
  origin on the screen, for such tests. `paint N` logs the lines each refresh
  repainted.
- FS-UAE turns cursor keys into a joystick unless `joystick_port_1 = none`
  is set, which the test config does.
- `SPEED=real test/emu.sh --auto speed` runs a stock 14 MHz A1200 (not the
  unthrottled CPU) and reports image decoding times (`imgtime`/`imgconv`
  log events, in 1/50 s). With `PROFILE=1` as well, it builds the
  profiling version (`make PROFILE=1`, PROFB/PROFE macros, EClock) and
  lists the time of each decoding stage. The 68020's instruction cache
  holds 256 bytes, and a stock A1200 has only Chip RAM, so hot loops
  that fit in 256 bytes run much faster.
- Profiling builds also log `gap TICKS` / `gapat ADDRESS` / `codebase
  ADDRESS` when the loader ran 0.14 s or more without yielding (where
  it yielded: `codebase` is `TaskResume`'s address; link a map with
  `vlink -M` from the same objects to find the routine), and `slowmsg`
  for window events taking that long. `SPEED=real PROFILE=1 TIMEOUT=1500
  test/emu.sh --auto linkspeed` (manual, the real forum) shows them
  with the slowest key answers.
- `SPEED=real PROFILE=1 test/emu.sh --auto pagespeed` (manual) lists the
  stage times of big.html: fetched, from the disk cache (its page file),
  coming in 4 parts, and Back to it kept.
- `OS=3.2 test/emu.sh --auto` runs the same tests on AmigaOS 3.2 (Kickstart
  3.2 and Workbench/Classes/Fonts disks from the user's 3.2 CD in
  `~/amiga/os32/cd`). Run both before calling GUI or image work done.
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
  themselves. So never keep a value in a6 across a call (this bug
  happened twice in the image decoders).
- Call routines in other modules with `jsr`/`jmp`, never `bsr`/`bra`. The
  code is larger than 32 KB, so 16-bit branches between modules don't
  reach. vasm turns `jsr` into a 32-bit `bsr.l` on the 68020. Conditional
  branches to other modules need a local `jmp` trampoline.
- OS calls take LONG arguments. Clear upper words (`moveq #0,dN`) before
  loading a `.w` or `.b` value into an argument register. The same goes for
  counters used by `dbf`, and for indexes: `move.b` into a register that
  still holds a code point made `dbf` copy 8 KB (this bug happened).
- vasm does not process `\` escapes in strings. Write special bytes as
  numbers, e.g. `dc.b 92,"n"`.
- Each routine gets a header comment stating In/Out.
- Cleanup routines must be safe to call when the resource was never
  acquired (test, clear, then free).
- Loading runs in the loader, a coroutine of the event loop (task.s).
  Anything that can wait yields to the event loop: `WaitSocket`,
  `TaskPoll`, `BgRun`, so any network call or image decode. Don't keep
  data in shared scratch globals (`g_LinkUrl`, `g_UrlTmp2`,
  `g_StatusBuf`, `g_Line`) across such a call, because window handlers
  use them meanwhile (this bug happened). A layout yields too
  (`LayPoll`, before each element) and may be left there for good (the
  stack reset to `LayoutDocument`'s, when the load stops or the width
  changes): code inside a layout keeps its state on the stack or in
  layout globals, takes nothing but page memory and `g_LRuns`/
  `g_LAnchors`, and writes no view global (`g_Runs`, `g_DocHeight`,
  `g_PageBg`...) before the end, where the new runs replace those shown.
  LayPoll keeps all registers (LayoutNode's a1 is live there: this bug
  happened).
- A page of frames has a view per frame (frames.s): the view globals
  (`g_View` .. `g_ViewEnd` in velox.i: runs, scroll position, page
  rectangle, bands...) are those of the view in G (`ViewSelect`). Outside
  an event handler or a loop over the frames, G holds the page's own
  view (`g_ViewCur` 0): code that changes the view selects the right one
  first and puts the page's back. A new view global goes into that block.
- AmiSSL's crypto runs in the TLS process (conn.s, `TwRun`), at the
  same time as Velox's task. What runs there (`TwExec`, `TlsVerify`,
  `CertFile`) uses only the `g_Tw*`/`g_Cert*` globals, no shared
  scratch, and logs nothing (`LogEvent` would interleave with Velox's).
  Velox's task makes only cheap AmiSSL calls itself (BIOs,
  `SSL_pending`, sessions), never on the SSL of a job under way, and
  anything a job reads (its host, its data) is set after `TwRun` has
  waited for the job before: a job of a stopped page runs on to its end.
- A page is its arena (`PageAlloc`), its buffers and the globals listed
  in `KeepTab` (keep.s): pages are kept for Back by copying those, and
  saved to disk as page files (pagefile.s). A new per-page global goes
  into `KeepTab`. A new pointer field in page memory goes into
  `PfWalk` (pagefile.s); a pointer it does not know fails the save
  (safe, but the page is then never saved: `make test` runs
  `test/unit/pagefile.vt`, which checks that pages save and come back
  the same). Pointers out of the page are only allowed into
  `AttrNames` (html.s).
