;
; vp8l.s - WebP lossless (VP8L) decoding: the transforms (predictor,
; cross colour, subtract green, colour indexing), the colour cache,
; meta prefix codes, LZ77 with 2D distances.  Also used for the alpha
; of lossy WebP (ALPH, compressed).
;
; Bits come LSB first (d2 = buffer, d3 = bits in it, a2/a3 = input and
; its end, as in inflate.s); past the end they read as zeros, and too
; many of those is an error.  Memory comes from PicAlloc, chained, and
; is freed at the end (VFreeAll).
;

	include	"velox.i"

	xdef	Vp8lDecode,Vp8lImage,VFreeAll
	xref	PicNew,PicAlloc,PicFreeMem

; a prefix code: codes up to 8 bits by one look-up
LFAST		equ	8
	RSRESET
lh_Fast		rs.w	1<<LFAST	; length << 12 | symbol, 0: longer
lh_Count	rs.w	16
lh_Single	rs.w	1		; one symbol (+1): no bits at all
lh_Sym		rs.w	0		; symbols by code (as many as codes)
LH_SIZEOF	rs.b	0

; a level of the image stream (on the stack)
	RSRESET
lv_W		rs.l	1		; width (packed, at level 0)
lv_H		rs.l	1
lv_Out		rs.l	1		; the pixels
lv_CBits	rs.l	1		; colour cache: bits (0: none),
lv_Cache	rs.l	1		; ... the colours
lv_MBits	rs.l	1		; meta codes: block size (0: none),
lv_MW		rs.l	1		; ... the entropy image's width,
lv_Meta		rs.l	1		; ... (group numbers)
lv_Groups	rs.l	1		; 5 codes a group
lv_NGroups	rs.l	1
lv_Level0	rs.l	1
lv_Total	rs.l	1		; pixels
LV_SIZEOF	rs.b	0

OVER		equ	16		; zero bytes past the end that are ok

	section	code,code

;--------------------------------------------------------------------
; Vp8lDecode - a VP8L bit stream (from its signature byte)
; In:  a0 = data, d0 = length; Out: d0 = 1 if decoded (g_Pic*)
;--------------------------------------------------------------------
Vp8lDecode:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	clr.l	g_VChain(a4)
	clr.l	g_VOver(a4)
	move.l	a0,a2
	lea	(a0,d0.l),a3
	moveq	#0,d2
	moveq	#0,d3
	moveq	#8,d0
	bsr	VBits
	cmp.b	#$2f,d0			; signature
	bne.s	.no
	moveq	#14,d0
	bsr	VBits
	addq.l	#1,d0
	move.l	d0,d6			; width
	moveq	#14,d0
	bsr	VBits
	addq.l	#1,d0
	move.l	d0,d7			; height
	moveq	#4,d0			; alpha used, version (0)
	bsr	VBits
	lsr.l	#1,d0
	bne.s	.no
	move.l	d6,d0
	move.l	d7,d1
	jsr	PicNew
	beq.s	.no
	move.l	d0,a0
	move.l	d6,d0
	move.l	d7,d1
	bsr	Vp8lImage
	bra.s	.x
.no:	moveq	#0,d0
.x:	move.l	d0,d6
	bsr	VFreeAll
	move.l	d6,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

;--------------------------------------------------------------------
; Vp8lImage - a level 0 image stream (transforms, then the image)
; In:  d0 = width, d1 = height, a0 = the pixels (width * height longs);
;      d2/d3/a2/a3 = the bits
; Out: d0 = 1 if decoded (CCR set)
;--------------------------------------------------------------------
Vp8lImage:
	movem.l	d4-d7/a5-a6,-(sp)
	move.l	d0,g_VW(a4)		; (the real width: for the transforms)
	clr.l	g_VNTrans(a4)
	clr.l	g_VTSeen(a4)
	move.l	d0,d6			; d6 = width, as transforms make it
	move.l	d1,d7
	move.l	a0,a6			; a6 = the pixels
.tr:	moveq	#1,d0			; a transform?
	bsr	VBits
	tst.l	d0
	beq	.image
	cmp.l	#4,g_VNTrans(a4)
	bhs	.no
	moveq	#2,d0
	bsr	VBits
	move.l	d0,d5			; d5 = type
	move.l	g_VTSeen(a4),d1		; each once
	btst	d5,d1
	bne	.no
	bset	d5,d1
	move.l	d1,g_VTSeen(a4)
	move.l	g_VNTrans(a4),d0
	addq.l	#1,g_VNTrans(a4)
	lsl.l	#4,d0
	lea	g_VTrans(a4,d0.l),a5	; a5 = the transform: type, bits,
	move.l	d5,(a5)			; data, width
	move.l	d6,12(a5)
	cmp.l	#2,d5
	beq.s	.tr			; subtract green: nothing more
	bhi.s	.index
	moveq	#3,d0			; predictor, cross colour: a block
	bsr	VBits			; size and an image of them
	addq.l	#2,d0
	move.l	d0,4(a5)
	move.l	d7,d4			; blocks down,
	bsr	.div
	move.l	d4,-(sp)
	move.l	d6,d4			; ... across
	bsr	.div
	move.l	d4,d0
	move.l	(sp)+,d1
	bsr	SubImage
	move.l	d0,8(a5)
	beq	.no
	bra	.tr
