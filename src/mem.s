;
; mem.s - memory pools and growable buffers
;
; Alloc/Free use the application pool (exec v39 pools).  Every block
; remembers its size, so Free needs only the pointer.  Memory is cleared.
;

	include	"velox.i"

	xdef	MemInit,MemExit,Alloc,Free
	xdef	BufReserve,BufAppend,BufAppendByte,BufAppendStr,BufClear,BufFree

	section	code,code

;--------------------------------------------------------------------
; MemInit - create the application pool
; Out: d0 = 0 on failure
;--------------------------------------------------------------------
MemInit:
	move.l	d2,-(sp)
	move.l	#MEMF_ANY|MEMF_CLEAR,d0
	move.l	#16384,d1		; puddle size
	move.l	#4096,d2		; larger blocks get their own puddle
	EXEC	CreatePool
	move.l	d0,g_AppPool(a4)
	move.l	(sp)+,d2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; MemExit - free all memory of the application pool
;--------------------------------------------------------------------
MemExit:
	move.l	g_AppPool(a4),d0
	beq.s	.x
	clr.l	g_AppPool(a4)
	move.l	d0,a0
	EXEC	DeletePool
.x:	rts

;--------------------------------------------------------------------
; Alloc - allocate cleared memory
; In:  d0 = size
; Out: d0 = pointer or 0 (g_Error = ERR_NOMEM)
;--------------------------------------------------------------------
Alloc:
	addq.l	#4,d0
	move.l	d0,-(sp)
	move.l	g_AppPool(a4),a0
	EXEC	AllocPooled
	move.l	(sp)+,d1
	tst.l	d0
	beq.s	.fail
	move.l	d0,a0
	move.l	d1,(a0)+
	move.l	a0,d0
	rts
.fail:
	SETERR	ERR_NOMEM
	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; Free - free memory from Alloc
; In: a1 = pointer or 0
;--------------------------------------------------------------------
Free:
	move.l	a1,d0
	beq.s	.x
	move.l	-(a1),d0
	move.l	g_AppPool(a4),a0
	EXEC	FreePooled
.x:	rts

;--------------------------------------------------------------------
; BufReserve - make room for d0 more bytes (plus a terminating NUL)
; In:  a0 = Buf, d0 = extra bytes needed
; Out: d0 = 0 on failure; a0 preserved
;--------------------------------------------------------------------
BufReserve:
	movem.l	d2-d3/a2,-(sp)
	move.l	a0,a2
	move.l	buf_Len(a2),d2
	add.l	d0,d2
	addq.l	#1,d2			; d2 = bytes needed
	move.l	buf_Cap(a2),d3
	cmp.l	d3,d2
	bls.s	.ok
	tst.l	d3
	bne.s	.grow
	move.l	#256,d3
	bra.s	.check
.grow:	add.l	d3,d3
.check:	cmp.l	d3,d2
	bhi.s	.grow
	move.l	d3,d0
	bsr.s	Alloc
	beq.s	.fail
	move.l	buf_Data(a2),d1		; copy old contents
	beq.s	.new
	move.l	d0,-(sp)
	move.l	d1,a0
	move.l	d0,a1
	move.l	buf_Len(a2),d0
	EXEC	CopyMem
	move.l	buf_Data(a2),a1
	bsr.s	Free
	move.l	(sp)+,d0
.new:	move.l	d0,buf_Data(a2)
	move.l	d3,buf_Cap(a2)
.ok:	moveq	#1,d0
.x:	move.l	a2,a0
	movem.l	(sp)+,d2-d3/a2
	rts
.fail:	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; BufAppend - append bytes
; In:  a0 = Buf, a1 = data, d0 = length
; Out: d0 = 0 on failure
;--------------------------------------------------------------------
BufAppend:
	movem.l	d2/a2-a3,-(sp)
	move.l	d0,d2
	move.l	a1,a3
	bsr.s	BufReserve
	beq.s	.x
	move.l	a0,a2
	move.l	a3,a0
	move.l	buf_Data(a2),a1
	add.l	buf_Len(a2),a1
	move.l	d2,d0
	EXEC	CopyMem
	add.l	d2,buf_Len(a2)
	move.l	buf_Data(a2),a0
	add.l	buf_Len(a2),a0
	clr.b	(a0)
	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

;--------------------------------------------------------------------
; BufAppendByte
; In:  a0 = Buf, d0.b = byte
; Out: d0 = 0 on failure
;--------------------------------------------------------------------
BufAppendByte:
	move.l	d2,-(sp)
	move.b	d0,d2
	moveq	#1,d0
	bsr.s	BufReserve
	beq.s	.x
	move.l	buf_Data(a0),a1
	add.l	buf_Len(a0),a1
	move.b	d2,(a1)+
	clr.b	(a1)
	addq.l	#1,buf_Len(a0)
	moveq	#1,d0
.x:	move.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; BufAppendStr - append a NUL terminated string
; In:  a0 = Buf, a1 = string
; Out: d0 = 0 on failure
;--------------------------------------------------------------------
BufAppendStr:
	move.l	a1,d1
.len:	tst.b	(a1)+
	bne.s	.len
	move.l	a1,d0
	sub.l	d1,d0
	subq.l	#1,d0
	move.l	d1,a1
	bra	BufAppend

;--------------------------------------------------------------------
; BufClear - set length to 0, keep the memory
; In: a0 = Buf
;--------------------------------------------------------------------
BufClear:
	clr.l	buf_Len(a0)
	move.l	buf_Data(a0),d0
	beq.s	.x
	move.l	d0,a1
	clr.b	(a1)
.x:	rts

;--------------------------------------------------------------------
; BufFree - release the memory of a Buf
; In: a0 = Buf
;--------------------------------------------------------------------
BufFree:
	move.l	buf_Data(a0),a1
	clr.l	buf_Data(a0)
	clr.l	buf_Len(a0)
	clr.l	buf_Cap(a0)
	bra	Free
