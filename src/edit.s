;
; edit.s - editing a text field or a text area, as a notepad does
;
; A text area's lines are soft-wrapped: a line ends after the last
; blank that fits in the area's width (fs_TextW, which painting sets),
; or inside a word longer than a line.  The cursor moves by character,
; by line (Up and Down keep the column: fs_Goal), to a line's start and
; end and to the text's; with Shift the selection (fs_Anchor .. the
; cursor) follows it.  Typing replaces the selection.  Every change goes
; through EdReplace, which keeps it as an undo step (g_Undo: typing
; goes on in one step until a blank or a move), so that undo and redo
; go back and forth through them.
;
; Characters are measured with a table of their widths in the field's
; font (fs_Font), made once for each font: no OS calls while editing.
; Here a3 is the FormState.
;

	include	"velox.i"

	xdef	EdWidths,EdNextLine,EdLocate,EdLine,EdXOf,EdIndexAt
	xdef	EdMove,EdType,EdBack,EdDel,EdSelAll,EdSel,EdUndo,EdRedo
	xdef	EdHit,EdForget
	xref	Measure,BufAppend,BufClear,BufReserve

UNDO_MAX	equ	32768		; bytes of undo steps kept at most
UR_POS		equ	0		; an undo step: where,
UR_DEL		equ	4		; ... bytes taken out,
UR_INS		equ	8		; ... bytes put in,
UR_CUR		equ	12		; ... the cursor before,
UR_ANC		equ	16		; ... the anchor before,
UR_SIZEOF	equ	20		; then the bytes taken out, those put
					; in, and the step's length (a long)

	section	code,code

;--------------------------------------------------------------------
; EdWidths - the width table (g_EdWid) for the field's font, made if it
; is for another one
;--------------------------------------------------------------------
EdWidths:
	moveq	#0,d0
	move.w	fs_Font(a3),d0
	addq.l	#1,d0
	cmp.l	g_EdWFont(a4),d0
	beq.s	.x
	movem.l	d2-d3,-(sp)
	move.l	d0,g_EdWFont(a4)
	subq.l	#1,d0
	move.l	d0,d3			; d3 = font | soft << 8
	moveq	#0,d2			; d2 = the character
.l:	moveq	#0,d0			; (control characters: nothing)
	cmp.w	#32,d2
	blo.s	.set
	move.w	d2,-(sp)
	move.b	d2,(sp)
	move.l	sp,a0
	moveq	#1,d1
	move.l	d3,d0
	jsr	Measure
	addq.l	#2,sp
.set:	lea	g_EdWid(a4),a0
	move.w	d0,(a0,d2.w*2)
	addq.w	#1,d2
	cmp.w	#256,d2
	blo.s	.l
	movem.l	(sp)+,d2-d3
.x:	rts

; CharW - Out: d0 = the width of character d0 (a password's: a star's)
; (d1, a0, a1 kept)
CharW:
	cmp.b	#FK_PASSWORD,fs_Kind(a3)
	bne.s	.c
	moveq	#'*',d0
.c:	and.w	#$ff,d0
	move.l	a1,-(sp)
	lea	g_EdWid(a4),a1
	move.w	(a1,d0.w*2),d0
	movem.l	(sp)+,a1
	ext.l	d0
	rts

;--------------------------------------------------------------------
; EdNextLine - the line that begins at a0: soft-wrapped at the area's
; width (fs_TextW; 0: not wrapped), at a newline, at the text's end
; In:  a0 = the line's start
; Out: a0 = its end (the first character not on it), a1 = the next
;      line's start, d0 = 1 if there is one (CCR set)
;--------------------------------------------------------------------
EdNextLine:
	movem.l	d2-d4/a2,-(sp)
	move.l	a0,a2			; a2 = the start
	moveq	#0,d2			; d2 = its width so far
	moveq	#0,d4			; d4 = after its last blank, or 0
	moveq	#0,d3
	move.w	fs_TextW(a3),d3		; d3 = the width there is
	bne.s	.l
	move.l	#$7fffffff,d3
