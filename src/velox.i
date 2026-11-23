;
; velox.i - common include for every Velox module
;
; Pulls in the NDK definitions we use, the shared structures, the global
; data layout and the library-call macros.  Every .s file includes this.
;
; Register conventions (see CLAUDE.md):
;   a4        = pointer to the global data block G, never changed
;   d0-d1/a0-a1/a6 = scratch, may be destroyed by any routine
;   d2-d7/a2-a3/a5 = preserved by every routine
;   Results come back in d0; the CCR reflects d0 unless documented otherwise.
;

	IFND	VELOX_I
VELOX_I	SET	1

	include	"exec/types.i"
	include	"exec/ports.i"
	include	"exec/memory.i"
	include	"dos/dos.i"
	include	"dos/dosextens.i"
	include	"intuition/intuition.i"
	include	"graphics/rastport.i"
	include	"workbench/startup.i"
	include	"utility/tagitem.i"
	include	"libraries/gadtools.i"

	include	"lvo/exec_lib.i"
	include	"lvo/dos_lib.i"
	include	"lvo/intuition_lib.i"
	include	"lvo/graphics_lib.i"
	include	"lvo_bsdsocket.i"
	include	"tags.i"

VERSION_STR	MACRO
	dc.b	"0.2"
	ENDM

URL_MAX		equ	2048		; max URL length incl. NUL
LINE_MAX	equ	1024		; max HTTP header line we keep
HOST_MAX	equ	256
CONN_BUFSIZE	equ	4096
NET_TIMEOUT	equ	60		; seconds without data before giving up
MAX_REDIRECTS	equ	8
STATUS_MAX	equ	160		; status line / title buffers
PEN_CACHE	equ	64		; colours with an allocated pen
HIST_ENTRIES	equ	32

RC_OK		equ	0
RC_WARN		equ	5
RC_FAIL		equ	20

;--------------------------------------------------------------------
; Error codes (g_Error).  Messages are in ErrorText (util.s).
;--------------------------------------------------------------------
ERR_NONE	equ	0
ERR_NOMEM	equ	1
ERR_URL		equ	2		; malformed / unsupported URL
ERR_NOTCP	equ	3		; bsdsocket.library missing
ERR_RESOLVE	equ	4
ERR_CONNECT	equ	5
ERR_SEND	equ	6
ERR_RECV	equ	7
ERR_TIMEOUT	equ	8
ERR_ABORT	equ	9
ERR_PROTOCOL	equ	10		; not a valid HTTP response
ERR_REDIRECTS	equ	11
ERR_TLS		equ	12
ERR_FILE	equ	13
ERR_COUNT	equ	14

;--------------------------------------------------------------------
; Buf - growable byte buffer, always NUL terminated when allocated
;--------------------------------------------------------------------
	RSRESET
buf_Data	rs.l	1
buf_Len		rs.l	1
buf_Cap		rs.l	1
BUF_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; UrlParts - result of UrlParse.  up_Path points into the parsed string.
;--------------------------------------------------------------------
SCHEME_HTTP	equ	0
SCHEME_HTTPS	equ	1
SCHEME_OTHER	equ	-1

	RSRESET
up_Scheme	rs.l	1
up_Port		rs.l	1
up_Path		rs.l	1		; path + query, without fragment
up_PathLen	rs.l	1
up_Host		rs.b	HOST_MAX	; lower case, NUL terminated
UP_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Conn - a buffered byte stream: TCP socket, TLS session or (for tests)
; a DOS file.
;--------------------------------------------------------------------
	RSRESET
c_Sock		rs.l	1		; -1 when not a socket
c_SSL		rs.l	1		; 0 = plain
c_File		rs.l	1		; DOS file handle (tests), 0 = none
c_Pos		rs.l	1		; read position in c_Buf
c_End		rs.l	1		; end of valid data in c_Buf
c_Buf		rs.b	CONN_BUFSIZE
CONN_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Resp - an HTTP response
;--------------------------------------------------------------------
	RSRESET
r_Status	rs.l	1
r_Length	rs.l	1		; Content-Length or -1
r_Chunked	rs.l	1
r_Body		rs.b	BUF_SIZEOF
r_CType		rs.b	64		; Content-Type value
r_Url		rs.b	URL_MAX		; final URL after redirects
r_Location	rs.b	URL_MAX		; Location header
RESP_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; DOM.  Nodes and their strings live in the page pool.
;--------------------------------------------------------------------
DN_ELEMENT	equ	1
DN_TEXT		equ	3
DN_DOCUMENT	equ	9

	RSRESET
n_Parent	rs.l	1
n_First		rs.l	1		; first child
n_Last		rs.l	1		; last child
n_Next		rs.l	1		; next sibling
n_Type		rs.b	1		; DN_xxx
n_Flags		rs.b	1
n_Tag		rs.w	1		; TAG_xxx (elements)
n_Data		rs.l	1		; element: first Attr; text: text
n_Data2		rs.l	1		; element: aux data; text: length
NODE_SIZEOF	rs.b	0

	RSRESET