.index:	moveq	#8,d0			; colour indexing: the palette
	bsr	VBits
	addq.l	#1,d0
	move.l	d0,d4			; colours
	moveq	#0,d1			; pixels per byte: 2^bits
	cmp.l	#16,d4
	bhi.s	.ib
	moveq	#1,d1
	cmp.l	#4,d4
	bhi.s	.ib
	moveq	#2,d1
	cmp.l	#2,d4
	bhi.s	.ib
	moveq	#3,d1
.ib:	move.l	d1,4(a5)
	move.l	d4,d0
	moveq	#1,d1
	bsr	SubImage
	move.l	d0,8(a5)
	beq	.no
	move.l	d0,a0			; delta coded: add the previous one
	move.l	d4,d5
	subq.l	#2,d5
	bmi.s	.pd
.pl:	move.l	(a0)+,d1
	move.l	(a0),d0
	bsr	AddPix
	move.l	d0,(a0)
	dbf	d5,.pl
.pd:	move.l	#256*4,d0		; into a table of 256 (the rest 0)
	bsr	VAlloc
	beq	.no
	move.l	d0,a1
	move.l	8(a5),a0
	move.l	a1,8(a5)
	move.l	d4,d0
	subq.l	#1,d0
.pc:	move.l	(a0)+,(a1)+
	dbf	d0,.pc
	move.l	4(a5),d0		; the packed width
	moveq	#1,d1
	lsl.l	d0,d1
	add.l	d1,d6
	subq.l	#1,d6
	lsr.l	d0,d6
	bra	.tr
.image:	; the image itself, then the transforms undone, last first
	move.l	d6,d0
	move.l	d7,d1
	move.l	a6,a0
	moveq	#1,d4
	bsr	Entropy
	beq.s	.no
	move.l	g_VNTrans(a4),d5
.undo:	subq.l	#1,d5
	bmi.s	.ok
	move.l	d5,d0
	lsl.l	#4,d0
	lea	g_VTrans(a4,d0.l),a5
	move.l	a6,a0
	move.l	12(a5),d0		; its width
	move.l	d7,d1
	move.l	(a5),d4
	bne.s	.u1
	bsr	UnPredict
	bra.s	.undo
.u1:	subq.l	#1,d4
	bne.s	.u2
	bsr	UnCross
	bra.s	.undo
.u2:	subq.l	#1,d4
	bne.s	.u3
	bsr	UnGreen
	bra.s	.undo
.u3:	bsr	UnIndex
	bra.s	.undo
.ok:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d4-d7/a5-a6
	rts
.div:	moveq	#1,d0			; d4 = ceil(d4 / 2^bits) (4(a5))
	move.l	4(a5),d1
	lsl.l	d1,d0
	add.l	d0,d4
	subq.l	#1,d4
	lsr.l	d1,d4
	rts

; SubImage - a sub-image (no transforms, no meta codes) of d0 x d1
; Out: d0 = its pixels or 0 (CCR set)
SubImage:
	movem.l	d4-d7,-(sp)
	move.l	d0,d6
	move.l	d1,d7
	mulu.l	d1,d0
	cmp.l	#PIC_MAXPIX,d0
	bhi.s	.no
	lsl.l	#2,d0
	bsr	VAlloc
	beq.s	.no
	move.l	d0,d5
	move.l	d0,a0
	move.l	d6,d0
	move.l	d7,d1
	moveq	#0,d4
	bsr	Entropy
	beq.s	.no
	move.l	d5,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d4-d7
	rts

;--------------------------------------------------------------------
; Entropy - an entropy-coded image: colour cache, meta codes (d4 = 1:
; level 0), the prefix codes, the pixels
; In:  d0 = width, d1 = height, a0 = the pixels
; Out: d0 = 1 if decoded (CCR set)
;--------------------------------------------------------------------
Entropy:
	movem.l	d4-d7/a5-a6,-(sp)
	lea	-LV_SIZEOF(sp),sp
	move.l	sp,a5			; a5 = this level
	move.l	d0,lv_W(a5)
	move.l	d1,lv_H(a5)
	move.l	a0,lv_Out(a5)
	move.l	d4,lv_Level0(a5)
	mulu.l	d1,d0
	move.l	d0,lv_Total(a5)
	clr.l	lv_CBits(a5)
	clr.l	lv_MBits(a5)
	moveq	#1,d0			; colour cache
	bsr	VBits
	tst.l	d0
	beq.s	.nocc
	moveq	#4,d0
	bsr	VBits
	tst.l	d0
	beq	.no
	cmp.l	#11,d0
	bhi	.no
	move.l	d0,lv_CBits(a5)
	moveq	#4,d1
	lsl.l	d0,d1
	move.l	d1,d0
	bsr	VAlloc
	move.l	d0,lv_Cache(a5)
	beq	.no
.nocc:	moveq	#1,d6			; groups
	tst.l	lv_Level0(a5)
	beq.s	.codes
	moveq	#1,d0			; meta prefix codes?
	bsr	VBits
	tst.l	d0
	beq.s	.codes
	moveq	#3,d0
	bsr	VBits
	addq.l	#2,d0
	move.l	d0,lv_MBits(a5)
	moveq	#1,d1			; the entropy image
	lsl.l	d0,d1
	move.l	lv_W(a5),d4
	add.l	d1,d4
	subq.l	#1,d4
	lsr.l	d0,d4
	move.l	d4,lv_MW(a5)
	move.l	lv_H(a5),d5
	add.l	d1,d5
	subq.l	#1,d5
	lsr.l	d0,d5
	move.l	d4,d0
	move.l	d5,d1
	bsr	SubImage
	move.l	d0,lv_Meta(a5)
	beq	.no
	move.l	d0,a0			; group numbers: (pixel >> 8) & $ffff
	mulu.l	d5,d4
	moveq	#0,d6			; largest + 1
