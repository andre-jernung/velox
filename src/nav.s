;
; nav.s - navigation: loading pages, history, links, internal pages
;

	include	"velox.i"
	include	"lvo/asl_lib.i"

	xdef	NavGo,NavBack,NavForward,NavReload,NavHome,NavLink,NavExit,NavPost
	xdef	SaveDownload,BookmarkAdd,BookmarksShow
	xref	HttpGet,UrlResolve,PageNew,BufReserve,BufAppend,BufAppendStr
	xref	BufAppendByte,BufClear,CharsetDetect,DecodeCharset,HtmlParse
	xref	DomNewNode,DomAppend,DomGetAttr,StrCopyN,StrCopy,StrIPrefix,StrLen
	xref	Alloc,Free,ErrorText,FmtDec,LayoutDocument
	xref	HttpGetCached,CacheFlush
	xref	GuiStatus,GuiSetUrl,GuiSetTitle,GuiPaintAll,GuiBusy,GuiNetHook
	xref	GuiPageWidth,GuiScrollTo,LogEvent,CssLoad,BufFree,ImagesStart

HIST_MAX	equ	HIST_ENTRIES
NAV_HISTORY	equ	1
NAV_CACHE	equ	2		; Back/Forward: from the cache if there
NAV_RELOAD	equ	4		; fetch everything anew

	section	code,code

;--------------------------------------------------------------------
; NavGo - load and show a URL
; In: a0 = absolute URL, d0 = NAV_HISTORY to add it to the history
;--------------------------------------------------------------------
NavGo:
	movem.l	d2-d3/a2,-(sp)
	clr.l	g_FindOn(a4)		; a new page ends finding
	move.l	d0,d3
	moveq	#NAV_RELOAD,d1
	and.l	d0,d1
	move.l	d1,g_NoCache(a4)
	move.l	a0,-(sp)		; "about:save": save the download,
	lea	AboutSave(pc),a1	; stay on the page
	jsr	StrIPrefix
	movem.l	(sp)+,a0
	tst.l	d0
	beq.s	.go
	bsr	SaveDownload
	bra	.x
