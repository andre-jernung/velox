;
; layout.s - turn the DOM into a display list (g_Runs)
;
; Block layout with collapsing vertical margins, inline layout with word
; wrapping, list markers, rules, line breaks and image placeholders.
; Tables are in table.s.  Layout can be rerun at any time (new width,
; images loaded, DOM changed): it only reads the DOM.
;
; Coordinates are document pixels; y grows down from 0.  Text width is
; measured through g_MeasureFn, so the same code is tested headless.
;

	include	"velox.i"

	xdef	LayoutDocument,LayoutChildren,LayoutNode,LayoutBlockContent
	xdef	FlushLine,LineReset,AddMargin,AddRun,RunCount,RunPtr,Measure
	xdef	ApplyPendingMargin,IntAttr,ClearFloats
	xref	StyleRoot,StyleCompute,BufClear,BufReserve,PageAlloc,FmtDec
	xref	DomGetAttr,ParseDec,LayoutTable,CssApply
	xref	FormIsControl,FormControlSize,CssInvalidate

	IFNE	RUN_SIZEOF-32
	FAIL	"RunCount/RunPtr assume RUN_SIZEOF = 32"
	ENDC

PAGE_MARGIN	equ	8
MIN_WIDTH	equ	16
MAX_LAYDEPTH	equ	200

	section	code,code

;--------------------------------------------------------------------
; LayoutDocument - lay out g_Doc
; In:  d0 = width in pixels
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
LayoutDocument:
	movem.l	d2/a2,-(sp)
	move.l	d0,g_LayWidth(a4)
	clr.l	g_ViewLive(a4)		; the runs change
	clr.l	g_PageBgRec(a4)		; (the page background image: <body>)
	clr.l	g_FindRun(a4)
	clr.l	g_SelShown(a4)
	clr.l	g_SelOn(a4)
	tst.l	g_CssHasMq(a4)		; media queries: matches depend on
	beq.s	.nomq			; the width
	cmp.l	g_CssCacheW(a4),d0
	beq.s	.nomq
	move.l	d0,g_CssCacheW(a4)
	jsr	CssInvalidate
.nomq:
	lea	g_Runs(a4),a0
	jsr	BufClear
	clr.l	g_LayY(a4)
	clr.l	g_PendMargin(a4)
	clr.l	g_DocHeight(a4)
	clr.l	g_LayAlign(a4)
	clr.l	g_LayWhite(a4)
	clr.l	g_Marker(a4)
	clr.l	g_LayDepth(a4)
	clr.l	g_FlLBot(a4)
	clr.l	g_FlRBot(a4)
	moveq	#1,d0
	move.l	d0,g_ListNum(a4)
	moveq	#PAGE_MARGIN,d0
	move.l	d0,g_LayLeft(a4)
	move.l	g_LayWidth(a4),d0
	sub.l	#PAGE_MARGIN,d0
	cmp.l	#PAGE_MARGIN+MIN_WIDTH,d0
	bge.s	.w
	moveq	#PAGE_MARGIN+MIN_WIDTH,d0
.w:	move.l	d0,g_LayRight(a4)
	moveq	#0,d0
	move.w	g_FontH+2(a4),d0
	move.l	d0,g_LastH(a4)
	bsr	LineReset
	lea	-STYLE_SIZEOF(sp),sp
	move.l	sp,a0
	jsr	StyleRoot
	move.l	g_Doc(a4),d0
	beq.s	.done
	move.l	d0,a0
	move.l	sp,a1
	bsr	LayoutChildren
	bsr	FlushLine
.done:	lea	STYLE_SIZEOF(sp),sp
	bsr	ClearFloats		; (floats reach down too)
	move.l	g_LayY(a4),d0
	add.l	g_PendMargin(a4),d0
	move.l	d0,g_DocHeight(a4)
	moveq	#1,d0
	move.l	d0,g_ViewLive(a4)	; the runs can be painted
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; LayoutChildren - lay out all children of a node
; In: a0 = node, a1 = the node's style
;--------------------------------------------------------------------
LayoutChildren:
	movem.l	a2-a3,-(sp)
	move.l	a1,a3
	move.l	n_First(a0),a2
.l:	move.l	a2,d0
	beq.s	.x
	move.l	a2,a0
	move.l	a3,a1
	bsr.s	LayoutNode
	move.l	n_Next(a2),a2
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; LayoutNode - lay out one node
; In: a0 = node, a1 = parent's style
;--------------------------------------------------------------------
LayoutNode:
	movem.l	a2-a3/a5,-(sp)
	move.l	a0,a5
	move.b	n_Type(a5),d0
	cmp.b	#DN_TEXT,d0
	bne.s	.elem
	move.l	n_Data(a5),a0
	move.l	n_Data2(a5),d0
	bsr	LayoutChars
	bra	.x
.elem:	cmp.b	#DN_ELEMENT,d0
	bne	.x
	cmp.l	#MAX_LAYDEPTH,g_LayDepth(a4)
	bhs	.x
	addq.l	#1,g_LayDepth(a4)
	lea	-STYLE_SIZEOF(sp),sp
	move.l	sp,a3
	move.l	a5,a0
	move.l	a3,a2
	jsr	StyleCompute
	move.l	a5,a0
	move.l	a3,a1
	jsr	CssApply		; author styles on top
	move.b	st_Display(a3),d0
	cmp.b	#DISP_NONE,d0
	beq.s	.pop
	tst.l	g_FragName(a4)		; the #fragment target?
	beq.s	.nofrag
	tst.l	g_FragY(a4)
	bpl.s	.nofrag
	move.l	a5,a0
	bsr	CheckFragment
	move.b	st_Display(a3),d0