.mg:	move.l	(a0),d0
	lsr.l	#8,d0
	and.l	#$ffff,d0
	move.l	d0,(a0)+
	cmp.l	d6,d0
	blo.s	.mgn
	move.l	d0,d6
	addq.l	#1,d6
.mgn:	subq.l	#1,d4
	bne.s	.mg
.codes:	move.l	d6,lv_NGroups(a5)
	move.l	d6,d0			; 5 code pointers a group
	mulu.l	#20,d0
	bsr	VAlloc
	move.l	d0,lv_Groups(a5)
	beq	.no
	move.l	d0,a6
.grp:	moveq	#0,d5			; the five codes
.g5:	move.l	d5,d0
	moveq	#0,d1
	move.w	Alpha(pc,d0.l*2),d1	; alphabet size
	tst.l	d5
	bne.s	.al
	moveq	#1,d0			; green: + 24 + the cache
	move.l	lv_CBits(a5),d4
	beq.s	.al
	lsl.l	d4,d0
	add.l	d0,d1
.al:	move.l	d1,d0
	bsr	ReadCode		; d0 = the code
	move.l	d0,(a6)+
	beq	.no
	addq.l	#1,d5
	cmp.l	#5,d5
	blo.s	.g5
	subq.l	#1,d6
	bne.s	.grp
	bsr	Pixels
	bra.s	.x
.no:	moveq	#0,d0
.x:	lea	LV_SIZEOF(sp),sp
	movem.l	(sp)+,d4-d7/a5-a6
	rts
Alpha:	dc.w	256+24,256,256,256,40

;--------------------------------------------------------------------
; Pixels - the pixels of level a5
; Out: d0 = 1 if decoded (CCR set)
; d4 = x, d5 = y, d6 = position, a6 = the group, a0/a1 scratch
;--------------------------------------------------------------------
Pixels:
	movem.l	d4-d7/a6,-(sp)
	moveq	#0,d4
	moveq	#0,d5
	moveq	#0,d6
	move.l	lv_Groups(a5),a6
.next:	cmp.l	lv_Total(a5),d6
	bhs	.done
	cmp.l	#OVER,g_VOver(a4)
	bhi	.no
	tst.l	lv_MBits(a5)		; meta codes: the group of this block
	beq.s	.g
	bsr	Group
.g:	move.l	(a6),a0			; green (or length, or cache)
	bsr	VDecode
	cmp.l	#256,d0
	bhs.s	.ref
	move.l	d0,d7			; literal: green, red, blue, alpha
	lsl.l	#8,d7
	move.l	4(a6),a0
	bsr	VDecode
	swap	d0
	or.l	d0,d7
	move.l	8(a6),a0
	bsr	VDecode
	or.l	d0,d7
	move.l	12(a6),a0
	bsr	VDecode
	ror.l	#8,d0
	or.l	d7,d0
.put:	move.l	lv_Out(a5),a0		; a pixel
	move.l	d0,(a0,d6.l*4)
	bsr	CacheIn
	addq.l	#1,d6
	addq.l	#1,d4
	cmp.l	lv_W(a5),d4
	blo.s	.next
	moveq	#0,d4
	addq.l	#1,d5
	bra.s	.next
.ref:	sub.l	#256,d0
	cmp.l	#24,d0
	bhs.s	.cache
	bsr	Prefix			; copy: length,
	move.l	d0,d7
	move.l	16(a6),a0
	bsr	VDecode
	cmp.l	#40,d0
	bhs.s	.no
	bsr	Prefix			; ... distance code
	cmp.l	#120,d0
	bls.s	.plane
	sub.l	#120,d0
	bra.s	.dist
.plane:	lea	Plane-1(pc),a0		; a 2D distance: y << 4 | 8 - x
	moveq	#0,d1
	move.b	(a0,d0.l),d1
	move.l	d1,d0
	lsr.l	#4,d0
	mulu.l	lv_W(a5),d0
	and.l	#$0f,d1
	subq.l	#8,d1
	sub.l	d1,d0
	bgt.s	.dist
	moveq	#1,d0
.dist:	cmp.l	d6,d0			; not before the start
	bhi	.no
	move.l	lv_Out(a5),a0
	lea	(a0,d6.l*4),a1		; a1 = here
	move.l	d6,d1
	sub.l	d0,d1
	lea	(a0,d1.l*4),a0		; a0 = the source
.cp:	cmp.l	lv_Total(a5),d6
	bhs.s	.done
	move.l	(a0)+,d0
	move.l	d0,(a1)+
	bsr	CacheIn
	addq.l	#1,d6
	addq.l	#1,d4
	cmp.l	lv_W(a5),d4
	blo.s	.cn
	moveq	#0,d4
	addq.l	#1,d5
.cn:	subq.l	#1,d7
	bne.s	.cp
	tst.l	lv_MBits(a5)
	beq	.next
	bsr	Group			; (the group may change in a copy)
	bra	.next
.cache:	sub.l	#24,d0			; a colour of the cache
	move.l	lv_CBits(a5),d1
	beq.s	.no
	moveq	#1,d7
	lsl.l	d1,d7
	cmp.l	d7,d0
	bhs.s	.no
	move.l	lv_Cache(a5),a0
	move.l	(a0,d0.l*4),d0
	bra	.put
.done:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d4-d7/a6
	rts

