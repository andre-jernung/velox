# Velox design

A modern, extremely lightweight web browser for classic AmigaOS, written
entirely in 68k assembly.

## Targets and fixed decisions

| Decision      | Choice                                                         |
|---------------|----------------------------------------------------------------|
| OS            | AmigaOS 3.x (all libraries opened at v39+)                     |
| CPU           | 68020 or better (`-m68020`; no FPU required)                   |
| Display       | Any: window on the default public screen (OCS/AGA/RTG)         |
| Assembler     | vasm (Motorola syntax) + vlink, Amiga hunk format              |
| Networking    | bsdsocket.library (Roadshow, AmiTCP, Miami)                    |
| HTTPS         | Both: AmiSSL (in-process) **and** an optional rewriting proxy  |
| Size          | As small as is realistic; 64 KB is a target, not a limit (`make size`) |
| JavaScript    | Not now, but the architecture must not rule it out (see below) |

## Pipeline

```
URL --> fetch (http / https via AmiSSL / proxy)
    --> decode (chunked, charset -> Latin-1)
    --> tokenize (HTML5-style state machine, tolerant)
    --> tree builder  --> DOM (kept in memory for the life of the page)
    --> style (UA defaults + CSS subset) --> computed style per node
    --> layout  --> box/line list
    --> paint   --> window RastPort (clipped)
```

Each stage is a separate module (`src/<stage>.s`) with a narrow
interface, so stages can be unit-tested in isolation.

### Staying responsive

Velox is one process with one event loop, which always serves the window
first. Loading runs as a coroutine of that loop (task.s, "the loader"):
fetching a page, its style sheets and images, parsing and laying out run
on a stack of their own in the same process.
- **Waiting.** Where the loader would wait (`WaitSocket` for a socket,
  the image decoder process), it yields to the event loop instead. The
  loop sleeps in `WaitSelect` on the window, Ctrl-C and the loader's
  socket or signal, and resumes the loader when that is ready.
- **Computing.** While it computes, the loader yields whenever a window
  message is waiting (`TaskPoll`; the parser checks every 32 tokens).
- **No locking.** Control changes hands only at those points. There the
  DOM, the runs and the view are always consistent: a layout never
  yields. So window messages need no special handling while something
  loads: scrolling, typing, clicking all work as usual.
- **Stopping.** `NavGo` returns at once. A link to another page stops the
  load in progress (`TaskAbort`): the loader's waits fail with
  `ERR_ABORT` and it unwinds through its normal error paths, closing
  connections and freeing buffers. Esc, Reload and Ctrl-C stop it the
  same way. A #fragment of the page shown just scrolls, through the
  anchors the last layout noted (`g_Anchors`). If the anchor has not
  come yet, the page scrolls to it after the layout that brings it,
  unless the user scrolls first.
- **The image decoders** run in a process of their own at a lower
  priority. They are long computations that would be slow to cut into
  pieces, and a lower priority gives exactly "only when the window has
  nothing to do". A decoder left running by a stopped load ends on its
  own, and what it made is freed then.

Pages are shown while they come. After each piece of the body,
`PageHook` decodes it (a UTF-8 character cut at the end waits) and
parses it (`HtmlMore`: a token not yet complete waits). Once the body
begins, the style sheets are fetched, with the page's response put aside
meanwhile, and the page is shown. It is laid out again as more comes, at
most every 4 times the last layout took (at least 1 s), never within
0.3 s of the user scrolling and never while the scroller is held.
Elements keep their computed style (`StyleOf`), so laying out again
costs much less than the first time.

Host names that were already looked up are cached, because
`gethostbyname` blocks. What still blocks: DNS for a new host, the
crypto of the TLS handshake, and one layout of a big page.

### Disk cache

diskcache.s keeps pages and style sheets on disk as they came, with
their validators (ETag, Last-Modified) and max-age, in a cache directory
(`Velox/CacheDir`, default `PROGDIR:Cache`; `Velox/CacheSize` in KB,
default 4096, 0 for none; the oldest files go).
- **Pages.** A page in the cache is shown at once, then checked unless
  it is still fresh: 304 keeps it; a newer version is shown as it comes,
  where the user had scrolled to, unless the user has typed into the
  page meanwhile (then the status line says so). Offline, the copy
  stays. Back and Forward to a page that was not kept (see below) use
  the cache as it is.
