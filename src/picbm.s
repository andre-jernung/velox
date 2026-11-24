;
; picbm.s - decoded images (ARGB, pic.s) to bitmaps like the screen's
;
; The screen gets a colour cube of pens (L levels of red, green and
; blue, L by its depth: 2 to 6), obtained once (PalInit).  Images are
; scaled (nearest pixel) and dithered to the cube with a 4x4 ordered
; dither through tables: the index of a pixel's cube colour is
; DitTab[R][row][column][red] + ...[green] + ...[blue].  Pixels less
; than half opaque are left out by a mask plane.
;
; PicToBitMap runs in the image decoder process (img.s); PalInit and
; PalFree in Velox's own.
;

	include	"velox.i"
	include	"graphics/gfx.i"
	include	"graphics/view.i"

	xdef	PalInit,PalFree,PicToBitMap
	xref	PicAlloc,PicFreeMem

DIT_CH		equ	4*4*256		; one channel: 4 rows, 4 columns

	section	code,code

;--------------------------------------------------------------------
; PalInit - the colour cube and the dither tables for the screen
; (once; Velox's process)
;--------------------------------------------------------------------
PalInit:
	tst.l	g_PalReady(a4)
	bne	.x
	movem.l	d2-d7/a2,-(sp)
	move.l	g_Screen(a4),a0
	move.l	sc_RastPort+rp_BitMap(a0),a0
	move.l	a0,g_PalFriend(a4)
	moveq	#BMA_DEPTH,d1
	GFX	GetBitMapAttr
	move.l	d0,g_PalDepth(a4)
	cmp.l	#8,d0
	bls.s	.d
	moveq	#8,d0
.d:	moveq	#0,d7
	move.b	Levels(pc,d0.l),d7	; d7 = L
	move.l	d7,g_PalLevels(a4)
	; the pens: red slowest
	lea	g_Cube(a4),a2
	moveq	#0,d4			; red level
.r:	moveq	#0,d5			; green
.g:	moveq	#0,d6			; blue
.b:	move.l	d4,d0
	bsr	Level32
	move.l	d0,d1
	move.l	d5,d0
	bsr	Level32
	move.l	d0,d2
	move.l	d6,d0
	bsr	Level32
	move.l	d0,d3
	move.l	d1,-(sp)
	move.l	g_ColorMap(a4),a0
	lea	CubeTags(pc),a1
	move.l	(sp)+,d1
	GFX	ObtainBestPenA
	tst.l	d0
	bpl.s	.pen
	moveq	#1,d0			; (none: should not happen)
.pen:	move.b	d0,(a2)+
	addq.l	#1,d6
	cmp.l	d7,d6
	blo.s	.b
	addq.l	#1,d5
	cmp.l	d7,d5
	blo.s	.g
	addq.l	#1,d4
	cmp.l	d7,d4
	blo.s	.r
	move.l	d7,d0
	mulu.w	d7,d0
	mulu.w	d7,d0
	move.l	d0,g_PalCount(a4)
	; the dither tables: level = (v * (L-1) + threshold) >> 8,
	; times L*L (red), L (green), 1 (blue)
	lea	g_DitTab(a4),a2
	moveq	#3-1,d6			; channels
	move.l	d7,d5
	mulu.w	d7,d5			; d5 = multiplier: L*L, L, 1
.ch:	lea	Bayer(pc),a1
	moveq	#16-1,d4		; rows and columns
.pos:	moveq	#0,d3
	move.b	(a1)+,d3
	lsl.l	#4,d3
	addq.l	#8,d3			; d3 = threshold
	moveq	#0,d2			; value
.v:	move.l	d7,d0
	subq.l	#1,d0
	mulu.w	d2,d0
	add.l	d3,d0
	lsr.l	#8,d0
	mulu.w	d5,d0
	move.b	d0,(a2)+
	addq.l	#1,d2
	cmp.w	#256,d2
	blo.s	.v
	dbf	d4,.pos
	divu.w	d7,d5
	dbf	d6,.ch
	moveq	#1,d0
	move.l	d0,g_PalReady(a4)
	movem.l	(sp)+,d2-d7/a2
.x:	rts

; Level32 - level d0 of L (d7) as a 32-bit colour value
; Out: d0 (d1 kept)
Level32:
	move.l	d1,-(sp)
	mulu.w	#255,d0
	move.l	d7,d1
	subq.l	#1,d1
	divu.w	d1,d0
	and.l	#$ff,d0
	mulu.l	#$01010101,d0
	movem.l	(sp)+,d1
	rts

; levels of the cube by screen depth
Levels:	dc.b	2,2,2,2,3,3,4,5,6
Bayer:	dc.b	0,8,2,10, 12,4,14,6, 3,11,1,9, 15,7,13,5
	even
CubeTags:	dc.l	OBP_Precision,PRECISION_IMAGE,TAG_DONE

;--------------------------------------------------------------------
; PalFree - release the cube's pens
;--------------------------------------------------------------------
PalFree:
	tst.l	g_PalReady(a4)
	beq.s	.x
	clr.l	g_PalReady(a4)
	movem.l	d2/a2,-(sp)
	lea	g_Cube(a4),a2
	move.l	g_PalCount(a4),d2
	bra.s	.e
.l:	move.l	g_ColorMap(a4),a0
	moveq	#0,d0
	move.b	(a2)+,d0
	GFX	ReleasePen
.e:	dbf	d2,.l
	movem.l	(sp)+,d2/a2
.x:	rts

;--------------------------------------------------------------------
; PicToBitMap - the decoded image as a bitmap like the screen's
; In:  d0 = width, d1 = height wanted
; Out: d0 = bitmap or 0; g_PbmMask = its mask plane (a set bit: drawn)
;      or 0 if all of it is drawn
;--------------------------------------------------------------------
PicToBitMap:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	clr.l	g_PbmMask(a4)
	clr.l	g_PbmXMap(a4)
	clr.l	g_PbmBuf(a4)
	move.l	d0,g_PbmW(a4)
	move.l	d1,g_PbmH(a4)
	move.l	g_PalDepth(a4),d2	; the bitmap
	moveq	#BMF_CLEAR,d3
	move.l	g_PalFriend(a4),a0
	GFX	AllocBitMap
	move.l	d0,d7			; d7 = bitmap
	beq	.x
	move.l	g_PbmW(a4),d0		; source x of each column, in bytes
	lsl.l	#2,d0
	jsr	PicAlloc
	move.l	d0,g_PbmXMap(a4)
	beq	.fail
	move.l	d0,a0
	moveq	#0,d2
.xm:	move.l	d2,d0
	mulu.l	g_PicW(a4),d0
	divu.l	g_PbmW(a4),d0
	lsl.l	#2,d0
	move.l	d0,(a0)+
	addq.l	#1,d2
	cmp.l	g_PbmW(a4),d2
	blo.s	.xm
	move.l	g_PbmW(a4),d0		; one row of pens
	addq.l	#1,d0
	jsr	PicAlloc
	move.l	d0,g_PbmBuf(a4)
	beq	.fail
	move.l	g_PbmW(a4),d0		; the mask (freed if not needed)
	move.l	g_PbmH(a4),d1
	GFX	AllocRaster
	move.l	d0,g_PbmMask(a4)
	beq	.fail
	move.l	g_PbmW(a4),d0
	add.l	#15,d0
	lsr.l	#4,d0
	add.l	d0,d0
	move.l	d0,g_PbmMaskBPR(a4)
	mulu.l	g_PbmH(a4),d0
	move.l	g_PbmMask(a4),a0
	lsr.l	#1,d0
	bra.s	.mce
.mc:	clr.w	(a0)+
.mce:	subq.l	#1,d0
	bpl.s	.mc
	clr.l	g_PbmHoles(a4)
	lea	g_PbmRP(a4),a1		; a RastPort for WriteChunkyPixels
	GFX	InitRastPort
	move.l	d7,g_PbmRP+rp_BitMap(a4)
	lea	g_Cube(a4),a3		; a3 = the pens
	moveq	#0,d3			; d3 = row
.row:	cmp.l	g_PbmH(a4),d3
	bhs	.done
	move.l	d3,d0			; the source row
	mulu.l	g_PicH(a4),d0
	divu.l	g_PbmH(a4),d0
	mulu.l	g_PicW(a4),d0
	move.l	g_PicData(a4),a1
	lea	(a1,d0.l*4),a1		; a1 = source row
	moveq	#3,d0			; a5 = the dither tables of this row
	and.l	d3,d0
	lsl.l	#8,d0
	lsl.l	#2,d0
	lea	g_DitTab(a4),a5
	add.l	d0,a5
	move.l	g_PbmXMap(a4),a0
	move.l	g_PbmBuf(a4),a2
	move.l	d3,d0			; a6 = mask row
	mulu.l	g_PbmMaskBPR(a4),d0
	move.l	g_PbmMask(a4),a6
	add.l	d0,a6
	moveq	#7,d6			; d6 = mask bit
	moveq	#0,d5			; d5 = column & 3, times 256
	move.l	g_PbmW(a4),d2		; d2 = pixels left
.px:	move.l	(a0)+,d0
	move.l	(a1,d0.l),d0		; ARGB
	bpl.s	.hole			; less than half opaque
	bset	d6,(a6)
	moveq	#0,d1			; blue
	move.b	d0,d1
	or.w	d5,d1
	moveq	#0,d4
	move.b	2*DIT_CH(a5,d1.w),d4
	lsr.l	#8,d0			; green
	move.b	d0,d1
	add.b	DIT_CH(a5,d1.w),d4
	lsr.l	#8,d0			; red
	move.b	d0,d1
	add.b	(a5,d1.w),d4
	move.b	(a3,d4.w),(a2)+
.next:	add.w	#256,d5
	and.w	#$300,d5
	subq.l	#1,d6
	bpl.s	.mb
	moveq	#7,d6
	addq.l	#1,a6
.mb:	subq.l	#1,d2
	bne.s	.px
	lea	g_PbmRP(a4),a0		; the row into the bitmap
	moveq	#0,d0
	move.l	d3,d1
	move.l	g_PbmW(a4),d2
	subq.l	#1,d2
	move.l	g_PbmBuf(a4),a2
	move.l	d3,-(sp)
	move.l	g_PbmW(a4),d4
	GFX	WriteChunkyPixels
	move.l	(sp)+,d3
	addq.l	#1,d3
	bra	.row
.hole:	move.b	(a3),(a2)+		; (any pen: not drawn)
	st	g_PbmHoles(a4)
	bra.s	.next
.done:	tst.b	g_PbmHoles(a4)		; no holes: no mask
	bne.s	.free
	bsr	FreeMask
	bra.s	.free
.fail:	bsr	FreeMask
	GFX	WaitBlit
	move.l	d7,a0
	GFX	FreeBitMap
	moveq	#0,d7
.free:	move.l	g_PbmXMap(a4),a1
	jsr	PicFreeMem
	move.l	g_PbmBuf(a4),a1
	jsr	PicFreeMem
.x:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; FreeMask - free g_PbmMask (if any)
FreeMask:
	move.l	g_PbmMask(a4),d0
	beq.s	.x
	clr.l	g_PbmMask(a4)
	move.l	d0,a0
	move.l	g_PbmW(a4),d0
	move.l	g_PbmH(a4),d1
	GFX	FreeRaster
.x:	rts