.l:	moveq	#0,d0
	move.b	(a0),d0
	beq.s	.end
	cmp.b	#10,d0
	beq.s	.nl
	bsr	CharW
	add.l	d0,d2
	cmp.l	d3,d2
	bgt.s	.wrap
	cmp.b	#' ',(a0)+
	bne.s	.l
	move.l	a0,d4
	bra.s	.l
.wrap:	tst.l	d4			; at the last blank,
	beq.s	.cut
	move.l	d4,a0
	move.l	d4,a1
	bra.s	.more
.cut:	cmp.l	a2,a0			; or inside the word (a character at
	bne.s	.c1			; least)
	addq.l	#1,a0
.c1:	move.l	a0,a1
	bra.s	.more
.nl:	lea	1(a0),a1
.more:	moveq	#1,d0
	bra.s	.x
.end:	move.l	a0,a1
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4/a2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; EdLocate - the line the character at index d0 is on (the cursor
; there: at a soft wrap, the start of the next line)
; Out: d0 = the line's number, d1 = its start, a0 = its end (indexes),
;      a1 = 1 if it ends at a soft wrap
;--------------------------------------------------------------------
EdLocate:
	movem.l	d2-d4,-(sp)
	move.l	d0,d2			; d2 = the index
	moveq	#0,d3			; d3 = the line
	move.l	fs_Value(a3),a0		; d4 = its start (pointer)
	move.l	a0,d4
.l:	move.l	d4,a0
	bsr	EdNextLine
	move.l	d0,d1			; d1 = 1: a next line
	beq.s	.got			; (the last line)
	move.l	a1,d0
	sub.l	fs_Value(a3),d0
	cmp.l	d0,d2			; before the next line's start?
	blo.s	.got
	move.l	a1,d4
	addq.l	#1,d3
	bra.s	.l
.got:	move.l	a0,d0			; soft: it ends where the next begins
	cmp.l	a1,d0
	seq	d0
	and.l	d1,d0
	move.l	d0,a1
	sub.l	fs_Value(a3),a0
	move.l	d4,d1
	sub.l	fs_Value(a3),d1
	move.l	d3,d0
	movem.l	(sp)+,d2-d4
	rts

;--------------------------------------------------------------------
; EdLine - line d0 (the last one if there are not as many)
; Out: d0 = its number, d1 = its start, a0 = its end (indexes), a1 = 1
;      if it ends at a soft wrap
;--------------------------------------------------------------------
EdLine:
	movem.l	d2-d4,-(sp)
	move.l	d0,d2			; d2 = lines to go
	moveq	#0,d3			; d3 = the line
	move.l	fs_Value(a3),d4		; d4 = its start
.l:	move.l	d4,a0
	bsr	EdNextLine
	beq.s	.got
	cmp.l	d3,d2
	beq.s	.got
	move.l	a1,d4
	addq.l	#1,d3
	bra.s	.l
.got:	move.l	d0,d1			; soft wrap: it ends where the next
	move.l	a0,d0			; begins
	cmp.l	a1,d0
	seq	d0
	and.l	d1,d0
	and.l	#1,d0
	move.l	d0,a1
	sub.l	fs_Value(a3),a0
	move.l	d4,d1
	sub.l	fs_Value(a3),d1
	move.l	d3,d0
	movem.l	(sp)+,d2-d4
	rts

;--------------------------------------------------------------------
; EdXOf - Out: d0 = the width of the text from index d0 to index d1
;--------------------------------------------------------------------
EdXOf:
	movem.l	d2-d3,-(sp)
	moveq	#0,d2
	move.l	fs_Value(a3),a0
	add.l	d0,a0
	move.l	d1,d3
	sub.l	d0,d3			; d3 = characters
	ble.s	.x
.l:	moveq	#0,d0
	move.b	(a0)+,d0
	bsr	CharW
	add.l	d0,d2
	subq.l	#1,d3
	bne.s	.l
.x:	move.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

