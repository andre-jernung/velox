;
; mem.s - memory pools and growable buffers
;
; Alloc/Free use the application pool (exec v39 pools).  Every block
; remembers its size, so Free needs only the pointer.  Memory is cleared.
;

	include	"velox.i"

	xdef	MemInit,MemExit,Alloc,Free,PageNew,PageFree,PageAlloc,ArenaFree,ArenaBlock,ArenaBlockRaw
	xdef	BufReserve,BufAppend,BufAppendByte,BufAppendStr,BufClear,BufFree
	xref	FramesFree
	xref	PageLeave,KeepEvict

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
	movem.l	(sp)+,d2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; MemExit - free the page and all memory of the application pool
;--------------------------------------------------------------------
MemExit:
	bsr	PageFree
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
	movem.l	(sp)+,d1
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
; The page's memory: an arena of blocks (AllocVec, cleared), handed out
; in order and freed all at once.  g_PagePool is the block being used,
; the others follow it (ab_Next).  Being Velox's own blocks, a page can
; be written to disk and read back as they are (pagefile.s).
;--------------------------------------------------------------------
ARENA_CHUNK	equ	32768		; bytes of a block
ARENA_BIG	equ	8192		; larger: a block of its own

;--------------------------------------------------------------------
; PageNew - drop the current page's memory and start a new page
; Out: d0 = 0 on failure
;--------------------------------------------------------------------
PageNew:
	jsr	PageLeave		; (kept for Back, or freed)
	clr.l	g_PageDone(a4)		; (not in the history yet)
	clr.l	g_ImgCut(a4)
	clr.l	g_PageHash(a4)
	clr.l	g_PageStatus(a4)
	clr.l	g_PfFresh(a4)
	clr.l	g_FormTouched(a4)
	moveq	#-1,d0
	move.l	d0,g_PageHist(a4)
	move.l	#ARENA_CHUNK,d0
	bsr.s	ArenaBlock
	move.l	d0,g_PagePool(a4)
	bne.s	.x
	SETERR	ERR_NOMEM
	moveq	#0,d0			; (Z set again after SETERR)
.x:	rts

;--------------------------------------------------------------------
; ArenaBlock - a new arena block for d0 bytes
; Out: d0 = block or 0 (CCR set)
;--------------------------------------------------------------------
ArenaBlock:
	move.l	#MEMF_ANY|MEMF_CLEAR,d1
	bra.s	ArenaAlloc
; ArenaBlockRaw - the same, not cleared (it is read into at once)
ArenaBlockRaw:
	moveq	#MEMF_ANY,d1
ArenaAlloc:
	move.l	d0,-(sp)
	add.l	#AB_SIZEOF,d0
	EXEC	AllocVec
	move.l	(sp)+,d1
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	move.l	d1,ab_Size(a0)		; (ab_Next, ab_Used: 0)
	tst.l	d0
.x:	rts

;--------------------------------------------------------------------
; ArenaFree - free the arena blocks from a0 on
;--------------------------------------------------------------------
ArenaFree:
	move.l	a2,-(sp)
	move.l	a0,a2
.l:	move.l	a2,d0
	beq.s	.x
	move.l	d0,a1
	move.l	ab_Next(a2),a2
	EXEC	FreeVec
	bra.s	.l
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; PageFree - free the page's memory and source
;--------------------------------------------------------------------
PageFree:
	jsr	FramesFree		; (a page of frames: their views)
	clr.l	g_MapImg(a4)		; (maps.s)
	move.l	g_PageFreeHook(a4),d0	; (images free their bitmaps)
	beq.s	.nohook
	move.l	d0,a0
	jsr	(a0)
.nohook:
	lea	g_PageSrc(a4),a0
	bsr	BufFree
	clr.l	g_ViewLive(a4)		; (the runs point into the page)
	clr.l	g_Doc(a4)
	clr.l	g_Title(a4)
	clr.l	g_BaseHref(a4)
	move.l	g_PagePool(a4),a0
	clr.l	g_PagePool(a4)
	bra.s	ArenaFree

;--------------------------------------------------------------------
; PageAlloc - allocate cleared memory that lives as long as the page
; (4-byte aligned)
; In:  d0 = size
; Out: d0 = pointer or 0 (g_Error = ERR_NOMEM)
;--------------------------------------------------------------------
PageAlloc:
	movem.l	d2/a2,-(sp)
	addq.l	#3,d0
	moveq	#-4,d2
	and.l	d0,d2			; d2 = size
.try:	move.l	g_PagePool(a4),d0
	beq.s	.fail			; (no page)
	move.l	d0,a2
	move.l	ab_Used(a2),d0		; in the block being used?
	move.l	d0,d1
	add.l	d2,d1
	cmp.l	ab_Size(a2),d1
	bhi.s	.new
	move.l	d1,ab_Used(a2)
	lea	AB_SIZEOF(a2,d0.l),a0
	move.l	a0,d0
	bra.s	.x
.new:	cmp.l	#ARENA_BIG,d2
	bhs.s	.big
	move.l	#ARENA_CHUNK,d0		; a new block, used from now on
	bsr	ArenaBlock
	beq.s	.evict
	move.l	d0,a0
	move.l	a2,ab_Next(a0)
	move.l	a0,g_PagePool(a4)
	bra.s	.try
.big:	move.l	d2,d0			; a block of its own, after it
	bsr	ArenaBlock
	beq.s	.evict
	move.l	d0,a0
	move.l	d2,ab_Used(a0)
	move.l	ab_Next(a2),ab_Next(a0)
	move.l	a0,ab_Next(a2)
	lea	AB_SIZEOF(a0),a0
	move.l	a0,d0
	bra.s	.x
.evict:	jsr	KeepEvict		; pages kept for Back give way
	bne.s	.try
.fail:	SETERR	ERR_NOMEM
	moveq	#0,d0			; (Z set again after SETERR)
.x:	movem.l	(sp)+,d2/a2
	rts

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
	movem.l	(sp)+,d0
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
.x:	movem.l	(sp)+,d2
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
