;
; webp.s - WebP: the RIFF container (simple, or extended with VP8X and
; an ALPH chunk); lossless (VP8L, vp8l.s) and lossy (VP8, vp8.s)
; images.  Animations are not decoded.
;

	include	"velox.i"

	xdef	WebpInfo,WebpDecode
	xref	Vp8lDecode

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
	cmp.l	#'ANIM',d2		; animations: no
	beq.s	.no
	moveq	#1,d0			; the next chunk (padded to even)
	and.l	d3,d0
	add.l	d3,a2
	add.l	d0,a2
	bra.s	.chunk
.vp8l:	move.l	a2,a0
	move.l	d3,d0
	jsr	Vp8lDecode
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts
