;
; sel.s - selecting text with the mouse
;
; Pressing the left button on text (not on a link or control) starts a
; selection, moving with the button down extends it, and releasing it
; copies the selected text to the clipboard.  The selection is drawn
; complemented over the text runs it covers.  Runs are in reading order,
; so a selection is a range (run, offset) .. (run, offset).
;

	include	"velox.i"

	xdef	SelPress,SelMove,SelRelease,SelHighlight
	xref	RunCount,RunPtr,Measure,GuiPaintAll,ClipCopy,GuiStatus
	xref	BufAppend,BufAppendByte,BufFree,LogEvent,FmtDec,StrCopy

	section	code,code

;--------------------------------------------------------------------
; SelPress - the left button went down at d5/d6 (window) on no link
;--------------------------------------------------------------------
SelPress:
	tst.l	g_SelShown(a4)		; an old selection goes
	beq.s	.n
	clr.l	g_SelShown(a4)
	jsr	GuiPaintAll
.n:	bsr	TextAt
	tst.l	d0
	bmi.s	.x
	move.l	d0,g_SelA(a4)
	move.l	d1,g_SelAOff(a4)
	move.l	d0,g_SelB(a4)
	move.l	d1,g_SelBOff(a4)
	moveq	#1,d0
	move.l	d0,g_SelOn(a4)
.x:	rts

;--------------------------------------------------------------------
; SelMove - the mouse moved to d5/d6 with the button down
;--------------------------------------------------------------------
SelMove:
	tst.l	g_SelOn(a4)
	beq.s	.x
	bsr	TextAt
	tst.l	d0
	bmi.s	.x
	cmp.l	g_SelB(a4),d0		; changed?
	bne.s	.set
	cmp.l	g_SelBOff(a4),d1
	beq.s	.x
.set:	move.l	d0,g_SelB(a4)
	move.l	d1,g_SelBOff(a4)
	moveq	#1,d0
	move.l	d0,g_SelShown(a4)
	jmp	GuiPaintAll
.x:	rts

;--------------------------------------------------------------------
; SelRelease - the button went up: copy the selection
;--------------------------------------------------------------------
SelRelease:
	tst.l	g_SelOn(a4)
	beq	.x
	clr.l	g_SelOn(a4)
	tst.l	g_SelShown(a4)
	beq	.x
	movem.l	d2-d7/a2-a3,-(sp)
	bsr	Range			; d2/d3 .. d4/d5
	lea	-BUF_SIZEOF(sp),sp	; the text
	move.l	sp,a3
	clr.l	(a3)
	clr.l	4(a3)
	clr.l	8(a3)
	moveq	#-1,d7			; y of the previous run
	moveq	#0,d6			; its right edge
.r:	cmp.l	d4,d2
	bhi.s	.done
	move.l	d2,d0
	jsr	RunPtr
	move.l	a0,a2
	cmp.b	#RT_TEXT,ru_Type(a2)
	bne.s	.n
	tst.l	d7			; between runs: a newline or a blank
	bmi.s	.t
	moveq	#10,d0
	cmp.l	ru_Y(a2),d7
	bne.s	.sep
	moveq	#' ',d0
	move.w	ru_X(a2),d1
	ext.l	d1
	cmp.l	d6,d1
	ble.s	.t
.sep:	move.l	a3,a0
	jsr	BufAppendByte
.t:	move.l	ru_Y(a2),d7
	move.w	ru_X(a2),d6
	ext.l	d6
	add.w	ru_W(a2),d6
	moveq	#0,d0			; from ... to
	cmp.l	g_SelFrom(a4),d2
	bne.s	.f
	move.l	d3,d0
.f:	move.l	ru_Len(a2),d1
	cmp.l	d4,d2
	bne.s	.e
	move.l	d5,d1
.e:	sub.l	d0,d1
	ble.s	.n
	move.l	ru_Text(a2),a1
	add.l	d0,a1
	move.l	d1,d0
	move.l	a3,a0
	jsr	BufAppend
.n:	addq.l	#1,d2
	bra.s	.r
.done:	move.l	a3,a0			; NUL terminated
	moveq	#0,d0
	jsr	BufAppendByte
	move.l	buf_Data(a3),d0
	beq.s	.free
	move.l	d0,a0
	tst.b	(a0)
	beq.s	.free
	jsr	ClipCopy
	tst.l	d0
	beq.s	.free
	move.l	buf_Len(a3),d0		; "Copied 123 characters"
	subq.l	#1,d0
	lea	LogSel(pc),a0
	suba.l	a1,a1
	move.l	d0,-(sp)
	jsr	LogEvent
	lea	MsgCopied(pc),a0
	lea	g_StatusBuf(a4),a1
	jsr	StrCopy
	move.l	a1,a0
	move.l	(sp)+,d0
	jsr	FmtDec
	move.l	a0,a1
	lea	MsgChars(pc),a0
	jsr	StrCopy
	lea	g_StatusBuf(a4),a0
	jsr	GuiStatus
