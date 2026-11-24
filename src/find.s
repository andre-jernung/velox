;
; find.s - find in page
;
; '/' (or Find in the menu) starts it.  Typed text appears in the status
; line as "Find: text"; every key searches the text runs of the page
; (case-insensitive, within one run), scrolls the match into view and
; highlights it.  Return goes to the next match, Backspace deletes,
; Esc ends.  Cursor keys and commands keep working meanwhile.
;

	include	"velox.i"

	xdef	FindStart,FindKey,FindStop,FindHighlight
	xref	RunCount,RunPtr,KeyToChars,GuiStatus,GuiPaintAll,GuiScrollTo
	xref	LogEvent,StrCopyN,ToLower,DrawStatus

FIND_MAX	equ	63

	section	code,code

;--------------------------------------------------------------------
; FindStart - start finding (an empty search)
;--------------------------------------------------------------------
FindStart:
	moveq	#1,d0
	move.l	d0,g_FindOn(a4)
	clr.b	g_Find(a4)
	clr.l	g_FindRun(a4)
	moveq	#-1,d0
	move.l	d0,g_FindIdx(a4)
	bra	ShowFind

;--------------------------------------------------------------------
; FindStop - end finding and remove the highlight
;--------------------------------------------------------------------
FindStop:
	tst.l	g_FindOn(a4)
	beq.s	.x
	clr.l	g_FindOn(a4)
	tst.l	g_FindRun(a4)
	beq.s	.s
	clr.l	g_FindRun(a4)
	jsr	GuiPaintAll
.s:	lea	EmptyS(pc),a0
	jmp	GuiStatus
.x:	rts

;--------------------------------------------------------------------
; FindKey - a raw key while finding
; In:  d0 = raw code, d1 = qualifier
; Out: d0 = 1 if the key was used
;--------------------------------------------------------------------
FindKey:
	movem.l	d2-d4/a2,-(sp)
	move.l	d0,d2
	move.l	d1,d3
	tst.l	g_FindOn(a4)
	beq	.no
	cmp.w	#$80,d2			; releases
	bhs	.yes
	cmp.w	#$45,d2			; Esc
	bne.s	.n1
	bsr	FindStop
	bra	.yes
.n1:	cmp.w	#$44,d2			; Return / Enter: the next match
	beq.s	.next
	cmp.w	#$43,d2
	bne.s	.n2
.next:	move.l	g_FindIdx(a4),d0
	addq.l	#1,d0
	bsr	Search
	bra	.yes
.n2:	cmp.w	#$41,d2			; Backspace
	bne.s	.n3
	lea	g_Find(a4),a0
	tst.b	(a0)
	beq	.yes
.e:	tst.b	(a0)+
	bne.s	.e
	clr.b	-2(a0)
	bra.s	.again
.n3:	cmp.w	#$4c,d2			; cursor keys, wheel: not ours
	blo.s	.n4
	cmp.w	#$4f,d2
	bls	.no
.n4:	cmp.w	#$7a,d2
	beq	.no
	cmp.w	#$7b,d2
	beq	.no
	cmp.w	#$42,d2			; Tab ends finding, then moves on
	bne.s	.n5
	bsr	FindStop
	bra	.no
.n5:	move.w	d3,d0			; Amiga/Ctrl: commands
	and.w	#$00c8,d0
	bne	.no
	move.l	d2,d0
	move.l	d3,d1
	jsr	KeyToChars		; d0 = count, g_KeyChars
	move.l	d0,d4
	ble	.yes
	lea	g_KeyChars(a4),a2
	lea	g_Find(a4),a0		; append the printable ones
	moveq	#0,d1
.len:	tst.b	(a0)+
	beq.s	.le
	addq.l	#1,d1
	bra.s	.len
.le:	subq.l	#1,a0
.ch:	move.b	(a2)+,d0
	cmp.b	#32,d0
	blo.s	.chn
	cmp.b	#127,d0
	beq.s	.chn
	cmp.l	#FIND_MAX,d1
	bhs.s	.chn
	move.b	d0,(a0)+
	addq.l	#1,d1
.chn:	subq.l	#1,d4
	bne.s	.ch
	clr.b	(a0)
.again:	move.l	g_FindIdx(a4),d0	; from the current match on (it may
	bpl.s	.from			; still match, longer)
	moveq	#0,d0
.from:	bsr	Search
.yes:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4/a2
	rts

;--------------------------------------------------------------------
; Search - find g_Find from run d0 on (wrapping), show the result
;--------------------------------------------------------------------
Search:
	movem.l	d2-d6/a2,-(sp)
	move.l	d0,d2			; start
	clr.l	g_FindRun(a4)
	tst.b	g_Find(a4)
	beq	.show
	jsr	RunCount
	move.l	d0,d3			; count
	beq	.show
	cmp.l	d3,d2
	blo.s	.s
	moveq	#0,d2
.s:	move.l	d2,d4			; d4 = index being tried
	move.l	d3,d6			; runs to try
