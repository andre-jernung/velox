;
; png.s - PNG decoder: all colour types and bit depths, transparency
; (alpha, tRNS), Adam7 interlacing.  The IDAT chunks are joined and
; inflated at once; the rows are unfiltered in place and converted to
; ARGB.  A file cut short shows what it has.
;

	include	"velox.i"

	xdef	PngInfo,PngDecode
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	PicNew,PicAlloc,PicFreeMem,Inflate

	section	code,code

;--------------------------------------------------------------------
; PngInfo - In: a0 = data; Out: d0 = width, d1 = height (IHDR)
;--------------------------------------------------------------------
PngInfo:
	cmp.l	#'IHDR',12(a0)
	bne.s	.no
	move.l	16(a0),d0
	move.l	20(a0),d1
	rts
.no:	moveq	#0,d0
	moveq	#0,d1
	rts

;--------------------------------------------------------------------
; PngDecode - In: a0 = data, d0 = length; Out: d0 = 1 if decoded
;--------------------------------------------------------------------
PngDecode:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	lea	(a0,d0.l),a5		; a5 = end
	lea	8(a0),a2		; the chunks
	move.l	a2,g_PngFirst(a4)	; (again, for the IDATs)
	clr.l	g_PngIdat(a4)
	clr.l	g_PngRaw(a4)
	clr.l	g_PngGrey(a4)
	clr.l	g_PngTrns(a4)
	clr.l	g_PngW(a4)
	moveq	#0,d7			; d7 = length of the IDATs
	lea	g_GifPal(a4),a0		; the palette: opaque black
	move.w	#255,d0
.pc:	move.l	#$ff000000,(a0)+
	dbf	d0,.pc
.chunk:	lea	12(a2),a0		; length, type, CRC
	cmp.l	a5,a0
	bhi	.chunks
	move.l	(a2)+,d2		; d2 = length
	move.l	(a2)+,d3		; d3 = type
	move.l	a5,d0
	sub.l	a2,d0
	subq.l	#4,d0
	cmp.l	d0,d2			; (cut short: as far as it goes)
	bls.s	.len
	move.l	d0,d2
.len:	cmp.l	#'IHDR',d3
	beq	.ihdr
	cmp.l	#'PLTE',d3
	beq	.plte
	cmp.l	#'tRNS',d3
	beq	.trns
	cmp.l	#'IDAT',d3
	bne.s	.notid
	add.l	d2,d7
.notid:	cmp.l	#'IEND',d3
	beq.s	.chunks
.skip:	lea	4(a2,d2.l),a2
	bra.s	.chunk
.ihdr:	cmp.l	#13,d2
	blo	.fail
	move.l	(a2),g_PngW(a4)
	move.l	4(a2),g_PngH(a4)
	moveq	#0,d0
	move.b	8(a2),d0
	move.l	d0,g_PngDepth(a4)
	move.b	9(a2),d0
	move.l	d0,g_PngType(a4)
	move.b	12(a2),d0
	move.l	d0,g_PngLace(a4)
	tst.w	10(a2)			; compression, filter method 0
	bne	.fail
	bra.s	.skip
.plte:	move.l	d2,d0			; colours
	divu.w	#3,d0
	and.l	#$ffff,d0
	cmp.l	#256,d0
	bls.s	.pn
	move.l	#256,d0
.pn:	lea	g_GifPal(a4),a0
	move.l	a2,a1
	bra.s	.pe
.pl:	moveq	#-1,d1
	lsl.l	#8,d1
	move.b	(a1)+,d1
	lsl.l	#8,d1
	move.b	(a1)+,d1
	lsl.l	#8,d1
	move.b	(a1)+,d1
	move.l	d1,(a0)+
.pe:	dbf	d0,.pl
	bra.s	.skip
.trns:	move.l	g_PngType(a4),d0
	cmp.l	#3,d0
	bne.s	.tkey
	move.l	d2,d0			; palette alphas
	cmp.l	#256,d0
	bls.s	.ta
	move.l	#256,d0
