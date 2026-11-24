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

The window is served while anything loads. Sockets are non-blocking,
so connecting, the TLS handshake and reading all wait in `WaitSocket`
(`WaitSelect` on the socket and the window). A window message calls the
network hook, and the hook calls `BusyEvents`. Messages that only change
the view, such as scrolling, the scroller, hovering, selecting, resizing
and window refreshes, are handled there and then (`IsViewEvent`). Other
messages are kept in a queue (`Defer`) that the event loop replays
first:
- **While images load,** the first kept message stops the image fetch.
  The image is fetched again later.
- **While a page loads,** keys are kept for after the load. Gadgets,
  menus and links of the page shown stop the load, and that page stays
  (as with Esc and Reload).
- **Image decoding** (`NewDTObject` and the remapping) runs in a process
  of its own at a lower priority. Velox serves the window while it
  waits.

Host names that were already looked up are cached, because
`gethostbyname` blocks. What still blocks: DNS for a new host, the
crypto of the TLS handshake, and parsing and layout.

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
make the next refresh paint everything too. This fits the JavaScript
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

## Modules

| Module      | Job                                                            |
|-------------|----------------------------------------------------------------|
| main.s      | startup (CLI/Workbench, tool types), settings, CLI fetch        |
| mem.s       | application and page pools, growable buffers                    |
| util.s      | strings, numbers, output, event log (`LOG=`), error texts       |
| url.s       | parsing, resolving (RFC 3986), fixing typed addresses           |
| conn.s      | sockets (non-blocking), AmiSSL, DNS cache, I/O through `WaitSelect` |
| http.s      | requests, responses, redirects, keep-alive                      |
| cache.s     | memory cache of recent responses                                |
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

- JPEG uses libjpeg's fast integer inverse DCT. When an image is shown at
  1/8 of its size or less, only the DC coefficients are used.
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

Background images (`background="..."`, CSS `url()`) get one record per
URL (img.s `BgFind`), so a tile used by many cells is fetched once. A
URL in a linked style sheet resolves against the sheet's URL. They load
before the `<img>`s, are tiled from the box's top left (`repeat`,
`repeat-x`, `repeat-y`, `no-repeat`), and small ones are pre-tiled to
64 pixels or more so that painting them takes few blits.

Speed on a stock A1200 (14 MHz 68020, `SPEED=real test/emu.sh --auto
speed`), for a 640x480 picture shown 400 wide (seconds):

| Format           | decode | bitmap |
|------------------|--------|--------|
| baseline JPEG    | 9.5    | 2.7    |
| progressive JPEG | 13.7   | 2.7    |
| PNG              | 17.4   | 2.8    |
| WebP (lossy)     | 35.9   | 2.8    |
| GIF              | 3.2    | 2.7    |

These are first, unoptimized versions: the inner loops still go through
subroutines per symbol and per pixel.

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
