;
; frames.s - framesets: the frames' documents in one page, each frame
; a view of its own
;
; A page that is a <frameset> keeps it: each <frame> gets its document,
; fetched (through the caches) and parsed into the page: its <body>
; (with its attributes) and its style sheets, its relative URLs made
; absolute (they are the frame document's, not the page's); a frameset
; in it in the same way (FramesCompose).
;
; Laid out (FramesLayout), the window's page area is cut into the
; frames' rectangles (rows and cols: pixels, percent, the rest for the
; "*" ones), and each frame is a view of its own: its runs, its height,
; its scroll position, its background (the globals from g_View to
; g_ViewEnd: ViewSelect puts a frame's in G).  The mouse acts on the
; frame under it, a click makes a frame the active one: the keys and
; the scroller act on that (gui.s).
;
; A link (or a form sent with GET) in a frame that targets a frame (by
; its target, else the frame document's <base target>, else its own
; frame) loads the page again with that frame's document replaced.
; Which frames show what is part of the page's URL, after its own:
; "URL<1>name<2>url<1>name<2>url" (bytes 1 and 2), so that the
; history, the page files and the pages kept see one page as always.
; URL parsing stops at the <1> (url.s), and the URL gadget does not
; show what follows it.
;

	include	"velox.i"

	xdef	FramesCompose,FrameNav,FrameSplit,FrameShow
	xdef	FramesPage,FramesLayout,FramesFree,ViewSelect,ViewSlot,FrameAt
	xref	LayoutDocument
	xref	HttpGetCached,HtmlParse,CharsetDetect,DecodeCharset,BufFree
	xref	PageAlloc,DomNewNode,DomAppend,DomAddAttr,DomGetAttr
	xref	UrlResolve,StrIPrefix,StrLen,LogEvent,GuiStatus,NavGo

FR_DEPTH	equ	4		; framesets in frames, at most
FR_SEP		equ	1		; "<1>name<2>url" after the page's URL
FR_EQ		equ	2
FR_BORDER	equ	2		; between frames

	section	code,code

;--------------------------------------------------------------------
; FrameSplit - (NavLoad) g_NavUrl with frames' URLs after it: those go
; to g_FrOv, g_NavUrl keeps the page's own; g_NavKey = all of it (the
; page as composed: its page file)
;--------------------------------------------------------------------
FrameSplit:
	lea	g_NavUrl(a4),a0
	lea	g_NavKey(a4),a1
.c:	move.b	(a0)+,(a1)+
	bne.s	.c
	clr.b	g_FrOv(a4)
	lea	g_NavUrl(a4),a0
.f:	move.b	(a0),d0
	beq.s	.x
	cmp.b	#FR_SEP,d0
	beq.s	.cut
	addq.l	#1,a0
	bra.s	.f
.cut:	clr.b	(a0)+
	lea	g_FrOv(a4),a1
	move.b	#FR_SEP,(a1)+
.o:	move.b	(a0)+,(a1)+
	bne.s	.o
.x:	rts