.ta:	lea	g_GifPal(a4),a0
	move.l	a2,a1
	bra.s	.tae
.tal:	move.b	(a1)+,(a0)
	addq.l	#4,a0
.tae:	dbf	d0,.tal
	bra	.skip
.tkey:	tst.l	d0			; grey: one value that is clear
	bne.s	.tk2
	cmp.l	#2,d2
	blo	.skip
	move.w	(a2),g_PngKey(a4)
	bra.s	.tk
.tk2:	cmp.l	#2,d0			; colour: three values
	bne	.skip
	cmp.l	#6,d2
	blo	.skip
	move.w	(a2),g_PngKey(a4)
	move.w	2(a2),g_PngKey+2(a4)
	move.w	4(a2),g_PngKey+4(a4)
.tk:	moveq	#1,d0
	move.l	d0,g_PngTrns(a4)
	bra	.skip
.chunks:
	; the header must be sane: 8 bits for every type, 16 for all but
	; palettes, 1/2/4 for grey and palettes
	move.l	g_PngType(a4),d0
	cmp.l	#6,d0
	bhi	.fail
	moveq	#0,d1
	move.b	Chans(pc,d0.l),d1
	beq	.fail			; (types 1 and 5)
	move.l	d1,g_PngChans(a4)
	move.l	g_PngDepth(a4),d1
	cmp.l	#8,d1
	beq.s	.dok
	cmp.l	#16,d1
	bne.s	.dsm
	cmp.l	#3,d0
	beq	.fail
	bra.s	.dok
.dsm:	cmp.l	#1,d1
	beq.s	.d124
	cmp.l	#2,d1
	beq.s	.d124
	cmp.l	#4,d1
	bne	.fail
.d124:	tst.l	d0
	beq.s	.dok
	cmp.l	#3,d0
	bne	.fail
.dok:	; the IDATs, joined
	tst.l	d7
	beq	.fail
	move.l	d7,d0
	jsr	PicAlloc
	move.l	d0,g_PngIdat(a4)
	beq	.fail
	move.l	d0,a3			; a3 = the IDATs
	move.l	g_PngFirst(a4),a2
	move.l	a3,a1
.id:	lea	12(a2),a0
	cmp.l	a5,a0
	bhi.s	.joined
	move.l	(a2)+,d2
	move.l	(a2)+,d3
	move.l	a5,d0
	sub.l	a2,d0
	subq.l	#4,d0
	cmp.l	d0,d2
	bls.s	.il
	move.l	d0,d2
.il:	cmp.l	#'IDAT',d3
	bne.s	.in
	move.l	a2,a0
	move.l	d2,d0
	bra.s	.ice
.icl:	move.b	(a0)+,(a1)+
.ice:	subq.l	#1,d0
	bpl.s	.icl
.in:	cmp.l	#'IEND',d3
	beq.s	.joined
	lea	4(a2,d2.l),a2
	bra.s	.id
.joined:
	; zlib: deflate, no dictionary
	cmp.l	#2,d7
	bls	.fail
	moveq	#$0f,d0
	and.b	(a3),d0
	cmp.b	#8,d0
	bne	.fail
	btst	#5,1(a3)
	bne	.fail
	; the raw rows: their size, over the passes
	moveq	#0,d6			; d6 = size
	moveq	#0,d5			; pass
.sz:	bsr	PassSize		; d0 = width, d1 = height, d2 = bytes
	beq.s	.szn
	addq.l	#1,d2
	mulu.l	d1,d2
	add.l	d2,d6
