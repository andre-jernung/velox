;
; webp.s - WebP: the RIFF container (simple, or extended with VP8X and
; an ALPH chunk); lossless (VP8L, vp8l.s) and lossy (VP8, vp8.s)
; images.  Animations are not decoded.
;

	include	"velox.i"

	xdef	WebpInfo,WebpDecode
	xref	Vp8lDecode,Vp8Decode,Vp8lImage,VFreeAll,PicAlloc,PicFreeMem

	section	code,code

;--------------------------------------------------------------------
; WebpInfo - In: a0 = data; Out: d0 = width, d1 = height
;--------------------------------------------------------------------
WebpInfo:
	move.l	12(a0),d1
	cmp.l	#'VP8 ',d1
	beq.s	.lossy
	cmp.l	#'VP8L',d1
	beq.s	.lossless
	cmp.l	#'VP8X',d1
	bne.s	.no
	moveq	#0,d0			; canvas: 24 bits each, minus 1
	move.b	26(a0),d0
	swap	d0
	move.b	25(a0),d0
	lsl.w	#8,d0
	move.b	24(a0),d0
	addq.l	#1,d0
	moveq	#0,d1
	move.b	29(a0),d1
	swap	d1
	move.b	28(a0),d1
	lsl.w	#8,d1
	move.b	27(a0),d1
	addq.l	#1,d1
	rts
.lossy:	moveq	#0,d0			; 14 bits each (and a scale)
	move.b	27(a0),d0
	lsl.w	#8,d0
	move.b	26(a0),d0
	and.w	#$3fff,d0
	moveq	#0,d1
	move.b	29(a0),d1
	lsl.w	#8,d1
	move.b	28(a0),d1
	and.w	#$3fff,d1
	rts
.lossless:
	move.b	24(a0),d1		; 14 bits width - 1, 14 bits height - 1
	lsl.l	#8,d1
	move.b	23(a0),d1
	lsl.l	#8,d1
	move.b	22(a0),d1
	lsl.l	#8,d1
	move.b	21(a0),d1
	move.l	d1,d0
	and.l	#$3fff,d0
	addq.l	#1,d0
	lsr.l	#8,d1
	lsr.l	#6,d1
	and.l	#$3fff,d1
	addq.l	#1,d1
	rts
.no:	moveq	#0,d0
	moveq	#0,d1
	rts

;--------------------------------------------------------------------
; WebpDecode - In: a0 = data, d0 = length; Out: d0 = 1 if decoded
;--------------------------------------------------------------------
WebpDecode:
	movem.l	d2-d3/a2-a3,-(sp)
	lea	(a0,d0.l),a3		; a3 = end
	lea	12(a0),a2		; the chunks
	clr.l	g_WAlph(a4)
.chunk:	lea	8(a2),a0
	cmp.l	a3,a0
	bhi.s	.no
	move.l	(a2)+,d2		; type
	moveq	#0,d3			; length (little-endian)
	move.b	3(a2),d3
	lsl.l	#8,d3
	move.b	2(a2),d3
	lsl.l	#8,d3
	move.b	1(a2),d3
	lsl.l	#8,d3
	move.b	(a2),d3
	addq.l	#4,a2
	move.l	a3,d0			; (cut short: as far as it goes)
	sub.l	a2,d0
	cmp.l	d0,d3
	bls.s	.len
	move.l	d0,d3
.len:	cmp.l	#'VP8L',d2
	beq.s	.vp8l
	cmp.l	#'VP8 ',d2
	beq.s	.vp8
	cmp.l	#'ANIM',d2		; animations: no
	beq.s	.no
	cmp.l	#'ALPH',d2		; the alpha of a lossy image
	bne.s	.na
	move.l	a2,g_WAlph(a4)
	move.l	d3,g_WAlphLen(a4)
.na:
	moveq	#1,d0			; the next chunk (padded to even)
	and.l	d3,d0
	add.l	d3,a2
	add.l	d0,a2
	bra.s	.chunk
.vp8l:	move.l	a2,a0
	move.l	d3,d0
	jsr	Vp8lDecode
	bra.s	.x