at_Next		rs.l	1
at_Name		rs.l	1		; lower case, NUL terminated
at_Value	rs.l	1		; NUL terminated, entities decoded
ATTR_SIZEOF	rs.b	0

MAX_DEPTH	equ	256		; deepest element nesting kept

; character sets for DecodeCharset
CS_AUTO		equ	0
CS_UTF8		equ	1
CS_LATIN1	equ	2		; also Windows-1252

;--------------------------------------------------------------------
; Style - computed style of an element (built on the stack in layout)
;--------------------------------------------------------------------
FONT_SIZES	equ	6		; size classes 0 (small) .. 5 (h1)
FONT_MONO	equ	8		; added to the size class
FONT_COUNT	equ	16
SOFT_UNDERLINE	equ	1		; = graphics FSF_UNDERLINED
SOFT_BOLD	equ	2
SOFT_ITALIC	equ	4

ALIGN_LEFT	equ	0
ALIGN_CENTER	equ	1
ALIGN_RIGHT	equ	2
WS_NORMAL	equ	0
WS_PRE		equ	1
WS_NOWRAP	equ	2
LIST_DISC	equ	0
LIST_CIRCLE	equ	1
LIST_SQUARE	equ	2
LIST_DECIMAL	equ	3
LIST_NONE	equ	4
SF_INLIST	equ	1		; st_Flags: inside a list (inherited)

	RSRESET
st_Display	rs.b	1		; DISP_xxx
st_Font		rs.b	1		; size class + FONT_MONO
st_Soft		rs.b	1		; SOFT_xxx
st_Align	rs.b	1
st_White	rs.b	1
st_List		rs.b	1
st_Flags	rs.b	1
st_pad		rs.b	1
st_Color	rs.l	1		; $RRGGBB
st_Bg		rs.l	1		; $RRGGBB or -1 (not inherited)
st_MTop		rs.w	1		; margins in pixels (not inherited)
st_MBottom	rs.w	1
st_MLeft	rs.w	1
st_MRight	rs.w	1
st_Link		rs.l	1		; enclosing <a href> element
st_Width	rs.w	1		; px; negative = percent; 0 = auto
st_Height	rs.w	1
STYLE_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Run - one item of the display list made by layout
;--------------------------------------------------------------------
RT_TEXT		equ	1
RT_RECT		equ	2		; filled background
RT_RULE		equ	3		; <hr>
RT_BULLET	equ	4		; list marker, ru_Len = LIST_xxx
RT_IMAGE	equ	5		; ru_Text = <img> node
RT_BOX		equ	6		; 1 pixel outline

	RSRESET
ru_Y		rs.l	1		; top, document coordinates
ru_X		rs.w	1
ru_W		rs.w	1
ru_H		rs.w	1
ru_Base		rs.w	1		; baseline offset from ru_Y
ru_Type		rs.b	1
ru_Font		rs.b	1
ru_Soft		rs.b	1
ru_Flags	rs.b	1
ru_Color	rs.l	1		; $RRGGBB
ru_Text		rs.l	1
ru_Len		rs.l	1
ru_Link		rs.l	1		; <a> element (or form control)
RUN_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Global data block, addressed as xxx(a4)
;--------------------------------------------------------------------
	RSRESET