.szn:	addq.l	#1,d5
	bsr	Passes
	cmp.l	d0,d5
	blo.s	.sz
	; inflate (cleared memory: missing rows stay 0)
	move.l	g_PngW(a4),d0		; + one row of zeros (the row
	mulu.l	g_PngChans(a4),d0	;   before the first)
	add.l	d0,d0
	add.l	#16,d0
	move.l	d0,g_PngZero(a4)
	addq.l	#4,d0			; (+4: the RGB loop reads a byte on)
	add.l	d6,d0
	jsr	PicAlloc
	move.l	d0,g_PngRaw(a4)
	beq	.fail
	lea	2(a3),a0
	move.l	d7,d0
	subq.l	#2,d0
	move.l	g_PngRaw(a4),a1
	add.l	g_PngZero(a4),a1
	move.l	d6,d1
	PROFB	5
	jsr	Inflate
	PROFE	5
	tst.l	d0			; (damaged: what came out is shown)
	bgt.s	.infl
	cmp.l	#-1,d0
	bne	.fail
.infl:	move.l	g_PngIdat(a4),a1	; the IDATs can go
	clr.l	g_PngIdat(a4)
	jsr	PicFreeMem
	move.l	g_PngW(a4),d0
	move.l	g_PngH(a4),d1
	jsr	PicNew
	beq	.fail
	; each pass: unfilter and convert its rows
	move.l	g_PngRaw(a4),a3
	add.l	g_PngZero(a4),a3	; a3 = the rows
	moveq	#0,d5
.pass:	bsr	PassSize
	beq.s	.pnext
	move.l	d0,g_PngPW(a4)
	move.l	d2,g_PngRB(a4)
	move.l	d1,d7			; rows
	move.l	g_PngRaw(a4),a6		; a6 = previous row (zeros)
	moveq	#0,d4			; row
.row:	move.b	(a3)+,d0		; filter
	move.l	a3,a0
	move.l	a6,a1
	PROFB	6
	bsr	Unfilter
	PROFE	6
	move.l	d4,d0
	PROFB	7
	bsr	Convert
	PROFE	7
	move.l	a3,a6
	add.l	g_PngRB(a4),a3
	addq.l	#1,d4
	cmp.l	d7,d4
	blo.s	.row
.pnext:	addq.l	#1,d5
	bsr	Passes
	cmp.l	d0,d5
	blo.s	.pass
	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	move.l	d0,d2
	move.l	g_PngIdat(a4),a1
	jsr	PicFreeMem
	move.l	g_PngRaw(a4),a1
	jsr	PicFreeMem
	move.l	d2,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; samples per pixel of each colour type
Chans:	dc.b	1,0,3,1,2,0,4
	even

; Passes - Out: d0 = passes (1, or 7 when interlaced)
Passes:
	moveq	#1,d0
	tst.l	g_PngLace(a4)
	beq.s	.x
	moveq	#7,d0
.x:	rts

; PassSize - the size of pass d5
; Out: d0 = width, d1 = height (0 if the pass is empty: Z set),
;      d2 = bytes in a row (without the filter byte)
PassSize:
	move.l	g_PngW(a4),d0
	move.l	g_PngH(a4),d1
	tst.l	g_PngLace(a4)
	beq.s	.bytes
	moveq	#0,d2			; (w - x0 + step - 1) / step
	move.b	Adam7(pc,d5.l*4),d2
	sub.l	d2,d0
	ble.s	.none
	move.b	Adam7+2(pc,d5.l*4),d2
	add.l	d2,d0
	subq.l	#1,d0
	divu.w	d2,d0
	and.l	#$ffff,d0
	move.b	Adam7+1(pc,d5.l*4),d2
	sub.l	d2,d1
	ble.s	.none
	move.b	Adam7+3(pc,d5.l*4),d2
	add.l	d2,d1
	subq.l	#1,d1
	divu.w	d2,d1
	and.l	#$ffff,d1
.bytes:	move.l	d0,d2			; (w * channels * depth + 7) / 8
	mulu.l	g_PngChans(a4),d2
	mulu.l	g_PngDepth(a4),d2
	addq.l	#7,d2
	lsr.l	#3,d2
	tst.l	d1
	rts
.none:	moveq	#0,d1
	rts

; Adam7 passes: x0, y0, x step, y step
Adam7:	dc.b	0,0,8,8, 4,0,8,8, 0,4,4,8, 2,0,4,4, 0,2,2,4, 1,0,2,2
	dc.b	0,1,1,2