;--------------------------------------------------------------------
; FrameShow - URL a0 as shown (without its frames' URLs)
; Out: a0 = it (g_UrlShow, or a0 itself if it has none)
;--------------------------------------------------------------------
FrameShow:
	move.l	a0,a1
.f:	move.b	(a1)+,d0
	beq.s	.x
	cmp.b	#FR_SEP,d0
	bne.s	.f
	lea	g_UrlShow(a4),a1
.c:	move.b	(a0)+,d0
	cmp.b	#FR_SEP,d0
	beq.s	.e
	move.b	d0,(a1)+
	bra.s	.c
.e:	clr.b	(a1)
	lea	g_UrlShow(a4),a0
.x:	rts

;--------------------------------------------------------------------
; FramesCompose - (loader: PageFixups) a page that is a <frameset>:
; its frames get their documents, and g_PageUrl gets the frames' URLs
; (g_FrOv) after it.  The response, the disk cache entry
; read (DcFresh, DcCond after) and the progress hook are kept.
;--------------------------------------------------------------------
FR_SAVE		equ	52+ETAG_MAX+LASTMOD_MAX

FramesCompose:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	g_Doc(a4),d0
	beq	.x
	move.l	d0,a0
	move.l	#TAG_FRAMESET,d0
	bsr	FindTag
	beq	.x
	move.l	d0,a2			; a2 = the frameset
	lea	-FR_SAVE(sp),sp		; what fetching the frames changes
	lea	g_DcHdr(a4),a0
	move.l	sp,a1
	moveq	#52/4-1,d0
.s1:	move.l	(a0)+,(a1)+
	dbf	d0,.s1
	lea	g_DcETag(a4),a0
	move.l	#(ETAG_MAX+LASTMOD_MAX)/4-1,d0
.s2:	move.l	(a0)+,(a1)+
	dbf	d0,.s2
	move.l	g_ProgressHook(a4),-(sp)
	clr.l	g_ProgressHook(a4)
	move.l	g_PageCharset(a4),-(sp)
	move.l	g_RespFrom(a4),-(sp)
	clr.l	g_FrCount(a4)
	lea	g_PageUrl(a4),a0	; the page's own URL (the base)
	bsr	FrCopy
	beq.s	.rest
	move.l	d0,a1
	move.l	a2,a0
	moveq	#0,d0
	bsr	FrCompose
	bsr	FrNoFrames		; (what is there for browsers without)
	lea	g_PageUrl(a4),a0	; the frames' URLs after the page's
.e:	tst.b	(a0)+
	bne.s	.e
	subq.l	#1,a0
	lea	g_FrOv(a4),a1
	lea	g_PageUrl+URL_MAX-1(a4),a2
.ov:	cmp.l	a2,a0
	bhs.s	.ovx
	move.b	(a1)+,(a0)+
	bne.s	.ov
.ovx:	clr.b	(a0)
.rest:	move.l	(sp)+,g_RespFrom(a4)
	move.l	(sp)+,g_PageCharset(a4)
	move.l	(sp)+,g_ProgressHook(a4)
	move.l	sp,a0
	lea	g_DcHdr(a4),a1
	moveq	#52/4-1,d0
.r1:	move.l	(a0)+,(a1)+
	dbf	d0,.r1
	lea	g_DcETag(a4),a1
	move.l	#(ETAG_MAX+LASTMOD_MAX)/4-1,d0
.r2:	move.l	(a0)+,(a1)+
	dbf	d0,.r2
	lea	FR_SAVE(sp),sp
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; FrCompose - the frames of frameset a0 get their documents (FrameFill;
; URLs relative to a1), its framesets the same
; In:  d0 = how deep (framesets in frames)
;--------------------------------------------------------------------
FrCompose:
	movem.l	d2/d7/a2,-(sp)
	move.l	a1,d7			; d7 = base URL
	move.l	d0,d2			; d2 = depth
	move.l	n_First(a0),a2
.l:	move.l	a2,d0
	beq.s	.x
	tst.l	g_TkAbort(a4)		; (stopped: no more)
	bne.s	.x
	move.l	d0,a0
	move.l	n_Next(a0),a2
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.l
	cmp.w	#TAG_FRAME,n_Tag(a0)
	bne.s	.fs
	move.l	d7,d0
	move.l	d2,d1
	bsr	FrameFill
	bra.s	.l
.fs:	cmp.w	#TAG_FRAMESET,n_Tag(a0)
	bne.s	.l
	cmp.l	#FR_DEPTH,d2
	bhs.s	.l
	move.l	d7,a1
	move.l	d2,d0
	addq.l	#1,d0
	bsr	FrCompose
	bra.s	.l
.x:	movem.l	(sp)+,d2/d7/a2
	rts

;--------------------------------------------------------------------
; FrameFill - give frame a0 its document (its src relative to d0, or
; the URL g_FrOv has for its name; d1 = how deep, for a frameset in
; it): its <body> and its style sheets, relative URLs in it made
; absolute, or the frameset in it (FrCompose).  The frame notes its
; name and its document's <base target> (vxframe, vxtarget: FrameNav).
; A frame that cannot be shown gets a link to its document.
;--------------------------------------------------------------------
FrameFill:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2			; a2 = the frame
	suba.l	a5,a5			; a5 = its body (FrBody)
	move.l	d0,d7			; d7 = base URL
	move.l	d1,-(sp)		; (sp) = depth
	moveq	#0,d6			; d6 = its document's URL
	lea	SSrc(pc),a1
	move.l	a2,a0
	jsr	DomGetAttr
	move.l	d0,d5			; d5 = src
	move.l	a2,a0			; its label (a link if not shown):
	lea	STitle(pc),a1		; name, title or src
	jsr	DomGetAttr
	tst.l	d0
	bne.s	.lab
	move.l	d5,d0
.lab:	move.l	d0,-(sp)		; 4(sp) = depth, (sp) = label
	lea	SName(pc),a1		; its name, or "f" and its number
	move.l	a2,a0
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.gen
	move.l	d0,(sp)
	bra.s	.named
.gen:
	moveq	#4,d0
	jsr	PageAlloc
	beq	.x
	move.l	d0,a0
	move.b	#'f',(a0)
	move.l	g_FrCount(a4),d1
	divu.w	#10,d1
	add.b	#'0',d1
	move.b	d1,1(a0)
	swap	d1
	add.b	#'0',d1
	move.b	d1,2(a0)
.named:	move.l	d0,d4			; d4 = name
	addq.l	#1,g_FrCount(a4)
	move.l	a2,a0
	lea	SVxFrame(pc),a1
	move.l	d4,d1
	bsr	FrAttrV
	move.l	d4,a0			; its URL: as the page's URL says,
	bsr	FrOvFind		; or its src
	bne.s	.url
	tst.l	d5
	beq	.x
	move.l	d7,a0
	move.l	d5,a1
	move.l	a2,-(sp)
	lea	g_FrTmp(a4),a2
	jsr	UrlResolve
	move.l	(sp)+,a2
	tst.l	d0
	beq	.x
	lea	g_FrTmp(a4),a0
	bsr	FrCopy
	beq	.x
.url:	move.l	d0,d6
	cmp.l	#FR_MAX,g_FrCount(a4)	; (too many: a link)
	bhi	.link
	move.l	d4,a1			; (for tests: "frame NAME")
	lea	LogFrame(pc),a0
	move.l	#$80000000,d0
	jsr	LogEvent
	lea	MsgFrame(pc),a0
	jsr	GuiStatus
	move.l	d6,a0
	jsr	HttpGetCached
	tst.l	g_TkAbort(a4)
	bne	.free
	cmp.l	#200,d0
	bne	.flink
	move.l	g_Resp+r_Body+buf_Data(a4),d0
	beq	.flink
	lea	g_Resp+r_CType(a4),a0	; HTML (or not said): its document
	tst.b	(a0)
	beq.s	.html
	lea	CtHtml(pc),a1
	jsr	StrIPrefix
	bne.s	.html
	lea	g_Resp+r_CType(a4),a0
	lea	CtXhtml(pc),a1
	jsr	StrIPrefix
	bne.s	.html
	lea	g_Resp+r_CType(a4),a0	; a picture: it
	lea	CtImage(pc),a1
	jsr	StrIPrefix
	beq	.flink
	moveq	#DN_ELEMENT,d0
	move.l	#TAG_IMG,d1
	jsr	DomNewNode
	beq	.free
	move.l	d0,a3
	move.l	a3,a0
	lea	SSrc(pc),a1
	move.l	d6,d1
	bsr	FrAttrV
	bsr	FrBody
	beq	.free
	move.l	a5,a0
	move.l	a3,a1
	jsr	DomAppend
	bra	.free
.html:	lea	g_Resp+r_Url(a4),a0	; (its URL after redirects)
	bsr	FrCopy
	beq	.flink
	move.l	d0,d6
	move.l	g_Resp+r_Body+buf_Len(a4),d0	; its text, into the page
	addq.l	#1,d0
	jsr	PageAlloc
	beq	.free
	move.l	d0,a3			; a3 = the text
	move.l	g_Resp+r_Body+buf_Data(a4),a0
	move.l	a3,a1
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	beq.s	.cpe
.cp:	move.b	(a0)+,(a1)+
	subq.l	#1,d0
	bne.s	.cp
.cpe:	clr.b	(a1)
	lea	g_Resp+r_CType(a4),a0
	tst.b	(a0)
	bne.s	.ct
	suba.l	a0,a0
.ct:	move.l	a3,a1
	jsr	CharsetDetect
	move.l	d0,d1
	move.l	a3,a0
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	jsr	DecodeCharset
	clr.b	(a3,d0.l)
	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	move.l	g_Doc(a4),-(sp)		; parsed as a document of its own
	move.l	g_Title(a4),-(sp)
	move.l	g_BaseHref(a4),-(sp)
	move.l	a3,a0
	jsr	HtmlParse
	move.l	d0,d2			; d2 = its document
	move.l	g_BaseHref(a4),d3	; d3 = its <base href>
	move.l	(sp)+,g_BaseHref(a4)
	move.l	(sp)+,g_Title(a4)
	move.l	(sp)+,g_Doc(a4)
	tst.l	d2
	beq	.flink
	tst.l	d3			; its base: <base href> against its URL
	beq.s	.base
	move.l	d6,a0
	move.l	d3,a1
	move.l	a2,-(sp)
	lea	g_FrTmp(a4),a2
	jsr	UrlResolve
	move.l	(sp)+,a2
	tst.l	d0
	beq.s	.base
	lea	g_FrTmp(a4),a0
	bsr	FrCopy
	beq.s	.base
	move.l	d0,d6
.base:	move.l	d2,a0			; relative URLs: absolute
	move.l	d6,a1
	bsr	FrFixUrls
	move.l	d2,a0			; <base target>: the cell notes it
	move.l	#TAG_BASE,d0
	bsr	FindTag
	beq.s	.nbt
	move.l	d0,a0
	lea	STarget(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.nbt
	move.l	d0,d1
	move.l	a2,a0
	lea	SVxTarget(pc),a1
	bsr	FrAttrV
.nbt:	move.l	d2,a0			; a frameset in it: that, in the frame
	move.l	#TAG_FRAMESET,d0
	bsr	FindTag
	beq.s	.body
	cmp.l	#FR_DEPTH,4(sp)
	bhs.s	.body
	move.l	d0,a3
	move.l	a3,a0
	bsr	DomUnlinkPrev
	move.l	a2,a0
	move.l	a3,a1
	jsr	DomAppend
	move.l	a3,a0
	move.l	d6,a1
	move.l	4(sp),d0
	addq.l	#1,d0
	bsr	FrCompose
	bra	.free
.body:	move.l	d2,a0			; its style sheets
	move.l	a2,a1
	bsr	FrSheets
	bsr	FrBody			; its body: its attributes, its content
	beq	.free			; (or all of the document's)
	move.l	d2,a0
	move.l	#TAG_BODY,d0
	bsr	FindTag
	beq.s	.nob
	move.l	d0,a3
	move.l	n_Data(a3),n_Data(a5)
	move.l	a3,a0
	move.l	a5,a1
	bsr	FrMove
	bra.s	.free
.nob:	move.l	d2,a0
	move.l	n_First(a0),d0		; (<html>: its children)
	beq.s	.free
	move.l	d0,a0
	cmp.w	#TAG_HTML,n_Tag(a0)
	bne.s	.mv
	move.l	d2,a0
	move.l	n_First(a0),a0
.mv:	move.l	a5,a1
	bsr	FrMove
	bra.s	.free
.flink:	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
.link:	bsr	FrBody			; a link "Frame: name" to it
	beq.s	.x
	moveq	#DN_ELEMENT,d0
	move.l	#TAG_A,d1
	jsr	DomNewNode
	beq.s	.x
	move.l	d0,a3
	move.l	a3,a0
	lea	SHref(pc),a1
	move.l	d6,d1
	beq.s	.x
	bsr	FrAttrV
	move.l	a5,a0
	move.l	a3,a1
	jsr	DomAppend
	lea	MsgFrame(pc),a0
	move.l	(sp),a1
	move.l	a1,d0
	beq.s	.x
	bsr	FrJoin
	beq.s	.x
	move.l	d0,d2
	move.l	d1,d3
	moveq	#DN_TEXT,d0
	moveq	#0,d1
	jsr	DomNewNode
	beq.s	.x
	move.l	d0,a1
	move.l	d2,n_Data(a1)
	move.l	d3,n_Data2(a1)
	move.l	a3,a0
	jsr	DomAppend
	bra.s	.x
.free:	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
.x:	addq.l	#8,sp
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; FrBody - (FrameFill: a2 = the frame) a <body> in it: a5 (once)
; Out: d0 = 0 if out of memory (CCR set)
FrBody:
	move.l	a5,d0
	bne.s	.x
	moveq	#DN_ELEMENT,d0
	move.l	#TAG_BODY,d1
	jsr	DomNewNode
	beq.s	.x
	move.l	d0,a5
	move.l	a2,a0
	move.l	a5,a1
	jsr	DomAppend
	move.l	a5,d0
.x:	rts

LogFrame:	dc.b	"frame",0
MsgFrame:	dc.b	"Frame: ",0
CtHtml:		dc.b	"text/html",0
CtXhtml:	dc.b	"application/xhtml",0
CtImage:	dc.b	"image/",0
SRows:		dc.b	"rows",0
SCols:		dc.b	"cols",0
SSrc:		dc.b	"src",0
SName:		dc.b	"name",0
STitle:		dc.b	"title",0
SHref:		dc.b	"href",0
STarget:	dc.b	"target",0
SVxFrame:	dc.b	"vxframe",0
SVxTarget:	dc.b	"vxtarget",0
	even

;--------------------------------------------------------------------
; FrSheets - move the <style> and <link> elements of document a0 to
; element a1 (CssLoad finds them there, in document order; up to 16)
;--------------------------------------------------------------------
FrSheets:
	movem.l	d2/a2-a3/a5,-(sp)
	lea	-16*4(sp),sp		; found first, moved after
	move.l	a1,a3			; a3 = where to
	move.l	a0,a5			; a5 = root
	move.l	a0,a2
	moveq	#0,d2			; d2 = found
.walk:	move.l	n_First(a2),d0
	bne.s	.go
.up:	cmp.l	a5,a2
	beq.s	.mv
	move.l	n_Next(a2),d0
	bne.s	.go
	move.l	n_Parent(a2),a2
	bra.s	.up
.go:	move.l	d0,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.walk
	move.w	n_Tag(a2),d0
	cmp.w	#TAG_STYLE,d0
	beq.s	.f
	cmp.w	#TAG_LINK,d0
	bne.s	.walk
.f:	cmp.l	#16,d2
	bhs.s	.walk
	move.l	a2,(sp,d2.l*4)
	addq.l	#1,d2
	bra.s	.walk
.mv:	move.l	sp,a2			; in document order
.m:	subq.l	#1,d2
	bmi.s	.x
	move.l	(a2)+,a0
	bsr	DomUnlinkPrev
	move.l	a0,a1
	move.l	a3,a0
	jsr	DomAppend
	bra.s	.m
.x:	lea	16*4(sp),sp
	movem.l	(sp)+,d2/a2-a3/a5
	rts

;--------------------------------------------------------------------
; FrMove - move the children of a0 to a1 (but not <head>)
;--------------------------------------------------------------------
FrMove:
	movem.l	a2-a3,-(sp)
	move.l	a1,a3
	move.l	n_First(a0),a2
.l:	move.l	a2,d0
	beq.s	.x
	move.l	n_Next(a2),-(sp)
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.mv
	cmp.w	#TAG_HEAD,n_Tag(a2)
	beq.s	.n
.mv:	move.l	a3,a0
	move.l	a2,a1
	jsr	DomAppend
.n:	move.l	(sp)+,a2
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3
	rts

SBackground:	dc.b	"background",0
SAction:	dc.b	"action",0
SLowSrc:	dc.b	"lowsrc",0
	even

;--------------------------------------------------------------------
; FrFixUrls - the URL attributes (href, src, background, action,
; lowsrc) in document a0 made absolute against a1
;--------------------------------------------------------------------
FrFixUrls:
	movem.l	d2/a2-a3/a5,-(sp)
	move.l	a0,a5			; a5 = root
	move.l	a1,d2			; d2 = base
	move.l	a0,a2
.walk:	move.l	n_First(a2),d0
	bne.s	.go
.up:	cmp.l	a5,a2
	beq.s	.x
	move.l	n_Next(a2),d0
	bne.s	.go
	move.l	n_Parent(a2),a2
	bra.s	.up
.go:	move.l	d0,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.walk
	move.l	n_Data(a2),a3		; its attributes
.at:	move.l	a3,d0
	beq.s	.walk
	move.l	at_Name(a3),a0
	bsr	FrIsUrl
	beq.s	.na
	move.l	at_Value(a3),d0
	beq.s	.na
	move.l	d2,a0
	move.l	d0,a1
	movem.l	a2,-(sp)
	lea	g_FrTmp(a4),a2
	jsr	UrlResolve
	movem.l	(sp)+,a2
	tst.l	d0
	beq.s	.na
	lea	g_FrTmp(a4),a0
	bsr	FrCopy
	beq.s	.na
	move.l	d0,at_Value(a3)
.na:	move.l	at_Next(a3),a3
	bra.s	.at
.x:	movem.l	(sp)+,d2/a2-a3/a5
	rts

; FrIsUrl - is attribute name a0 one with a URL?  Out: d0 = 1 (CCR)
FrIsUrl:
	move.l	a0,-(sp)
	lea	SHref(pc),a1
	bsr.s	FrSame
	bne.s	.y
	move.l	(sp),a0
	lea	SSrc(pc),a1
	bsr.s	FrSame
	bne.s	.y
	move.l	(sp),a0
	lea	SBackground(pc),a1
	bsr.s	FrSame
	bne.s	.y
	move.l	(sp),a0
	lea	SAction(pc),a1
	bsr.s	FrSame
	bne.s	.y
	move.l	(sp),a0
	lea	SLowSrc(pc),a1
	bsr.s	FrSame
.y:	addq.l	#4,sp
	tst.l	d0
	rts

; FrSame - are strings a0 and a1 the same?  Out: d0 = 1 if so (CCR)
FrSame:
.l:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.no
	tst.b	d0
	bne.s	.l
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; FrNoFrames - take the <noframes> elements out of the page
;--------------------------------------------------------------------
FrNoFrames:
.l:	move.l	g_Doc(a4),a0
	move.l	#TAG_NOFRAMES,d0
	bsr	FindTag
	beq.s	.x
	move.l	d0,a0
	bsr	DomUnlinkPrev
	bra.s	.l
.x:	rts

;--------------------------------------------------------------------
; FrameNav - (a link or a form followed: g_LinkUrl) element a0 in a
; frame, targeting a frame: the page again with that frame's document
; replaced (NavGo)
; Out: d0 = 1 if so; 0: an ordinary link (CCR set)
;--------------------------------------------------------------------
FrameNav:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a0,a3			; a3 = its frame
.cell:	move.l	n_Parent(a3),d0
	beq	.no
	move.l	d0,a3
	cmp.b	#DN_ELEMENT,n_Type(a3)
	bne	.no
	cmp.w	#TAG_FRAME,n_Tag(a3)
	bne.s	.cell
	move.l	a3,a0
	lea	SVxFrame(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.cell
	move.l	d0,d3			; d3 = its frame's name
	move.l	a2,a0			; the target: its own, else <base
	lea	STarget(pc),a1		; target>, else its frame
	jsr	DomGetAttr
	tst.l	d0
	bne.s	.t
	move.l	a3,a0
	lea	SVxTarget(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	bne.s	.t
	move.l	d3,d0
.t:	move.l	d0,a0
	cmp.b	#'_',(a0)		; _self: its frame; _top, _parent,
	bne.s	.named			; _blank: the whole page
	lea	SSelf(pc),a1
	bsr	FrSame
	beq	.no
	move.l	d3,d0
.named:	move.l	d0,d2			; d2 = the frame's name
	move.l	g_Doc(a4),a3		; a frame of that name in the page?
.walk:	move.l	n_First(a3),d0
	bne.s	.go
.up:	move.l	n_Next(a3),d0
	bne.s	.go
	move.l	n_Parent(a3),d0
	beq	.no			; (none: the whole page)
	move.l	d0,a3
	bra.s	.up
.go:	move.l	d0,a3
	cmp.b	#DN_ELEMENT,n_Type(a3)
	bne.s	.walk
	cmp.w	#TAG_FRAME,n_Tag(a3)
	bne.s	.walk
	move.l	a3,a0
	lea	SVxFrame(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.walk
	move.l	d0,a0
	move.l	d2,a1
	bsr	FrSame
	beq.s	.walk
	lea	g_PageUrl(a4),a0	; the page's URL, its frames' but that
	lea	g_FrNav(a4),a1		; one, then that one's
	lea	g_FrNav+URL_MAX-2(a4),a3	; (a3 = the end)
.base:	move.b	(a0),d0
	beq	.add
	cmp.b	#FR_SEP,d0
	beq.s	.ent
	move.b	(a0)+,(a1)+
	bra.s	.base
.ent:	addq.l	#1,a0			; an entry: its name the one?
	move.l	a0,-(sp)
	move.l	d2,a2
.cmp:	move.b	(a0)+,d0
	cmp.b	#FR_EQ,d0
	beq.s	.eq
	tst.b	d0
	beq.s	.keep
	cmp.b	(a2)+,d0
	beq.s	.cmp
	bra.s	.keep
.eq:	tst.b	(a2)
	bne.s	.keep
	addq.l	#4,sp			; that one: left out
.skip:	move.b	(a0),d0
	beq.s	.add
	cmp.b	#FR_SEP,d0
	beq.s	.ent0
	addq.l	#1,a0
	bra.s	.skip
.ent0:	bra.s	.base
.keep:	move.l	(sp)+,a0		; another: copied
	move.b	#FR_SEP,(a1)+
.kc:	move.b	(a0),d0
	beq.s	.add
	cmp.b	#FR_SEP,d0
	beq.s	.base
	cmp.l	a3,a1
	bhs.s	.no
	move.b	d0,(a1)+
	addq.l	#1,a0
	bra.s	.kc
.add:	move.b	#FR_SEP,(a1)+		; this one's
	move.l	d2,a0
.an:	cmp.l	a3,a1
	bhs.s	.no
	move.b	(a0)+,(a1)+
	bne.s	.an
	move.b	#FR_EQ,-1(a1)
	lea	g_LinkUrl(a4),a0
.au:	cmp.l	a3,a1
	bhs.s	.no
	move.b	(a0)+,(a1)+
	bne.s	.au
	lea	g_FrNav(a4),a0
	moveq	#1,d0			; (NAV_HISTORY)
	jsr	NavGo
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

SSelf:		dc.b	"_self",0
	even

;--------------------------------------------------------------------
; FrOvFind - the URL g_FrOv has for frame name a0
; Out: d0 = it (a copy in the page) or 0 (CCR set)
;--------------------------------------------------------------------
FrOvFind:
	move.l	a2,-(sp)
	lea	g_FrOv(a4),a1
.e:	cmp.b	#FR_SEP,(a1)+
	bne.s	.no
	move.l	a0,a2
.n:	move.b	(a1)+,d0
	cmp.b	#FR_EQ,d0
	beq.s	.eq
	tst.b	d0
	beq.s	.no
	cmp.b	(a2)+,d0
	beq.s	.n
.sk:	move.b	(a1),d0			; another: on to the next
	beq.s	.no
	cmp.b	#FR_SEP,d0
	beq.s	.e
	addq.l	#1,a1
	bra.s	.sk
.eq:	tst.b	(a2)
	bne.s	.sk
	move.l	a1,a0			; its URL, up to the next entry
	moveq	#0,d1
.len:	move.b	(a1)+,d0
	beq.s	.cp
	cmp.b	#FR_SEP,d0
	beq.s	.cp
	addq.l	#1,d1
	bra.s	.len
.cp:	move.l	d1,d0
	bsr	FrCopyN
	bra.s	.x
.no:	moveq	#0,d0
.x:	move.l	(sp)+,a2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; FrCount - entries in a rows/cols list a0 (or 0): Out: d0 (1 at least)
;--------------------------------------------------------------------
FrCount:
	moveq	#1,d0
	move.l	a0,d1
	beq.s	.x
.l:	move.b	(a0)+,d1
	beq.s	.x
	cmp.b	#',',d1
	bne.s	.l
	addq.l	#1,d0
	bra.s	.l
.x:	rts

;--------------------------------------------------------------------
; FrCopy - string a0 copied into the page (up to a <1>: the page's own
; URL); FrCopyN - d0 bytes of a0
; Out: d0 = the copy or 0 (CCR set)
;--------------------------------------------------------------------
FrCopy:
	move.l	a0,a1
	moveq	#0,d0
.l:	move.b	(a1)+,d1
	beq.s	FrCopyN
	cmp.b	#FR_SEP,d1
	beq.s	FrCopyN
	addq.l	#1,d0
	bra.s	.l
FrCopyN:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	addq.l	#1,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a1
	move.l	a2,a0
	move.l	d2,d1
	bra.s	.e
.c:	move.b	(a0)+,(a1)+
.e:	subq.l	#1,d1
	bpl.s	.c
	clr.b	(a1)
	tst.l	d0
.x:	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; FrAttr - element a0 gets attribute a1 = d1 (both copied into the
; page: page files allow no pointers out of it); FrAttrV - d1 is in
; the page already
; Out: (d1, a0, a1 kept)
;--------------------------------------------------------------------
FrAttr:
	movem.l	d1/a0-a1,-(sp)
	move.l	d1,a0
	bsr	FrCopy
	move.l	d0,d1
	movem.l	(sp),d0/a0-a1		; (d0: the value as given)
	beq.s	.x
	bsr.s	FrAttrV
.x:	movem.l	(sp)+,d1/a0-a1
	rts
FrAttrV:
	movem.l	d1/a0-a1,-(sp)
	move.l	a1,a0			; the name
	bsr	FrCopy
	beq.s	.x
	move.l	d0,a1
	move.l	(sp),d0
	move.l	4(sp),a0
	jsr	DomAddAttr
.x:	movem.l	(sp)+,d1/a0-a1
	rts

; FrJoin - strings a0 and a1 one after the other, in the page
; Out: d0 = it or 0 (CCR set), d1 = its length
FrJoin:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	jsr	StrLen
	move.l	d0,d2
	move.l	a3,a0
	jsr	StrLen
	add.l	d0,d2			; d2 = length
	move.l	d2,d0
	addq.l	#1,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a1
.a:	move.b	(a2)+,(a1)+
	bne.s	.a
	subq.l	#1,a1
.b:	move.b	(a3)+,(a1)+
	bne.s	.b
	move.l	d2,d1
	tst.l	d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

;--------------------------------------------------------------------
; FindTag - the first element d0 (tag) in the tree under a0, in
; document order; Out: d0 = it or 0 (CCR set)
;--------------------------------------------------------------------
FindTag:
	move.l	a2,-(sp)
	move.l	a0,a1			; a1 = root
	move.l	a0,a2
.walk:	move.l	n_First(a2),d1
	bne.s	.go
.up:	cmp.l	a1,a2
	beq.s	.no
	move.l	n_Next(a2),d1
	bne.s	.go
	move.l	n_Parent(a2),a2
	bra.s	.up
.go:	move.l	d1,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.walk
	cmp.w	n_Tag(a2),d0
	bne.s	.walk
	move.l	a2,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	move.l	(sp)+,a2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; DomUnlinkPrev - take node a0 out of its parent's children
; Out: d0 = the sibling that was before it, or 0 (a0 kept)
;--------------------------------------------------------------------
DomUnlinkPrev:
	move.l	n_Parent(a0),d0
	beq.s	.x
	move.l	d0,a1			; a1 = parent
	moveq	#0,d1			; d1 = the one before
	move.l	n_First(a1),d0
.f:	cmp.l	a0,d0
	beq.s	.at
	move.l	d0,d1
	move.l	d0,a1
	move.l	n_Next(a1),d0
	bne.s	.f
	moveq	#0,d0			; (not there)
	rts
.at:	move.l	n_Parent(a0),a1
	tst.l	d1
	bne.s	.mid
	move.l	n_Next(a0),n_First(a1)
	bra.s	.l
.mid:	move.l	d1,a1
	move.l	n_Next(a0),n_Next(a1)
	move.l	n_Parent(a0),a1
.l:	cmp.l	n_Last(a1),a0
	bne.s	.d
	move.l	d1,n_Last(a1)
.d:	clr.l	n_Next(a0)
	clr.l	n_Parent(a0)
	move.l	d1,d0
.x:	rts


;--------------------------------------------------------------------
; FramesPage - Out: d0 = the page's <frameset> (a page of frames), or 0
; (CCR set).  It is not in a <body>: those are not looked into.
;--------------------------------------------------------------------
FramesPage:
	move.l	a2,-(sp)
	move.l	g_Doc(a4),d0
	beq.s	.x
	move.l	d0,a1			; a1 = root
	move.l	d0,a2
.walk:	move.l	n_First(a2),d1
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.t
	cmp.w	#TAG_BODY,n_Tag(a2)
	bne.s	.t
	moveq	#0,d1
.t:	tst.l	d1
	bne.s	.go
.up:	cmp.l	a1,a2
	beq.s	.no
	move.l	n_Next(a2),d1
	bne.s	.go
	move.l	n_Parent(a2),a2
	bra.s	.up
.go:	move.l	d1,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.walk
	cmp.w	#TAG_FRAMESET,n_Tag(a2)
	bne.s	.walk
	move.l	a2,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	move.l	(sp)+,a2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; FramesLayout - (GuiLayout) lay out a page of frames (frameset a0): the
; frames' rectangles in the page area, each frame laid out in its view
; (kept for the same page and frames: their scroll positions stay)
; Out: d0 = 1 done, 0 if the load stopped or the size changed meanwhile
;      (CCR set)
;--------------------------------------------------------------------
FramesLayout:
	movem.l	d2-d4/a2,-(sp)
	move.l	a0,a2
	moveq	#0,d0			; (the page's view in G)
	bsr	ViewSelect
	clr.l	g_FrN(a4)		; the rectangles
	clr.l	g_FrGapN(a4)
	move.l	a2,a0
	move.l	g_PageX(a4),d0
	move.l	g_PageY(a4),d1
	move.l	g_PageW(a4),d2
	move.l	g_PageH(a4),d3
	moveq	#0,d4
	bsr	FrGeom
	move.l	g_FrN(a4),d0
	beq	.none
	move.l	g_Doc(a4),d1		; the views: anew for another page or
	cmp.l	g_FrDoc(a4),d1		; other frames
	bne.s	.new
	cmp.l	g_FrViewN(a4),d0
	beq.s	.have
.new:	move.l	g_FrN(a4),-(sp)
	bsr	FramesFree
	move.l	(sp)+,d0
	move.l	d0,g_FrN(a4)
	mulu.l	#VIEW_SIZE,d0
	move.l	#MEMF_ANY|MEMF_CLEAR,d1
	EXEC	AllocVec
	move.l	d0,g_FrViews(a4)
	beq	.none
	move.l	g_FrN(a4),g_FrViewN(a4)
	move.l	g_Doc(a4),g_FrDoc(a4)
	moveq	#1,d2			; each: the page's colours, no focus
.init:	cmp.l	g_FrN(a4),d2
	bhi.s	.act
	move.l	d2,d0
	bsr	ViewSlot
	move.l	g_PageFg(a4),g_PageFg-g_View(a0)
	move.l	g_LinkColor(a4),g_LinkColor-g_View(a0)
	moveq	#-1,d0
	move.l	d0,g_FocusIdx-g_View(a0)
	addq.l	#1,d2
	bra.s	.init
.act:	bsr	FrLargest		; the largest: the active one
	move.l	d0,g_FrActive(a4)
.have:	moveq	#1,d2			; the rectangles into the views
.rc:	cmp.l	g_FrN(a4),d2
	bhi.s	.lay
	move.l	d2,d0
	bsr	ViewSlot
	lea	g_FrRect-16(a4),a1
	move.l	d2,d0
	lsl.l	#4,d0
	add.l	d0,a1
	move.l	(a1)+,g_PageX-g_View(a0)
	move.l	(a1)+,g_PageY-g_View(a0)
	move.l	(a1)+,g_PageW-g_View(a0)
	move.l	(a1)+,g_PageH-g_View(a0)
	clr.l	g_BandsOk-g_View(a0)
	addq.l	#1,d2
	bra.s	.rc
.lay:	lea	LogFrames(pc),a0	; (for tests: "frames N")
	suba.l	a1,a1
	move.l	g_FrN(a4),d0
	jsr	LogEvent
	moveq	#1,d2			; each frame laid out in its view
.l:	cmp.l	g_FrN(a4),d2
	bhi.s	.done
	move.l	d2,g_LayTarget(a4)
	lea	g_FrNode-4(a4),a0
	move.l	(a0,d2.l*4),g_LayRoot(a4)
	move.l	d2,d0
	bsr	ViewSlot
	move.l	g_PageW-g_View(a0),d0
	jsr	LayoutDocument
	beq.s	.stop
	move.l	d2,d0			; (its scroll position: within it)
	bsr	ViewSlot
	move.l	g_DocHeight-g_View(a0),d0
	sub.l	g_PageH-g_View(a0),d0
	bpl.s	.cl
	moveq	#0,d0
.cl:	cmp.l	g_ScrollY-g_View(a0),d0
	bge.s	.sc
	move.l	d0,g_ScrollY-g_View(a0)
.sc:	addq.l	#1,d2
	bra.s	.l
.done:	clr.l	g_LayTarget(a4)
	clr.l	g_LayRoot(a4)
	move.l	g_PageW(a4),g_LayWidth(a4)	; the page's own view: the
	clr.l	g_DocHeight(a4)			; frames only
	clr.l	g_ScrollY(a4)
	moveq	#1,d0
	move.l	d0,g_ViewLive(a4)
	clr.l	g_Blank(a4)
	bra.s	.x
.stop:	clr.l	g_LayTarget(a4)
	clr.l	g_LayRoot(a4)
	moveq	#0,d0
	bra.s	.x
.none:	bsr	FramesFree		; no frame to show: the page as it is
	move.l	g_PageW(a4),d0
	jsr	LayoutDocument
.x:	movem.l	(sp)+,d2-d4/a2
	tst.l	d0
	rts

LogFrames:	dc.b	"frames",0
	even

; FrLargest - Out: d0 = the frame with the largest area (1..)
FrLargest:
	movem.l	d2-d4,-(sp)
	lea	g_FrRect(a4),a0
	moveq	#1,d0
	moveq	#0,d3			; d3 = its area
	moveq	#1,d2
.l:	cmp.l	g_FrN(a4),d2
	bhi.s	.x
	move.l	8(a0),d4
	mulu.l	12(a0),d4
	cmp.l	d3,d4
	bls.s	.n
	move.l	d4,d3
	move.l	d2,d0
.n:	lea	16(a0),a0
	addq.l	#1,d2
	bra.s	.l
.x:	movem.l	(sp)+,d2-d4
	rts

;--------------------------------------------------------------------
; FrGeom - the frames of frameset a0 in rectangle d0/d1 (x, y), d2/d3
; (width, height): each frame shown into g_FrNode/g_FrRect (g_FrN), the
; borders between them into g_FrGap (g_FrGapN); framesets in it (or in
; a frame) the same
; In: d4 = how deep
;--------------------------------------------------------------------
FG_ROWS		equ	-64		; locals (a5): row heights,
FG_COLS		equ	-128		; ... column widths,
FG_R		equ	-132		; ... rows,
FG_C		equ	-136		; ... columns,
FG_IR		equ	-140		; ... the row,
FG_IC		equ	-144		; ... the column,
FG_CX		equ	-148		; ... where the cell is,
FG_CY		equ	-152
FG_X0		equ	-156		; ... the rectangle
FG_Y0		equ	-160
FG_W		equ	-164
FG_H		equ	-168
FG_D		equ	-172		; ... how deep
FG_SIZE		equ	176

FrGeom:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	link	a5,#-FG_SIZE
	move.l	a0,a2			; a2 = the frameset
	move.l	d0,FG_X0(a5)
	move.l	d1,FG_Y0(a5)
	move.l	d2,FG_W(a5)
	move.l	d3,FG_H(a5)
	move.l	d4,FG_D(a5)
	move.l	a2,a0			; heights of the rows,
	lea	SRows(pc),a1
	jsr	DomGetAttr
	move.l	d0,a0
	move.l	FG_H(a5),d0
	lea	FG_ROWS(a5),a1
	bsr	FrSizes
	move.l	d0,FG_R(a5)
	move.l	a2,a0			; widths of the columns
	lea	SCols(pc),a1
	jsr	DomGetAttr
	move.l	d0,a0
	move.l	FG_W(a5),d0
	lea	FG_COLS(a5),a1
	bsr	FrSizes
	move.l	d0,FG_C(a5)
	move.l	FG_X0(a5),d6		; the borders between the columns
	moveq	#1,d2
.gc:	cmp.l	FG_C(a5),d2
	bhs.s	.gr
	lea	FG_COLS(a5),a0
	add.l	-4(a0,d2.l*4),d6
	move.l	d6,d0
	move.l	FG_Y0(a5),d1
	moveq	#FR_BORDER,d3
	move.l	FG_H(a5),d4
	bsr	FrGap
	addq.l	#FR_BORDER,d6
	addq.l	#1,d2
	bra.s	.gc
.gr:	move.l	FG_Y0(a5),d7		; ... and the rows
	moveq	#1,d2
.gr1:	cmp.l	FG_R(a5),d2
	bhs.s	.cells
	lea	FG_ROWS(a5),a0
	add.l	-4(a0,d2.l*4),d7
	move.l	FG_X0(a5),d0
	move.l	d7,d1
	move.l	FG_W(a5),d3
	moveq	#FR_BORDER,d4
	bsr	FrGap
	addq.l	#FR_BORDER,d7
	addq.l	#1,d2
	bra.s	.gr1
.cells:	clr.l	FG_IR(a5)		; the frames, row after row
	clr.l	FG_IC(a5)
	move.l	FG_X0(a5),FG_CX(a5)
	move.l	FG_Y0(a5),FG_CY(a5)
	move.l	n_First(a2),a3
.ch:	move.l	a3,d0
	beq	.done
	move.l	d0,a0
	move.l	n_Next(a0),a3
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.ch
	cmp.w	#TAG_FRAME,n_Tag(a0)
	beq.s	.one
	cmp.w	#TAG_FRAMESET,n_Tag(a0)
	bne.s	.ch
.one:	move.l	FG_IR(a5),d0
	cmp.l	FG_R(a5),d0
	bhs	.done			; (more than rows x columns)
	lea	FG_ROWS(a5),a1
	move.l	(a1,d0.l*4),d3		; its height,
	move.l	FG_IC(a5),d1
	lea	FG_COLS(a5),a1
	move.l	(a1,d1.l*4),d2		; its width (within the rectangle)
	move.l	FG_X0(a5),d0
	add.l	FG_W(a5),d0
	sub.l	FG_CX(a5),d0
	cmp.l	d0,d2
	ble.s	.wok
	move.l	d0,d2
.wok:	move.l	FG_Y0(a5),d0
	add.l	FG_H(a5),d0
	sub.l	FG_CY(a5),d0
	cmp.l	d0,d3
	ble.s	.hok
	move.l	d0,d3
.hok:	tst.l	d2			; (size 0: hidden)
	ble.s	.next
	tst.l	d3
	ble.s	.next
	move.l	FG_CX(a5),d0
	move.l	FG_CY(a5),d1
	move.l	FG_D(a5),d4
	bsr	FrPlace
.next:	lea	FG_COLS(a5),a1		; on to the next cell
	move.l	FG_IC(a5),d1
	move.l	(a1,d1.l*4),d0
	addq.l	#FR_BORDER,d0
	add.l	d0,FG_CX(a5)
	addq.l	#1,d1
	move.l	d1,FG_IC(a5)
	cmp.l	FG_C(a5),d1
	blo	.ch
	clr.l	FG_IC(a5)		; the next row
	move.l	FG_X0(a5),FG_CX(a5)
	lea	FG_ROWS(a5),a1
	move.l	FG_IR(a5),d1
	move.l	(a1,d1.l*4),d0
	addq.l	#FR_BORDER,d0
	add.l	d0,FG_CY(a5)
	addq.l	#1,FG_IR(a5)
	bra	.ch
.done:	unlk	a5
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; FrPlace - (FrGeom) frame or frameset a0 in rectangle d0-d3, d4 = how
; deep: a frameset (or a frame with one: its document's) cut further,
; a frame noted (d0-d4 changed)
FrPlace:
	cmp.w	#TAG_FRAMESET,n_Tag(a0)
	beq.s	.set
	move.l	n_First(a0),d4		; a frame: a frameset in it?
.f:	beq.s	.leaf
	move.l	d4,a1
	cmp.b	#DN_ELEMENT,n_Type(a1)
	bne.s	.fn
	cmp.w	#TAG_FRAMESET,n_Tag(a1)
	bne.s	.fn
	move.l	a1,a0
	move.l	FG_D(a5),d4
	bra.s	.set
.fn:	move.l	n_Next(a1),d4
	bra.s	.f
.set:	cmp.l	#FR_DEPTH,d4
	bhs.s	.x
	addq.l	#1,d4
	bra	FrGeom
.leaf:	move.l	g_FrN(a4),d4
	cmp.l	#FR_MAX,d4
	bhs.s	.x
	lea	g_FrNode(a4),a1
	move.l	a0,(a1,d4.l*4)
	lsl.l	#4,d4
	lea	g_FrRect(a4),a1
	add.l	d4,a1
	movem.l	d0-d3,(a1)
	addq.l	#1,g_FrN(a4)
.x:	rts

; FrGap - (FrGeom) a border at d0/d1 (x, y), d3/d4 (width, height)
; (d0-d4 kept)
FrGap:
	move.l	g_FrGapN(a4),a0
	cmp.l	#FR_GAPS,a0
	bhs.s	.x
	addq.l	#1,g_FrGapN(a4)
	add.l	a0,a0			; (16 bytes each)
	add.l	a0,a0
	add.l	a0,a0
	add.l	a0,a0
	lea	g_FrGap(a4),a1
	add.l	a1,a0
	move.l	d0,(a0)+
	move.l	d1,(a0)+
	move.l	d3,(a0)+
	move.l	d4,(a0)
.x:	rts

;--------------------------------------------------------------------
; FrSizes - the sizes of the rows or columns of list a0 ("100,30%,*",
; or 0: one) in d0 pixels, into a1 (FR_MAX longs): pixels, percent of
; what is left without the borders, the rest shared by the "*" ones by
; their weights ("2*"), or else given to the last one
; Out: d0 = how many
;--------------------------------------------------------------------
FrSizes:
	movem.l	d2-d7/a2,-(sp)
	lea	-FR_MAX*4(sp),sp	; (sp) = the weights of the "*" ones
	move.l	a1,a2			; a2 = out
	move.l	d0,d7			; d7 = room
	move.l	a0,-(sp)
	bsr	FrCount
	move.l	(sp)+,a0
	cmp.l	#FR_MAX,d0
	bls.s	.c
	moveq	#FR_MAX,d0
.c:	move.l	d0,d6			; d6 = how many
	move.l	d6,d1
	subq.l	#1,d1
	mulu.l	#FR_BORDER,d1
	sub.l	d1,d7			; (the borders between them)
	bpl.s	.r
	moveq	#0,d7
.r:	moveq	#0,d5			; d5 = taken
	moveq	#0,d4			; d4 = the weights
	moveq	#0,d3			; d3 = entry
.e:	cmp.l	d6,d3
	bhs	.rest
	moveq	#0,d1			; its number,
	moveq	#0,d2			; ... digits
	move.l	a0,d0
	beq.s	.st			; (no list: "*")
.sp:	cmp.b	#' ',(a0)
	bne.s	.dg
	addq.l	#1,a0
	bra.s	.sp
.dg:	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.nd
	mulu.l	#10,d1
	add.l	d0,d1
	addq.l	#1,d2
	addq.l	#1,a0
	bra.s	.dg
.nd:	move.b	(a0),d0
	cmp.b	#'%',d0
	beq.s	.pc
	cmp.b	#'*',d0
	beq.s	.st
	tst.l	d2			; (nothing: "*")
	beq.s	.st
	bra.s	.px
.pc:	mulu.l	d7,d1			; percent
	divu.l	#100,d1
.px:	move.l	d1,(a2,d3.l*4)		; pixels
	add.l	d1,d5
	clr.l	(sp,d3.l*4)
	bra.s	.skip
.st:	tst.l	d2			; "*" = "1*"
	bne.s	.w
	moveq	#1,d1
.w:	clr.l	(a2,d3.l*4)
	move.l	d1,(sp,d3.l*4)
	add.l	d1,d4
.skip:	move.l	a0,d0			; to the next entry
	beq.s	.ne
.sk:	move.b	(a0)+,d0
	beq.s	.end
	cmp.b	#',',d0
	bne.s	.sk
	bra.s	.ne
.end:	subq.l	#1,a0
.ne:	addq.l	#1,d3
	bra	.e
.rest:	move.l	d7,d1			; d1 = what is left
	sub.l	d5,d1
	bpl.s	.pos
	moveq	#0,d1
.pos:	tst.l	d4
	beq.s	.nost
	moveq	#0,d3
.s:	cmp.l	d6,d3
	bhs.s	.x
	move.l	(sp,d3.l*4),d0
	beq.s	.sn
	mulu.l	d1,d0
	divu.l	d4,d0
	move.l	d0,(a2,d3.l*4)
.sn:	addq.l	#1,d3
	bra.s	.s
.nost:	move.l	d6,d3			; no "*": the last one gets it
	subq.l	#1,d3
	add.l	d1,(a2,d3.l*4)
.x:	move.l	d6,d0
	lea	FR_MAX*4(sp),sp
	movem.l	(sp)+,d2-d7/a2
	rts

;--------------------------------------------------------------------
; FramesFree - the frames' views go (their runs too): the page left, or
; other frames (laid out again when shown: g_LayWidth 0)
;--------------------------------------------------------------------
FramesFree:
	tst.l	g_FrViews(a4)
	beq.s	.x
	move.l	d2,-(sp)
	moveq	#0,d0
	bsr	ViewSelect
	move.l	g_FrViewN(a4),d2
.f:	tst.l	d2
	beq.s	.v
	move.l	d2,d0
	bsr	ViewSlot
	move.l	a0,-(sp)
	lea	g_Runs-g_View(a0),a0
	jsr	BufFree
	move.l	(sp)+,a0
	lea	g_Anchors-g_View(a0),a0
	jsr	BufFree
	subq.l	#1,d2
	bra.s	.f
.v:	move.l	g_FrViews(a4),a1
	clr.l	g_FrViews(a4)
	EXEC	FreeVec
	clr.l	g_FrViewN(a4)
	clr.l	g_FrN(a4)
	clr.l	g_FrDoc(a4)
	clr.l	g_FrActive(a4)
	clr.l	g_FrHover(a4)
	clr.l	g_LayWidth(a4)
	move.l	(sp)+,d2
.x:	rts

;--------------------------------------------------------------------
; ViewSlot - where view d0 is kept while not in G: 0 the page's own
; (g_ViewTop), 1.. the frames' (g_FrViews)
; Out: a0 (d1 kept) (a1 kept)
;--------------------------------------------------------------------
ViewSlot:
	tst.l	d0
	bne.s	.f
	lea	g_ViewTop(a4),a0
	rts
.f:	subq.l	#1,d0
	mulu.l	#VIEW_SIZE,d0
	move.l	g_FrViews(a4),a0
	add.l	d0,a0
	rts

;--------------------------------------------------------------------
; ViewSelect - put view d0 (0: the page's own, 1..: a frame's) in G,
; the one there back to its place.  Painting, scrolling, finding and
; pointing at links then work on it.
;--------------------------------------------------------------------
ViewSelect:
	cmp.l	g_ViewCur(a4),d0
	beq.s	.x
	tst.l	d0
	beq.s	.ok
	tst.l	g_FrViews(a4)		; (no such frame: nothing)
	beq.s	.x
	cmp.l	g_FrViewN(a4),d0
	bhi.s	.x
.ok:	move.l	d0,-(sp)
	move.l	g_ViewCur(a4),d0	; G's to its place
	bsr.s	ViewSlot
	move.l	a0,a1
	lea	g_View(a4),a0
	move.l	#VIEW_SIZE/4-1,d1
.o:	move.l	(a0)+,(a1)+
	dbf	d1,.o
	move.l	(sp),d0			; the other into G
	bsr.s	ViewSlot
	lea	g_View(a4),a1
	move.l	#VIEW_SIZE/4-1,d1
.i:	move.l	(a0)+,(a1)+
	dbf	d1,.i
	move.l	(sp)+,g_ViewCur(a4)
.x:	rts

;--------------------------------------------------------------------
; FrameAt - the frame at window position d0/d1
; Out: d0 = it (1..), 0 if none (CCR set)
;--------------------------------------------------------------------
FrameAt:
	movem.l	d2-d3,-(sp)
	lea	g_FrRect(a4),a0
	moveq	#1,d2
.l:	cmp.l	g_FrN(a4),d2
	bhi.s	.no
	move.l	d0,d3
	sub.l	(a0),d3
	bmi.s	.n
	cmp.l	8(a0),d3
	bhs.s	.n
	move.l	d1,d3
	sub.l	4(a0),d3
	bmi.s	.n
	cmp.l	12(a0),d3
	bhs.s	.n
	move.l	d2,d0
	bra.s	.x
.n:	lea	16(a0),a0
	addq.l	#1,d2
	bra.s	.l
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3
	tst.l	d0
	rts