- **Style sheets** come from memory, then disk (checked when stale),
  then the network.
- **Images** are kept as they were shown: scaled and dithered for this
  screen, with their mask, keyed by URL, width=/height=, the page width
  and the screen's colours. They come back without fetching or decoding,
  and are checked like pages. For an image without validators the file
  is fetched again, but decoded only if its hash changed.

- **Laid-out pages** (pagefile.s). Showing a 53 KB page from its HTML
  takes 1.0 s to parse and 4.0 s to lay out on a stock A1200, so a page
  that has been shown (with its images) is also saved as it is in
  memory: its arena blocks (DOM, attributes, styles, CSS rules, form
  state), source, runs, anchors and globals. The next time it comes
  from the disk cache, that is read back instead: for big.html on a
  stock A1200, 0.34 s to read and relocate it and 0.11 s to paint,
  instead of 5.7 s (plus the disk: about 0.2 s for its 350 KB on IDE).
  A saved DOM alone (without the layout) would save only the sixth that
  is parsing. Building the file takes 0.4 s after the page and its
  images are there, in slices that yield to the window; if the page is
  laid out again or typed into meanwhile, it is not saved.

  Page memory is Velox's own arena of blocks (mem.s), so its parts can
  be written as they are. Pointers are the hard part: `PfBuild` copies
  the parts one after the other, walks the page's structures as the rest
  of Velox does, and for each pointer field writes the offset of its
  target into the copy and marks the field in a bitmap (a bit a long).
  Loading needs no walk: the parts go to new memory and each marked long
  becomes an address again. A pointer out of the page fails the save
  (never a wrong file); known attribute names point into html.s's table
  on purpose, which counts as a part (its offsets hold within a build).
  Images are not saved: they come back from the image cache as shown.
  CSS match caches are dropped.

  A page file is used only with the HTML entry it was made from (a hash
  of the source as it came), the same build (`BUILD_ID`, a hash of the
  sources made by the Makefile) and the same fonts; at another window
  width it is laid out again with its kept styles. Pages the user typed
  into are not saved. The `pagefile` unit test saves pages, spoils their
  memory, loads them and compares DOM, runs and anchors, also after a
  relayout with all styles computed anew.

  Checking a page shown from the cache no longer shows the new version
  as it comes: it is read whole, and if its hash is the one shown (a
  server without validators sends the same page again), nothing is
  done; otherwise it replaces the copy.

### Kept pages (Back and Forward)