;--------------------------------------------------------------------
; Unfilter - undo the filter d0 of row a0 (previous row a1), in place
;--------------------------------------------------------------------
Unfilter:
	movem.l	d2-d7,-(sp)
	move.l	g_PngChans(a4),d2	; d2 = bytes per pixel (at least 1)
	mulu.l	g_PngDepth(a4),d2
	lsr.l	#3,d2
	bne.s	.b
	moveq	#1,d2
.b:	move.l	d2,d5
	neg.l	d5			; d5 = -bpp: the pixel to the left
	move.l	g_PngRB(a4),d3		; d3 = bytes
	beq	.x
	cmp.b	#1,d0
	beq.s	.sub
	cmp.b	#2,d0
	beq.s	.up
	cmp.b	#3,d0
	beq.s	.avg
	cmp.b	#4,d0
	beq	.paeth
	bra	.x			; 0 (or unknown): as it is
.sub:	sub.l	d2,d3			; x += left
	ble	.x
	add.l	d2,a0
.sl:	move.b	(a0,d5.l),d0
	add.b	d0,(a0)+
	subq.l	#1,d3
	bne.s	.sl
	bra	.x
.up:	move.b	(a1)+,d0		; x += above
	add.b	d0,(a0)+
	subq.l	#1,d3
	bne.s	.up
	bra	.x
.avg:	move.l	d2,d1			; x += (left + above) / 2; the first
.a0:	move.b	(a1)+,d0		; pixel has no left
	lsr.b	#1,d0
	add.b	d0,(a0)+
	subq.l	#1,d3
	beq	.x
	subq.l	#1,d1
	bne.s	.a0
.ar:	moveq	#0,d0
	move.b	(a0,d5.l),d0
	moveq	#0,d1
	move.b	(a1)+,d1
	add.w	d1,d0
	lsr.w	#1,d0
	add.b	d0,(a0)+
	subq.l	#1,d3
	bne.s	.ar
	bra.s	.x
.paeth:	move.l	d2,d1			; the first pixel: x += above
.p0:	move.b	(a1)+,d0
	add.b	d0,(a0)+
	subq.l	#1,d3
	beq.s	.x
	subq.l	#1,d1
	bne.s	.p0
.pl:	moveq	#0,d0
	move.b	(a0,d5.l),d0		; a: left
	moveq	#0,d1
	move.b	(a1)+,d1		; b: above
	moveq	#0,d4
	move.b	-1(a1,d5.l),d4		; c: above left
	move.w	d1,d2
	sub.w	d4,d2			; p = b - c: pa = |p|
	move.w	d0,d6
	sub.w	d4,d6			; q = a - c: pb = |q|
	move.w	d2,d7
	add.w	d6,d7			; pc = |p + q|
	bpl.s	.a1
	neg.w	d7
.a1:	tst.w	d2
	bpl.s	.a2
	neg.w	d2
.a2:	tst.w	d6
	bpl.s	.a3
	neg.w	d6
.a3:	cmp.w	d6,d2			; pa <= pb and pa <= pc: a
	bhi.s	.nb
	cmp.w	d7,d2
	bls.s	.pp
.nb:	move.w	d1,d0			; pb <= pc: b, else c
	cmp.w	d7,d6
	bls.s	.pp
	move.w	d4,d0
.pp:	add.b	d0,(a0)+
	subq.l	#1,d3
	bne.s	.pl
.x:	movem.l	(sp)+,d2-d7
	rts

;--------------------------------------------------------------------
; Convert - row d0 of pass d5 (at a3, unfiltered) to ARGB pixels
;--------------------------------------------------------------------
Convert:
	movem.l	d2-d7/a2-a3,-(sp)
	moveq	#0,d1			; x0, y0, steps of the pass
	moveq	#0,d2
	moveq	#1,d3
	moveq	#1,d4
	tst.l	g_PngLace(a4)
	beq.s	.np
	move.b	Adam7(pc,d5.l*4),d1
	move.b	Adam7+1(pc,d5.l*4),d2
	move.b	Adam7+2(pc,d5.l*4),d3
	move.b	Adam7+3(pc,d5.l*4),d4