.l:	move.l	d4,d0
	jsr	RunPtr
	move.l	a0,a2
	cmp.b	#RT_TEXT,ru_Type(a2)
	bne.s	.n
	bsr	InRun			; d0 = offset or -1
	bpl.s	.hit
.n:	addq.l	#1,d4
	cmp.l	d3,d4
	blo.s	.nw
	moveq	#0,d4
.nw:	subq.l	#1,d6
	bne.s	.l
	bra.s	.show			; not found
.hit:	move.l	a2,g_FindRun(a4)
	move.l	d0,g_FindOff(a4)
	move.l	d4,g_FindIdx(a4)
	move.l	ru_Y(a2),d0		; in view?
	cmp.l	g_ScrollY(a4),d0
	blt.s	.scr
	moveq	#0,d1
	move.w	ru_H(a2),d1
	add.l	d1,d0
	move.l	g_ScrollY(a4),d1
	add.l	g_PageH(a4),d1
	cmp.l	d1,d0
	ble.s	.show
.scr:	move.l	ru_Y(a2),d0		; a third from the top
	move.l	g_PageH(a4),d1
	divu.w	#3,d1
	and.l	#$ffff,d1
	sub.l	d1,d0
	jsr	GuiScrollTo
.show:	jsr	GuiPaintAll
	bsr	ShowFind
	; log "find <run index>" (-1: not found)
	moveq	#-1,d0
	tst.l	g_FindRun(a4)
	beq.s	.lg
	move.l	g_FindIdx(a4),d0
.lg:	lea	LogFind(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	movem.l	(sp)+,d2-d6/a2
	rts

; InRun - case-insensitive search for g_Find in run a2
; Out: d0 = offset or -1 (CCR set)
InRun:
	movem.l	d2-d4/a3,-(sp)
	move.l	ru_Text(a2),a3
	move.l	ru_Len(a2),d3
	moveq	#0,d2			; offset
.o:	cmp.l	d3,d2
	bhs.s	.no
	lea	g_Find(a4),a0
	lea	0(a3,d2.l),a1
	move.l	d3,d4
	sub.l	d2,d4			; bytes left in the run
.c:	move.b	(a0)+,d0
	beq.s	.yes
	subq.l	#1,d4
	bmi.s	.no			; runs out: no later offset fits
	jsr	ToLower
	move.b	d0,d1
	move.b	(a1)+,d0
	jsr	ToLower
	cmp.b	d0,d1
	beq.s	.c
	addq.l	#1,d2
	bra.s	.o
.yes:	move.l	d2,d0
	bra.s	.x
.no:	moveq	#-1,d0
.x:	movem.l	(sp)+,d2-d4/a3
	rts

; ShowFind - "Find: text" (or "... not found") in the status line
ShowFind:
	lea	g_StatusText(a4),a1
	lea	SFind(pc),a0
.c1:	move.b	(a0)+,(a1)+
	bne.s	.c1
	subq.l	#1,a1
	lea	g_Find(a4),a0
.c2:	move.b	(a0)+,(a1)+
	bne.s	.c2
	tst.b	g_Find(a4)
	beq.s	.d
	tst.l	g_FindRun(a4)
	bne.s	.d
	subq.l	#1,a1
	lea	SNotFound(pc),a0
.c3:	move.b	(a0)+,(a1)+
	bne.s	.c3
.d:	jmp	DrawStatus

;--------------------------------------------------------------------
; FindHighlight - mark the match if run a2 holds it
; In: a2 = run, a3 = RastPort (font set), d2 = window x, d3 = window y
;     of the run's top
;--------------------------------------------------------------------
FindHighlight:
	tst.l	g_FindRun(a4)
	beq.s	.x
	cmp.l	g_FindRun(a4),a2
	bne.s	.x
	movem.l	d2-d5,-(sp)
	move.l	a3,a1			; x of the match
	move.l	ru_Text(a2),a0
	move.l	g_FindOff(a4),d0
	GFX	TextLength
	ext.l	d0
	add.l	d0,d2
	lea	g_Find(a4),a0		; its width
	moveq	#-1,d0
.len:	addq.l	#1,d0
	tst.b	(a0)+
	bne.s	.len
	move.l	a3,a1
	move.l	ru_Text(a2),a0
	add.l	g_FindOff(a4),a0
	GFX	TextLength
	ext.l	d0
	move.l	d2,d4
	add.l	d0,d4
	subq.l	#1,d4
	moveq	#0,d5
	move.w	ru_H(a2),d5
	add.l	d3,d5
	subq.l	#1,d5
	move.l	a3,a1
	moveq	#RP_COMPLEMENT,d0
	GFX	SetDrMd
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	move.l	d4,d2
	move.l	d5,d3
	GFX	RectFill
	move.l	a3,a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	movem.l	(sp)+,d2-d5
.x:	rts

SFind:		dc.b	"Find: ",0
SNotFound:	dc.b	"  (not found)",0
LogFind:	dc.b	"find",0
EmptyS:		dc.b	0
	even
