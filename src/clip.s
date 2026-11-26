;
; clip.s - text to and from the clipboard (unit 0, as IFF FTXT)
;

	include	"velox.i"
	include	"devices/clipboard.i"

	xdef	ClipCopy,ClipCopyN,ClipPaste
	xref	StrLen

	section	code,code

;--------------------------------------------------------------------
; ClipCopy - put a text on the clipboard
; In:  a0 = text (NUL terminated)
; Out: d0 = 1 if done
; ClipCopyN - the same, In: d0 = its length (no NUL needed)
;--------------------------------------------------------------------
ClipCopy:
	move.l	a0,-(sp)
	jsr	StrLen
	movem.l	(sp)+,a0
ClipCopyN:
	movem.l	d2-d4/a2-a3,-(sp)
	moveq	#0,d3			; result
	move.l	a0,a3
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

;--------------------------------------------------------------------
; ClipPaste - the text on the clipboard (its first CHRS chunk)
; Out: d0 = it (AllocVec, NUL terminated: FreeVec it) or 0 (CCR set),
;      d1 = its length
;--------------------------------------------------------------------
ClipPaste:
	movem.l	d2-d5/a2,-(sp)
	moveq	#0,d4			; d4 = the text
	moveq	#0,d5			; d5 = its length
	EXEC	CreateMsgPort
	move.l	d0,d2
	beq	.x
	move.l	d2,a0
	moveq	#iocr_SIZEOF,d0
	EXEC	CreateIORequest
	move.l	d0,a2
	tst.l	d0
	beq	.port
	lea	ClipName(pc),a0
	moveq	#PRIMARY_CLIP,d0
	move.l	a2,a1
	moveq	#0,d1
	EXEC	OpenDevice
	tst.l	d0
	bne	.req
	clr.l	io_Offset(a2)
	clr.l	io_ClipID(a2)
	lea	-16(sp),sp		; FORM size FTXT
	move.l	sp,a0
	moveq	#12,d0
	bsr	.read
	cmp.l	#12,d0
	bne.s	.done
	cmp.l	#'FORM',(sp)
	bne.s	.done
	cmp.l	#'FTXT',8(sp)
	bne.s	.done
.chunk:	move.l	sp,a0			; a chunk: its id and size
	moveq	#8,d0
	bsr	.read
	cmp.l	#8,d0
	bne.s	.done
	move.l	4(sp),d3		; d3 = its size
	cmp.l	#'CHRS',(sp)
	bne.s	.skip
	move.l	d3,d0			; the text
	addq.l	#1,d0
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,d4
	beq.s	.done
	move.l	d4,a0
	move.l	d3,d0
	bsr	.read
	move.l	d0,d5
	move.l	d4,a0
	clr.b	(a0,d5.l)
	bra.s	.done
.skip:	addq.l	#1,d3			; (even)
	and.w	#$fffe,d3
.sk:	tst.l	d3			; skipped, 16 bytes at a time
	beq.s	.chunk
	moveq	#16,d0
	cmp.l	d0,d3
	bhs.s	.s16
	move.l	d3,d0
.s16:	sub.l	d0,d3
	move.l	sp,a0
	bsr	.read
	tst.l	d0
	bne.s	.sk
.done:	move.l	sp,a0			; read to its end: the device is done
	moveq	#16,d0			; with it
	bsr	.read
	tst.l	d0
	bne.s	.done
	lea	16(sp),sp
	move.l	a2,a1
	EXEC	CloseDevice
.req:	move.l	a2,a0
	EXEC	DeleteIORequest
.port:	move.l	d2,a0
	EXEC	DeleteMsgPort
.x:	move.l	d5,d1
	move.l	d4,d0
	movem.l	(sp)+,d2-d5/a2
	rts
; .read - d0 bytes into a0; Out: d0 = bytes read
.read:	move.w	#CMD_READ,io_Command(a2)
	move.l	a0,io_Data(a2)
	move.l	d0,io_Length(a2)
	move.l	a2,a1
	EXEC	DoIO
	move.l	io_Actual(a2),d0
	tst.b	io_Error(a2)
	beq.s	.r
	moveq	#0,d0
.r:	rts