.vp8:	move.l	a2,a0
	move.l	d3,d0
	jsr	Vp8Decode
	beq.s	.x
	tst.l	g_WAlph(a4)
	beq.s	.x
	bsr	Alpha			; (no alpha if that fails)
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; Alpha - the ALPH chunk (g_WAlph, g_WAlphLen) into the decoded image:
; raw or VP8L-compressed (the green channel), and unfiltered
; (horizontal, vertical, gradient) as libwebp does
;--------------------------------------------------------------------
Alpha:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	sub.l	a5,a5			; a5 = the plane (w * h bytes)
	clr.l	g_WArgb(a4)		; ARGB of the lossless one
	move.l	g_PicW(a4),d6
	move.l	g_PicH(a4),d7
	move.l	d6,d0
	mulu.l	d7,d0
	move.l	d0,d5			; d5 = pixels
	jsr	PicAlloc
	move.l	d0,a5
	beq	.x
	move.l	g_WAlph(a4),a2
	move.l	g_WAlphLen(a4),d0
	subq.l	#1,d0
	bmi	.x
	move.b	(a2)+,d4		; d4 = header
	lea	(a2,d0.l),a3
	moveq	#3,d0
	and.b	d4,d0
	beq.s	.raw
	subq.b	#1,d0
	bne	.x			; (other compressions: unknown)
	move.l	d5,d0			; lossless: an image stream
	lsl.l	#2,d0
	jsr	PicAlloc
	move.l	d0,g_WArgb(a4)
	beq	.x
	clr.l	g_VChain(a4)
	clr.l	g_VOver(a4)
	moveq	#0,d2
	moveq	#0,d3
	move.l	d6,d0
	move.l	d7,d1
	move.l	d0,a0
	move.l	g_WArgb(a4),a0
	jsr	Vp8lImage
	move.l	d0,-(sp)
	jsr	VFreeAll
	move.l	(sp)+,d0
	beq	.x
	move.l	g_WArgb(a4),a0	; its green
	move.l	a5,a1
	move.l	d5,d0
	bra.s	.ge
.gl:	move.b	2(a0),(a1)+
	addq.l	#4,a0
.ge:	subq.l	#1,d0
	bpl.s	.gl
	bra.s	.unf
.raw:	move.l	a3,d0			; raw bytes (as many as there are)
	sub.l	a2,d0
	cmp.l	d5,d0
	bls.s	.rl
	move.l	d5,d0
.rl:	move.l	a5,a1
	bra.s	.re
.rc:	move.b	(a2)+,(a1)+
.re:	subq.l	#1,d0
	bpl.s	.rc
.unf:	lsr.b	#2,d4			; the filter
	and.l	#3,d4
	beq.s	.put
	move.l	a5,a0			; a0 = row, a1 = the row above
	sub.l	a1,a1
	moveq	#0,d3			; row
.row:	cmp.l	d7,d3
	bhs.s	.put
	move.l	a1,d0			; the first row: horizontal
	beq.s	.hor
	cmp.l	#1,d4
	beq.s	.hor
	cmp.l	#2,d4
	beq.s	.ver
	bsr	Gradient
	bra.s	.rn
.ver:	move.l	d6,d0			; + above
	subq.l	#1,d0
	moveq	#0,d1
.vl:	move.b	(a1,d1.l),d2
	add.b	d2,(a0,d1.l)
	addq.l	#1,d1
	dbf	d0,.vl
	bra.s	.rn
.hor:	moveq	#0,d2			; + left (the first: + above)
	move.l	a1,d0
	beq.s	.h0
	move.b	(a1),d2
.h0:	move.l	d6,d0
	subq.l	#1,d0
	move.l	a0,a6
.hl:	add.b	(a6),d2
	move.b	d2,(a6)+
	dbf	d0,.hl
	sub.l	a6,a6
.rn:	move.l	a0,a1
	add.l	d6,a0
	addq.l	#1,d3
	bra.s	.row
.put:	move.l	g_PicData(a4),a0	; into the pixels
	move.l	a5,a1
	move.l	d5,d0
	bra.s	.pe
.pl:	move.b	(a1)+,(a0)
	addq.l	#4,a0
.pe:	subq.l	#1,d0
	bpl.s	.pl
.x:	move.l	g_WArgb(a4),a1
	jsr	PicFreeMem
	move.l	a5,a1
	jsr	PicFreeMem
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; Gradient - row a0 (d6 wide) += clip(left + above - above left), row
; a1 above it (libwebp's GradientUnfilter)
Gradient:
	movem.l	d2-d5,-(sp)
	moveq	#0,d2
	move.b	(a1),d2			; top
	move.l	d2,d3			; top left
	move.l	d2,d4			; left
	moveq	#0,d5			; x
.l:	cmp.l	d6,d5
	bhs.s	.x
	moveq	#0,d2
	move.b	(a1,d5.l),d2		; top
	move.l	d4,d0			; left + top - top left, clipped
	add.l	d2,d0
	sub.l	d3,d0
	bpl.s	.p
	moveq	#0,d0
.p:	cmp.l	#255,d0
	bls.s	.c
	move.l	#255,d0
.c:	add.b	(a0,d5.l),d0
	and.l	#$ff,d0
	move.l	d0,d4			; the new left
	move.b	d0,(a0,d5.l)
	move.l	d2,d3
	addq.l	#1,d5
	bra.s	.l
.x:	movem.l	(sp)+,d2-d5
	rts