; Group - a6 = the group of position d4/d5 (level a5)
Group:
	move.l	lv_MBits(a5),d1
	move.l	d5,d0			; (y >> bits) * width + (x >> bits)
	lsr.l	d1,d0
	mulu.l	lv_MW(a5),d0
	move.l	d0,-(sp)
	move.l	d4,d0
	lsr.l	d1,d0
	add.l	(sp)+,d0
	move.l	lv_Meta(a5),a0
	move.l	(a0,d0.l*4),d0
	mulu.l	#20,d0
	move.l	lv_Groups(a5),a6
	add.l	d0,a6
	rts

; CacheIn - put colour d0 into the cache of level a5 (d0, a0, a1 kept)
CacheIn:
	move.l	lv_CBits(a5),d1
	beq.s	.x
	movem.l	d0/d2/a0,-(sp)
	mulu.l	#$1e35a7bd,d0
	moveq	#32,d2
	sub.l	d1,d2
	lsr.l	d2,d0
	move.l	lv_Cache(a5),a0
	move.l	(sp),(a0,d0.l*4)
	movem.l	(sp)+,d0/d2/a0
.x:	rts

; Prefix - a length or distance from its prefix code d0 (and extra bits)
; Out: d0 (a5, a6 kept)
Prefix:
	cmp.l	#4,d0
	bhs.s	.e
	addq.l	#1,d0
	rts
.e:	move.l	d0,d1			; extra = (code - 2) >> 1
	subq.l	#2,d1
	lsr.l	#1,d1
	and.l	#1,d0			; offset = (2 + (code & 1)) << extra
	addq.l	#2,d0
	lsl.l	d1,d0
	move.l	d0,-(sp)
	move.l	d1,d0
	bsr	VBits
	add.l	(sp)+,d0
	addq.l	#1,d0
	rts