.np:	mulu.l	d4,d0			; y = y0 + row * step
	add.l	d2,d0
	mulu.l	g_PngW(a4),d0
	add.l	d1,d0
	move.l	g_PicData(a4),a2
	lea	(a2,d0.l*4),a2		; a2 = first pixel
	lsl.l	#2,d3
	move.l	d3,a1			; a1 = to the next pixel
	move.l	g_PngPW(a4),d7		; d7 = pixels
	move.l	a3,a0			; a0 = samples
	moveq	#0,d6			; d6 = bit offset (depths < 8)
	cmp.l	#8,g_PngDepth(a4)	; 8 bits: tight loops
	bne.s	.px
	move.l	g_PngType(a4),d0
	cmp.l	#6,d0
	beq.s	.f6
	cmp.l	#3,d0
	beq.s	.f3
	cmp.l	#4,d0
	beq.s	.f4
	tst.l	d0
	beq.s	.f0
	tst.l	g_PngTrns(a4)		; RGB (a colour key: the slow way)
	bne.s	.px
	subq.l	#1,d7
.f2:	move.l	(a0),d1			; (one byte more: the buffer has it)
	addq.l	#3,a0
	lsr.l	#8,d1
	or.l	#$ff000000,d1
	move.l	d1,(a2)
	add.l	a1,a2
	dbf	d7,.f2
	bra	.done
.f6:	subq.l	#1,d7			; RGBA: rotate the alpha to the top
.f6l:	move.l	(a0)+,d1
	ror.l	#8,d1
	move.l	d1,(a2)
	add.l	a1,a2
	dbf	d7,.f6l
	bra	.done
.f0:	tst.l	g_PngGrey(a4)		; grey: as a palette of greys
	bne.s	.f3
	move.l	a0,-(sp)
	bsr	GreyPal
	move.l	(sp)+,a0
.f3:	lea	g_GifPal(a4),a3		; palette
	subq.l	#1,d7
	moveq	#0,d0
.f3l:	move.b	(a0)+,d0
	move.l	(a3,d0.l*4),(a2)
	add.l	a1,a2
	dbf	d7,.f3l
	bra	.done
.f4:	subq.l	#1,d7			; grey and alpha
	moveq	#0,d0
.f4l:	move.b	(a0)+,d0
	move.l	d0,d1
	lsl.l	#8,d1
	or.l	d0,d1
	lsl.l	#8,d1
	or.l	d0,d1
	move.b	(a0)+,d0
	ror.l	#8,d0
	or.l	d0,d1
	moveq	#0,d0
	move.l	d1,(a2)
	add.l	a1,a2
	dbf	d7,.f4l
	bra.s	.done
.px:	move.l	g_PngType(a4),d0
	move.w	.types(pc,d0.l*2),d0
	jmp	.types(pc,d0.w)
.types:	dc.w	.grey-.types,0,.rgb-.types,.pal-.types,.ga-.types,0
	dc.w	.rgba-.types
.grey:	bsr	Sample
	move.l	d0,d2
	bsr	Scale
	move.l	d0,d1			; grey: the same in r, g, b
	lsl.l	#8,d1
	or.l	d0,d1
	lsl.l	#8,d1
	or.l	d0,d1
	tst.l	g_PngTrns(a4)		; the clear grey?
	beq.s	.opaque
	cmp.w	g_PngKey(a4),d2
	beq.s	.put
	bra.s	.opaque
.rgb:	bsr	Sample
	move.l	d0,d2
	bsr	Scale
	move.l	d0,d1
	bsr	Sample
	move.l	d0,d3
	bsr	Scale
	lsl.l	#8,d1
	or.l	d0,d1
	bsr	Sample
	move.l	d0,d4
	bsr	Scale
	lsl.l	#8,d1
	or.l	d0,d1
	tst.l	g_PngTrns(a4)
	beq.s	.opaque
	cmp.w	g_PngKey(a4),d2
	bne.s	.opaque
	cmp.w	g_PngKey+2(a4),d3
	bne.s	.opaque
	cmp.w	g_PngKey+4(a4),d4
	beq.s	.put