.free:	move.l	a3,a0
	jsr	BufFree
	lea	BUF_SIZEOF(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3
.x:	rts

LogSel:		dc.b	"selected",0
MsgCopied:	dc.b	"Copied ",0
MsgChars:	dc.b	" characters to the clipboard",0
	even

; Range - the selection in reading order
; Out: d2 = first run, d3 = offset in it, d4 = last run, d5 = offset;
;      g_SelFrom = d2
Range:
	move.l	g_SelA(a4),d2
	move.l	g_SelAOff(a4),d3
	move.l	g_SelB(a4),d4
	move.l	g_SelBOff(a4),d5
	cmp.l	d4,d2
	blo.s	.x
	bhi.s	.swap
	cmp.l	d5,d3
	bls.s	.x
.swap:	exg	d2,d4
	exg	d3,d5
.x:	move.l	d2,g_SelFrom(a4)
	rts

;--------------------------------------------------------------------
; SelHighlight - mark the selected part of text run a2
; In: a3 = RastPort (font set), d2 = window x, d3 = window y (top),
;     g_PaintIdx = the run's index
;--------------------------------------------------------------------
SelHighlight:
	tst.l	g_SelShown(a4)
	beq.s	.x
	movem.l	d2-d6,-(sp)
	move.l	d2,d6
	move.l	d3,-(sp)
	bsr	Range			; (d2-d5 = the range)
	move.l	(sp)+,d1		; d1 = y
	move.l	g_PaintIdx(a4),d0
	cmp.l	d2,d0
	blo.s	.no
	cmp.l	d4,d0
	bhi.s	.no
	moveq	#0,d2			; from
	cmp.l	g_SelFrom(a4),d0
	bne.s	.f
	move.l	d3,d2
.f:	move.l	ru_Len(a2),d3		; to
	cmp.l	d4,d0
	bne.s	.t
	move.l	d5,d3
.t:	cmp.l	d2,d3
	bls.s	.no
	move.l	d1,d5			; y
	move.l	a3,a1			; x of from and of to
	move.l	ru_Text(a2),a0
	move.l	d2,d0
	GFX	TextLength
	ext.l	d0
	move.l	d0,d4
	add.l	d6,d4
	move.l	a3,a1
	move.l	ru_Text(a2),a0
	move.l	d3,d0
	GFX	TextLength
	ext.l	d0
	add.l	d6,d0
	subq.l	#1,d0
	move.l	d0,d6			; x max
	move.l	a3,a1
	moveq	#RP_COMPLEMENT,d0
	GFX	SetDrMd
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	move.l	d6,d2
	moveq	#0,d3
	move.w	ru_H(a2),d3
	add.l	d5,d3
	subq.l	#1,d3
	GFX	RectFill
	move.l	a3,a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
.no:	movem.l	(sp)+,d2-d6
.x:	rts

;--------------------------------------------------------------------
; TextAt - the text position under the mouse
; In:  d5/d6 = window position
; Out: d0 = run index (-1 if none), d1 = character offset in it
;--------------------------------------------------------------------
TextAt:
	movem.l	d2-d7/a2,-(sp)
	move.l	d5,d2
	sub.l	g_PageX(a4),d2		; d2 = document x
	move.l	d6,d3
	sub.l	g_PageY(a4),d3
	bmi.s	.none
	cmp.l	g_PageH(a4),d3
	bge.s	.none
	add.l	g_ScrollY(a4),d3	; d3 = document y
	moveq	#-1,d6			; best run
	moveq	#0,d7			; its offset
	jsr	RunCount
	move.l	d0,d4
	moveq	#0,d5
.l:	cmp.l	d4,d5
	bhs.s	.done
	move.l	d5,d0
	jsr	RunPtr
	move.l	a0,a2
	cmp.b	#RT_TEXT,ru_Type(a2)
	bne.s	.n
	move.l	ru_Y(a2),d0		; on this line?
	cmp.l	d0,d3
	blt.s	.n
	moveq	#0,d1
	move.w	ru_H(a2),d1
	add.l	d1,d0
	cmp.l	d0,d3
	bge.s	.n
	move.w	ru_X(a2),d0		; left of it: only as a first guess
	ext.l	d0
	sub.l	d2,d0
	neg.l	d0			; d0 = x within the run
	bpl.s	.in
	tst.l	d6
	bpl.s	.n
	move.l	d5,d6
	moveq	#0,d7
	bra.s	.n
.in:	move.l	d5,d6
	bsr	Offset
	move.l	d0,d7
.n:	addq.l	#1,d5
	bra.s	.l
.done:	move.l	d6,d0
	move.l	d7,d1
	bra.s	.x
.none:	moveq	#-1,d0
	moveq	#0,d1
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; Offset - characters of run a2 left of x d0 (within the run)
; Out: d0
Offset:
	movem.l	d2-d4,-(sp)
	move.l	d0,d3			; x
	moveq	#0,d2			; characters
.l:	cmp.l	ru_Len(a2),d2
	bhs.s	.x
	moveq	#0,d0			; width of d2+1 characters
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	move.l	ru_Text(a2),a0
	move.l	d2,d1
	addq.l	#1,d1
	jsr	Measure
	cmp.l	d3,d0
	bgt.s	.x
	addq.l	#1,d2
	bra.s	.l
.x:	move.l	d2,d0
	movem.l	(sp)+,d2-d4
	rts