;--------------------------------------------------------------------
; EdIndexAt - the index nearest to x d1 on a line from index d0, up to
; index a0 at most
; Out: d0 = the index
;--------------------------------------------------------------------
EdIndexAt:
	movem.l	d2-d4,-(sp)
	move.l	d0,d2			; d2 = the index
	move.l	d1,d3			; d3 = x left to go
	move.l	a0,d4			; d4 = the last one
	move.l	fs_Value(a3),a0
	add.l	d2,a0
.l:	cmp.l	d4,d2
	bhs.s	.x
	moveq	#0,d0
	move.b	(a0)+,d0
	beq.s	.x
	cmp.b	#10,d0
	beq.s	.x
	bsr	CharW
	move.l	d0,d1			; past its middle: after it
	lsr.l	#1,d1
	cmp.l	d1,d3
	blt.s	.x
	sub.l	d0,d3
	addq.l	#1,d2
	bra.s	.l
.x:	move.l	d2,d0
	movem.l	(sp)+,d2-d4
	rts

; LastPos - (a soft-wrapped line ending at index a0 in a1 = 1) the last
; place for the cursor on it: before its end, which is the next line's
; Out: a0 = that index (d0, d1 kept)
LastPos:
	cmp.l	#0,a1
	beq.s	.x
	subq.l	#1,a0
.x:	rts

;--------------------------------------------------------------------
; EdSel - Out: d0 = the selection's start, d1 = its end (the same: none)
;--------------------------------------------------------------------
EdSel:
	move.l	fs_Cursor(a3),d0
	move.l	d0,d1
	move.l	fs_Anchor(a3),d1
	bpl.s	.s
	move.l	d0,d1
	rts
.s:	cmp.l	d0,d1
	bhs.s	.x
	exg	d0,d1
.x:	rts

;--------------------------------------------------------------------
; EdMove - move the cursor (d0 = MV_xxx); d1 = 1: the selection
; follows it (Shift), 0: no selection after
;--------------------------------------------------------------------
EdMove:
	movem.l	d2-d4,-(sp)
	move.l	d0,d2			; d2 = the move
	move.l	d1,d3
	clr.l	g_UndoMerge(a4)
	bsr	EdWidths
	move.l	fs_Cursor(a3),d4	; d4 = the cursor
	tst.l	d3
	beq.s	.drop
	tst.l	fs_Anchor(a3)		; Shift: the selection grows from
	bpl.s	.go			; where it was, or from here
	move.l	d4,fs_Anchor(a3)
	bra.s	.go
.drop:	move.l	fs_Anchor(a3),d0	; a selection and Left or Right: to
	bmi.s	.go			; its start or end, then none
	moveq	#-1,d1
	move.l	d1,fs_Anchor(a3)
	cmp.l	#MV_LEFT,d2
	beq.s	.min
	cmp.l	#MV_RIGHT,d2
	bne.s	.go
	cmp.l	d0,d4			; (the larger)
	bhs	.set
	move.l	d0,d4
	bra	.set
.min:	cmp.l	d0,d4
	bls	.set
	move.l	d0,d4
	bra	.set
.go:	move.l	d2,d0
	add.w	d0,d0
	move.w	.jt(pc,d0.w),d0
	jmp	.jt(pc,d0.w)
.jt:	dc.w	.left-.jt,.right-.jt,.up-.jt,.down-.jt
	dc.w	.home-.jt,.end-.jt,.top-.jt,.bottom-.jt
.left:	tst.l	d4
	beq	.set
	subq.l	#1,d4
	bra	.set
.right:	cmp.l	fs_Len(a3),d4
	bhs	.set
	addq.l	#1,d4
	bra	.set
.home:	move.l	d4,d0
	bsr	EdLocate
	move.l	d1,d4
	bra	.set
.end:	move.l	d4,d0
	bsr	EdLocate
	bsr.s	LastPos
	move.l	a0,d4
	bra	.set
.top:	moveq	#0,d4
	bra	.set
.bottom:
	move.l	fs_Len(a3),d4
	bra	.set
.up:	moveq	#-1,d3
	bra.s	.ud
