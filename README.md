# Velox

A small, fast web browser for classic AmigaOS 3.x, written entirely in
68k assembly. The program is about 55 KB.

## Requirements

- AmigaOS 3.1 or newer, 68020 or better
- A TCP/IP stack with bsdsocket.library (Roadshow, AmiTCP, Miami)
- For https: AmiSSL 5 or newer (AmiSSL 6 recommended), or
  `velox-proxy.py` running on a modern machine
- For images: picture datatypes. OS 3.1 has ILBM; OS 3.2 also has PNG,
  GIF and BMP.

## Features

- HTML with a tolerant HTML5-style parser; UTF-8, Latin-1 and
  Windows-1252 pages
- CSS subset: selectors (including `:not()`, `:is()`, attribute and
  structural ones) with specificity, colors, fonts, margins, padding,
  borders, widths, alignment, display, media queries
- Tables, lists, preformatted text, headings, horizontal rules, images
  floated left or right with the text flowing around them
- Forms: text, password, checkboxes, radio buttons, selects, text areas;
  GET and POST
- Images through datatypes.library, scaled and remapped to the screen,
  loaded while the page is already usable
- http and https (AmiSSL with certificate checks, or through a proxy),
  keep-alive connections, redirects, chunked transfers, cookies
- Password protected pages (HTTP Basic): `http://user:password@host/`
- A memory cache: Back and Forward, style sheets and images do not
  fetch again (Reload does)
- Downloads of anything that is not a page, with a file requester
- History, bookmarks, local `file:` pages, a home page, find in page
- Frames and iframes as links to their pages; `<meta>` refresh redirects
- Keyboard navigation for everything; keys typed while a page loads
  are not lost
- Stays responsive while loading: the page scrolls, and links,
  gadgets and menus work, while images and pages load
- Transfer progress in the status line
- Select text with the mouse: it is copied to the clipboard

## Starting

From the Shell:

    Velox [URL] [PROXY=host:port] [LOG=file]

From Workbench, double-click the icon. Settings can be tool types in the
icon (remove the parentheses to enable one) or environment variables
(`SetEnv SAVE Velox/Home http://frogfind.com/`):

| Tool type            | Variable            | Meaning                             |
|----------------------|---------------------|-------------------------------------|
| `PROXY=host:port`    | `Velox/Proxy`       | send all requests through a proxy   |
| `HOME=url`           | `Velox/Home`        | the home page (also the start page) |
| `URL=url`            |                     | the page to start with              |
| `DOWNLOADDIR=drawer` | `Velox/DownloadDir` | where downloads go (default `RAM:`) |
| `NOIMAGES`           | `Velox/NoImages`    | do not load images                  |
| `PUBSCREEN=name`     | `Velox/PubScreen`   | open on that public screen          |
|                      | `Velox/InsecureTLS` | skip certificate checks (testing)   |

The window opens where it was last closed (`Velox/Window`).
Bookmarks are kept in `ENVARC:Velox/Bookmarks.html`, an ordinary page
you can edit. Cookies that a site wants kept (with an expiry date) are
saved in `ENVARC:Velox/Cookies`; delete that file to forget them.

## Keys

| Key                  | Action                                  |
|----------------------|-----------------------------------------|
| Ctrl-L               | go to the URL field                     |
| Tab / Shift-Tab      | next / previous link or form field      |
| Return               | follow the link, activate the field     |
| Cursor up/down       | scroll a line (with Shift: a page)      |
| Space                | page down                               |
| Ctrl-Up / Ctrl-Down  | top / bottom of the page                |
| Backspace, Ctrl-B    | back                                    |
| Ctrl-F               | forward                                 |
| Ctrl-R               | reload                                  |
| Esc                  | stop loading (the page or its images)   |
| Ctrl-H               | home                                    |
| /                    | find in the page (Return next, Esc end)  |
| Ctrl-D               | add a bookmark                          |
| Ctrl-K               | show the bookmarks                      |
| Amiga-S              | save the page or file                   |
| Amiga-C              | copy the address (of the focused link)  |
| Amiga-U              | view the page source                    |
| Ctrl-Q               | quit                                    |

The Amiga key works in place of Ctrl for the menu commands.

## https through a proxy

Without AmiSSL, or on a slow machine, run `velox-proxy.py` on a modern
computer on your network (see the comment at its top) and set
`PROXY=` or `Velox/Proxy` to it. TLS handshakes take about 15 seconds on
a stock 68020 with AmiSSL; keep-alive connections mean one handshake per
site instead of one per request.

## Building

See `CLAUDE.md` for the toolchain and tests and `docs/DESIGN.md` for the
architecture. `make dist` puts the program, its icon, the proxy and this
file in `build/dist/Velox`.