A page that is left is not freed but kept with its history entry
(keep.s): its pool (DOM, styles, CSS, form state), its source, runs and
anchors, its images' bitmaps, and the globals that make it the page
shown (`KeepTab`: copied into a `KeepPage` record and back). Back or
Forward to that entry swaps it in: it is shown as it was left, with its
scroll position, focus and what was typed, with nothing fetched, parsed
or laid out (unless the window's width changed); only painted. On a
stock A1200 that takes 0.1 s for big.html, which takes 5.7 s from the
disk cache. Images it had not loaded yet load then.

Only complete pages are kept, not error pages, and not a page replaced
by itself (Reload, a newer version of a cached copy). At most
`Velox/KeepPages` (default 4) are kept, and only while 384 KB stay
free; the kept page farthest from the current entry goes first, also
when a page allocation or an image's chip memory would fail otherwise.
Like other browsers, Back does not check the server; Reload does.

### Painting

Painting never shows a half-drawn page. `PaintRange` draws the runs into
an off-screen strip (`STRIP_H` lines, a bitmap like the screen's with
its own layer for clipping) and copies each strip into the window with
one blit. If the strip can't be allocated, it draws into the window
directly.

When the runs change, for example after an image loads, a relayout or a
new page, `GuiRefresh` repaints only what changed. It hashes the runs over
each band of `BAND_H` view lines (position, size, colour, font, the
characters, and for images and form controls whether they are loaded and
the page they belong to). It compares the hashes with those of what is on
the screen, and paints only the bands that differ. Unchanged parts of the
view, such as a site's header on the next page, stay as they are.
`GuiPaintAll` repaints everything. Scrolling, window damage and resizing
make the next refresh paint everything too.

Changes whose place is known paint a rectangle instead (`PaintRect`):
only the runs over it are drawn, clipped to it, and only it is copied to
the window. An image that comes into a box whose size was known is
painted where it is shown, every copy, with no text drawn
(`GuiPaintImage`). Typing into a field, toggling a control or moving the
focus paints the control's box (`GuiPaintNode`). After that the band
hashes are taken again, so the next `GuiRefresh` does not paint it a
second time. This fits the JavaScript
plan: a script that changes the DOM triggers a relayout, then
`GuiRefresh`.

## Keeping the door open for JavaScript

JS is not on the roadmap yet, but it must stay possible to add. That means:

1. **The DOM is a real, persistent tree.** Nodes are kept and are never
   discarded after painting. Every element node has parent, first-child,
   next-sibling and previous-sibling links, a tag id, and an attribute
   list. Text nodes own their text. Nothing in layout or paint may cache
   pointers into the source buffer that would go stale if the tree changes.
2. **Layout and paint are re-runnable.** Layout builds a separate box list
   from the DOM and can be thrown away and rebuilt at any time. A "dirty"
   flag on nodes allows partial relayout later.
3. **Scripts are kept, not dropped.** The `<script>` body, the `src`
   attribute, and event-handler attributes (`onclick`, ...) are stored in
   the DOM like any other content. Today they are simply not executed.
   `<noscript>` is rendered because scripting is off.
4. **Events go through one dispatch point.** Clicks, key presses and form
   submissions become DOM events delivered to a target node via
   `DispatchEvent`. The default action (follow link, submit form) runs only
   if nothing cancelled it. A script engine plugs in there later.
5. **Memory comes from per-page pools** (exec memory pools, v39), so a page
   and everything hanging off it, including a future JS heap, are freed
   together.
6. **Networking is asynchronous-capable.** The fetch layer is a state
   machine driven by `WaitSelect`, not a blocking call, so later "fetch
   from script", images and stylesheets can share it.

## Milestones

1. [x] Toolchain, a window that opens and closes cleanly (CLI and Workbench).
2. [x] HTTP fetch over bsdsocket: chunked, redirects, errors.
3. [x] HTML tokenizer + DOM, charsets and entities.
4. [x] Layout and GUI: fonts, lists, tables, links, scrolling, history,
   URL field, keyboard navigation, menus.
5. [x] Forms (GET/POST), CSS subset, images via datatypes.library.
6. [x] HTTPS via AmiSSL 6 and via tools/velox-proxy.py.
7. [x] Session cookies, downloads (ASL requester).
8. [x] Keep-alive connections, bookmarks, `file:` pages, home page,
   Workbench icon with tool types.
9. [x] Find in page, memory cache (Back/Forward, style sheets, images),
   persistent cookies, meta refresh, frames as links, view source, copy
   address, `:not()`/`:is()` and structural selectors, tables squeezed
   to the window.
10. [x] Text selection to the clipboard, type-ahead while loading,
   transfer progress, window geometry, public screen setting, floating
   images, rowspan, media query ranges, HTTP Basic authentication.
11. [x] Painting without flicker (off-screen strips, only what changed),
   staying responsive while loading (non-blocking sockets, a decoder
   process), Velox's own JPEG/PNG/GIF/WebP decoders, background images.
12. [x] The loader as a coroutine of the event loop, pages shown while
   they come, instant in-page links, disk cache (pages, style sheets,
   images as shown), styles kept per element, painting rectangles.
13. [ ] Pages kept in memory for Back/Forward; laid-out pages on disk;
   faster layout.

## Modules

| Module      | Job                                                            |
|-------------|----------------------------------------------------------------|
| main.s      | startup (CLI/Workbench, tool types), settings, CLI fetch        |
| mem.s       | application pool, the page's arena, growable buffers            |
| util.s      | strings, numbers, output, event log (`LOG=`), error texts       |
| url.s       | parsing, resolving (RFC 3986), fixing typed addresses           |
| conn.s      | sockets (non-blocking), AmiSSL, DNS cache, I/O through `WaitSelect` |
| http.s      | requests, responses, redirects, keep-alive                      |
| task.s      | the loader: a coroutine of the event loop                       |
| keep.s      | pages kept for Back/Forward                                     |
| pagefile.s  | laid-out pages in the disk cache                                 |
| cache.s     | memory cache of recent responses                                |
| diskcache.s | disk cache: pages and style sheets, images as shown             |
| cookies.s   | cookie store, persistent cookies in ENVARC:                     |
| charset.s   | UTF-8 / Windows-1252 / Latin-1 to Latin-1, entities              |
| html.s      | tokenizer and tree builder (DOM)                                |
| dom.s       | nodes, attributes, tag table                                    |
| style.s     | computed style from the user-agent rules and HTML attributes     |
| css.s       | author style sheets: parsing, matching, cascade                 |
| layout.s    | blocks, inline text, replaced elements: the run list            |
| table.s     | automatic table layout                                          |
| forms.s     | form controls, editing, submission                              |
| img.s       | loading images (also backgrounds), the decoder process, datatypes |
| pic.s       | image formats, the decoded image (ARGB)                         |
| gif.s png.s jpeg.s webp.s vp8.s vp8l.s inflate.s | the decoders     |
| picbm.s     | decoded images to bitmaps: colour cube, dither, mask            |
| gui.s       | window, gadgets, menus, painting, events                        |
| find.s      | find in page                                                    |
| sel.s       | selecting text with the mouse                                   |
| clip.s      | clipboard                                                       |
| nav.s       | navigation, history, built-in pages, bookmarks, downloads        |

Everything is tested on AmigaOS 3.1 and 3.2 (see CLAUDE.md).

## Images

Velox decodes the web's formats itself, from the response in memory:
GIF (gif.s), PNG (png.s with inflate.s), JPEG (jpeg.s: baseline and
progressive) and WebP (webp.s, vp8.s lossy, vp8l.s lossless, alpha).
The decoders write ARGB pixels (pic.s). They use no Velox state but
their own and allocate with AllocVec, because they run in the image
decoder process. They never read past their input or write past what
they allocated, whatever the file contains (the headless tests feed
them cut and damaged files).

- JPEG uses libjpeg's fast integer inverse DCT. When an image is shown
  at half its size or less, it is decoded at 1/2, 1/4 or 1/8: the
  largest of these that is still as big as the image is shown (width and
  height). The reduced inverse DCTs are libjpeg's 4x4 and 2x2
  (jidctred), and 1/8 uses only the DC coefficients. Subsampled chroma
  takes a larger inverse DCT instead of being upsampled, as in
  libjpeg-turbo. At these scales the output matches `djpeg -scale`
  exactly, except 4:2:0 chroma at 1/2, which uses the fast 8x8 inverse
  DCT.
- WebP follows libwebp step by step, including its "fancy" chroma
  upsampling. The headless tests check that lossy WebP comes out with
  exactly libwebp's pixels, and that PNG, GIF and lossless WebP come out
  exactly as PIL decodes them. JPEG is checked against libjpeg
  (`djpeg -nosmooth`) within a tolerance.

picbm.s turns the pixels into a bitmap like the screen's. It obtains a
colour cube of pens once, with 2 to 6 levels by the screen depth, and
scales to the size shown (nearest pixel). It dithers with a 4x4 ordered
matrix through tables, and pixels less than half opaque go into a mask
plane. Other formats (ILBM, BMP ...) still go through datatypes.library.
Images that cannot be decoded keep their placeholder box (with
width/height) or show their alt text.

Copies of an image share it. When an `<img>` is decoded, the queued
`<img>`s with the same `src`, `width` and `height` attributes get the
same ImageInfo (img.s `ShareImage`), so they appear at once. The picture
is fetched, decoded and held in chip memory only once, however many
icons, bullets or spacers repeat it. Painting a copy is one blit from
the shared bitmap. Bitmaps are allocated as friends of the screen's, so
on an interleaved screen (Workbench is one) all planes go in one
blitter operation.

Background images (`background="..."`, CSS `url()`) get one record per
URL (img.s `BgFind`), so a tile used by many cells is fetched once. A
URL in a linked style sheet resolves against the sheet's URL. They load
before the `<img>`s, are tiled from the box's top left (`repeat`,
`repeat-x`, `repeat-y`, `no-repeat`), and small ones are pre-tiled to
64 pixels or more so that painting them takes few blits.

