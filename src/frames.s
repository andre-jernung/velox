;
; frames.s - framesets: the frames' documents in one page
;
; A page that is a <frameset> becomes a table of its frames (columns
; and rows as its cols and rows say): each frame's document is fetched
; (through the caches), parsed into the page and put in the frame's
; cell, its relative URLs made absolute (they are the frame document's,
; not the page's).  The page scrolls as a whole.
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
	xref	HttpGetCached,HtmlParse,CharsetDetect,DecodeCharset,BufFree
	xref	PageAlloc,DomNewNode,DomAppend,DomAddAttr,DomGetAttr
	xref	UrlResolve,StrIPrefix,StrLen,LogEvent,GuiStatus,NavGo

FR_DEPTH	equ	4		; framesets in frames, at most
FR_MAX		equ	16		; frames in a page, at most
FR_SEP		equ	1		; "<1>name<2>url" after the page's URL
FR_EQ		equ	2

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
; FramesCompose - (loader: PageFixups) a page that is a <frameset>
; becomes the table of its frames' documents, and g_PageUrl gets the
; frames' URLs (g_FrOv) after it.  The response, the disk cache entry
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
	bsr	FrameSet
	beq.s	.rest
	move.l	d0,a3			; a3 = its table
	move.l	n_Parent(a2),a0
	cmp.w	#TAG_BODY,n_Tag(a0)	; in place of the frameset, in a
	beq.s	.inb			; body without margins
	moveq	#DN_ELEMENT,d0
	move.l	#TAG_BODY,d1
	jsr	DomNewNode
	beq.s	.rest
	move.l	d0,a1
	move.l	a2,a0
	move.l	a1,-(sp)
	bsr	DomReplace
	move.l	(sp),a0
	move.l	a3,a1
	jsr	DomAppend
	move.l	(sp)+,a0
	bra.s	.marg
.inb:	move.l	a0,-(sp)
	move.l	a2,a0
	move.l	a3,a1
	bsr	DomReplace
	move.l	(sp)+,a0
.marg:	lea	SStyle(pc),a1
	lea	SNoMargin(pc),a2
	move.l	a2,d1
	bsr	FrAttr
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
; FrameSet - the table of frameset a0 (its frame URLs relative to a1)
; In:  d0 = how deep (framesets in frames)
; Out: d0 = the table, or 0 (CCR set)
;--------------------------------------------------------------------
FrameSet:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2			; a2 = the frameset
	move.l	a1,d7			; d7 = base URL
	move.l	d0,d6			; d6 = depth
	lea	SRows(pc),a1		; d4 = rows, d5 = columns
	jsr	DomGetAttr
	move.l	d0,a0
	bsr	FrCount
	move.l	d0,d4
	move.l	a2,a0
	lea	SCols(pc),a1
	jsr	DomGetAttr
	move.l	d0,a0
	bsr	FrCount
	move.l	d0,d5
	moveq	#DN_ELEMENT,d0
	move.l	#TAG_TABLE,d1
	jsr	DomNewNode
	beq	.x
	move.l	d0,a5			; a5 = the table
	move.l	a5,a0
	lea	SWidth(pc),a1
	lea	S100(pc),a3
	move.l	a3,d1
	bsr	FrAttr
	lea	S0(pc),a3
	move.l	a3,d1
	lea	SCellSp(pc),a1
	bsr	FrAttr
	lea	SBorder(pc),a1
	bsr	FrAttr
	lea	S4(pc),a1		; (frames have a margin)
	move.l	a1,d1
	lea	SCellPad(pc),a1
	bsr	FrAttr
	lea	SVxFixed(pc),a1		; (its columns as wide as they say:
	bsr	FrAttr			;  table.s FixedWidths)
	move.l	n_First(a2),a3		; a3 = the next child
	moveq	#0,d2			; d2 = row
.row:	cmp.l	d4,d2
	bhs	.done
	move.l	a2,a0			; a row of height 0 (hidden frames):
	lea	SRows(pc),a1		; its frames left out
	jsr	DomGetAttr
	move.l	d0,a0
	move.l	d2,d0
	bsr	FrZero
	beq.s	.shown
	move.l	d5,d3
.hid:	subq.l	#1,d3
	bmi.s	.hidd
	move.l	a3,a0
	bsr	FrNext
	move.l	a0,a3
	tst.l	d0
	bne.s	.hid
.hidd:	addq.l	#1,d2
	bra.s	.row
.shown:	moveq	#DN_ELEMENT,d0
	move.l	#TAG_TR,d1
	jsr	DomNewNode
	beq	.done
	move.l	d0,-(sp)		; (sp) = the row
	move.l	a5,a0
	move.l	d0,a1
	jsr	DomAppend
	moveq	#0,d3			; d3 = column
.col:	cmp.l	d5,d3
	bhs	.rowd
	move.l	a3,a0			; the next frame or frameset
	bsr	FrNext
	move.l	a0,a3
	tst.l	d0
	beq	.rowd
	move.l	d0,-(sp)
	move.l	a2,a0			; a column of width 0: left out
	lea	SCols(pc),a1
	jsr	DomGetAttr
	move.l	d0,a0
	move.l	d3,d0
	bsr	FrZero
	movem.l	(sp)+,a0
	beq.s	.cell
	addq.l	#1,d3
	bra.s	.col
.cell:	move.l	a0,-(sp)		; 4(sp) = the frame, (sp) = the cell
	moveq	#DN_ELEMENT,d0
	move.l	#TAG_TD,d1
	jsr	DomNewNode
	move.l	d0,-(sp)
	beq	.cellx
	move.l	d0,a0
	lea	SVAlign(pc),a1
	lea	SVTop(pc),a0
	move.l	a0,d1
	move.l	(sp),a0
	bsr	FrAttr
	cmp.l	#1,d5			; its width: the column's
	bls.s	.nw
	move.l	a2,a0
	lea	SCols(pc),a1
	jsr	DomGetAttr
	move.l	d0,a0
	move.l	d3,d0
	bsr	FrEntry
	beq.s	.nw
	move.l	d0,d1
	move.l	(sp),a0
	lea	SWidth(pc),a1
	bsr	FrAttrV
.nw:	move.l	4(sp),a0		; what goes in it
	move.l	(sp),a1
	cmp.w	#TAG_FRAMESET,n_Tag(a0)
	beq.s	.sub
	move.l	d7,d0
	move.l	d6,d1
	bsr	FrameFill
	bra.s	.put
.sub:	cmp.l	#FR_DEPTH,d6		; a frameset in it: its table
	bhs.s	.put
	move.l	d7,a1
	move.l	d6,d0
	addq.l	#1,d0
	bsr	FrameSet
	beq.s	.put
	move.l	d0,a1
	move.l	(sp),a0
	jsr	DomAppend
.put:	move.l	8(sp),a0		; the cell into the row
	move.l	(sp),a1
	jsr	DomAppend
.cellx:	addq.l	#8,sp
	tst.l	g_TkAbort(a4)		; (stopped: no more)
	bne.s	.rowd
	addq.l	#1,d3
	bra	.col
.rowd:	addq.l	#4,sp
	tst.l	g_TkAbort(a4)
	bne.s	.done
	addq.l	#1,d2
	bra	.row
.done:	move.l	a5,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	tst.l	d0
	rts

;--------------------------------------------------------------------
; FrameFill - give cell a1 the document of frame a0 (its src relative
; to d0, or the URL g_FrOv has for its name; d1 = how deep, for a
; frameset in it): its body's content, and
; its style sheets; relative URLs in it made absolute.  The cell notes
; the frame's name and its document's <base target> (FrameNav).  A
; frame that cannot be shown gets a link to its document.
;--------------------------------------------------------------------
FrameFill:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2			; a2 = the frame
	move.l	a1,a5			; a5 = the cell
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
	move.l	a5,a0
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
	lea	g_FrTmp(a4),a2
	jsr	UrlResolve
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
	lea	g_FrTmp(a4),a2
	jsr	UrlResolve
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
	move.l	a5,a0
	lea	SVxTarget(pc),a1
	bsr	FrAttrV
.nbt:	move.l	d2,a0			; a frameset in it: that, in the cell
	move.l	#TAG_FRAMESET,d0
	bsr	FindTag
	beq.s	.body
	cmp.l	#FR_DEPTH,4(sp)
	bhs.s	.body
	move.l	d0,a0
	move.l	d6,a1
	move.l	4(sp),d0
	addq.l	#1,d0
	bsr	FrameSet
	beq	.free
	move.l	d0,a1
	move.l	a5,a0
	jsr	DomAppend
	bra	.free
.body:	move.l	d2,a0			; its style sheets
	move.l	a5,a1
	bsr	FrSheets
	move.l	d2,a0			; its body's content (or all of it)
	move.l	#TAG_BODY,d0
	bsr	FindTag
	beq.s	.nob
	move.l	d0,a3
	move.l	a3,a0			; the body's colours: the cell's
	move.l	a5,a1
	bsr	FrBodyAttrs
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
.link:	moveq	#DN_ELEMENT,d0		; a link "Frame: name" to it
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
SWidth:		dc.b	"width",0
SCellSp:	dc.b	"cellspacing",0
SCellPad:	dc.b	"cellpadding",0
SBorder:	dc.b	"border",0
SVAlign:	dc.b	"valign",0
SStyle:		dc.b	"style",0
SVxFrame:	dc.b	"vxframe",0
SVxFixed:	dc.b	"vxfixed",0
SVxTarget:	dc.b	"vxtarget",0
S100:		dc.b	"100%",0
S0:		dc.b	"0",0
S4:		dc.b	"4",0
SVTop:		dc.b	"top",0
SNoMargin:	dc.b	"margin:0",0
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

;--------------------------------------------------------------------
; FrBodyAttrs - (FrameFill) the colours of body a0 for cell a1:
; bgcolor, background and link as they are, text as a style
;--------------------------------------------------------------------
FrBodyAttrs:
	movem.l	a2-a3/a5,-(sp)
	move.l	a1,a5
	move.l	n_Data(a0),a3		; its attributes
.l:	move.l	a3,d0
	beq.s	.x
	move.l	at_Name(a3),a0
	lea	SBgColor(pc),a1
	bsr	FrSame
	bne.s	.add
	move.l	at_Name(a3),a0
	lea	SBackground(pc),a1
	bsr	FrSame
	bne.s	.add
	move.l	at_Name(a3),a0
	lea	SLink(pc),a1
	bsr	FrSame
	bne.s	.add
	move.l	at_Name(a3),a0
	lea	SText(pc),a1
	bsr	FrSame
	beq.s	.n
	move.l	at_Value(a3),a0		; text="#rrggbb": style="color:..."
	jsr	StrLen
	addq.l	#SColorE-SColor+1,d0
	jsr	PageAlloc
	beq.s	.n
	move.l	d0,a2
	move.l	d0,a1
	lea	SColor(pc),a0
.c1:	move.b	(a0)+,(a1)+
	bne.s	.c1
	subq.l	#1,a1
	move.l	at_Value(a3),a0
.c2:	move.b	(a0)+,(a1)+
	bne.s	.c2
	move.l	a2,d1
	move.l	a5,a0
	lea	SStyle(pc),a1
	bsr	FrAttrV
	bra.s	.n
.add:	move.l	a5,a0			; (the same name and value)
	move.l	at_Name(a3),a1
	move.l	at_Value(a3),d0
	jsr	DomAddAttr
.n:	move.l	at_Next(a3),a3
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3/a5
	rts

SBgColor:	dc.b	"bgcolor",0
SBackground:	dc.b	"background",0
SText:		dc.b	"text",0
SLink:		dc.b	"link",0
SColor:		dc.b	"color:",0
SColorE		equ	*-1
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
	move.l	a0,a3			; a3 = its frame's cell
.cell:	move.l	n_Parent(a3),d0
	beq	.no
	move.l	d0,a3
	cmp.b	#DN_ELEMENT,n_Type(a3)
	bne	.no
	cmp.w	#TAG_TD,n_Tag(a3)
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
	cmp.w	#TAG_TD,n_Tag(a3)
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

; FrNext - the next <frame> or <frameset> from node a0 on
; Out: d0 = it or 0 (CCR set), a0 = the node after it
FrNext:
.l:	move.l	a0,d0
	beq.s	.x
	move.l	n_Next(a0),a0
	move.l	d0,a1
	cmp.b	#DN_ELEMENT,n_Type(a1)
	bne.s	.l
	cmp.w	#TAG_FRAME,n_Tag(a1)
	beq.s	.x
	cmp.w	#TAG_FRAMESET,n_Tag(a1)
	bne.s	.l
.x:	tst.l	d0
	rts

; FrZero - is entry d0 of rows/cols list a0 (or 0) "0" (a hidden
; frame)?  Out: d0 = 1 if so (CCR set)
FrZero:
	move.l	a0,d1
	beq.s	.no
.sk:	tst.l	d0
	beq.s	.at
.f:	move.b	(a0)+,d1
	beq.s	.no
	cmp.b	#',',d1
	bne.s	.f
	subq.l	#1,d0
	bra.s	.sk
.at:	move.b	(a0)+,d1
	cmp.b	#' ',d1
	beq.s	.at
	cmp.b	#'0',d1
	bne.s	.no
	move.b	(a0),d1			; (not "05")
	sub.b	#'0',d1
	cmp.b	#9,d1
	bls.s	.no
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; FrCount - entries in a rows/cols list a0 (or 0): Out: d0 (1 at least)
; FrEntry - entry d0 of list a0 as a width ("200", "30%"; a copy in
; the page), 0 for "*" and the like (CCR set)
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

FrEntry:
	move.l	a0,d1
	beq.s	.no
.sk:	tst.l	d0			; to entry d0
	beq.s	.at
.f:	move.b	(a0)+,d1
	beq.s	.no
	cmp.b	#',',d1
	bne.s	.f
	subq.l	#1,d0
	bra.s	.sk
.at:	cmp.b	#' ',(a0)		; (blanks before it)
	bne.s	.ws
	addq.l	#1,a0
	bra.s	.at
.ws:	move.l	a0,a1			; digits, then maybe '%'
	moveq	#0,d0
.d:	move.b	(a1),d1
	sub.b	#'0',d1
	cmp.b	#9,d1
	bhi.s	.nd
	addq.l	#1,a1
	addq.l	#1,d0
	bra.s	.d
.nd:	tst.l	d0
	beq.s	.no
	cmp.b	#'*',(a1)		; "2*": relative
	beq.s	.no
	cmp.b	#'%',(a1)
	bne.s	FrCopyN
	addq.l	#1,d0
	bra.s	FrCopyN
.no:	moveq	#0,d0
	rts

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
; DomReplace - node a1 in the place of node a0 (which goes)
;--------------------------------------------------------------------
DomReplace:
	movem.l	a2-a3,-(sp)
	move.l	n_Parent(a0),d0
	beq.s	.x
	move.l	d0,a2			; a2 = parent
	move.l	a2,n_Parent(a1)
	move.l	n_Next(a0),n_Next(a1)
	move.l	n_First(a2),a3
	cmp.l	a0,a3
	bne.s	.f
	move.l	a1,n_First(a2)
	bra.s	.last
.f:	move.l	n_Next(a3),d0		; the one before it
	beq.s	.last
	cmp.l	a0,d0
	beq.s	.at
	move.l	d0,a3
	bra.s	.f
.at:	move.l	a1,n_Next(a3)
.last:	cmp.l	n_Last(a2),a0
	bne.s	.x
	move.l	a1,n_Last(a2)
.x:	movem.l	(sp)+,a2-a3
	rts