g_SysBase	rs.l	1
g_DOSBase	rs.l	1
g_IntuitionBase	rs.l	1
g_GfxBase	rs.l	1
g_SocketBase	rs.l	1		; opened on first network use
g_WBMsg		rs.l	1		; WBStartup message, 0 when run from CLI
g_StdOut	rs.l	1		; Output() handle for CLI printing
g_AppPool	rs.l	1		; memory for the life of the program
g_Error		rs.l	1		; last ERR_xxx
g_Window	rs.l	1		; main window
g_WinSigMask	rs.l	1		; signal mask of the window's UserPort
g_AbortMask	rs.l	1		; signals that interrupt network waits
g_NetSigHook	rs.l	1		; routine(d0=signals) -> d0<>0 = abort
g_RDArgs	rs.l	1
g_ArgArray	rs.l	8
g_Timeval	rs.l	2
g_FdSet		rs.l	8		; fd_set for WaitSelect (256 sockets)
g_SockAddr	rs.b	16
g_Parts		rs.b	UP_SIZEOF
g_ReqBuf	rs.b	BUF_SIZEOF	; request being built
g_Line		rs.b	LINE_MAX	; current header line
g_UrlTmp	rs.b	URL_MAX		; scratch for UrlResolve
g_UrlTmp2	rs.b	URL_MAX		; scratch for callers of UrlResolve
g_Resp		rs.b	RESP_SIZEOF
; page
g_PagePool	rs.l	1		; memory for the current page
g_PageSrc	rs.b	BUF_SIZEOF	; page source (DOM strings point here)
g_Doc		rs.l	1		; document node
g_Title		rs.l	1		; <title> text node or 0
g_BaseHref	rs.l	1		; <base href> value or 0
; parser state
g_Depth		rs.l	1		; open element stack depth
g_PreDepth	rs.l	1		; open elements that preserve blanks
g_TagName	rs.b	32		; current tag name, lower case
g_AttrName	rs.b	32		; current attribute name, lower case
g_OpenStack	rs.l	MAX_DEPTH
; fonts and text measuring (set up by the GUI or the test driver)
g_MeasureFn	rs.l	1		; d0=font|soft<<8, a0=text, d1=len -> d0=width
g_FontH		rs.w	FONT_COUNT	; height per font index
g_FontBase	rs.w	FONT_COUNT	; baseline per font index
; layout
g_Runs		rs.b	BUF_SIZEOF	; display list (Run records)
g_LayWidth	rs.l	1		; width laid out for
g_DocHeight	rs.l	1
g_PageFg	rs.l	1		; default text colour
g_PageBg	rs.l	1		; page background colour
g_LinkColor	rs.l	1
g_LayY		rs.l	1		; top of the current line
g_LayLeft	rs.l	1		; content box of the current block
g_LayRight	rs.l	1
g_LayAlign	rs.l	1
g_LayWhite	rs.l	1
g_LineX		rs.l	1		; next x on the line
g_LineStart	rs.l	1		; index of the first run of the line
g_LineAsc	rs.l	1
g_LineDesc	rs.l	1
g_LineUsed	rs.l	1		; line has content
g_PendSpace	rs.l	1		; a blank is pending before the next word
g_PendMargin	rs.l	1		; collapsed vertical margin to add
g_LastH		rs.l	1		; font height for empty lines
g_SpaceW	rs.l	1		; width of a blank in the current font
g_Marker	rs.l	1		; list marker pending (LIST_xxx + 1)
g_MarkerNum	rs.l	1
g_ListNum	rs.l	1		; counter of the innermost list
g_LayDepth	rs.l	1
g_MeasMin	rs.l	1		; table measuring
g_MeasPref	rs.l	1
g_MeasLine	rs.l	1
g_StackSwap	rs.l	3		; StackSwapStruct
; GUI
g_GadToolsBase	rs.l	1
g_LayersBase	rs.l	1
g_DiskfontBase	rs.l	1
g_Screen	rs.l	1		; locked public screen
g_ColorMap	rs.l	1
g_VisualInfo	rs.l	1
g_GList		rs.l	1
g_GadUrl	rs.l	1
g_GadScroll	rs.l	1
g_NewGad	rs.b	gng_SIZEOF
g_ScreenFont	rs.l	1
g_FontPtr	rs.l	FONT_COUNT
g_FontOwned	rs.b	FONT_COUNT
g_TextAttr	rs.l	2		; struct TextAttr
g_MeasRP	rs.b	rp_SIZEOF	; RastPort for measuring text
g_MeasFont	rs.l	2		; font index / soft style set in g_MeasRP
g_PaintFont	rs.l	2		; the same for the window RastPort
g_PenCache	rs.l	PEN_CACHE*2	; $RRGGBB, pen
g_PenCount	rs.l	1
g_PageX		rs.l	1		; page view in window coordinates
g_PageY		rs.l	1
g_PageW		rs.l	1
g_PageH		rs.l	1
g_StatusY	rs.l	1
g_ScrollY	rs.l	1		; document line at the top of the view
g_ClipRect	rs.w	4		; struct Rectangle
g_Quit		rs.l	1
g_AbortReq	rs.l	1
g_HoverLink	rs.l	1
g_FocusLink	rs.l	1		; link with the keyboard focus or 0
g_FocusIdx	rs.l	1		; its first run, or -1
g_LogFH		rs.l	1		; LOG=file handle or 0
g_PressLink	rs.l	1
g_StatusText	rs.b	STATUS_MAX
g_StatusBuf	rs.b	STATUS_MAX
g_TitleText	rs.b	STATUS_MAX
; navigation
g_FragName	rs.l	1		; #fragment of the page URL or 0
g_FragY		rs.l	1		; its position after layout or -1
g_WantScroll	rs.l	1		; scroll position to restore or -1
g_HistPos	rs.l	1		; current history entry or -1
g_HistCount	rs.l	1
g_Hist		rs.l	HIST_ENTRIES*2	; URL, scroll position
g_PageUrl	rs.b	URL_MAX		; URL of the page shown
g_NavUrl	rs.b	URL_MAX		; URL being loaded
g_LinkUrl	rs.b	URL_MAX
g_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Library call macros.  They load a6 themselves, so a6 is always scratch.
;--------------------------------------------------------------------
EXEC	MACRO
	move.l	g_SysBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

DOS	MACRO
	move.l	g_DOSBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

INTUI	MACRO
	move.l	g_IntuitionBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

GFX	MACRO
	move.l	g_GfxBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

GT	MACRO
	move.l	g_GadToolsBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

LAYERS	MACRO
	move.l	g_LayersBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

SOCK	MACRO
	move.l	g_SocketBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

; SETERR code - store an error code in g_Error
SETERR	MACRO
	move.l	#\1,g_Error(a4)
	ENDM

	ENDC	; VELOX_I