.down:	moveq	#1,d3
.ud:	cmp.b	#FK_TEXTAREA,fs_Kind(a3)	; (text areas only)
	bne	.setg
	move.l	d4,d0			; d0 = the line, d1 its start
	bsr	EdLocate
	move.l	d0,-(sp)
	tst.l	fs_Goal(a3)		; the x to keep: the cursor's, when
	bpl.s	.g			; Up/Down begin
	move.l	d1,d0
	move.l	d4,d1
	bsr	EdXOf
	move.l	d0,fs_Goal(a3)
.g:	move.l	(sp)+,d0
	add.l	d3,d0			; the line above, below
	bmi.s	.first
	move.l	d0,-(sp)
	bsr	EdLine
	cmp.l	(sp)+,d0		; (not as many: the last line, at its
	beq.s	.on			;  end)
	move.l	fs_Len(a3),d4
	bra.s	.setg
.on:	bsr	LastPos
	move.l	d1,d0
	move.l	fs_Goal(a3),d1
	bsr	EdIndexAt
	move.l	d0,d4
	bra.s	.setg
.first:	moveq	#0,d4			; (above the first line: its start)
	bra.s	.setg
.set:	moveq	#-1,d0			; any other move: a new x to keep
	move.l	d0,fs_Goal(a3)
.setg:	move.l	d4,fs_Cursor(a3)
	cmp.l	fs_Anchor(a3),d4	; (the anchor here: no selection)
	bne.s	.x
.keep:	moveq	#-1,d0
	move.l	d0,fs_Anchor(a3)
.x:	movem.l	(sp)+,d2-d4
	rts

;--------------------------------------------------------------------
; EdSelAll - select all of the text
;--------------------------------------------------------------------
EdSelAll:
	clr.l	fs_Anchor(a3)
	move.l	fs_Len(a3),fs_Cursor(a3)
	tst.l	fs_Len(a3)
	bne.s	.x
	moveq	#-1,d0
	move.l	d0,fs_Anchor(a3)
.x:	clr.l	g_UndoMerge(a4)
	rts

;--------------------------------------------------------------------
; EdType - text a0 (d0 bytes) in place of the selection, or at the
; cursor
;--------------------------------------------------------------------
EdType:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	bsr	EdSel
	move.l	a2,a0
	bsr	EdReplace
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; EdBack - Backspace: the selection goes, or the character before the
; cursor
; EdDel - Del: the selection goes, or the character at the cursor
;--------------------------------------------------------------------
EdBack:
	bsr	EdSel
	cmp.l	d0,d1
	bne.s	EdCut0
	tst.l	d0
	beq.s	EdNone
	subq.l	#1,d0
	bra.s	EdCut0
EdDel:
	bsr	EdSel
	cmp.l	d0,d1
	bne.s	EdCut0
	cmp.l	fs_Len(a3),d1
	bhs.s	EdNone
	addq.l	#1,d1
EdCut0:	move.l	d2,-(sp)
	moveq	#0,d2
	bsr	EdReplace
	movem.l	(sp)+,d2
EdNone:	rts

;--------------------------------------------------------------------
; EdReplace - characters d0 .. d1 (end exclusive) become the d2 bytes at
; a0 (as many as fs_Max leaves room for); the cursor after them; an undo
; step (typing goes on in the one before)
;--------------------------------------------------------------------
EdReplace:
	movem.l	d2-d4/a2,-(sp)
	move.l	d0,d3
	move.l	d1,d4
	move.l	a0,a2
	move.l	fs_Len(a3),d0		; room: len - (end - start) + n <= max
	sub.l	d4,d0
	add.l	d3,d0
	add.l	d2,d0
	sub.l	fs_Max(a3),d0
	ble.s	.room
	sub.l	d0,d2
	bpl.s	.room
	moveq	#0,d2
.room:	cmp.l	d3,d4			; nothing at all: no step
	bne.s	.do
	tst.l	d2
	beq.s	.x
.do:	move.l	d3,d0
	move.l	d4,d1
	move.l	a2,a0
	bsr	UndoAdd			; (before the text changes)
	move.l	d3,d0
	move.l	d4,d1
	move.l	a2,a0
	bsr	Apply