; 2D distances: y << 4 | 8 - x (as libwebp's kCodeToPlane)
Plane:	dc.b	$18,$07,$17,$19,$28,$06,$27,$29,$16,$1a
	dc.b	$26,$2a,$38,$05,$37,$39,$15,$1b,$36,$3a
	dc.b	$25,$2b,$48,$04,$47,$49,$14,$1c,$35,$3b
	dc.b	$46,$4a,$24,$2c,$58,$45,$4b,$34,$3c,$03
	dc.b	$57,$59,$13,$1d,$56,$5a,$23,$2d,$44,$4c
	dc.b	$55,$5b,$33,$3d,$68,$02,$67,$69,$12,$1e
	dc.b	$66,$6a,$22,$2e,$54,$5c,$43,$4d,$65,$6b
	dc.b	$32,$3e,$78,$01,$77,$79,$53,$5d,$11,$1f
	dc.b	$64,$6c,$42,$4e,$76,$7a,$21,$2f,$75,$7b
	dc.b	$31,$3f,$63,$6d,$52,$5e,$00,$74,$7c,$41
	dc.b	$4f,$10,$20,$62,$6e,$30,$73,$7d,$51,$5f
	dc.b	$40,$72,$7e,$61,$6f,$50,$71,$7f,$60,$70
	even

;--------------------------------------------------------------------
; ReadCode - read a prefix code of d0 symbols
; Out: d0 = the code (lh_), 0 if damaged (CCR set); a5, a6 kept
;--------------------------------------------------------------------
ReadCode:
	movem.l	d4-d7/a5-a6,-(sp)
	move.l	d0,d7			; d7 = symbols
	bsr	VAlloc			; their lengths
	beq	.no
	move.l	d0,a6			; a6 = lengths
	moveq	#1,d0
	bsr	VBits
	tst.l	d0
	beq.s	.normal
	moveq	#1,d0			; simple: 1 or 2 symbols
	bsr	VBits
	move.l	d0,d5
	moveq	#1,d0
	bsr	VBits
	move.l	d0,d1			; the first: 1 or 8 bits
	lsl.l	#3,d1
	sub.l	d0,d1
	addq.l	#1,d1
	move.l	d1,d0
	bsr	VBits
	cmp.l	d7,d0
	bhs	.no
	move.b	#1,(a6,d0.l)
	tst.l	d5
	beq	.build
	moveq	#8,d0
	bsr	VBits
	cmp.l	d7,d0
	bhs	.no
	move.b	#1,(a6,d0.l)
	bra	.build
.normal:
	moveq	#4,d0			; the code length code
	bsr	VBits
	addq.l	#4,d0
	move.l	d0,d6
	lea	-20(sp),sp
	move.l	sp,a5
	moveq	#20/4-1,d0
.cz:	clr.l	(a5)+
	dbf	d0,.cz
	move.l	sp,a5
	moveq	#0,d4
.cl:	moveq	#3,d0
	bsr	VBits
	lea	ClOrder(pc),a0
	moveq	#0,d1
	move.b	(a0,d4.l),d1
	move.b	d0,(a5,d1.l)
	addq.l	#1,d4
	cmp.l	d6,d4
	blo.s	.cl
	move.l	a5,a1
	moveq	#19,d0
	bsr	VBuild
	lea	20(sp),sp
	move.l	d0,a5			; a5 = the code length code
	beq	.no
	move.l	d7,d6			; d6 = most code lengths to read
	moveq	#1,d0
	bsr	VBits
	tst.l	d0
	beq.s	.lens
	moveq	#3,d0
	bsr	VBits
	add.l	d0,d0
	addq.l	#2,d0
	bsr	VBits
	addq.l	#2,d0
	move.l	d0,d6
	cmp.l	d7,d6
	bhi	.no
.lens:	moveq	#8,d5			; d5 = the previous length
	moveq	#0,d4			; d4 = symbol
.ln:	cmp.l	d7,d4
	bhs.s	.build
	subq.l	#1,d6
	bmi.s	.build
	move.l	a5,a0
	bsr	VDecode
	cmp.l	#16,d0
	bhs.s	.rep
	move.b	d0,(a6,d4.l)
	addq.l	#1,d4
	tst.l	d0
	beq.s	.ln
	move.l	d0,d5
	bra.s	.ln
.rep:	move.l	d0,d1
	moveq	#0,d0			; 16: the previous 3-6 times
	move.l	d5,-(sp)
	cmp.l	#16,d1
	beq.s	.r16
	clr.l	(sp)
	cmp.l	#17,d1
	beq.s	.r17
	moveq	#7,d0			; 18: zero 11-138 times
	bsr	VBits
	add.l	#11,d0
	bra.s	.rput
.r17:	moveq	#3,d0			; 17: zero 3-10 times
	bsr	VBits
	addq.l	#3,d0
	bra.s	.rput
.r16:	moveq	#2,d0
	bsr	VBits
	addq.l	#3,d0
.rput:	move.l	(sp)+,d1
	move.l	d4,a0
	add.l	d0,a0
	cmp.l	d7,a0
	bhi.s	.no
.rl:	move.b	d1,(a6,d4.l)
	addq.l	#1,d4
	subq.l	#1,d0
	bne.s	.rl
	bra.s	.ln
.build:	move.l	a6,a1
	move.l	d7,d0
	bsr	VBuild
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d4-d7/a5-a6
	rts
ClOrder:	dc.b	17,18,0,1,2,3,4,5,16,6,7,8,9,10,11,12,13,14,15
	even

;--------------------------------------------------------------------
; VBuild - a prefix code from d0 code lengths (bytes) at a1
; Out: d0 = the code (allocated), 0 if not usable (CCR set)
;--------------------------------------------------------------------
VBuild:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	a1,a3
	move.l	d0,d7			; symbols
	moveq	#0,d6			; codes, and the last symbol with one
	moveq	#0,d1
.n:	cmp.l	d7,d1
	bhs.s	.nd
	tst.b	(a3,d1.l)
	beq.s	.nn
	addq.l	#1,d6
	move.l	d1,d5
.nn:	addq.l	#1,d1
	bra.s	.n
.nd:	tst.l	d6
	beq	.no
	move.l	d6,d0
	add.l	d0,d0
	add.l	#LH_SIZEOF,d0
	bsr	VAlloc
	beq	.no
	move.l	d0,a2			; a2 = the code
	cmp.l	#1,d6			; one symbol: no bits
	bne.s	.many
	addq.l	#1,d5
	move.w	d5,lh_Single(a2)
	bra	.ok
.many:	moveq	#0,d1			; counts
.c1:	cmp.l	d7,d1
	bhs.s	.c2
	moveq	#0,d0
	move.b	(a3,d1.l),d0
	cmp.b	#15,d0
	bhi	.no
	addq.w	#1,lh_Count(a2,d0.l*2)
	addq.l	#1,d1
	bra.s	.c1
.c2:	clr.w	lh_Count(a2)
	lea	-32(sp),sp		; offsets by length; symbols sorted
	moveq	#0,d0
	moveq	#1,d1
.o:	move.w	d0,(sp,d1.l*2)
	add.w	lh_Count(a2,d1.l*2),d0
	addq.l	#1,d1
	cmp.l	#16,d1
	blo.s	.o
	moveq	#0,d1
.s:	cmp.l	d7,d1
	bhs.s	.f
	moveq	#0,d0
	move.b	(a3,d1.l),d0
	beq.s	.sn
	move.w	(sp,d0.l*2),d2
	addq.w	#1,(sp,d0.l*2)
	move.w	d1,lh_Sym(a2,d2.w*2)
.sn:	addq.l	#1,d1
	bra.s	.s
.f:	lea	32(sp),sp
	moveq	#0,d4			; the fast table
	moveq	#0,d5
	moveq	#1,d6
.len:	moveq	#0,d7
	move.w	lh_Count(a2,d6.l*2),d7
	bra.s	.ne
.c:	moveq	#1,d0
	lsl.l	d6,d0
	cmp.l	d0,d4
	bhs.s	.no			; too many codes
	cmp.l	#LFAST,d6
	bhi.s	.skip
	move.l	d4,d0			; reversed
	moveq	#0,d1
	move.l	d6,d2
.r:	lsr.l	#1,d0
	addx.l	d1,d1
	subq.l	#1,d2
	bne.s	.r
	move.w	lh_Sym(a2,d5.l*2),d0
	move.w	d6,d2
	lsl.w	#8,d2
	lsl.w	#4,d2
	or.w	d2,d0
	moveq	#1,d2
	lsl.l	d6,d2
.fill:	move.w	d0,lh_Fast(a2,d1.l*2)
	add.l	d2,d1
	cmp.l	#1<<LFAST,d1
	blo.s	.fill
.skip:	addq.l	#1,d4
	addq.l	#1,d5
.ne:	dbf	d7,.c
	add.l	d4,d4
	addq.l	#1,d6
	cmp.l	#15,d6
	bls.s	.len
.ok:	move.l	a2,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

;--------------------------------------------------------------------
; VDecode - the next symbol of code a0; Out: d0 (-1: no code) (a5, a6
; kept)
;--------------------------------------------------------------------
VDecode:
	moveq	#0,d0
	move.w	lh_Single(a0),d0
	beq.s	.n
	subq.l	#1,d0
	rts
.n:	cmp.l	#15,d3
	bge.s	.h
	bsr	VFill
.h:	move.w	d2,d0
	and.w	#(1<<LFAST)-1,d0
	move.w	lh_Fast(a0,d0.w*2),d0
	beq.s	.slow
	moveq	#0,d1
	move.w	d0,d1
	lsr.w	#8,d1
	lsr.w	#4,d1
	lsr.l	d1,d2
	sub.l	d1,d3
	and.l	#$fff,d0
	rts
.slow:	movem.l	d4-d6,-(sp)		; bit by bit (canonical)
	moveq	#0,d0
	moveq	#0,d4
	moveq	#0,d5
	moveq	#1,d6
.l:	moveq	#1,d1
	and.l	d2,d1
	or.l	d1,d0
	lsr.l	#1,d2
	subq.l	#1,d3
	moveq	#0,d1
	move.w	lh_Count(a0,d6.l*2),d1
	move.l	d4,a1
	add.l	d1,a1
	cmp.l	a1,d0
	blt.s	.found
	add.l	d1,d5
	move.l	a1,d4
	add.l	d4,d4
	add.l	d0,d0
	addq.l	#1,d6
	cmp.l	#15,d6
	bls.s	.l
	moveq	#-1,d0
	bra.s	.x
.found:	sub.l	d4,d0
	add.l	d5,d0
	move.w	lh_Sym(a0,d0.l*2),d0
	and.l	#$ffff,d0
.x:	movem.l	(sp)+,d4-d6
	rts

; VFill - at least 25 bits in d2 (a5, a6 kept)
VFill:
.l:	cmp.l	#24,d3
	bgt.s	.x
	cmp.l	a3,a2
	bhs.s	.over
	moveq	#0,d0
	move.b	(a2)+,d0
	lsl.l	d3,d0
	or.l	d0,d2
	addq.l	#8,d3
	bra.s	.l
.over:	addq.l	#1,g_VOver(a4)
	addq.l	#8,d3
	bra.s	.l
.x:	rts

; VBits - the next d0 bits (up to 16); Out: d0 (a5, a6 kept)
VBits:
	tst.l	d0
	beq.s	.x
	cmp.l	d0,d3
	bge.s	.h
	move.l	d0,-(sp)
	bsr.s	VFill
	move.l	(sp)+,d0
.h:	moveq	#1,d1
	lsl.l	d0,d1
	subq.l	#1,d1
	and.l	d2,d1
	lsr.l	d0,d2
	sub.l	d0,d3
	move.l	d1,d0
.x:	rts

;--------------------------------------------------------------------
; VAlloc - cleared memory, freed by VFreeAll
; In:  d0 = size; Out: d0 = memory or 0 (CCR set); a6 kept (the
; library call would change it)
;--------------------------------------------------------------------
VAlloc:
	move.l	a6,-(sp)
	addq.l	#4,d0
	jsr	PicAlloc
	beq.s	.x
	move.l	d0,a0
	move.l	g_VChain(a4),(a0)
	move.l	a0,g_VChain(a4)
	addq.l	#4,d0
.x:	movem.l	(sp)+,a6
	rts

; VFreeAll - free all VAlloc memory
VFreeAll:
	move.l	g_VChain(a4),d0
	beq.s	.x
	move.l	d0,a1
	move.l	(a1),g_VChain(a4)
	jsr	PicFreeMem
	bra.s	VFreeAll
.x:	rts

; AddPix - d0 + d1, each channel modulo 256; Out: d0 (d1 kept)
AddPix:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	and.l	#$00ff00ff,d2
	move.l	d1,d3
	and.l	#$00ff00ff,d3
	add.l	d3,d2
	and.l	#$00ff00ff,d2
	and.l	#$ff00ff00,d0
	move.l	d1,d3
	and.l	#$ff00ff00,d3
	add.l	d3,d0
	and.l	#$ff00ff00,d0
	or.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

; Avg2 - the average of d0 and d1, each channel (rounded down)
; Out: d0 (d1, a1 kept)
Avg2:
	move.l	d2,-(sp)
	move.l	d0,d2
	and.l	d1,d2			; a & b
	eor.l	d1,d0
	and.l	#$fefefefe,d0
	lsr.l	#1,d0			; + (a ^ b) / 2
	add.l	d2,d0
	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; the inverse transforms: a0 = pixels, d0 = width, d1 = height,
; a5 = the transform (type, bits, data, width)
;--------------------------------------------------------------------

; UnPredict - add each pixel's prediction (mode by block, 14 modes)
UnPredict:
	movem.l	d2-d7/a2-a3/a6,-(sp)
	move.l	a0,a2			; a2 = pixel
	move.l	d0,d6			; d6 = width
	move.l	d1,d7			; d7 = rows
	move.l	d6,d5
	lsl.l	#2,d5			; d5 = bytes a row
	move.l	4(a5),d0		; blocks across
	moveq	#1,d1
	lsl.l	d0,d1
	move.l	d6,d4
	add.l	d1,d4
	subq.l	#1,d4
	lsr.l	d0,d4
	move.l	d4,g_VBw(a4)
	; the first row: opaque black, then the left one
	move.l	(a2),d0
	move.l	#$ff000000,d1
	bsr	AddPix
	move.l	d0,(a2)+
	move.l	d6,d4
	subq.l	#1,d4
	bra.s	.r0e
.r0:	move.l	(a2),d0
	move.l	-4(a2),d1
	bsr	AddPix
	move.l	d0,(a2)+
.r0e:	dbf	d4,.r0
	moveq	#1,d3			; d3 = row
.row:	cmp.l	d7,d3
	bhs	.x
	move.l	d3,d0			; a3 = this row's modes
	move.l	4(a5),d1
	lsr.l	d1,d0
	mulu.l	g_VBw(a4),d0
	move.l	8(a5),a3
	lea	(a3,d0.l*4),a3
	move.l	(a2),d0			; the first pixel: the one above
	move.l	a2,a0
	sub.l	d5,a0
	move.l	(a0),d1
	bsr	AddPix
	move.l	d0,(a2)+
	moveq	#1,d4			; d4 = x
.px:	cmp.l	d6,d4
	bhs.s	.rn
	move.l	d4,d0
	move.l	4(a5),d1
	lsr.l	d1,d0
	move.l	(a3,d0.l*4),d0
	lsr.l	#8,d0
	and.w	#15,d0
	move.l	a2,a1			; a1 = above
	sub.l	d5,a1
	move.w	.modes(pc,d0.w*2),d0
	jsr	.modes(pc,d0.w)		; d0 = the prediction
	move.l	d0,d1
	move.l	(a2),d0
	bsr	AddPix
	move.l	d0,(a2)+
	addq.l	#1,d4
	bra.s	.px
.rn:	addq.l	#1,d3
	bra.s	.row
.x:	movem.l	(sp)+,d2-d7/a2-a3/a6
	rts
.modes:	dc.w	P0-.modes,P1-.modes,P2-.modes,P3-.modes,P4-.modes
	dc.w	P5-.modes,P6-.modes,P7-.modes,P8-.modes,P9-.modes
	dc.w	P10-.modes,P11-.modes,P12-.modes,P13-.modes
	dc.w	P0-.modes,P0-.modes

; the predictors: a2 = the pixel, a1 = the one above; Out: d0
L	equ	-4			; (offsets: left from a2,
T	equ	0			;  top, top left, top right from a1)
TL	equ	-4
TR	equ	4
P0:	move.l	#$ff000000,d0
	rts
P1:	move.l	L(a2),d0
	rts
P2:	move.l	T(a1),d0
	rts
P3:	move.l	TR(a1),d0
	rts
P4:	move.l	TL(a1),d0
	rts
P5:	move.l	L(a2),d0		; avg(avg(L, TR), T)
	move.l	TR(a1),d1
	bsr	Avg2
	move.l	T(a1),d1
	bra	Avg2
P6:	move.l	L(a2),d0
	move.l	TL(a1),d1
	bra	Avg2
P7:	move.l	L(a2),d0
	move.l	T(a1),d1
	bra	Avg2
P8:	move.l	TL(a1),d0
	move.l	T(a1),d1
	bra	Avg2
P9:	move.l	T(a1),d0
	move.l	TR(a1),d1
	bra	Avg2
P10:	move.l	L(a2),d0		; avg(avg(L, TL), avg(T, TR))
	move.l	TL(a1),d1
	bsr	Avg2
	move.l	d0,-(sp)
	move.l	T(a1),d0
	move.l	TR(a1),d1
	bsr	Avg2
	move.l	(sp)+,d1
	bra	Avg2
P11:	; select: L or T, the one nearer to L + T - TL
	movem.l	d2-d4,-(sp)
	moveq	#0,d2			; distance of L: sum |T - TL|
	moveq	#0,d3			; distance of T: sum |L - TL|
	moveq	#4-1,d4
.ch:	moveq	#0,d0
	move.b	T(a1,d4.l),d0
	moveq	#0,d1
	move.b	TL(a1,d4.l),d1
	sub.l	d1,d0
	bpl.s	.a
	neg.l	d0
.a:	add.l	d0,d2
	moveq	#0,d0
	move.b	L(a2,d4.l),d0
	sub.l	d1,d0
	bpl.s	.b
	neg.l	d0
.b:	add.l	d0,d3
	dbf	d4,.ch
	move.l	L(a2),d0
	cmp.l	d3,d2
	blt.s	.l
	move.l	T(a1),d0
.l:	movem.l	(sp)+,d2-d4
	rts
P12:	; clamp(L + T - TL) per channel
	movem.l	d2-d4,-(sp)
	moveq	#0,d2
	moveq	#24,d4			; channel shift
.ch:	move.l	L(a2),d0
	lsr.l	d4,d0
	and.l	#$ff,d0
	move.l	T(a1),d1
	lsr.l	d4,d1
	and.l	#$ff,d1
	add.l	d1,d0
	move.l	TL(a1),d1
	lsr.l	d4,d1
	and.l	#$ff,d1
	sub.l	d1,d0
	bsr	Clamp
	lsl.l	d4,d0
	or.l	d0,d2
	subq.l	#8,d4
	bpl.s	.ch
	move.l	d2,d0
	movem.l	(sp)+,d2-d4
	rts
P13:	; clamp(a + (a - TL) / 2), a = avg(L, T)
	movem.l	d2-d4,-(sp)
	move.l	L(a2),d0
	move.l	T(a1),d1
	bsr	Avg2
	move.l	d0,d3			; a
	moveq	#0,d2
	moveq	#24,d4			; channel shift
.ch:	move.l	d3,d0
	lsr.l	d4,d0
	and.l	#$ff,d0
	move.l	TL(a1),d1
	lsr.l	d4,d1
	and.l	#$ff,d1
	neg.l	d1
	add.l	d0,d1			; a - TL
	bpl.s	.p
	addq.l	#1,d1			; (division towards zero)
.p:	asr.l	#1,d1
	add.l	d1,d0
	bsr	Clamp
	lsl.l	d4,d0
	or.l	d0,d2
	subq.l	#8,d4
	bpl.s	.ch
	move.l	d2,d0
	movem.l	(sp)+,d2-d4
	rts

; Clamp - d0 to 0..255; Out: d0 (d1 kept)
Clamp:
	tst.l	d0
	bpl.s	.p
	moveq	#0,d0
	rts
.p:	cmp.l	#255,d0
	bls.s	.x
	move.l	#255,d0
.x:	rts

; UnCross - the colour transform: red and blue from green (and red)
UnCross:
	movem.l	d2-d7/a2-a3/a6,-(sp)
	move.l	a0,a6
	move.l	d0,d6
	move.l	d1,d7
	move.l	4(a5),d0		; blocks across
	moveq	#1,d1
	lsl.l	d0,d1
	move.l	d6,d4
	add.l	d1,d4
	subq.l	#1,d4
	lsr.l	d0,d4
	move.l	d4,g_VBw(a4)
	moveq	#0,d3			; row
.row:	cmp.l	d7,d3
	bhs	.x
	move.l	d3,d0
	move.l	4(a5),d1
	lsr.l	d1,d0
	mulu.l	g_VBw(a4),d0
	move.l	8(a5),a3
	lea	(a3,d0.l*4),a3
	moveq	#0,d4			; x
.px:	cmp.l	d6,d4
	bhs.s	.rn
	move.l	d4,d0
	move.l	4(a5),d1
	lsr.l	d1,d0
	move.l	(a3,d0.l*4),d5		; d5 = element: r2b g2b g2r
	move.l	(a6),d2			; the pixel
	move.l	d2,d0
	lsr.l	#8,d0
	ext.w	d0			; (signed green)
	move.b	d5,d1			; red += g2r * green >> 5
	ext.w	d1
	muls.w	d0,d1
	asr.l	#5,d1
	swap	d2
	add.b	d1,d2			; (red: low byte after the swap)
	swap	d2
	move.l	d5,d1			; blue += g2b * green >> 5
	lsr.l	#8,d1
	ext.w	d1
	muls.w	d0,d1
	asr.l	#5,d1
	add.b	d1,d2
	move.l	d5,d1			; blue += r2b * red (new) >> 5
	swap	d1
	ext.w	d1
	move.l	d2,d0
	swap	d0
	ext.w	d0
	muls.w	d0,d1
	asr.l	#5,d1
	add.b	d1,d2
	move.l	d2,(a6)+
	addq.l	#1,d4
	bra.s	.px
.rn:	addq.l	#1,d3
	bra.s	.row
.x:	movem.l	(sp)+,d2-d7/a2-a3/a6
	rts

; UnGreen - add green to red and blue
UnGreen:
	mulu.l	d1,d0
	bra.s	.e
.l:	move.l	(a0),d1
	lsr.l	#8,d1
	and.l	#$ff,d1
	move.l	d1,-(sp)
	swap	d1
	or.l	(sp)+,d1		; green in both
	move.l	d2,-(sp)
	move.l	(a0),d2
	and.l	#$00ff00ff,d2
	add.l	d1,d2
	and.l	#$00ff00ff,d2
	move.l	(a0),d1
	and.l	#$ff00ff00,d1
	or.l	d2,d1
	move.l	d1,(a0)+
	move.l	(sp)+,d2
.e:	subq.l	#1,d0
	bpl.s	.l
	rts

; UnIndex - colour indexing: the palette's colours, pixels unpacked
; (from the end backwards: they spread out over the packed ones)
UnIndex:
	movem.l	d2-d7/a2-a3/a6,-(sp)
	move.l	a0,a6			; a6 = pixels
	move.l	d0,d6			; d6 = the real width
	move.l	d1,d7			; d7 = rows
	move.l	4(a5),d5		; d5 = bits (packing)
	moveq	#1,d0			; packed width
	lsl.l	d5,d0
	move.l	d6,d4
	add.l	d0,d4
	subq.l	#1,d4
	lsr.l	d5,d4
	move.l	d4,g_VBw(a4)
	moveq	#8,d2			; bits an index
	lsr.l	d5,d2
	move.l	8(a5),a3		; a3 = the palette (256)
	move.l	d7,d3			; row
.row:	subq.l	#1,d3
	bmi.s	.x
	move.l	d6,d4			; x
.px:	subq.l	#1,d4
	bmi.s	.row
	move.l	d3,d0			; the packed pixel
	mulu.l	g_VBw(a4),d0
	move.l	d4,d1
	lsr.l	d5,d1
	add.l	d1,d0
	move.l	(a6,d0.l*4),d0
	lsr.l	#8,d0
	and.l	#$ff,d0			; green
	moveq	#1,d1			; index: bits (x & (2^bits - 1))
	lsl.l	d5,d1
	subq.l	#1,d1
	and.l	d4,d1
	mulu.w	d2,d1
	lsr.l	d1,d0
	moveq	#1,d1
	lsl.l	d2,d1
	subq.l	#1,d1
	and.l	d1,d0
	move.l	(a3,d0.l*4),d0
	move.l	d3,d1
	mulu.l	d6,d1
	add.l	d4,d1
	move.l	d0,(a6,d1.l*4)
	bra.s	.px
.x:	movem.l	(sp)+,d2-d7/a2-a3/a6
	rts