.go:
	lea	g_NavUrl(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bsr	SaveScroll
	; a fragment of the page we are on: just scroll
	bsr	SamePage
	beq.s	.load
	lea	g_NavUrl(a4),a0
	lea	g_PageUrl(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	moveq	#-1,d0
	move.l	d0,g_WantScroll(a4)
	bsr	ShowPage
	bra	.hist
.load:	move.l	g_WinSigMask(a4),d0	; window events and Ctrl-C can stop
	or.l	#SIGBREAKF_CTRL_C,d0	; the page and its style sheets
	move.l	d0,g_AbortMask(a4)
	lea	GuiNetHook,a0
	move.l	a0,g_NetSigHook(a4)
	lea	LogGo(pc),a0
	lea	g_NavUrl(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	lea	MsgLoading(pc),a0
	bsr	StatusWithUrl
	moveq	#1,d0
	jsr	GuiBusy
	lea	g_NavUrl(a4),a0
	lea	AboutPrefix(pc),a1
	jsr	StrIPrefix
	beq.s	.net
	bsr	AboutPage
	lea	g_NavUrl(a4),a0
	bra.s	.built
.net:	lea	g_NavUrl(a4),a0		; file: URLs read a local file
	lea	FilePrefix(pc),a1
	jsr	StrIPrefix
	beq.s	.http
	bsr	FilePage
	lea	g_NavUrl(a4),a0
	bra.s	.built
.http:	lea	g_NavUrl(a4),a0
	btst	#1,d3			; NAV_CACHE
	beq.s	.fetch
	jsr	HttpGetCached
	bra.s	.got
.fetch:	jsr	HttpGet
.got:
	tst.l	d0
	bne.s	.ok
	tst.l	g_Quit(a4)		; window closed while loading
	bne	.x
	bsr	ErrorPage
	lea	g_NavUrl(a4),a0
	bra.s	.built
.ok:	bsr	TakeResponse
	lea	g_Resp+r_Url(a4),a0
.built:	lea	g_PageUrl(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	jsr	CssLoad
	clr.l	g_NetSigHook(a4)
	tst.l	g_Quit(a4)
	bne	.x
	bsr	ShowPage
.hist:	btst	#0,d3
	beq.s	.nohist
	lea	g_PageUrl(a4),a0
	bsr	HistoryPush
.nohist:
	moveq	#0,d0
	jsr	GuiBusy
.x:	clr.l	g_NoCache(a4)
	movem.l	(sp)+,d2-d3/a2
	rts

AboutPrefix:	dc.b	"about:",0
AboutSave:	dc.b	"about:save",0
FilePrefix:	dc.b	"file:",0
LogGo:		dc.b	"go",0
LogPage:	dc.b	"page",0
LogTitle:	dc.b	"title",0
LogTop:		dc.b	"top",0
MsgLoading:	dc.b	"Loading ",0
	even

; StatusWithUrl - status line "<a0>g_NavUrl"
StatusWithUrl:
	lea	g_StatusBuf(a4),a1
	jsr	StrCopy
	lea	g_NavUrl(a4),a0
	move.l	#STATUS_MAX-20,d0
	jsr	StrCopyN
	lea	g_StatusBuf(a4),a0
	jmp	GuiStatus

; SamePage - is g_NavUrl a #fragment of the current page?
; Out: d0 = 1 if yes
SamePage:
	tst.l	g_Doc(a4)
	beq.s	.no
	lea	g_NavUrl(a4),a0
	lea	g_PageUrl(a4),a1
.l:	move.b	(a0)+,d0
	move.b	(a1)+,d1
	cmp.b	#'#',d0
	beq.s	.hash
	cmp.b	d0,d1
	bne.s	.no
	tst.b	d0
	bne.s	.l
.no:	moveq	#0,d0
	rts
.hash:	tst.b	d1			; page URL ends or has its own #
	beq.s	.yes
	cmp.b	#'#',d1
	bne.s	.no
.yes:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; Building pages
;--------------------------------------------------------------------

; TakeResponse - make the page from g_Resp
TakeResponse:
	movem.l	a2,-(sp)
	jsr	PageNew
	lea	g_Resp+r_Body(a4),a0	; the body becomes the page source
	lea	g_PageSrc(a4),a1
	move.l	(a0),(a1)+
	move.l	4(a0),(a1)+
	move.l	8(a0),(a1)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	lea	g_PageSrc(a4),a0	; make sure there is a terminated buffer
	moveq	#1,d0
	jsr	BufReserve
	move.l	g_PageSrc+buf_Data(a4),a0
	add.l	g_PageSrc+buf_Len(a4),a0
	clr.b	(a0)
	lea	g_Resp+r_CType(a4),a2
	tst.b	(a2)
	beq.s	.html
	move.l	a2,a0
	lea	CtHtml(pc),a1
	jsr	StrIPrefix
	bne.s	.html
	move.l	a2,a0
	lea	CtXhtml(pc),a1
	jsr	StrIPrefix
	bne.s	.html
	move.l	a2,a0
	lea	CtText(pc),a1
	jsr	StrIPrefix
	bne.s	.plain
	bsr	BinaryPage
	bra.s	.x
.plain:	bsr	PlainPage
	bra.s	.x
.html:	move.l	a2,a0
	bsr	HtmlPage
.x:	movem.l	(sp)+,a2
	rts

CtHtml:		dc.b	"text/html",0
CtXhtml:	dc.b	"application/xhtml",0
CtText:		dc.b	"text/",0
	even

; HtmlPage - decode and parse g_PageSrc
; In: a0 = Content-Type or 0
HtmlPage:
	move.l	g_PageSrc+buf_Data(a4),a1
	jsr	CharsetDetect
	move.l	d0,d1
	move.l	g_PageSrc+buf_Data(a4),a0
	move.l	g_PageSrc+buf_Len(a4),d0
	jsr	DecodeCharset
	move.l	d0,g_PageSrc+buf_Len(a4)
	move.l	g_PageSrc+buf_Data(a4),a0
	jmp	HtmlParse

; PlainPage - show g_PageSrc as preformatted text
PlainPage:
	movem.l	a2-a3,-(sp)
	lea	g_Resp+r_CType(a4),a0
	move.l	g_PageSrc+buf_Data(a4),a1
	jsr	CharsetDetect
	move.l	d0,d1
	move.l	g_PageSrc+buf_Data(a4),a0
	move.l	g_PageSrc+buf_Len(a4),d0
	jsr	DecodeCharset
	move.l	d0,g_PageSrc+buf_Len(a4)
	moveq	#DN_DOCUMENT,d0
	moveq	#0,d1
	jsr	DomNewNode
	move.l	d0,g_Doc(a4)
	beq.s	.x
	move.l	d0,a2
	moveq	#DN_ELEMENT,d0
	moveq	#TAG_PRE,d1
	jsr	DomNewNode
	tst.l	d0
	beq.s	.x
	move.l	d0,a3
	move.l	a2,a0
	move.l	a3,a1
	jsr	DomAppend
	moveq	#DN_TEXT,d0
	moveq	#0,d1
	jsr	DomNewNode
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.l	g_PageSrc+buf_Data(a4),n_Data(a1)
	move.l	g_PageSrc+buf_Len(a4),n_Data2(a1)
	move.l	a3,a0
	jsr	DomAppend
.x:	movem.l	(sp)+,a2-a3
	rts

; GenStart - start a generated HTML page in g_PageSrc
GenStart:
	jsr	PageNew
	lea	g_PageSrc(a4),a0
	jmp	BufClear

; Gen - append a string; Gen0 - append an HTML-escaped string
; In: a1 = string
Gen:
	lea	g_PageSrc(a4),a0
	jmp	BufAppendStr
GenEsc:
	movem.l	d2/a2,-(sp)
	move.l	a1,a2
.l:	moveq	#0,d2
	move.b	(a2)+,d2
	beq.s	.x
	lea	EscLt(pc),a1
	cmp.b	#'<',d2
	beq.s	.esc
	lea	EscAmp(pc),a1
	cmp.b	#'&',d2
	beq.s	.esc
	lea	EscQuot(pc),a1
	cmp.b	#'"',d2
	beq.s	.esc
	lea	g_PageSrc(a4),a0
	move.l	d2,d0
	jsr	BufAppendByte
	bra.s	.l
.esc:	bsr.s	Gen
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

EscLt:		dc.b	"&lt;",0
EscAmp:		dc.b	"&amp;",0
EscQuot:	dc.b	"&quot;",0
	even

; GenEnd - parse the generated page
GenEnd:
	move.l	g_PageSrc+buf_Data(a4),d0
	beq.s	.x
	moveq	#CS_LATIN1,d1
	move.l	d0,a0
	move.l	g_PageSrc+buf_Len(a4),d0
	jsr	DecodeCharset
	move.l	g_PageSrc+buf_Data(a4),a0
	jsr	HtmlParse
.x:	rts

; ErrorPage - page explaining g_Error for g_NavUrl
ErrorPage:
	bsr	GenStart
	lea	PgErr1(pc),a1
	bsr	Gen
	move.l	g_Error(a4),d0
	jsr	ErrorText
	move.l	a0,a1
	bsr	GenEsc
	lea	PgErr2(pc),a1
	bsr	Gen
	lea	g_NavUrl(a4),a1
	bsr	GenEsc
	lea	PgErr3(pc),a1
	bsr	Gen
	bra	GenEnd

PgErr1:	dc.b	"<title>Error</title><h2>Cannot show this page</h2><p><b>",0
PgErr2:	dc.b	"</b></p><p>",0
PgErr3:	dc.b	"</p><p>Check the address, or use Reload to try again.</p>",0
	even

; BinaryPage - page describing a file that is not text
BinaryPage:
	movem.l	d2,-(sp)
	move.l	g_PageSrc+buf_Len(a4),d2
	lea	g_Download(a4),a0	; the body becomes the download
	jsr	BufFree
	lea	g_PageSrc(a4),a0
	lea	g_Download(a4),a1
	move.l	(a0),(a1)+
	move.l	4(a0),(a1)+
	move.l	8(a0),(a1)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	bsr	DownloadName
	bsr	GenStart
	lea	PgBin1(pc),a1
	bsr	Gen
	lea	g_Resp+r_CType(a4),a1
	bsr	GenEsc
	lea	PgBin2(pc),a1
	bsr	Gen
	lea	-16(sp),sp
	move.l	d2,d0
	move.l	sp,a0
	jsr	FmtDec
	move.l	sp,a1
	bsr	Gen
	lea	16(sp),sp
	lea	PgBin3(pc),a1
	bsr	Gen
	bsr	GenEnd
	movem.l	(sp)+,d2
	rts

PgBin1:	dc.b	"<title>File</title><h2>This is not a web page</h2><p>Type: <b>",0
PgBin2:	dc.b	"</b><br>Size: ",0
PgBin3:	dc.b	" bytes</p><p>Velox cannot display this file, but it can "
	dc.b	'<a href="about:save">save it</a> (Amiga+S).</p>',0
	even

; AboutPage - internal pages (about:velox is the start page)
AboutPage:
	bsr	GenStart
	lea	g_NavUrl(a4),a0
	lea	AboutBlank(pc),a1
	jsr	StrIPrefix
	bne.s	.end
	lea	PgStart(pc),a1
	bsr	Gen
.end:	bra	GenEnd

AboutBlank:	dc.b	"about:blank",0
PgStart:
	dc.b	"<html><head><title>Velox</title></head><body>"
	dc.b	"<h1>Velox</h1>"
	dc.b	"<p>A lightweight web browser for AmigaOS 3.x, written in "
	dc.b	"68k assembly. Version "
	VERSION_STR
	dc.b	".</p>"
	dc.b	"<h3>Places to start</h3><ul>"
	dc.b	'<li><a href="http://frogfind.com/">FrogFind</a> - search the '
	dc.b	"web, simplified for vintage computers"
	dc.b	'<li><a href="http://68k.news/">68k.news</a> - news for old '
	dc.b	"browsers"
	dc.b	'<li><a href="http://aminet.net/">Aminet</a> - the Amiga '
	dc.b	"software archive"
	dc.b	'<li><a href="http://info.cern.ch/hypertext/WWW/TheProject.html">'
	dc.b	"The first web site</a>"
	dc.b	"</ul><h3>Keys</h3><p>Cursor up/down, Shift+cursor and Space "
	dc.b	"scroll. Backspace goes back. Click Reload while a page is "
	dc.b	"loading to stop it.</p></body></html>",0
	even

;--------------------------------------------------------------------
; FilePage - a local file as the page
; In: a0 = after "file:" ("///Work:dir/page.html" or "Work:page.html")
;--------------------------------------------------------------------
FilePage:
	movem.l	d2-d4/a2,-(sp)
	cmp.b	#'/',(a0)		; "//" authority (empty or localhost)
	bne.s	.p
	cmp.b	#'/',1(a0)
	bne.s	.p
	addq.l	#2,a0
	cmp.b	#'/',(a0)		; "/Work:..." -> "Work:..."
	bne.s	.lh
	move.l	a0,a1
.col:	move.b	(a1)+,d0
	beq.s	.p
	cmp.b	#':',d0
	bne.s	.col
	addq.l	#1,a0
	bra.s	.p
.lh:	lea	SLocalhost(pc),a1
	jsr	StrIPrefix
.p:	lea	g_UrlTmp2(a4),a1	; the path, without #fragment / ?query
	move.l	#URL_MAX-2,d0
.c:	move.b	(a0)+,d1
	beq.s	.ce
	cmp.b	#'#',d1
	beq.s	.ce
	cmp.b	#'?',d1
	beq.s	.ce
	move.b	d1,(a1)+
	subq.l	#1,d0
	bpl.s	.c
.ce:	clr.b	(a1)
	jsr	PageNew
	lea	g_PageSrc(a4),a0
	jsr	BufClear
	lea	g_UrlTmp2(a4),a0
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.err
.rd:	lea	g_PageSrc(a4),a0
	move.l	#8192,d0
	jsr	BufReserve
	beq.s	.cl
	move.l	d4,d1
	move.l	g_PageSrc+buf_Data(a4),d2
	add.l	g_PageSrc+buf_Len(a4),d2
	move.l	#8192,d3
	DOS	Read
	tst.l	d0
	ble.s	.cl
	add.l	d0,g_PageSrc+buf_Len(a4)
	bra.s	.rd
.cl:	move.l	d4,d1
	DOS	Close
	lea	g_PageSrc(a4),a0	; terminated (also when empty)
	moveq	#1,d0
	jsr	BufReserve
	move.l	g_PageSrc+buf_Data(a4),a0
	add.l	g_PageSrc+buf_Len(a4),a0
	clr.b	(a0)
	clr.b	g_Resp+r_CType(a4)
	lea	g_UrlTmp2(a4),a0	; ".txt": plain text
.e:	tst.b	(a0)+
	bne.s	.e
	lea	-5(a0),a0
	lea	STxt(pc),a1
	jsr	StrIPrefix
	beq.s	.html
	bsr	PlainPage
	bra.s	.x
.html:	suba.l	a0,a0
	bsr	HtmlPage
	bra.s	.x
.err:	SETERR	ERR_FILE
	bsr	ErrorPage
.x:	movem.l	(sp)+,d2-d4/a2
	rts

SLocalhost:	dc.b	"localhost",0
STxt:		dc.b	".txt",0
	even

;--------------------------------------------------------------------
; Bookmarks: an HTML file, ENVARC:Velox/Bookmarks.html
;--------------------------------------------------------------------
BookmarkAdd:
	movem.l	d2-d4,-(sp)
	tst.l	g_Doc(a4)
	beq	.x
	lea	BmDir(pc),a0		; ENVARC:Velox may not exist yet
	move.l	a0,d1
	DOS	CreateDir
	move.l	d0,d1
	beq.s	.nodir
	DOS	UnLock
.nodir:	lea	BmFile(pc),a0
	move.l	a0,d1
	move.l	#MODE_READWRITE,d2
	DOS	Open
	move.l	d0,d4
	beq	.err
	move.l	d4,d1			; to the end; is it new?
	moveq	#0,d2
	moveq	#OFFSET_END,d3
	DOS	Seek
	move.l	d4,d1
	moveq	#0,d2
	moveq	#OFFSET_CURRENT,d3
	DOS	Seek
	tst.l	d0
	bne.s	.old
	move.l	d4,d1
	lea	BmHead(pc),a0
	move.l	a0,d2
	DOS	FPuts
.old:	move.l	d4,d1
	lea	BmLi(pc),a0
	move.l	a0,d2
	DOS	FPuts
	lea	g_PageUrl(a4),a0
	bsr	PutEsc
	move.l	d4,d1
	lea	BmMid(pc),a0
	move.l	a0,d2
	DOS	FPuts
	lea	g_TitleText(a4),a0
	bsr	PutEsc
	move.l	d4,d1
	lea	BmEnd(pc),a0
	move.l	a0,d2
	DOS	FPuts
	move.l	d4,d1
	DOS	Close
	lea	MsgBm(pc),a0
	jsr	GuiStatus
	bra.s	.x
.err:	lea	MsgBmErr(pc),a0
	jsr	GuiStatus
.x:	movem.l	(sp)+,d2-d4
	rts

; PutEsc - write a0 HTML-escaped to the file d4
PutEsc:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
.l:	moveq	#0,d2
	move.b	(a2)+,d2
	beq.s	.x
	lea	EscLt(pc),a0
	cmp.b	#'<',d2
	beq.s	.s
	lea	EscAmp(pc),a0
	cmp.b	#'&',d2
	beq.s	.s
	lea	EscQuot(pc),a0
	cmp.b	#'"',d2
	beq.s	.s
	move.l	d4,d1
	DOS	FPutC
	bra.s	.l
.s:	move.l	d4,d1
	move.l	a0,d2
	DOS	FPuts
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

BookmarksShow:
	lea	BmUrl(pc),a0
	moveq	#NAV_HISTORY,d0
	bra	NavGo

BmDir:		dc.b	"ENVARC:Velox",0
BmFile:		dc.b	"ENVARC:Velox/Bookmarks.html",0
BmUrl:		dc.b	"file:///ENVARC:Velox/Bookmarks.html",0
BmHead:		dc.b	"<html><head><title>Bookmarks</title></head><body>",10
		dc.b	"<h1>Bookmarks</h1><ul>",10,0
BmLi:		dc.b	'<li><a href="',0
BmMid:		dc.b	'">',0
BmEnd:		dc.b	"</a>",10,0
MsgBm:		dc.b	"Bookmark added",0
MsgBmErr:	dc.b	"Could not write the bookmarks",0
	even

;--------------------------------------------------------------------
; DownloadName - file name for the download: the last part of the URL
; path (without query), or "download"
;--------------------------------------------------------------------
DownloadName:
	lea	g_Resp+r_Url(a4),a0
	move.l	a0,a1			; a1 = after the last '/'
.l:	move.b	(a0)+,d0
	beq.s	.e
	cmp.b	#'?',d0
	beq.s	.e
	cmp.b	#'#',d0
	beq.s	.e
	cmp.b	#'/',d0
	bne.s	.l
	move.l	a0,a1
	bra.s	.l
.e:	subq.l	#1,a0
	move.l	a0,d1
	sub.l	a1,d1			; length
	lea	g_DownloadName(a4),a0
	tst.l	d1
	beq.s	.def
	cmp.l	#100,d1
	bls.s	.c
	moveq	#100,d1
.c:	subq.l	#1,d1
.cl:	move.b	(a1)+,d0
	cmp.b	#':',d0			; no ':' or '/' in Amiga file names
	bne.s	.ok
	moveq	#'_',d0
.ok:	move.b	d0,(a0)+
	dbf	d1,.cl
	clr.b	(a0)
	rts
.def:	lea	SDownload(pc),a1
.dl:	move.b	(a1)+,(a0)+
	bne.s	.dl
	rts

SDownload:	dc.b	"download",0
	even

;--------------------------------------------------------------------
; SaveDownload - ask for a file name and save the last download
;--------------------------------------------------------------------
SaveDownload:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	g_Download+buf_Data(a4),d0
	beq	.none
	lea	AslName(pc),a1
	moveq	#38,d0
	EXEC	OpenLibrary
	move.l	d0,g_AslBase(a4)
	beq	.fail
	move.l	g_Window(a4),AslTagWin+4
	lea	g_DownloadName(a4),a0
	move.l	a0,AslTagFile+4
	lea	g_DownloadDir(a4),a0
	move.l	a0,AslTagDir+4
	moveq	#ASL_FileRequest,d0
	suba.l	a0,a0
	move.l	g_AslBase(a4),a6
	jsr	_LVOAllocAslRequest(a6)
	move.l	d0,a2
	tst.l	d0
	beq	.close
	move.l	a2,a0
	lea	AslTags,a1
	move.l	g_AslBase(a4),a6
	jsr	_LVOAslRequest(a6)
	tst.l	d0
	beq.s	.free			; cancelled
	; path = drawer + file
	move.l	fr_Drawer(a2),a0
	lea	g_UrlTmp2(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	lea	g_UrlTmp2(a4),a0
	move.l	a0,d1
	move.l	fr_File(a2),d2
	move.l	#URL_MAX,d3
	DOS	AddPart
	lea	g_UrlTmp2(a4),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.werr
	move.l	d4,d1
	move.l	g_Download+buf_Data(a4),d2
	move.l	g_Download+buf_Len(a4),d3
	DOS	Write
	move.l	d0,d2
	move.l	d4,d1
	DOS	Close
	cmp.l	g_Download+buf_Len(a4),d2
	bne.s	.werr
	lea	MsgSaved(pc),a0
	lea	g_StatusBuf(a4),a1
	jsr	StrCopy
	lea	g_UrlTmp2(a4),a0
	move.l	#STATUS_MAX-20,d0
	jsr	StrCopyN
	lea	LogSaved(pc),a0
	lea	g_UrlTmp2(a4),a1
	move.l	g_Download+buf_Len(a4),d0
	jsr	LogEvent
	lea	g_StatusBuf(a4),a0
	jsr	GuiStatus
	bra.s	.free
.werr:	lea	MsgWriteErr(pc),a0
	jsr	GuiStatus
.free:	move.l	a2,a0
	move.l	g_AslBase(a4),a6
	jsr	_LVOFreeAslRequest(a6)
.close:	move.l	g_AslBase(a4),a1
	clr.l	g_AslBase(a4)
	EXEC	CloseLibrary
	bra.s	.x
.none:	lea	MsgNoDownload(pc),a0
	jsr	GuiStatus
	bra.s	.x
.fail:	lea	MsgNoAsl(pc),a0
	jsr	GuiStatus
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

AslName:	dc.b	"asl.library",0
MsgSaved:	dc.b	"Saved ",0
LogSaved:	dc.b	"saved",0
MsgWriteErr:	dc.b	"Could not write the file",0
MsgNoDownload:	dc.b	"There is no file to save",0
MsgNoAsl:	dc.b	"asl.library is missing",0
	even

	section	data,data
AslTags:
	dc.l	ASLFR_TitleText,AslTitle
AslTagWin:	dc.l	ASLFR_Window,0
AslTagFile:	dc.l	ASLFR_InitialFile,0
AslTagDir:	dc.l	ASLFR_InitialDrawer,0
	dc.l	ASLFR_DoSaveMode,1
	dc.l	ASLFR_SleepWindow,1
	dc.l	TAG_DONE
AslTitle:	dc.b	"Save file as",0
	even
	section	code,code

;--------------------------------------------------------------------
; ShowPage - lay out the new page and show it
;--------------------------------------------------------------------
ShowPage:
	movem.l	a2,-(sp)
	; fragment to jump to
	clr.l	g_FragName(a4)
	moveq	#-1,d0
	move.l	d0,g_FragY(a4)
	lea	g_PageUrl(a4),a0
.f:	move.b	(a0)+,d0
	beq.s	.nof
	cmp.b	#'#',d0
	bne.s	.f
	tst.b	(a0)
	beq.s	.nof
	move.l	a0,g_FragName(a4)
.nof:	clr.l	g_ScrollY(a4)
	clr.l	g_EditField(a4)
	clr.l	g_FocusLink(a4)
	moveq	#-1,d0
	move.l	d0,g_FocusIdx(a4)
	jsr	GuiPageWidth
	jsr	LayoutDocument
	move.l	g_WantScroll(a4),d0	; back/forward: old position
	bpl.s	.scr
	move.l	g_FragY(a4),d0
	bpl.s	.scr
	moveq	#0,d0
.scr:	moveq	#-1,d1
	move.l	d1,g_WantScroll(a4)
	move.l	g_DocHeight(a4),d1
	sub.l	g_PageH(a4),d1
	bpl.s	.m
	moveq	#0,d1
.m:	cmp.l	d1,d0
	ble.s	.s
	move.l	d1,d0
.s:	move.l	d0,g_ScrollY(a4)
	; title
	lea	g_TitleText(a4),a1
	move.l	g_Title(a4),d0
	beq.s	.notitle
	move.l	d0,a0
	move.l	n_Data2(a0),d0
	cmp.l	#STATUS_MAX-1,d0
	bls.s	.tl
	move.l	#STATUS_MAX-1,d0
.tl:	move.l	n_Data(a0),a0
	bra.s	.tc
.notitle:
	lea	g_PageUrl(a4),a0
	move.l	#STATUS_MAX-1,d0
	jsr	StrCopyN
	bra.s	.tset
.tc:	subq.l	#1,d0
	bmi.s	.te
.tcl:	move.b	(a0)+,(a1)+
	dbf	d0,.tcl
.te:	clr.b	(a1)
.tset:	lea	g_TitleText(a4),a0
	jsr	GuiSetTitle
	lea	g_PageUrl(a4),a0
	jsr	GuiSetUrl
	lea	g_TitleText(a4),a0
	lea	g_StatusText(a4),a1
	move.l	#STATUS_MAX-1,d0
	jsr	StrCopyN
	jsr	GuiPaintAll
	lea	LogPage(pc),a0
	lea	g_PageUrl(a4),a1
	move.l	g_DocHeight(a4),d0
	jsr	LogEvent
	lea	LogTitle(pc),a0
	lea	g_TitleText(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	lea	LogTop(pc),a0
	suba.l	a1,a1
	move.l	g_ScrollY(a4),d0
	jsr	LogEvent
	jsr	ImagesStart		; then the images, from the event loop
	movem.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; NavPost - submit data with POST and show the result
; In: a0 = URL, a1 = body, d0 = body length
;--------------------------------------------------------------------
NavPost:
	move.l	a1,g_PostData(a4)
	move.l	d0,g_PostLen(a4)
	clr.l	g_Doc(a4)		; never a "same page" fragment jump
	moveq	#NAV_HISTORY,d0
	bra	NavGo

;--------------------------------------------------------------------
; Links
;--------------------------------------------------------------------

; NavLink - follow a link
; In: a0 = <a> element
NavLink:
	move.l	a2,-(sp)
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a2
	move.l	a2,a0
	lea	JsPrefix(pc),a1
	jsr	StrIPrefix
	beq.s	.notjs
	lea	MsgNoJs(pc),a0
	jsr	GuiStatus
	bra.s	.x
.notjs:	lea	g_PageUrl(a4),a0	; base: <base href> resolved, or the page
	move.l	g_BaseHref(a4),d0
	beq.s	.res
	move.l	d0,a1
	movem.l	a2,-(sp)
	lea	g_UrlTmp2(a4),a2
	jsr	UrlResolve
	movem.l	(sp)+,a2
	lea	g_UrlTmp2(a4),a0
	tst.l	d0
	bne.s	.res
	lea	g_PageUrl(a4),a0
.res:	move.l	a2,a1
	lea	g_LinkUrl(a4),a2
	jsr	UrlResolve
	tst.l	d0
	beq.s	.x
	lea	g_LinkUrl(a4),a0
	lea	MailPrefix(pc),a1
	jsr	StrIPrefix
	beq.s	.go
	lea	MsgNoMail(pc),a0
	jsr	GuiStatus
	bra.s	.x
.go:	lea	g_LinkUrl(a4),a0
	moveq	#NAV_HISTORY,d0
	bsr	NavGo
.x:	move.l	(sp)+,a2
	rts

AnHref:		dc.b	"href",0
JsPrefix:	dc.b	"javascript:",0
MailPrefix:	dc.b	"mailto:",0
MsgNoJs:	dc.b	"JavaScript links are not supported",0
MsgNoMail:	dc.b	"Mail links are not supported",0
	even

;--------------------------------------------------------------------
; History
;--------------------------------------------------------------------

; SaveScroll - remember the scroll position in the current entry
SaveScroll:
	move.l	g_HistPos(a4),d0
	bmi.s	.x
	lea	g_Hist(a4),a0
	move.l	g_ScrollY(a4),4(a0,d0.l*8)
.x:	rts

; HistoryPush - add a URL after the current entry
; In: a0 = URL
HistoryPush:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	; same as the current entry (reload, fragment)?  nothing to add
	move.l	g_HistPos(a4),d0
	bmi.s	.add
	lea	g_Hist(a4),a0
	move.l	(a0,d0.l*8),a0
	move.l	a2,a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.add
	tst.b	d0
	bne.s	.c
	bra.s	.x
.add:	; drop the entries after the current one
.drop:	move.l	g_HistCount(a4),d2
	subq.l	#1,d2
	cmp.l	g_HistPos(a4),d2
	ble.s	.dropped
	bsr	HistoryDropLast
	bra.s	.drop
.dropped:
	cmp.l	#HIST_MAX,g_HistCount(a4)
	blo.s	.room
	bsr	HistoryDropFirst
.room:	move.l	a2,a0
	jsr	StrLen
	addq.l	#1,d0
	jsr	Alloc
	beq.s	.x
	move.l	d0,a1
	move.l	a2,a0
	move.l	a1,-(sp)
	jsr	StrCopy
	move.l	(sp)+,d0
	move.l	g_HistCount(a4),d1
	lea	g_Hist(a4),a0
	move.l	d0,(a0,d1.l*8)
	clr.l	4(a0,d1.l*8)
	move.l	d1,g_HistPos(a4)
	addq.l	#1,g_HistCount(a4)
.x:	movem.l	(sp)+,d2/a2
	rts

HistoryDropLast:
	subq.l	#1,g_HistCount(a4)
	move.l	g_HistCount(a4),d0
	lea	g_Hist(a4),a0
	move.l	(a0,d0.l*8),a1
	jmp	Free

HistoryDropFirst:
	lea	g_Hist(a4),a0
	move.l	(a0),a1
	move.l	g_HistCount(a4),d0
	subq.l	#2,d0
	bmi.s	.f
.m:	move.l	8(a0),(a0)+
	move.l	8(a0),(a0)+
	dbf	d0,.m
.f:	subq.l	#1,g_HistCount(a4)
	subq.l	#1,g_HistPos(a4)
	jmp	Free

; NavBack / NavForward / NavReload / NavHome
NavBack:
	moveq	#-1,d1
	bra.s	NavStep
NavForward:
	moveq	#1,d1
NavStep:
	move.l	g_HistPos(a4),d0
	add.l	d1,d0
	bmi.s	.x
	cmp.l	g_HistCount(a4),d0
	bge.s	.x
	move.l	d0,-(sp)
	bsr	SaveScroll
	movem.l	(sp)+,d0
	move.l	d0,g_HistPos(a4)
	lea	g_Hist(a4),a0
	move.l	4(a0,d0.l*8),g_WantScroll(a4)
	move.l	(a0,d0.l*8),a0
	moveq	#NAV_CACHE,d0
	bra	NavGo
.x:	rts

NavReload:
	move.l	g_ScrollY(a4),g_WantScroll(a4)
	lea	g_PageUrl(a4),a0	; (NavGo copies it first)
	moveq	#NAV_RELOAD,d0
	bra	NavGo

NavHome:
	lea	g_HomeUrl(a4),a0	; Velox/Home or HOME tooltype ...
	tst.b	(a0)
	bne.s	.go
	lea	HomeUrl(pc),a0		; ... or the start page
.go:	moveq	#NAV_HISTORY,d0
	bra	NavGo

HomeUrl:	dc.b	"about:velox",0
	even

; NavExit - free the history
NavExit:
	jsr	CacheFlush
.l:	tst.l	g_HistCount(a4)
	beq.s	.x
	bsr	HistoryDropLast
	bra.s	.l
.x:	clr.l	g_HistPos(a4)
	subq.l	#1,g_HistPos(a4)
	rts