.x:	movem.l	(sp)+,d2-d4/a2
	rts

; Apply - (EdReplace, undo, redo) characters d0 .. d1 become the d2
; bytes at a0: the cursor after them, no selection
Apply:
	movem.l	d2-d5/a2,-(sp)
	move.l	d0,d3			; d3 = start
	move.l	d1,d4			; d4 = end
	move.l	a0,a2
	move.l	fs_Value(a3),a0		; the tail (with its NUL) moves to
	move.l	fs_Len(a3),d5		; start + n
	sub.l	d4,d5			; d5 = its bytes, without the NUL
	move.l	d2,d0
	sub.l	d4,d0
	add.l	d3,d0			; d0 = how far it moves
	beq.s	.copy
	bmi.s	.down
	lea	1(a0,d4.l),a1		; up: from its end
	add.l	d5,a1
	lea	(a1,d0.l),a0
	move.l	d5,d1
.u:	move.b	-(a1),-(a0)
	subq.l	#1,d1
	bpl.s	.u
	bra.s	.copy
.down:	lea	(a0,d4.l),a1		; down: from its start
	lea	(a1,d0.l),a0
	move.l	d5,d1
.d:	move.b	(a1)+,(a0)+
	subq.l	#1,d1
	bpl.s	.d
.copy:	move.l	fs_Value(a3),a0		; the new bytes
	add.l	d3,a0
	move.l	d2,d1
	bra.s	.ce
.c:	move.b	(a2)+,(a0)+
.ce:	subq.l	#1,d1
	bpl.s	.c
	move.l	fs_Len(a3),d0
	sub.l	d4,d0
	add.l	d3,d0
	add.l	d2,d0
	move.l	d0,fs_Len(a3)
	add.l	d2,d3
	move.l	d3,fs_Cursor(a3)
	moveq	#-1,d0
	move.l	d0,fs_Anchor(a3)
	move.l	d0,fs_Goal(a3)
	movem.l	(sp)+,d2-d5/a2
	rts

