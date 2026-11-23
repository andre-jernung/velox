;
; clip.s - copy text to the clipboard (unit 0, as IFF FTXT)
;

	include	"velox.i"
	include	"devices/clipboard.i"

	xdef	ClipCopy
	xref	StrLen

	section	code,code

;--------------------------------------------------------------------
; ClipCopy - put a text on the clipboard
; In:  a0 = text (NUL terminated)
; Out: d0 = 1 if done
;--------------------------------------------------------------------
ClipCopy:
	movem.l	d2-d4/a2-a3,-(sp)
	moveq	#0,d3			; result
	move.l	a0,a3
	jsr	StrLen
	move.l	d0,d4			; d4 = length
	EXEC	CreateMsgPort
	move.l	d0,d2
	beq.s	.x
	move.l	d2,a0
	moveq	#iocr_SIZEOF,d0
	EXEC	CreateIORequest
	move.l	d0,a2
	tst.l	d0
	beq.s	.port
	lea	ClipName(pc),a0
	moveq	#PRIMARY_CLIP,d0
	move.l	a2,a1
	moveq	#0,d1
	EXEC	OpenDevice
	tst.l	d0
	bne.s	.req
	clr.l	io_Offset(a2)
	clr.l	io_ClipID(a2)
	lea	-20(sp),sp		; FORM size FTXT CHRS length
	move.l	#'FORM',(sp)
	move.l	d4,d0
	addq.l	#1,d0
	and.w	#$fffe,d0		; (chunks have an even size)
	add.l	#12,d0
	move.l	d0,4(sp)
	move.l	#'FTXT',8(sp)
	move.l	#'CHRS',12(sp)
	move.l	d4,16(sp)
	move.l	sp,a0
	moveq	#20,d0
	bsr.s	.write
	move.l	a3,a0
	move.l	d4,d0
	bsr.s	.write
	btst	#0,d4
	beq.s	.even
	lea	20(sp),a0		; a pad byte (any)
	moveq	#1,d0
	bsr.s	.write
.even:	lea	20(sp),sp
	move.w	#CMD_UPDATE,io_Command(a2)
	move.l	a2,a1
	EXEC	DoIO
	tst.b	io_Error(a2)
	seq	d3
	neg.b	d3
	move.l	a2,a1
	EXEC	CloseDevice
.req:	move.l	a2,a0
	EXEC	DeleteIORequest
.port:	move.l	d2,a0
	EXEC	DeleteMsgPort
.x:	move.l	d3,d0
	movem.l	(sp)+,d2-d4/a2-a3
	rts
.write:	move.w	#CMD_WRITE,io_Command(a2)
	move.l	a0,io_Data(a2)
	move.l	d0,io_Length(a2)
	move.l	a2,a1
	EXEC	DoIO
	rts

ClipName:	dc.b	"clipboard.device",0
	even