Speed on a stock A1200 (14 MHz 68020, `SPEED=real test/emu.sh --auto
speed`), for a 640x480 picture shown 400 wide (seconds; the first
versions in brackets):

| Format           | decode       | bitmap     |
|------------------|--------------|------------|
| baseline JPEG    | 7.3 (9.5)    | 1.4 (2.7)  |
| progressive JPEG | 11.5 (13.7)  | 1.4 (2.7)  |
| PNG              | 9.2 (17.4)   | 1.4 (2.8)  |
| WebP (lossy)     | 19.2 (35.9)  | 1.4 (2.8)  |
| GIF              | 3.2          | 1.4 (2.7)  |

The same baseline JPEG shown at 320 is decoded at 1/2 in 4.4 s (bitmap
0.9 s), and at 160 it is decoded at 1/4 in 2.6 s (bitmap 0.24 s). The
progressive one at 160 takes 6.9 s, because all its scans must still be
decoded.

`PROFILE=1` with the same command times each stage. What is left, for a
640x480 image:
- JPEG: the IDCT takes 3.9 s, mostly in its `muls.l` (80 for each block).
  Colour conversion takes 2.2 s.
- PNG: Paeth unfiltering takes 6.3 s, inflate 1.8 s.
- WebP: the loop filter takes 6.6 s, VP8 to RGB 4.8 s, reconstruction
  4.5 s and tokens 3.0 s.
