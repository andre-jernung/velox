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

	include	"lvo/exec_lib.i"
	include	"lvo/dos_lib.i"
	include	"lvo/intuition_lib.i"
	include	"lvo/graphics_lib.i"
	include	"lvo_bsdsocket.i"

VERSION_STR	MACRO
	dc.b	"0.2"
	ENDM

URL_MAX		equ	2048		; max URL length incl. NUL
LINE_MAX	equ	1024		; max HTTP header line we keep
HOST_MAX	equ	256
CONN_BUFSIZE	equ	4096
NET_TIMEOUT	equ	60		; seconds without data before giving up
MAX_REDIRECTS	equ	8

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

SOCK	MACRO
	move.l	g_SocketBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

; SETERR code - store an error code in g_Error
SETERR	MACRO
	move.l	#\1,g_Error(a4)
	ENDM

	ENDC	; VELOX_I