.opaque:
	or.l	#$ff000000,d1
.put:	move.l	d1,(a2)
	add.l	a1,a2
	subq.l	#1,d7
	bne.s	.px
.done:	movem.l	(sp)+,d2-d7/a2-a3
	rts
.pal:	bsr	Sample
	and.l	#$ff,d0
	lea	g_GifPal(a4),a3
	move.l	(a3,d0.l*4),d1
	bra.s	.put
.ga:	bsr	Sample			; grey, alpha
	bsr	Scale
	move.l	d0,d1
	lsl.l	#8,d1
	or.l	d0,d1
	lsl.l	#8,d1
	or.l	d0,d1
	bsr	Sample
	bsr	Scale
	ror.l	#8,d0
	or.l	d0,d1
	bra.s	.put
.rgba:	bsr	Sample
	bsr	Scale
	move.l	d0,d1
	bsr	Sample
	bsr	Scale
	lsl.l	#8,d1
	or.l	d0,d1
	bsr	Sample
	bsr	Scale
	lsl.l	#8,d1
	or.l	d0,d1
	bsr	Sample
	bsr	Scale
	ror.l	#8,d0
	or.l	d0,d1
	bra.s	.put

; GreyPal - g_GifPal = 256 opaque greys (the clear grey of tRNS with
; alpha 0), for 8-bit grey rows
GreyPal:
	lea	g_GifPal(a4),a0
	move.l	#$ff000000,d0
	move.w	#256-1,d1
.l:	move.l	d0,(a0)+
	add.l	#$010101,d0
	dbf	d1,.l
	tst.l	g_PngTrns(a4)
	beq.s	.x
	moveq	#0,d0
	move.b	g_PngKey+1(a4),d0	; (the low byte: 8 bits)
	lea	g_GifPal(a4),a0
	clr.l	(a0,d0.l*4)
.x:	moveq	#1,d0
	move.l	d0,g_PngGrey(a4)
	rts

; Sample - the next sample at a0/d6 (bit offset)
; Out: d0 (16 bits for depth 16); d1 kept
Sample:
	move.l	g_PngDepth(a4),d0
	cmp.w	#8,d0
	beq.s	.b8
	bhi.s	.b16
	move.l	d1,-(sp)		; 1, 2, 4 bits, from the top
	move.l	d0,d1
	moveq	#0,d0
	move.b	(a0),d0
	lsl.l	d6,d0
	and.w	#$ff,d0
	add.l	d1,d6
	sub.l	#8,d1
	neg.l	d1
	lsr.l	d1,d0
	cmp.l	#8,d6
	blo.s	.s
	moveq	#0,d6
	addq.l	#1,a0
.s:	movem.l	(sp)+,d1
	rts
.b8:	moveq	#0,d0
	move.b	(a0)+,d0
	rts
.b16:	moveq	#0,d0
	move.b	(a0)+,d0
	lsl.w	#8,d0
	move.b	(a0)+,d0
	rts

; Scale - sample d0 to 8 bits; Out: d0 (d1 kept)
Scale:
	move.l	g_PngDepth(a4),-(sp)
	cmp.l	#16,(sp)
	beq.s	.s16
	cmp.l	#8,(sp)
	beq.s	.x
	cmp.l	#4,(sp)
	beq.s	.s4
	cmp.l	#2,(sp)
	beq.s	.s2
	neg.b	d0			; 1 bit: 0 or 255
	bra.s	.x
.s4:	mulu.w	#17,d0
	bra.s	.x
.s2:	mulu.w	#85,d0
	bra.s	.x
.s16:	lsr.l	#8,d0
.x:	addq.l	#4,sp
	and.l	#$ff,d0
	rts