- The bitmap: dithering takes 0.8 s and the chunky-to-planar conversion
  0.6 s.

What made the difference:
- Small loops without subroutine calls.
- Table lookups instead of clipping branches.
- A loop for each case, such as filter kind and edge direction, or
  chroma subsampling.
- Bytes kept in registers whose upper bytes stay zero, so no `moveq #0`
  before each load.
- The DC-only and two-coefficient IDCT shortcuts.

The 68020's cache holds 256 bytes, so a hot loop should fit in it.

Velox turns the dithered pens into bitplanes itself on standard (planar)
bitmaps, eight pixels at a time through lookup tables, instead of
calling `WriteChunkyPixels`. The mask of an image starts all set and
holes clear their bits, so opaque pixels cost nothing for it. On screens
of 15 bits or more (cybergraphics.library), images are written in ARGB
with `WritePixelArray`, with no colour cube and no dithering.

## Known issues

- Every TLS connection loses 48 bytes of memory in the emulated test system
  (A1200, KS 3.1, FS-UAE bsdsocket emulation, AmiSSL 6.1). This happens
  whether or not the handshake succeeds. Opening and closing AmiSSL without a
  connection loses nothing, plain HTTP loses nothing, and calling
  `OPENSSL_thread_stop()` did not change it. The cause is not found yet; it
  may be in AmiSSL's socket I/O or in the bsdsocket emulation. The `tls`
  emulator test tolerates up to 64 bytes per connection.
- A TLS handshake takes about 15 seconds on a stock 14 MHz 68020 (A1200).
  Some servers (for example example.com) close the connection before it
  finishes, and Velox then reports "Send failed". With an accelerator it
  takes a second or two. Velox restricts key exchange to X25519/P-256,
  because OpenSSL 4's default post-quantum hybrid is far slower. On slow
  machines, `PROXY=` with tools/velox-proxy.py avoids TLS on the Amiga
  entirely. The emulator tests run the 68020 unthrottled.