;--------------------------------------------------------------------
; Undo steps (g_Undo, the tab's): those of one field at a time
; (g_UndoState); a step after g_UndoAt is one undone, to be redone.
;--------------------------------------------------------------------

; UndoAdd - keep the change of characters d0 .. d1 into the d2 bytes at
; a0 as a step: one character typed after another (not after a blank)
; goes on in the step before
UndoAdd:
	movem.l	d2-d5/a2,-(sp)
	move.l	d0,d3			; d3 = start
	move.l	d1,d4			; d4 = end
	move.l	a0,a2
	bsr	UndoMine
	move.l	g_UndoAt(a4),g_Undo+buf_Len(a4)	; (redo: gone)
	tst.l	g_UndoMerge(a4)		; typing goes on?
	beq.s	.new
	tst.l	g_UndoAt(a4)
	beq.s	.new
	cmp.l	#1,d2
	bne.s	.new
	cmp.l	d3,d4
	bne.s	.new
	bsr	UndoLast		; the step before: typed, ending here,
	tst.l	UR_DEL(a1)		; its last character not a blank
	bne.s	.new
	move.l	UR_POS(a1),d0
	add.l	UR_INS(a1),d0
	cmp.l	d3,d0
	bne.s	.new
	move.b	-1(a0),d0
	cmp.b	#' ',d0
	beq.s	.new
	cmp.b	#10,d0
	beq.s	.new
	lea	g_Undo(a4),a0		; it gets the character (room for it)
	moveq	#1,d0
	jsr	BufReserve
	beq	.fail
	bsr	UndoLast
	addq.l	#1,UR_INS(a1)
	move.l	(a0),d5			; (the step's length, + 1)
	addq.l	#1,d5
	move.b	(a2),(a0)+
	move.l	d5,(a0)
	addq.l	#1,g_Undo+buf_Len(a4)
	bra	.done
.new:	lea	-UR_SIZEOF(sp),sp	; a new step
	move.l	d3,UR_POS(sp)
	move.l	d4,d0
	sub.l	d3,d0
	move.l	d0,UR_DEL(sp)
	move.l	d2,UR_INS(sp)
	move.l	fs_Cursor(a3),UR_CUR(sp)
	move.l	fs_Anchor(a3),UR_ANC(sp)
	move.l	UR_DEL(sp),d5		; its length
	add.l	d2,d5
	add.l	#UR_SIZEOF+4,d5
	lea	g_Undo(a4),a0
	move.l	sp,a1
	moveq	#UR_SIZEOF,d0
	jsr	BufAppend
	lea	UR_SIZEOF(sp),sp
	beq.s	.fail
	move.l	d4,d0		 	; the bytes taken out,
	sub.l	d3,d0
	beq.s	.nd
	lea	g_Undo(a4),a0
	move.l	fs_Value(a3),a1
	add.l	d3,a1
	jsr	BufAppend
	beq.s	.fail
.nd:	move.l	d2,d0			; those put in,
	beq.s	.ni
	lea	g_Undo(a4),a0
	move.l	a2,a1
	jsr	BufAppend
	beq.s	.fail
.ni:
	move.l	d5,-(sp)		; its length
	lea	g_Undo(a4),a0
	move.l	sp,a1
	moveq	#4,d0
	jsr	BufAppend
	addq.l	#4,sp
	beq.s	.fail
.done:	move.l	g_Undo+buf_Len(a4),g_UndoAt(a4)
	moveq	#0,d0			; typing: the next character may go on
	cmp.l	#1,d2			; in it
	bne.s	.m
	cmp.l	d3,d4
	bne.s	.m
	moveq	#1,d0
.m:	move.l	d0,g_UndoMerge(a4)
	bsr.s	UndoTrim
	movem.l	(sp)+,d2-d5/a2
	rts
.fail:	bsr.s	EdForget		; (no memory: no undo)
	movem.l	(sp)+,d2-d5/a2
	rts

; UndoLast - Out: a1 = the last step done, a0 = where its length is (at
; its end)
UndoLast:
	move.l	g_Undo+buf_Data(a4),a0
	add.l	g_UndoAt(a4),a0
	move.l	-(a0),d0
	neg.l	d0
	lea	4(a0,d0.l),a1
	rts

; UndoMine - the undo steps are this field's (a3); a new field: none
UndoMine:
	cmp.l	g_UndoState(a4),a3
	beq.s	.x
	bsr.s	EdForget
	move.l	a3,g_UndoState(a4)
.x:	rts

;--------------------------------------------------------------------
; EdForget - no undo steps (another field, another page)
;--------------------------------------------------------------------
EdForget:
	lea	g_Undo(a4),a0
	jsr	BufClear
	clr.l	g_UndoAt(a4)
	clr.l	g_UndoState(a4)
	clr.l	g_UndoMerge(a4)
	rts

; UndoTrim - the oldest steps go while they take more than UNDO_MAX
UndoTrim:
	movem.l	d2,-(sp)
.l:	move.l	g_Undo+buf_Len(a4),d0
	cmp.l	#UNDO_MAX,d0
	bls.s	.x
	move.l	g_Undo+buf_Data(a4),a0	; the first step's length
	move.l	UR_DEL(a0),d2
	add.l	UR_INS(a0),d2
	add.l	#UR_SIZEOF+4,d2
	cmp.l	g_UndoAt(a4),d2		; (not one that is done)
	bhi.s	.x
	lea	(a0,d2.l),a1		; the rest down
	sub.l	d2,d0
	move.l	d0,d1
	bra.s	.ce
.c:	move.b	(a1)+,(a0)+
.ce:	subq.l	#1,d1
	bpl.s	.c
	sub.l	d2,g_Undo+buf_Len(a4)
	sub.l	d2,g_UndoAt(a4)
	bra.s	.l
.x:	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; EdUndo - the last step undone (the cursor and selection as before it)
; EdRedo - the last step undone done again
; Out: d0 = 1 if there was one (CCR set)
;--------------------------------------------------------------------
EdUndo:
	movem.l	d2/a2,-(sp)
	clr.l	g_UndoMerge(a4)
	moveq	#0,d0
	cmp.l	g_UndoState(a4),a3
	bne.s	.x
	move.l	g_UndoAt(a4),d1
	beq.s	.x
	move.l	g_Undo+buf_Data(a4),a2
	add.l	d1,a2
	sub.l	-4(a2),d1		; the step's start
	move.l	d1,g_UndoAt(a4)
	move.l	g_Undo+buf_Data(a4),a2
	add.l	d1,a2			; a2 = the step
	move.l	UR_POS(a2),d0		; what it put in becomes what it
	move.l	d0,d1			; took out
	add.l	UR_INS(a2),d1
	move.l	UR_DEL(a2),d2
	lea	UR_SIZEOF(a2),a0
	bsr	Apply
	move.l	UR_CUR(a2),fs_Cursor(a3)
	move.l	UR_ANC(a2),fs_Anchor(a3)
	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a2
	tst.l	d0
	rts

EdRedo:
	movem.l	d2/a2,-(sp)
	clr.l	g_UndoMerge(a4)
	moveq	#0,d0
	cmp.l	g_UndoState(a4),a3
	bne.s	.x
	move.l	g_UndoAt(a4),d1
	cmp.l	g_Undo+buf_Len(a4),d1
	bhs.s	.x
	move.l	g_Undo+buf_Data(a4),a2
	add.l	d1,a2			; a2 = the step
	move.l	UR_DEL(a2),d0		; (its length)
	add.l	UR_INS(a2),d0
	add.l	#UR_SIZEOF+4,d0
	add.l	d0,g_UndoAt(a4)
	move.l	UR_POS(a2),d0
	move.l	d0,d1
	add.l	UR_DEL(a2),d1
	move.l	UR_INS(a2),d2
	lea	UR_SIZEOF(a2),a0
	add.l	UR_DEL(a2),a0
	bsr	Apply
	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; EdHit - the cursor to point d0/d1 of the field (from its text's left
; edge and from its top); d2 = 1: the selection follows (Shift-click, a
; drag)
;--------------------------------------------------------------------
EdHit:
	movem.l	d2-d4,-(sp)
	move.l	d0,d3			; d3 = x
	move.l	d1,d4			; d4 = y
	clr.l	g_UndoMerge(a4)
	moveq	#-1,d0
	move.l	d0,fs_Goal(a3)
	tst.l	d2			; the selection: from where it was, or
	beq.s	.drop			; from the cursor
	tst.l	fs_Anchor(a3)
	bpl.s	.go
	move.l	fs_Cursor(a3),fs_Anchor(a3)
	bra.s	.go
.drop:	moveq	#-1,d0
	move.l	d0,fs_Anchor(a3)
.go:	bsr	EdWidths
	tst.l	d3
	bpl.s	.xp
	moveq	#0,d3
.xp:	cmp.b	#FK_TEXTAREA,fs_Kind(a3)
	beq.s	.area
	move.l	fs_Scroll(a3),d0	; a field: from its first character
	move.l	d3,d1			; shown
	move.l	fs_Len(a3),a0
	bsr	EdIndexAt
	bra.s	.set
.area:	moveq	#0,d0			; a text area: the line under it
	move.b	fs_Font+1(a3),d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	moveq	#0,d1
	move.w	(a0,d0.w),d1
	move.l	d4,d0
	bpl.s	.yp
	moveq	#0,d0
.yp:	divu.l	d1,d0
	add.l	fs_Scroll(a3),d0
	bsr	EdLine
	bsr	LastPos
	move.l	d1,d0
	move.l	d3,d1
	bsr	EdIndexAt
.set:	move.l	d0,fs_Cursor(a3)
	cmp.l	fs_Anchor(a3),d0
	bne.s	.x
	moveq	#-1,d0
	move.l	d0,fs_Anchor(a3)
.x:	movem.l	(sp)+,d2-d4
	rts