.nofrag:
	move.w	n_Tag(a5),d1
	cmp.w	#TAG_BR,d1
	beq.s	.br
	cmp.w	#TAG_HR,d1
	beq.s	.hr
	cmp.b	#DISP_INLINE,d0
	beq.s	.inline
	cmp.b	#DISP_IBLOCK,d0
	beq.s	.replaced
	move.l	a5,a0			; block, list item, table, ...
	move.l	a3,a1
	bsr	LayoutBlock
	bra.s	.pop
.inline:
	move.l	a5,a0
	move.l	a3,a1
	bsr	LayoutChildren
	bra.s	.pop
.replaced:
	move.l	a5,a0
	move.l	a3,a1
	bsr	LayoutReplaced
	bra.s	.pop
.br:	move.l	a3,a1
	bsr	LineBreak
	move.l	a5,a0			; <br clear=...>: below the floats
	lea	AnClear(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.pop
	bsr	FlushLine
	bsr	ClearFloats
	bsr	LineReset
	bra.s	.pop
.hr:	move.l	a3,a1
	bsr	Rule
.pop:	lea	STYLE_SIZEOF(sp),sp
	subq.l	#1,g_LayDepth(a4)
.x:	movem.l	(sp)+,a2-a3/a5
	rts

; CheckFragment - set g_FragY if element a0 has id= or name= equal to
; the fragment
CheckFragment:
	movem.l	a2-a3,-(sp)
	move.l	a0,a3
	lea	AnId(pc),a1
	bsr	.cmp
	beq.s	.hit
	move.l	a3,a0
	lea	AnName(pc),a1
	bsr	.cmp
	bne.s	.x
.hit:	move.l	g_LayY(a4),d0
	add.l	g_PendMargin(a4),d0
	move.l	d0,g_FragY(a4)
.x:	movem.l	(sp)+,a2-a3
	rts
.cmp:	jsr	DomGetAttr		; Z set if the attribute matches
	tst.l	d0
	beq.s	.ne
	move.l	d0,a0
	move.l	g_FragName(a4),a1
.c:	move.b	(a0)+,d0
	beq.s	.end
	cmp.b	(a1)+,d0
	beq.s	.c
.ne:	moveq	#1,d0
	rts
.end:	tst.b	(a1)
	rts

AnId:	dc.b	"id",0
AnName:	dc.b	"name",0
	even

;--------------------------------------------------------------------
; LayoutBlock - a block-level element (incl. list items and tables)
; In: a0 = element, a1 = its style
;--------------------------------------------------------------------
LayoutBlock:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a5
	move.l	a1,a3
	bsr	FlushLine
	moveq	#0,d0
	move.w	st_MTop(a3),d0
	bsr	AddMargin
	move.l	g_LayLeft(a4),d2	; saved state
	move.l	g_LayRight(a4),d3
	move.l	g_LayAlign(a4),d4
	move.l	g_LayWhite(a4),d5
	move.l	g_ListNum(a4),d6

	move.l	a5,a0
	move.l	a3,a1
	bsr	BlockBounds
	bsr	LineReset		; the first line starts at the new edge

	; lists: <ol start=n>, other lists count from 1
	move.w	n_Tag(a5),d0
	cmp.w	#TAG_OL,d0
	beq.s	.ol
	cmp.w	#TAG_UL,d0
	beq.s	.list1
	cmp.w	#TAG_MENU,d0
	beq.s	.list1
	cmp.w	#TAG_DIR,d0
	bne.s	.notlist
.list1:	moveq	#1,d0
	move.l	d0,g_ListNum(a4)
	bra.s	.notlist
.ol:	moveq	#1,d7
	lea	AnStart(pc),a1
	bsr	IntAttr			; d0 = value or d7
	move.l	d0,g_ListNum(a4)
.notlist:
	cmp.b	#DISP_LISTITEM,st_Display(a3)
	bne.s	.notli
	move.l	g_ListNum(a4),d7
	lea	AnValue(pc),a1
	bsr	IntAttr
	move.l	d0,g_MarkerNum(a4)
	addq.l	#1,d0
	move.l	d0,g_ListNum(a4)
	moveq	#0,d0
	move.b	st_List(a3),d0
	addq.l	#1,d0
	move.l	d0,g_Marker(a4)
.notli:
	; background
	moveq	#-1,d7
	cmp.b	#DISP_TABLE,st_Display(a3)	; tables draw their own
	beq	.nobg
	move.l	st_Bg(a3),d0		; a colour or an image
	bpl.s	.bg
	tst.l	st_BgImg(a3)
	beq	.nobg
.bg:	move.w	n_Tag(a5),d1		; <body>/<html>: the page background
	cmp.w	#TAG_BODY,d1
	beq.s	.pagebg
	cmp.w	#TAG_HTML,d1
	bne.s	.rect
.pagebg:
	tst.l	d0
	bmi.s	.pbi
	move.l	d0,g_PageBg(a4)
.pbi:	move.l	st_BgImg(a3),d1
	beq	.nobg
	move.l	d1,g_PageBgRec(a4)
	moveq	#0,d1
	move.b	st_BgRep(a3),d1
	move.l	d1,g_PageBgRep(a4)
	bra	.nobg
.rect:
	bsr	ApplyPendingMargin
	bsr	AddRun
	beq.s	.nobg
	move.l	d0,a0
	move.b	#RT_RECT,ru_Type(a0)
	move.l	g_LayY(a4),ru_Y(a0)
	move.w	g_LayLeft+2(a4),ru_X(a0)	; the (narrowed) box
	move.l	g_LayRight(a4),d0
	sub.l	g_LayLeft(a4),d0
	move.w	d0,ru_W(a0)
	move.l	st_Bg(a3),ru_Color(a0)
	move.l	st_BgImg(a3),ru_Text(a0)	; (its image)
	moveq	#0,d0
	move.b	st_BgRep(a3),d0
	move.l	d0,ru_Len(a0)
	bsr	RunCount
	subq.l	#1,d0
	move.l	d0,d7			; index of the rectangle
	bsr	LineReset
.nobg:
	move.l	a5,a0
	move.l	a3,a1
	cmp.b	#DISP_TABLE,st_Display(a3)
	bne.s	.content
	jsr	LayoutTable
	bra.s	.after
.content:
	bsr	LayoutChildren
.after:	bsr	FlushLine
	tst.l	d7
	bmi.s	.norect
	move.l	d7,d0
	bsr	RunPtr
	move.l	g_LayY(a4),d0
	sub.l	ru_Y(a0),d0
	move.w	d0,ru_H(a0)
.norect:
	clr.l	g_Marker(a4)
	move.l	d2,g_LayLeft(a4)
	move.l	d3,g_LayRight(a4)
	move.l	d4,g_LayAlign(a4)
	move.l	d5,g_LayWhite(a4)
	cmp.b	#DISP_LISTITEM,st_Display(a3)
	beq.s	.keepnum
	move.l	d6,g_ListNum(a4)
.keepnum:
	bsr	LineReset
	moveq	#0,d0
	move.w	st_MBottom(a3),d0
	bsr	AddMargin
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

;--------------------------------------------------------------------
; LayoutBlockContent - lay out an element's children as a block inside
; the current bounds (used for table cells)
; In: a0 = element, a1 = its style
;--------------------------------------------------------------------
LayoutBlockContent:
	movem.l	d2-d5,-(sp)
	move.l	g_LayAlign(a4),d4
	move.l	g_LayWhite(a4),d5
	moveq	#0,d0
	move.b	st_Align(a1),d0
	move.l	d0,g_LayAlign(a4)
	move.b	st_White(a1),d0
	move.l	d0,g_LayWhite(a4)
	bsr	LayoutChildren
	bsr	FlushLine
	move.l	d4,g_LayAlign(a4)
	move.l	d5,g_LayWhite(a4)
	movem.l	(sp)+,d2-d5
	rts

; BlockBounds - apply margins, width and alignment of a block
; In: a0 = element, a1 = style
BlockBounds:
	moveq	#0,d0
	move.w	st_MLeft(a1),d0
	ext.l	d0
	add.l	d0,g_LayLeft(a4)
	move.w	st_MRight(a1),d0
	ext.l	d0
	sub.l	d0,g_LayRight(a4)
	move.w	st_Width(a1),d0		; explicit width
	beq.s	.nw
	cmp.b	#DISP_TABLE,st_Display(a1)	; tables size themselves
	beq.s	.nw
	ext.l	d0
	bpl.s	.px
	neg.l	d0			; percent of the available width
	move.l	g_LayRight(a4),d1
	sub.l	g_LayLeft(a4),d1
	mulu.l	d1,d0
	divu.l	#100,d0
.px:	move.l	g_LayRight(a4),d1	; free space
	sub.l	g_LayLeft(a4),d1
	sub.l	d0,d1
	ble.s	.nw
	btst	#1,st_Flags(a1)		; margin: auto: centre the block
	beq.s	.left
	lsr.l	#1,d1
	add.l	d1,g_LayLeft(a4)
.left:	add.l	g_LayLeft(a4),d0
	move.l	d0,g_LayRight(a4)
.nw:	move.l	g_LayRight(a4),d0
	sub.l	g_LayLeft(a4),d0
	cmp.l	#MIN_WIDTH,d0
	bge.s	.ok
	move.l	g_LayLeft(a4),d0
	add.l	#MIN_WIDTH,d0
	move.l	d0,g_LayRight(a4)
.ok:	moveq	#0,d0
	move.b	st_Align(a1),d0
	move.l	d0,g_LayAlign(a4)
	move.b	st_White(a1),d0
	move.l	d0,g_LayWhite(a4)
	rts

; IntAttr - integer attribute
; In:  a5 = element, a1 = name, d7 = default
; Out: d0 = value
IntAttr:
	move.l	a5,a0
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.def
	move.l	d0,a0
	jsr	ParseDec
	tst.l	d1
	bne.s	.x
.def:	move.l	d7,d0
.x:	rts

AnStart:	dc.b	"start",0
AnClear:	dc.b	"clear",0
AnValue:	dc.b	"value",0
AnAlt:		dc.b	"alt",0
	even

;--------------------------------------------------------------------
; Vertical space and lines
;--------------------------------------------------------------------

; LineBounds - g_LineL/g_LineR for a line at the current y: the block
; bounds, narrowed by floats beside it.  Where floats leave too little
; room the line goes below them.
LineBounds:
	movem.l	d2-d3,-(sp)
.again:	move.l	g_LayY(a4),d2
	add.l	g_PendMargin(a4),d2	; y of the line
	move.l	g_LayLeft(a4),d0
	move.l	g_LayRight(a4),d1
	cmp.l	g_FlLBot(a4),d2		; a left float beside it?
	bge.s	.r
	cmp.l	g_FlLEdge(a4),d0
	bge.s	.r
	move.l	g_FlLEdge(a4),d0
.r:	cmp.l	g_FlRBot(a4),d2		; a right one?
	bge.s	.set
	cmp.l	g_FlREdge(a4),d1
	ble.s	.set
	move.l	g_FlREdge(a4),d1
.set:	move.l	d1,d3
	sub.l	d0,d3
	cmp.l	#MIN_WIDTH,d3		; too narrow: below the floats
	bge.s	.ok
	cmp.l	g_LayLeft(a4),d0
	bne.s	.clr
	cmp.l	g_LayRight(a4),d1
	beq.s	.ok			; (the block itself is narrow)
.clr:	bsr	ClearFloats
	bra.s	.again
.ok:	move.l	d0,g_LineL(a4)
	move.l	d1,g_LineR(a4)
	movem.l	(sp)+,d2-d3
	rts

; ClearFloats - move y below the floats and forget them
ClearFloats:
	move.l	g_LayY(a4),d0
	add.l	g_PendMargin(a4),d0
	cmp.l	g_FlLBot(a4),d0
	bge.s	.r
	move.l	g_FlLBot(a4),d0
.r:	cmp.l	g_FlRBot(a4),d0
	bge.s	.s
	move.l	g_FlRBot(a4),d0
.s:	sub.l	g_PendMargin(a4),d0
	move.l	d0,g_LayY(a4)
	clr.l	g_FlLBot(a4)
	clr.l	g_FlRBot(a4)
	rts

; AddMargin - In: d0 = margin; collapses with the pending margin
AddMargin:
	cmp.l	g_PendMargin(a4),d0
	ble.s	.x
	move.l	d0,g_PendMargin(a4)
.x:	rts

; ApplyPendingMargin - move y past the pending margin (a1 kept)
ApplyPendingMargin:
	move.l	g_PendMargin(a4),d0
	add.l	d0,g_LayY(a4)
	clr.l	g_PendMargin(a4)
	rts

; LineReset - start an empty line at the left edge (beside floats)
LineReset:
	bsr	LineBounds
	move.l	g_LineL(a4),g_LineX(a4)
	bsr	RunCount
	move.l	d0,g_LineStart(a4)
	clr.l	g_LineAsc(a4)
	clr.l	g_LineDesc(a4)
	clr.l	g_LineUsed(a4)
	clr.l	g_PendSpace(a4)
	rts

; FlushLine - finish the current line: align it, give its runs their
; y position and advance g_LayY
FlushLine:
	movem.l	d2-d6,-(sp)
	tst.l	g_LineUsed(a4)
	beq.s	.reset
	bsr	ApplyPendingMargin
	move.l	g_LayY(a4),d2
	move.l	g_LineAsc(a4),d3
	moveq	#0,d4			; horizontal shift
	move.l	g_LayAlign(a4),d0
	beq.s	.place
	move.l	g_LineR(a4),d4
	sub.l	g_LineX(a4),d4
	bpl.s	.pos
	moveq	#0,d4
.pos:	cmp.l	#ALIGN_CENTER,d0
	bne.s	.place
	asr.l	#1,d4
.place:	bsr	RunCount
	move.l	d0,d6
	move.l	g_LineStart(a4),d5
.l:	cmp.l	d6,d5
	bhs.s	.adv
	move.l	d5,d0
	bsr	RunPtr
	move.l	d2,d0
	add.l	d3,d0
	moveq	#0,d1
	move.w	ru_Base(a0),d1
	sub.l	d1,d0
	move.l	d0,ru_Y(a0)
	add.w	d4,ru_X(a0)
	addq.l	#1,d5
	bra.s	.l
.adv:	add.l	g_LineDesc(a4),d3
	add.l	d3,d2
	move.l	d2,g_LayY(a4)
.reset:	bsr	LineReset
	movem.l	(sp)+,d2-d6
	rts

; LineBreak - <br>
; In: a1 = style
LineBreak:
	tst.l	g_LineUsed(a4)
	bne	FlushLine
	bsr	ApplyPendingMargin	; empty line: one line of the font
	moveq	#0,d0
	move.b	st_Font(a1),d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	move.w	(a0,d0.w),d0
	add.l	d0,g_LayY(a4)
	bra	LineReset

; Rule - <hr>
; In: a1 = style
Rule:
	movem.l	d2-d3/a3,-(sp)
	move.l	a1,a3
	bsr	FlushLine
	moveq	#0,d2
	move.w	g_FontH+2(a4),d2
	lsr.l	#1,d2			; half an em above and below
	move.l	d2,d0
	bsr	AddMargin
	bsr	ApplyPendingMargin
	bsr	AddRun
	beq.s	.x
	move.l	d0,a0
	move.b	#RT_RULE,ru_Type(a0)
	move.l	g_LayY(a4),ru_Y(a0)
	move.l	g_LayRight(a4),d0
	sub.l	g_LayLeft(a4),d0	; full width ...
	move.l	g_LayLeft(a4),d1
	move.w	st_Width(a3),d3		; ... or width="50%" / "200"
	beq.s	.w
	ext.l	d3
	bpl.s	.px
	neg.l	d3
	mulu.l	d0,d3
	divu.l	#100,d3
.px:	cmp.l	d0,d3
	bge.s	.w
	sub.l	d3,d0			; centre it
	lsr.l	#1,d0
	add.l	d0,d1
	move.l	d3,d0
.w:	move.w	d1,ru_X(a0)
	move.w	d0,ru_W(a0)
	move.w	#2,ru_H(a0)
	move.l	g_PageFg(a4),ru_Color(a0)
	addq.l	#2,g_LayY(a4)
	bsr	LineReset
	move.l	d2,d0
	bsr	AddMargin
.x:	movem.l	(sp)+,d2-d3/a3
	rts

;--------------------------------------------------------------------
; LayoutChars - lay out text in a style
; In: a0 = text, d0 = length, a1 = style
;--------------------------------------------------------------------
LayoutChars:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2			; cursor
	move.l	d0,d7			; bytes left
	move.l	a1,a3			; style
	moveq	#0,d6			; d6 = font | soft << 8
	move.b	st_Soft(a3),d6
	lsl.w	#8,d6
	move.b	st_Font(a3),d6
	moveq	#0,d0
	move.b	d6,d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	moveq	#0,d1
	move.w	(a0,d0.w),d1
	move.l	d1,g_LastH(a4)
	lea	Space(pc),a0		; width of a blank
	moveq	#1,d1
	move.l	d6,d0
	bsr	Measure
	move.l	d0,g_SpaceW(a4)
	cmp.b	#WS_PRE,st_White(a3)
	beq	.pre

.next:	tst.l	d7
	ble	.x
	cmp.b	#' ',(a2)
	bne.s	.word
	tst.l	g_LineUsed(a4)
	beq.s	.skipb
	moveq	#1,d0
	move.l	d0,g_PendSpace(a4)
.skipb:	addq.l	#1,a2
	subq.l	#1,d7
	bra.s	.next
.word:	move.l	a2,a5			; word start
.wl:	addq.l	#1,a2
	subq.l	#1,d7
	ble.s	.we
	cmp.b	#' ',(a2)
	bne.s	.wl
.we:	move.l	a2,d2
	sub.l	a5,d2			; word length
.measure:
	move.l	d6,d0
	move.l	a5,a0
	move.l	d2,d1
	bsr	Measure
	move.l	d0,d3			; word width
	; wrap before the word?
	cmp.b	#WS_NOWRAP,st_White(a3)
	bne.s	.wrap
	tst.l	g_Squeeze(a4)		; (in a squeezed table it wraps)
	beq.s	.place
.wrap:	tst.l	g_LineUsed(a4)
	beq.s	.fit
	move.l	g_LineX(a4),d0
	add.l	d3,d0
	tst.l	g_PendSpace(a4)
	beq.s	.nsp
	add.l	g_SpaceW(a4),d0
.nsp:	cmp.l	g_LineR(a4),d0
	ble.s	.place
	bsr	FlushLine
.fit:	; a word longer than the whole line is split
	move.l	g_LineR(a4),d0
	sub.l	g_LineX(a4),d0
	cmp.l	d0,d3
	ble.s	.place
	cmp.l	#1,d2
	ble.s	.place
	move.l	a5,a0
	move.l	d2,d1
	bsr	FitChars		; d0 = chars that fit (>= 1)
	move.l	d0,d4
	move.l	a5,a0
	move.l	d6,d0
	move.l	d4,d1
	bsr	Measure
	move.l	d0,d1
	move.l	a5,a0
	move.l	d4,d0
	move.l	a3,a1
	move.l	d6,d2
	bsr	PlaceText
	bsr	FlushLine
	add.l	d4,a5
	move.l	a2,d2
	sub.l	a5,d2
	bra.s	.measure
.place:	move.l	a5,a0
	move.l	d2,d0
	move.l	d3,d1
	move.l	a3,a1
	move.l	d6,d2
	bsr	PlaceText
	bra	.next

.pre:	; preformatted: newlines break, tabs go to the next 8 blanks
	tst.l	d7
	ble.s	.x
	move.b	(a2),d0
	cmp.b	#10,d0
	bne.s	.notnl
	addq.l	#1,a2
	subq.l	#1,d7
	move.l	a3,a1
	bsr	LineBreak
	bra.s	.pre
.notnl:	cmp.b	#13,d0
	bne.s	.notcr
	addq.l	#1,a2
	subq.l	#1,d7
	bra.s	.pre
.notcr:	cmp.b	#9,d0
	bne.s	.seg
	addq.l	#1,a2
	subq.l	#1,d7
	move.l	g_SpaceW(a4),d1
	lsl.l	#3,d1			; tab width
	beq.s	.pre
	move.l	g_LineX(a4),d0
	sub.l	g_LayLeft(a4),d0
	divul.l	d1,d2:d0		; d0 = tab stops passed
	addq.l	#1,d0
	mulu.l	d1,d0
	add.l	g_LayLeft(a4),d0
	move.l	d0,g_LineX(a4)
	moveq	#1,d0
	move.l	d0,g_LineUsed(a4)
	bra.s	.pre
.seg:	move.l	a2,a5
.sl:	addq.l	#1,a2
	subq.l	#1,d7
	ble.s	.se
	move.b	(a2),d0
	cmp.b	#10,d0
	beq.s	.se
	cmp.b	#13,d0
	beq.s	.se
	cmp.b	#9,d0
	bne.s	.sl
.se:	move.l	a2,d2
	sub.l	a5,d2
	move.l	d6,d0
	move.l	a5,a0
	move.l	d2,d1
	bsr	Measure
	move.l	d0,d1
	move.l	a5,a0
	move.l	d2,d0
	move.l	a3,a1
	move.l	d6,d2
	bsr	PlaceText
	bra	.pre
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

Space:	dc.b	" "
	even

; FitChars - how many characters of a word fit in the rest of the line
; In:  a0 = text, d1 = length; d6 = font code (from LayoutChars)
; Out: d0 = count, at least 1
FitChars:
	movem.l	d2-d5/a2,-(sp)
	move.l	a0,a2
	move.l	g_LineR(a4),d5
	sub.l	g_LineX(a4),d5		; room
	moveq	#1,d2			; lo: always fits
	move.l	d1,d3			; hi
	subq.l	#1,d3
.l:	cmp.l	d3,d2
	bge.s	.x
	move.l	d2,d4
	add.l	d3,d4
	addq.l	#1,d4
	lsr.l	#1,d4			; mid (rounded up)
	move.l	d6,d0
	move.l	a2,a0
	move.l	d4,d1
	bsr	Measure
	cmp.l	d5,d0
	bgt.s	.big
	move.l	d4,d2
	bra.s	.l
.big:	move.l	d4,d3
	subq.l	#1,d3
	bra.s	.l
.x:	move.l	d2,d0
	movem.l	(sp)+,d2-d5/a2
	rts

;--------------------------------------------------------------------
; PlaceText - put a piece of text on the current line
; In: a0 = text, d0 = length, d1 = width, a1 = style, d2 = font code
;--------------------------------------------------------------------
PlaceText:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2
	move.l	d0,d4			; length
	move.l	d1,d5			; width
	move.l	a1,a3
	move.l	d2,d6
	move.l	g_LineX(a4),d3		; x
	tst.l	g_PendSpace(a4)
	beq.s	.nosp
	add.l	g_SpaceW(a4),d3
.nosp:	; extend the previous run if it is the same style and the text
	; continues it in memory (words of one text node)
	bsr	RunCount
	move.l	d0,d7
	cmp.l	g_LineStart(a4),d7
	bls.s	.new
	subq.l	#1,d0
	bsr	RunPtr
	move.l	a0,a5
	cmp.b	#RT_TEXT,ru_Type(a5)
	bne.s	.new
	move.b	ru_Font(a5),d0
	cmp.b	d6,d0
	bne.s	.new
	move.w	d6,d0
	lsr.w	#8,d0
	cmp.b	ru_Soft(a5),d0
	bne.s	.new
	move.l	ru_Color(a5),d0
	cmp.l	st_Color(a3),d0
	bne.s	.new
	move.l	ru_Link(a5),d0
	cmp.l	st_Link(a3),d0
	bne.s	.new
	move.l	ru_Text(a5),a0
	add.l	ru_Len(a5),a0		; end of the previous run
	tst.l	g_PendSpace(a4)
	beq.s	.adj
	cmp.b	#' ',(a0)+
	bne.s	.new
.adj:	cmp.l	a0,a2
	bne.s	.new
	move.l	a2,d0
	add.l	d4,d0
	sub.l	ru_Text(a5),d0
	move.l	d0,ru_Len(a5)
	move.l	d3,d0
	add.l	d5,d0
	sub.w	ru_X(a5),d0
	move.w	d0,ru_W(a5)
	bra.s	.adv
.new:	bsr	AddRun
	beq	.x
	move.l	d0,a5
	move.b	#RT_TEXT,ru_Type(a5)
	move.w	d3,ru_X(a5)
	move.w	d5,ru_W(a5)
	moveq	#0,d0
	move.b	d6,d0
	move.b	d0,ru_Font(a5)
	add.w	d0,d0
	lea	g_FontH(a4),a0
	move.w	(a0,d0.w),ru_H(a5)
	lea	g_FontBase(a4),a0
	move.w	(a0,d0.w),ru_Base(a5)
	move.w	d6,d0
	lsr.w	#8,d0
	move.b	d0,ru_Soft(a5)
	move.l	st_Color(a3),ru_Color(a5)
	move.l	a2,ru_Text(a5)
	move.l	d4,ru_Len(a5)
	move.l	st_Link(a3),ru_Link(a5)
	move.l	a5,a0
	bsr	LineMetrics
	tst.l	g_Marker(a4)
	beq.s	.adv
	move.l	a3,a1
	move.l	d6,d0
	bsr	EmitMarker
.adv:	add.l	d5,d3
	move.l	d3,g_LineX(a4)
	moveq	#1,d0
	move.l	d0,g_LineUsed(a4)
	clr.l	g_PendSpace(a4)
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; LineMetrics - grow the line's ascent/descent for a run
; In: a0 = run
LineMetrics:
	moveq	#0,d0
	move.w	ru_Base(a0),d0
	cmp.l	g_LineAsc(a4),d0
	ble.s	.a
	move.l	d0,g_LineAsc(a4)
.a:	moveq	#0,d1
	move.w	ru_H(a0),d1
	sub.l	d0,d1
	cmp.l	g_LineDesc(a4),d1
	ble.s	.x
	move.l	d1,g_LineDesc(a4)
.x:	rts

;--------------------------------------------------------------------
; EmitMarker - list marker for the first line of a list item
; In: a1 = style, d0 = font code
;--------------------------------------------------------------------
EmitMarker:
	movem.l	d2-d5/a2-a3,-(sp)
	move.l	a1,a3
	move.l	d0,d5
	move.l	g_Marker(a4),d2
	clr.l	g_Marker(a4)
	subq.l	#1,d2			; LIST_xxx
	cmp.l	#LIST_NONE,d2
	beq	.x
	moveq	#0,d0
	move.b	d5,d0
	add.w	d0,d0
	lea	g_FontBase(a4),a0
	moveq	#0,d3
	move.w	(a0,d0.w),d3		; baseline of the text
	cmp.l	#LIST_DECIMAL,d2
	beq.s	.num
	bsr	AddRun
	beq	.x
	move.l	d0,a0
	move.b	#RT_BULLET,ru_Type(a0)
	move.l	d2,ru_Len(a0)
	move.l	d3,d0			; size: half the baseline, >= 3
	lsr.l	#1,d0
	cmp.l	#3,d0
	bge.s	.sz
	moveq	#3,d0
.sz:	move.w	d0,ru_W(a0)
	move.w	d0,ru_H(a0)
	add.l	d3,d0
	lsr.l	#1,d0
	move.w	d0,ru_Base(a0)		; centred between baseline and top
	move.l	g_LayLeft(a4),d1
	sub.w	ru_W(a0),d1
	sub.l	g_SpaceW(a4),d1
	sub.l	g_SpaceW(a4),d1
	move.w	d1,ru_X(a0)
	move.l	st_Color(a3),ru_Color(a0)
	bra.s	.x
.num:	; "12." in the page pool
	moveq	#16,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a2
	move.l	g_MarkerNum(a4),d0
	move.l	a2,a0
	jsr	FmtDec
	move.b	#'.',(a0)+
	clr.b	(a0)
	sub.l	a2,a0
	move.l	a0,d4			; length
	move.l	d5,d0
	move.l	a2,a0
	move.l	d4,d1
	bsr	Measure
	move.l	d0,d2			; width
	bsr	AddRun
	beq.s	.x
	move.l	d0,a0
	move.b	#RT_TEXT,ru_Type(a0)
	move.l	g_LayLeft(a4),d0
	sub.l	d2,d0
	sub.l	g_SpaceW(a4),d0
	move.w	d0,ru_X(a0)
	move.w	d2,ru_W(a0)
	move.b	d5,ru_Font(a0)
	move.w	d5,d0
	lsr.w	#8,d0
	and.b	#~SOFT_UNDERLINE,d0
	move.b	d0,ru_Soft(a0)
	moveq	#0,d0
	move.b	d5,d0
	add.w	d0,d0
	lea	g_FontH(a4),a1
	move.w	(a1,d0.w),ru_H(a0)
	move.w	d3,ru_Base(a0)
	move.l	st_Color(a3),ru_Color(a0)
	move.l	a2,ru_Text(a0)
	move.l	d4,ru_Len(a0)
.x:	movem.l	(sp)+,d2-d5/a2-a3
	rts

;--------------------------------------------------------------------
; LayoutReplaced - images and form controls
; In: a0 = element, a1 = style
;--------------------------------------------------------------------
LayoutReplaced:
	movem.l	d2-d6/a2-a3/a5,-(sp)
	move.l	a0,a5
	move.l	a1,a3
	cmp.w	#TAG_IMG,n_Tag(a5)
	bne.s	.notimg
	move.l	n_Data2(a5),d0		; loaded: its size
	beq.s	.unl
	move.l	d0,a0
	moveq	#0,d2
	move.w	im_W(a0),d2
	moveq	#0,d3
	move.w	im_H(a0),d3
	bra.s	.box
.unl:	moveq	#0,d2
	move.w	st_Width(a3),d2
	ble.s	.alt
	moveq	#0,d3
	move.w	st_Height(a3),d3
	ble.s	.alt
.box:	move.l	d3,d4			; sits on the baseline
	moveq	#0,d6			; font code (PlaceBox stores it)
	move.b	st_Soft(a3),d6
	lsl.w	#8,d6
	move.b	st_Font(a3),d6
	moveq	#RT_IMAGE,d5
	move.b	st_Flags(a3),d0
	and.b	#SF_FLOATL|SF_FLOATR,d0
	beq.s	.inl
	bsr	PlaceFloat
	bra	.x
.inl:	bsr	PlaceBox
	bra	.x
.alt:	; unknown size: show the alt text instead
	move.l	a5,a0
	lea	AnAlt(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.x
	move.l	d0,a0
	move.l	d0,a2
.len:	tst.b	(a2)+
	bne.s	.len
	move.l	a2,d0
	sub.l	a0,d0
	subq.l	#1,d0
	move.l	a3,a1
	bsr	LayoutChars
	bra	.x
.notimg:
	move.l	a5,a0
	jsr	FormIsControl
	beq.s	.other
	moveq	#0,d6			; font code
	move.b	st_Soft(a3),d6
	lsl.w	#8,d6
	move.b	st_Font(a3),d6
	move.l	a5,a0
	move.l	d6,d0
	jsr	FormControlSize
	tst.l	d0
	beq.s	.x			; hidden
	move.l	d0,d2
	move.l	d1,d3
	move.l	n_Data2(a5),a0		; checkboxes sit on the baseline,
	move.b	fs_Kind(a0),d0		; text boxes share it with the text
	move.l	d3,d4
	cmp.b	#FK_CHECKBOX,d0
	beq.s	.place
	cmp.b	#FK_RADIO,d0
	beq.s	.place
	moveq	#0,d0
	move.b	d6,d0
	add.w	d0,d0
	lea	g_FontBase(a4),a0
	moveq	#0,d4
	move.w	(a0,d0.w),d4
	addq.l	#3,d4
.place:	moveq	#RT_WIDGET,d5
	bsr	PlaceBox
	bra.s	.x
.other:	; iframe and others: show their content
	move.l	a5,a0
	move.l	a3,a1
	bsr	LayoutChildren
.x:	movem.l	(sp)+,d2-d6/a2-a3/a5
	rts

; PlaceFloat - an image floated to the left or right: it goes at the
; edge at the next line, and the lines beside it are made narrower
; In: d2 = width, d3 = height, d5 = run type, d6 = font code,
;     a5 = element, a3 = style
PlaceFloat:
	movem.l	d2-d7,-(sp)
	bsr	FlushLine		; (it starts a new line)
	bsr	ApplyPendingMargin
	bsr	LineReset
	move.l	g_LineR(a4),d0		; never wider than the line
	sub.l	g_LineL(a4),d0
	cmp.l	d0,d2
	ble.s	.w
	move.l	d0,d2
.w:	move.l	g_LineL(a4),d7		; x: at the left ...
	btst	#3,st_Flags(a3)
	beq.s	.x
	move.l	g_LineR(a4),d7		; ... or the right edge
	sub.l	d2,d7
.x:	bsr	AddRun
	beq	.done
	move.l	d0,a0
	move.b	d5,ru_Type(a0)
	move.l	g_LayY(a4),ru_Y(a0)
	move.w	d7,ru_X(a0)
	move.w	d2,ru_W(a0)
	move.w	d3,ru_H(a0)
	move.w	d3,ru_Base(a0)
	move.b	d6,ru_Font(a0)
	move.w	d6,d0
	lsr.w	#8,d0
	move.b	d0,ru_Soft(a0)
	move.l	a5,ru_Text(a0)
	move.l	st_Color(a3),ru_Color(a0)
	move.l	st_Link(a3),ru_Link(a0)
	move.l	g_LayY(a4),d0		; remember it: bottom and edge
	add.l	d3,d0
	addq.l	#4,d0
	btst	#3,st_Flags(a3)
	bne.s	.right
	cmp.l	g_FlLBot(a4),d0
	ble.s	.lb
	move.l	d0,g_FlLBot(a4)
.lb:	add.l	d2,d7
	addq.l	#6,d7
	move.l	d7,g_FlLEdge(a4)
	bra.s	.done
.right:	cmp.l	g_FlRBot(a4),d0
	ble.s	.rb
	move.l	d0,g_FlRBot(a4)
.rb:	subq.l	#6,d7
	move.l	d7,g_FlREdge(a4)
.done:	bsr	LineReset		; (the float is not on the line)
	movem.l	(sp)+,d2-d7
	rts

; PlaceBox - put an inline box on the line (wrapping first if needed)
; In: d2 = width, d3 = height, d4 = baseline offset, d5 = run type,
;     d6 = font code, a5 = element, a3 = style
PlaceBox:
	movem.l	d2-d7,-(sp)
	move.l	g_LineR(a4),d0
	sub.l	g_LineL(a4),d0
	cmp.l	d0,d2
	ble.s	.wok
	move.l	d0,d2			; never wider than the line
.wok:	tst.l	g_LineUsed(a4)
	beq.s	.room
	move.l	g_LineX(a4),d0
	add.l	d2,d0
	tst.l	g_PendSpace(a4)
	beq.s	.ns
	add.l	g_SpaceW(a4),d0
.ns:	cmp.l	g_LineR(a4),d0
	ble.s	.room
	bsr	FlushLine
.room:	move.l	g_LineX(a4),d7
	tst.l	g_PendSpace(a4)
	beq.s	.nsp
	add.l	g_SpaceW(a4),d7
.nsp:	bsr	AddRun
	beq.s	.x
	move.l	d0,a0
	move.b	d5,ru_Type(a0)
	move.w	d7,ru_X(a0)
	move.w	d2,ru_W(a0)
	move.w	d3,ru_H(a0)
	move.w	d4,ru_Base(a0)
	move.b	d6,ru_Font(a0)
	move.w	d6,d0
	lsr.w	#8,d0
	move.b	d0,ru_Soft(a0)
	move.l	a5,ru_Text(a0)
	move.l	st_Color(a3),ru_Color(a0)
	move.l	st_Link(a3),ru_Link(a0)
	cmp.b	#RT_WIDGET,d5		; controls are their own "link"
	bne.s	.nl
	move.l	a5,ru_Link(a0)
.nl:	bsr	LineMetrics
	add.l	d2,d7
	move.l	d7,g_LineX(a4)
	moveq	#1,d0
	move.l	d0,g_LineUsed(a4)
	clr.l	g_PendSpace(a4)
.x:	movem.l	(sp)+,d2-d7
	rts

;--------------------------------------------------------------------
; Runs
;--------------------------------------------------------------------

; AddRun - append a cleared run
; Out: d0 = run pointer or 0 (CCR set).  Pointers to runs are only
;      valid until the next AddRun.
AddRun:
	lea	g_Runs(a4),a0
	moveq	#RUN_SIZEOF,d0
	jsr	BufReserve
	beq.s	.x
	move.l	buf_Data(a0),a1
	add.l	buf_Len(a0),a1
	add.l	#RUN_SIZEOF,buf_Len(a0)
	move.l	a1,d0
	moveq	#RUN_SIZEOF/4-1,d1
.c:	clr.l	(a1)+
	dbf	d1,.c
	tst.l	d0
.x:	rts

; RunCount - Out: d0 = number of runs
RunCount:
	move.l	g_Runs+buf_Len(a4),d0
	lsr.l	#5,d0			; RUN_SIZEOF = 32
	rts

; RunPtr - In: d0 = index; Out: a0 = run
RunPtr:
	move.l	g_Runs+buf_Data(a4),a0
	lsl.l	#5,d0
	add.l	d0,a0
	rts

; Measure - width of text
; In: d0 = font | soft << 8, a0 = text, d1 = length; Out: d0 = width
Measure:
	move.l	g_MeasureFn(a4),-(sp)
	rts
