;
; vp8.s - WebP lossy: VP8 key frames (RFC 6386), as libwebp decodes
; them: the boolean entropy decoder, the headers (segments, filter,
; partitions, quantizers, token probabilities), intra modes, the
; coefficient tokens, inverse WHT and DCT, 16x16 / 4x4 / chroma intra
; prediction, the loop filter (simple and normal), YUV to RGB.
;
; A macroblock is reconstructed in a work block (32 bytes a row) that
; holds its top row and left column as libwebp's does, then copied to
; the planes; the loop filter runs over the whole frame at the end
; (prediction uses the unfiltered pixels).
;
; Bool decoder state while decoding: d2 = value (left-justified),
; d3 = bits in it, d4 = range, a2/a3 = data and its end.
;

	include	"velox.i"

	xdef	Vp8Decode
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	PicNew,PicAlloc,PicFreeMem

BPS		equ	32		; work block: bytes a row
WB_Y		equ	1*BPS+8		; (0,0) of Y (rows -1..15, x -8..23)
WB_U		equ	18*BPS+8	; of U (rows -1..7)
WB_V		equ	27*BPS+8	; of V
WB_SIZE		equ	35*BPS

; a bool decoder's state (when not in the registers)
	RSRESET
bd_Value	rs.l	1
bd_Bits		rs.l	1
bd_Range	rs.l	1
bd_Ptr		rs.l	1
bd_End		rs.l	1
BD_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; Vp8Decode - a VP8 frame (the "VP8 " chunk's data)
; In:  a0 = data, d0 = length; Out: d0 = 1 if decoded (g_Pic*)
;--------------------------------------------------------------------
Vp8Decode:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	clr.l	g_8Work(a4)
	cmp.l	#10,d0
	blo	.fail
	move.l	a0,a2
	lea	(a0,d0.l),a3		; a3 = end
	move.l	a3,g_8End(a4)
	moveq	#0,d1			; frame tag: key frame, partition size
	move.b	2(a2),d1
	lsl.l	#8,d1
	move.b	1(a2),d1
	lsl.l	#8,d1
	move.b	(a2),d1
	btst	#0,d1			; (0: a key frame)
	bne	.fail
	lsr.l	#5,d1
	move.l	d1,d5			; d5 = first partition's size
	cmp.b	#$9d,3(a2)
	bne	.fail
	cmp.b	#$01,4(a2)
	bne	.fail
	cmp.b	#$2a,5(a2)
	bne	.fail
	moveq	#0,d0
	move.b	7(a2),d0
	lsl.w	#8,d0
	move.b	6(a2),d0
	and.w	#$3fff,d0
	move.l	d0,g_8W(a4)
	moveq	#0,d1
	move.b	9(a2),d1
	lsl.w	#8,d1
	move.b	8(a2),d1
	and.w	#$3fff,d1
	move.l	d1,g_8H(a4)
	jsr	PicNew
	beq	.fail
	lea	10(a2),a2		; the first partition
	lea	(a2,d5.l),a0
	cmp.l	a3,a0
	bhi	.fail
	move.l	a0,g_8After(a4)		; (the partition sizes, after it)
	move.l	a0,a3
	bsr	Memory
	beq	.fail
	moveq	#0,d2			; the bool decoder
	moveq	#0,d3
	move.l	#255,d4
	bsr	Header
	beq	.fail
	; the macroblocks
	clr.l	g_8MbY(a4)
.row:	move.l	g_8MbY(a4),d0
	cmp.l	g_8MbH(a4),d0
	bhs	.done
	lea	g_8ILeft(a4),a0		; left contexts: none
	clr.l	(a0)
	lea	g_8NzLeft(a4),a0
	clr.l	(a0)+
	clr.l	(a0)+
	clr.w	(a0)
	clr.l	g_8MbX(a4)
.mb:	move.l	g_8MbX(a4),d0
	cmp.l	g_8MbW(a4),d0
	bhs.s	.rown
	PROFB	8
	bsr	Modes			; (first partition)
	lea	g_8BD(a4),a0
	bsr	BdSave
	move.l	g_8MbY(a4),d0		; the tokens: partition y & (n - 1)
	and.l	g_8PMask(a4),d0
	mulu.w	#BD_SIZEOF,d0
	lea	g_8BD+BD_SIZEOF(a4,d0.l),a0
	move.l	a0,-(sp)
	bsr	BdLoad
	bsr	Residuals
	PROFE	8
	move.l	(sp)+,a0
	bsr	BdSave
	lea	g_8BD(a4),a0
	bsr	BdLoad
	PROFB	9
	bsr	Reconstruct
	PROFE	9
	addq.l	#1,g_8MbX(a4)
	bra.s	.mb
.rown:	addq.l	#1,g_8MbY(a4)
	bra	.row
.done:	tst.l	g_8FType(a4)
	beq.s	.nf
	PROFB	10
	bsr	Filter
	PROFE	10
.nf:	PROFB	11
	bsr	ToARGB
	PROFE	11
	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	move.l	d0,d2
	move.l	g_8Work(a4),a1
	jsr	PicFreeMem
	clr.l	g_8Work(a4)
	move.l	d2,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

;--------------------------------------------------------------------
; Memory - the working memory: probabilities, coefficients, work
; block, top samples, contexts, filter info, the planes
; Out: d0 = 0 if there is none (CCR set)
;--------------------------------------------------------------------
Memory:
	movem.l	d2-d5,-(sp)
	move.l	g_8W(a4),d0
	add.l	#15,d0
	lsr.l	#4,d0
	move.l	d0,g_8MbW(a4)
	move.l	g_8H(a4),d1
	add.l	#15,d1
	lsr.l	#4,d1
	move.l	d1,g_8MbH(a4)
	move.l	d0,d2			; Y: 16 * MBs across, a row
	lsl.l	#4,d2
	move.l	d2,g_8YS(a4)
	lsr.l	#1,d2
	move.l	d2,g_8US(a4)
	lea	g_8Off(a4),a0		; offsets: d5 = running size
	moveq	#0,d5
	move.l	d5,(a0)+		; probabilities: 1056
	add.l	#1056,d5
	move.l	d5,(a0)+		; coefficients: 384 words
	add.l	#768,d5
	move.l	d5,(a0)+		; work block
	add.l	#WB_SIZE,d5
	move.l	d5,(a0)+		; top samples: 32 a column
	move.l	d0,d1
	lsl.l	#5,d1
	add.l	d1,d5
	move.l	d5,(a0)+		; top modes: 4 a column
	move.l	d0,d1
	lsl.l	#2,d1
	add.l	d1,d5
	move.l	d5,(a0)+		; top nonzero: 10 a column
	move.l	d0,d1
	mulu.w	#10,d1
	add.l	d1,d5
	move.l	d5,(a0)+		; filter info: 4 a macroblock
	move.l	d0,d1
	mulu.l	g_8MbH(a4),d1
	lsl.l	#2,d1
	add.l	d1,d5
	move.l	d5,(a0)+		; Y
	move.l	g_8YS(a4),d1
	move.l	g_8MbH(a4),d3
	lsl.l	#4,d3
	mulu.l	d3,d1
	add.l	d1,d5
	move.l	d5,(a0)+		; U
	lsr.l	#2,d1
	add.l	d1,d5
	move.l	d5,(a0)+		; V
	add.l	d1,d5
	move.l	d5,(a0)+		; YUV -> RGB: 5 x 256 words, then U
	add.l	#2560,d5		; and V of a row of pixels
	add.l	g_8YS(a4),d5
	add.l	g_8YS(a4),d5
	move.l	d5,(a0)+		; clip: (v >> 6) + 256 -> 0..255
	add.l	#1024,d5
	move.l	d5,d0
	jsr	PicAlloc
	move.l	d0,g_8Work(a4)
	beq.s	.x
	lea	g_8Off(a4),a0		; offsets to pointers
	moveq	#12-1,d1
.p:	add.l	d0,(a0)+
	dbf	d1,.p
	; the top row of the first macroblock row: 127 (and its top left,
	; and to the right); intra modes above: DC
	move.l	g_8WB(a4),a0
	moveq	#BPS-1,d1
.t:	move.b	#127,WB_Y-BPS-8(a0,d1.l)
	move.b	#127,WB_U-BPS-8(a0,d1.l)
	move.b	#127,WB_V-BPS-8(a0,d1.l)
	dbf	d1,.t
	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d5
	rts

;--------------------------------------------------------------------
; Header - the frame header in the first partition
; Out: d0 = 0 if not decodable (CCR set)
;--------------------------------------------------------------------
Header:
	movem.l	d5-d7/a5,-(sp)
	bsr	Flag			; colour space, clamping
	bsr	Flag
	; segments
	clr.l	g_8SegMap(a4)
	clr.l	g_8SegAbs(a4)
	clr.l	g_8SegQ(a4)
	clr.l	g_8SegF(a4)
	move.l	#$ffffffff,g_8SegP(a4)
	bsr	Flag
	move.l	d0,g_8Seg(a4)
	beq.s	.filt
	bsr	Flag
	move.l	d0,g_8SegMap(a4)
	bsr	Flag
	beq.s	.map
	bsr	Flag
	move.l	d0,g_8SegAbs(a4)
	lea	g_8SegQ(a4),a5
	moveq	#7,d6
	bsr	Four
	lea	g_8SegF(a4),a5
	moveq	#6,d6
	bsr	Four
.map:	tst.l	g_8SegMap(a4)
	beq.s	.filt
	lea	g_8SegP(a4),a5
	moveq	#3-1,d7
.mp:	bsr	Flag
	beq.s	.mpn
	moveq	#8,d0
	bsr	Lit
	move.b	d0,(a5)
.mpn:	addq.l	#1,a5
	dbf	d7,.mp
.filt:	; the loop filter
	bsr	Flag
	move.l	d0,g_8Simple(a4)
	moveq	#6,d0
	bsr	Lit
	move.l	d0,g_8Level(a4)
	moveq	#3,d0
	bsr	Lit
	move.l	d0,g_8Sharp(a4)
	clr.l	g_8RefLfd(a4)
	clr.l	g_8ModeLfd(a4)
	bsr	Flag
	move.l	d0,g_8UseLfd(a4)
	beq.s	.ft
	bsr	Flag
	beq.s	.ft
	lea	g_8RefLfd(a4),a5
	moveq	#6,d6
	bsr	Four
	lea	g_8ModeLfd(a4),a5
	moveq	#6,d6
	bsr	Four
.ft:	moveq	#0,d0			; 0: none, 1: simple, 2: normal
	tst.l	g_8Level(a4)
	beq.s	.fts
	moveq	#2,d0
	tst.l	g_8Simple(a4)
	beq.s	.fts
	moveq	#1,d0
.fts:	move.l	d0,g_8FType(a4)
	; the partitions
	moveq	#2,d0
	bsr	Lit
	moveq	#1,d1
	lsl.l	d0,d1
	subq.l	#1,d1
	move.l	d1,g_8PMask(a4)
	bsr	Partitions
	beq	.no
	; the quantizers
	moveq	#7,d0
	bsr	Lit
	move.l	d0,g_8Base(a4)		; base index
	lea	g_8Dq(a4),a5		; y1 dc, y2 dc, y2 ac, uv dc, uv ac
	moveq	#5-1,d6
.dq:	moveq	#0,d0
	bsr	Flag
	beq.s	.dqp
	moveq	#4,d0
	bsr	Signed
.dqp:	move.b	d0,(a5)+
	dbf	d6,.dq
	bsr	Quant
	bsr	Flag			; (refresh probabilities: no matter)
	; the token probabilities
	move.l	g_8Proba(a4),a5
	moveq	#0,d6
.pr:	lea	CoeffsUpdate(pc),a0
	moveq	#0,d0
	move.b	(a0,d6.l),d0
	bsr	Get
	beq.s	.p0
	moveq	#8,d0
	bsr	Lit
	bra.s	.pp
.p0:	lea	CoeffsProba0(pc),a0
	move.b	(a0,d6.l),d0
.pp:	move.b	d0,(a5)+
	addq.l	#1,d6
	cmp.l	#1056,d6
	blo.s	.pr
	clr.l	g_8SkipP(a4)
	bsr	Flag
	move.l	d0,g_8UseSkip(a4)
	beq.s	.ok
	moveq	#8,d0
	bsr	Lit
	move.l	d0,g_8SkipP(a4)
.ok:	bsr	Strengths
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d5-d7/a5
	rts

; Four - four optional signed values of d6 bits to bytes a5 (d7 changed)
Four:
	moveq	#4-1,d7
.f:	moveq	#0,d0
	bsr	Flag
	beq.s	.fz
	move.l	d6,d0
	bsr	Signed
.fz:	move.b	d0,(a5)+
	dbf	d7,.f
	rts

; Partitions - the token partitions after the first one
; Out: d0 = 0 if damaged (CCR set)
Partitions:
	movem.l	d5-d7/a5,-(sp)
	move.l	g_8After(a4),a5		; sizes (3 bytes each but the last)
	move.l	g_8PMask(a4),d7		; d7 = partitions - 1
	move.l	d7,d0
	mulu.w	#3,d0
	lea	(a5,d0.l),a0		; a0 = the first partition
	move.l	g_8End(a4),d6
	cmp.l	d6,a0
	bhi.s	.no
	lea	g_8BD+BD_SIZEOF(a4),a1
	moveq	#0,d5			; partition
.p:	cmp.l	d7,d5
	bhs.s	.last
	moveq	#0,d0
	move.b	2(a5),d0
	lsl.l	#8,d0
	move.b	1(a5),d0
	lsl.l	#8,d0
	move.b	(a5),d0
	addq.l	#3,a5
	move.l	d6,d1			; (at most to the end)
	sub.l	a0,d1
	cmp.l	d1,d0
	bls.s	.s
	move.l	d1,d0
.s:	bsr	PartInit
	add.l	d0,a0
	addq.l	#1,d5
	bra.s	.p
.last:	move.l	d6,d0
	sub.l	a0,d0
	bsr	PartInit
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d5-d7/a5
	rts

; PartInit - bool decoder a1 for d0 bytes at a0; a1 to the next one
; (d0, a0 kept)
PartInit:
	clr.l	bd_Value(a1)
	clr.l	bd_Bits(a1)
	move.l	#255,bd_Range(a1)
	move.l	a0,bd_Ptr(a1)
	lea	(a0,d0.l),a6
	move.l	a6,bd_End(a1)
	lea	BD_SIZEOF(a1),a1
	rts

; Quant - the quantizer steps of each segment (g_8Q: y1 dc/ac, y2
; dc/ac, uv dc/ac, words)
Quant:
	movem.l	d5-d7/a5,-(sp)
	lea	g_8Q(a4),a5
	moveq	#0,d7			; segment
.s:	move.l	g_8Base(a4),d6		; d6 = its index
	tst.l	g_8Seg(a4)
	beq.s	.q
	lea	g_8SegQ(a4),a0
	move.b	(a0,d7.l),d0
	ext.w	d0
	ext.l	d0
	tst.l	g_8SegAbs(a4)
	beq.s	.rel
	moveq	#0,d6
.rel:	add.l	d0,d6
.q:	lea	g_8Dq(a4),a1
	move.b	(a1),d0			; y1: dc + delta, ac
	bsr	QDc
	move.w	d0,(a5)+
	moveq	#0,d0
	bsr	QAc
	move.w	d0,(a5)+
	move.b	1(a1),d0		; y2: dc * 2, ac * 155/100 (at least 8)
	bsr	QDc
	add.w	d0,d0
	move.w	d0,(a5)+
	move.b	2(a1),d0
	bsr	QAc
	mulu.l	#101581,d0
	swap	d0
	and.l	#$ffff,d0
	cmp.w	#8,d0
	bhs.s	.y2
	moveq	#8,d0
.y2:	move.w	d0,(a5)+
	move.b	3(a1),d0		; uv: dc (index at most 117), ac
	ext.w	d0
	ext.l	d0
	add.l	d6,d0
	bpl.s	.u1
	moveq	#0,d0
.u1:	cmp.l	#117,d0
	bls.s	.u2
	moveq	#117,d0
.u2:	lea	DcTable(pc),a0
	move.b	(a0,d0.l),d0
	and.w	#$ff,d0
	move.w	d0,(a5)+
	move.b	4(a1),d0
	bsr	QAc
	move.w	d0,(a5)+
	addq.l	#1,d7
	cmp.l	#4,d7
	blo.s	.s
	movem.l	(sp)+,d5-d7/a5
	rts

; QDc - DcTable[clip(d6 + delta d0)]; Out: d0 (a1 kept)
QDc:
	ext.w	d0
	ext.l	d0
	add.l	d6,d0
	bsr.s	Q127
	lea	DcTable(pc),a0
	move.b	(a0,d0.l),d0
	and.l	#$ff,d0
	rts

; QAc - AcTable[clip(d6 + delta d0)]; Out: d0 (a1 kept)
QAc:
	ext.w	d0
	ext.l	d0
	add.l	d6,d0
	bsr.s	Q127
	lea	AcTable(pc),a0
	move.w	(a0,d0.l*2),d0
	and.l	#$ffff,d0
	rts

; Q127 - d0 to 0..127; Out: d0 (a1 kept)
Q127:
	tst.l	d0
	bpl.s	.c1
	moveq	#0,d0
.c1:	cmp.l	#127,d0
	bls.s	.c2
	moveq	#127,d0
.c2:	rts

; Strengths - the loop filter of each segment, 4x4 or not:
; g_8Strength[segment * 2 + i4x4] = limit, ilevel, hev threshold
Strengths:
	movem.l	d5-d7,-(sp)
	moveq	#0,d7			; segment * 2 + i4x4
.s:	move.l	g_8Level(a4),d5
	tst.l	g_8Seg(a4)
	beq.s	.lv
	move.l	d7,d0
	lsr.l	#1,d0
	lea	g_8SegF(a4),a0
	move.b	(a0,d0.l),d0
	ext.w	d0
	ext.l	d0
	tst.l	g_8SegAbs(a4)
	beq.s	.rel
	move.l	d0,d5
	bra.s	.lv
.rel:	add.l	d0,d5
.lv:	tst.l	g_8UseLfd(a4)
	beq.s	.cl
	move.b	g_8RefLfd(a4),d0
	ext.w	d0
	ext.l	d0
	add.l	d0,d5
	btst	#0,d7
	beq.s	.cl
	move.b	g_8ModeLfd(a4),d0
	ext.w	d0
	ext.l	d0
	add.l	d0,d5
.cl:	tst.l	d5			; 0..63
	bpl.s	.c1
	moveq	#0,d5
.c1:	cmp.l	#63,d5
	bls.s	.c2
	moveq	#63,d5
.c2:	lea	g_8Strength(a4,d7.l*4),a0
	clr.l	(a0)
	tst.l	d5
	beq.s	.n
	move.l	d5,d6			; interior limit
	move.l	g_8Sharp(a4),d0
	beq.s	.i1
	lsr.l	#1,d6
	cmp.l	#4,d0
	bls.s	.i0
	lsr.l	#1,d6
.i0:	moveq	#9,d1
	sub.l	d0,d1
	cmp.l	d1,d6
	bls.s	.i1
	move.l	d1,d6
.i1:	tst.l	d6
	bne.s	.i2
	moveq	#1,d6
.i2:	move.l	d5,d0			; limit = 2 * level + interior
	add.l	d0,d0
	add.l	d6,d0
	move.b	d0,(a0)
	move.b	d6,1(a0)
	moveq	#0,d0			; high edge variance threshold
	cmp.l	#15,d5
	blo.s	.h
	moveq	#1,d0
	cmp.l	#40,d5
	blo.s	.h
	moveq	#2,d0
.h:	move.b	d0,2(a0)
.n:	addq.l	#1,d7
	cmp.l	#8,d7
	blo.s	.s
	movem.l	(sp)+,d5-d7
	rts

;--------------------------------------------------------------------
; the bool decoder
;--------------------------------------------------------------------

; BdLoad - the state of decoder a0 into the registers
BdLoad:
	move.l	bd_Value(a0),d2
	move.l	bd_Bits(a0),d3
	move.l	bd_Range(a0),d4
	move.l	bd_Ptr(a0),a2
	move.l	bd_End(a0),a3
	rts

; BdSave - the registers into decoder a0
BdSave:
	move.l	d2,bd_Value(a0)
	move.l	d3,bd_Bits(a0)
	move.l	d4,bd_Range(a0)
	move.l	a2,bd_Ptr(a0)
	move.l	a3,bd_End(a0)
	rts

; Fill - at least 25 bits in d2 (zeros past the end); d0 kept
Fill:
	move.l	d0,-(sp)
.l:	cmp.l	#24,d3
	bgt.s	.x
	moveq	#0,d0
	cmp.l	a3,a2
	bhs.s	.z
	move.b	(a2)+,d0
.z:	moveq	#24,d1
	sub.l	d3,d1
	lsl.l	d1,d0
	or.l	d0,d2
	addq.l	#8,d3
	bra.s	.l
.x:	move.l	(sp)+,d0
	rts

; Get - a bool whose probability of being 0 is d0/256
; Out: d0 = 0 or 1 (CCR set); a0, a1, a5, a6 kept
Get:
	cmp.l	#16,d3
	bge.s	.h
	bsr.s	Fill
.h:	move.l	d4,d1			; split = 1 + ((range - 1) * p >> 8)
	subq.l	#1,d1
	mulu.w	d0,d1
	lsr.l	#8,d1
	addq.l	#1,d1
	move.l	d1,d0
	ror.l	#8,d0			; split << 24
	cmp.l	d0,d2
	bhs.s	.one
	move.l	d1,d4
	moveq	#0,d0
	bra.s	.norm
.one:	sub.l	d0,d2
	sub.l	d1,d4
	moveq	#1,d0
.norm:	cmp.l	#128,d4			; range back to 128..255
	bhs.s	.x
	moveq	#0,d1
	move.b	Norm(pc,d4.l),d1
	lsl.l	d1,d4
	lsl.l	d1,d2
	sub.l	d1,d3
.x:	tst.l	d0
	rts

; Flag - a bool of probability 1/2; Out: d0 (CCR set; a0, a1, a5 kept)
Flag:
	move.l	#128,d0
	bra.s	Get

; Lit - d0 bits (probability 1/2 each), MSB first; Out: d0 (a5 kept)
Lit:
	movem.l	d5-d6,-(sp)
	move.l	d0,d6
	moveq	#0,d5
.l:	subq.l	#1,d6
	bmi.s	.x
	bsr.s	Flag
	add.l	d5,d5
	or.l	d0,d5
	bra.s	.l
.x:	move.l	d5,d0
	movem.l	(sp)+,d5-d6
	rts

; Signed - d0 bits and a sign; Out: d0 (a5 kept)
Signed:
	bsr.s	Lit
	move.l	d0,-(sp)
	bsr.s	Flag
	movem.l	(sp)+,d0
	beq.s	.x
	neg.l	d0
.x:	rts

; shift that brings a range of 1..127 to 128..255
Norm:
	dc.b	7,7,6,6,5,5,5,5,4,4,4,4,4,4,4,4
	dcb.b	16,3
	dcb.b	32,2
	dcb.b	64,1
	even

;--------------------------------------------------------------------
; Modes - the modes of macroblock g_8MbX (first partition): g_8MSeg,
; g_8MSkip, g_8MI4, g_8MModes (16 4x4 modes, or the 16x16 mode first),
; g_8MUV.  (Modes: 0 DC, 1 TM, 2 V, 3 H; 4x4 also 4 RD, 5 VR, 6 LD,
; 7 VL, 8 HD, 9 HU)
;--------------------------------------------------------------------
Modes:
	movem.l	d5-d7/a5-a6,-(sp)
	moveq	#0,d5			; segment
	tst.l	g_8SegMap(a4)
	beq.s	.seg
	moveq	#0,d0
	move.b	g_8SegP(a4),d0
	bsr	Get
	bne.s	.s23
	moveq	#0,d0
	move.b	g_8SegP+1(a4),d0
	bsr	Get
	move.l	d0,d5
	bra.s	.seg
.s23:	moveq	#0,d0
	move.b	g_8SegP+2(a4),d0
	bsr	Get
	addq.l	#2,d0
	move.l	d0,d5
.seg:	move.l	d5,g_8MSeg(a4)
	clr.l	g_8MSkip(a4)
	tst.l	g_8UseSkip(a4)
	beq.s	.nsk
	move.l	g_8SkipP(a4),d0
	bsr	Get
	move.l	d0,g_8MSkip(a4)
.nsk:	move.l	g_8MbX(a4),d0		; a5 = modes above, a6 = to the left
	lsl.l	#2,d0
	move.l	g_8ITop(a4),a5
	add.l	d0,a5
	lea	g_8ILeft(a4),a6
	move.l	#145,d0
	bsr	Get
	bne	.i16
	moveq	#1,d0			; 4x4: each by its neighbours' modes
	move.l	d0,g_8MI4(a4)
	moveq	#0,d7			; y
.y:	moveq	#0,d6
	move.b	(a6,d7.l),d6		; d6 = the mode to the left
	moveq	#0,d5			; x
.x:	moveq	#0,d0			; probabilities [above][left]
	move.b	(a5,d5.l),d0
	mulu.w	#10,d0
	add.l	d6,d0
	mulu.w	#9,d0
	lea	BModesProba(pc),a0
	add.l	d0,a0			; (Get keeps a0)
	moveq	#0,d0
	move.b	(a0),d0
	bsr	Get
	lea	YModes4(pc),a1
	move.b	(a1,d0.l),d6
	ext.w	d6
	ext.l	d6
.t:	tst.l	d6			; > 0: an inner node
	ble.s	.leaf
	moveq	#0,d0
	move.b	(a0,d6.l),d0
	bsr	Get
	add.l	d6,d6
	add.l	d0,d6
	lea	YModes4(pc),a1
	move.b	(a1,d6.l),d6
	ext.w	d6
	ext.l	d6
	bra.s	.t
.leaf:	neg.l	d6			; the mode
	move.b	d6,(a5,d5.l)
	move.l	d7,d0
	lsl.l	#2,d0
	add.l	d5,d0
	lea	g_8MModes(a4),a0
	move.b	d6,(a0,d0.l)
	addq.l	#1,d5
	cmp.l	#4,d5
	blo.s	.x
	move.b	d6,(a6,d7.l)
	addq.l	#1,d7
	cmp.l	#4,d7
	blo.s	.y
	bra.s	.uv
.i16:	clr.l	g_8MI4(a4)		; 16x16: V H DC TM by a little tree
	move.l	#156,d0
	bsr	Get
	beq.s	.vd
	move.l	#128,d0
	bsr	Get
	moveq	#3,d6			; H
	tst.l	d0
	beq.s	.m
	moveq	#1,d6			; TM
	bra.s	.m
.vd:	move.l	#163,d0
	bsr	Get
	moveq	#0,d6			; DC
	tst.l	d0
	beq.s	.m
	moveq	#2,d6			; V
.m:	move.b	d6,g_8MModes(a4)
	move.b	d6,d0			; above and left: that mode
	lsl.w	#8,d0
	move.b	d6,d0
	move.w	d0,d1
	swap	d0
	move.w	d1,d0
	move.l	d0,(a5)
	move.l	d0,(a6)
.uv:	move.l	#142,d0			; chroma: DC V TM H
	bsr	Get
	moveq	#0,d6
	tst.l	d0
	beq.s	.u
	move.l	#114,d0
	bsr	Get
	moveq	#2,d6
	tst.l	d0
	beq.s	.u
	move.l	#183,d0
	bsr	Get
	moveq	#3,d6
	tst.l	d0
	beq.s	.u
	moveq	#1,d6
.u:	move.l	d6,g_8MUV(a4)
	movem.l	(sp)+,d5-d7/a5-a6
	rts

; the 4x4 mode tree: > 0 inner node, <= 0 minus the mode
YModes4:
	dc.b	0,1,-1,2,-2,3,4,6,-3,5,-4,-5,-6,7,-7,8,-8,-9
	even

;--------------------------------------------------------------------
; Residuals - the coefficients of the macroblock (a token partition):
; g_8Coef (24 blocks of 16 words: Y, U, V), g_8BNz, g_8MNz
;--------------------------------------------------------------------
Residuals:
	movem.l	d5-d7/a5-a6,-(sp)
	move.l	g_8Coef(a4),a0		; nothing yet
	move.w	#384/2-1,d0
.c:	clr.l	(a0)+
	dbf	d0,.c
	lea	g_8BNz(a4),a0
	moveq	#24/4-1,d0
.cb:	clr.l	(a0)+
	dbf	d0,.cb
	clr.l	g_8MNz(a4)
	move.l	g_8MbX(a4),d0		; a5 = nonzero above
	mulu.w	#10,d0
	move.l	g_8NzTop(a4),a5
	add.l	d0,a5
	tst.l	g_8MSkip(a4)
	beq.s	.tok
	clr.l	(a5)			; no tokens: nothing nonzero
	clr.l	4(a5)
	clr.l	g_8NzLeft(a4)
	clr.l	g_8NzLeft+4(a4)
	tst.l	g_8MI4(a4)
	bne	.x
	clr.b	8(a5)
	clr.b	g_8NzLeft+8(a4)
	bra	.x
.tok:	move.l	g_8MSeg(a4),d0		; g_8QPtr = the segment's steps
	mulu.w	#12,d0
	lea	g_8Q(a4,d0.l),a0
	move.l	a0,g_8QPtr(a4)
	moveq	#0,d5			; first coefficient
	moveq	#3,d7			; type (3: Y with DC)
	tst.l	g_8MI4(a4)
	bne.s	.y
	; Y2: the DCs of the 16 Y blocks
	lea	g_8Dc(a4),a0
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	moveq	#0,d6
	move.b	8(a5),d6
	add.b	g_8NzLeft+8(a4),d6	; context
	moveq	#1,d0
	bsr	TypeProba
	lea	g_8Dc(a4),a6
	move.l	g_8QPtr(a4),a1
	addq.l	#4,a1			; (y2)
	bsr	Coeffs
	sne	d1
	neg.b	d1			; (nz > 0)
	move.b	d1,8(a5)
	move.b	d1,g_8NzLeft+8(a4)
	cmp.l	#1,d0
	bls.s	.dc0
	bsr	WHT
	bra.s	.dcd
.dc0:	move.w	g_8Dc(a4),d0		; only the DC: (dc + 3) >> 3 to all
	ext.l	d0
	addq.l	#3,d0
	asr.l	#3,d0
	move.l	g_8Coef(a4),a0
	moveq	#16-1,d1
.dl:	move.w	d0,(a0)
	lea	32(a0),a0
	dbf	d1,.dl
.dcd:	moveq	#1,d5
	moveq	#0,d7			; type 0: Y without DC
.y:	; the 16 Y blocks
	move.l	d7,d0
	bsr	TypeProba
	moveq	#0,d7			; block
.yb:	move.l	d7,d0			; context: left + above
	lsr.l	#2,d0
	lea	g_8NzLeft(a4),a0
	moveq	#0,d6
	move.b	(a0,d0.l),d6
	moveq	#3,d0
	and.l	d7,d0
	add.b	(a5,d0.l),d6
	move.l	d7,d0
	lsl.l	#5,d0
	move.l	g_8Coef(a4),a6
	add.l	d0,a6
	move.l	g_8QPtr(a4),a1
	bsr	Coeffs
	bsr	Code			; block d7's code; d0 = 1 if nz > first
	move.l	d7,d1
	lsr.l	#2,d1
	lea	g_8NzLeft(a4),a0
	move.b	d0,(a0,d1.l)
	moveq	#3,d1
	and.l	d7,d1
	move.b	d0,(a5,d1.l)
	addq.l	#1,d7
	cmp.l	#16,d7
	blo.s	.yb
	; U and V: 2 x 2 blocks each
	moveq	#2,d0
	bsr	TypeProba
	moveq	#0,d5
	moveq	#16,d7
.uvb:	move.l	d7,d0			; context: left + above (U: 4, 5;
	sub.l	#16,d0			; V: 6, 7)
	move.l	d0,d1
	lsr.l	#2,d1			; 0 U, 1 V
	add.l	d1,d1
	addq.l	#4,d1			; 4 or 6
	move.l	d0,-(sp)
	lsr.l	#1,d0
	and.l	#1,d0			; row
	add.l	d1,d0
	lea	g_8NzLeft(a4),a0
	moveq	#0,d6
	move.b	(a0,d0.l),d6
	move.l	(sp)+,d0
	and.l	#1,d0			; column
	add.l	d1,d0
	add.b	(a5,d0.l),d6
	move.l	d7,d0
	lsl.l	#5,d0
	move.l	g_8Coef(a4),a6
	add.l	d0,a6
	move.l	g_8QPtr(a4),a1
	addq.l	#8,a1			; (uv)
	bsr	Coeffs
	bsr	Code
	move.l	d0,-(sp)
	move.l	d7,d0
	sub.l	#16,d0
	move.l	d0,d1
	lsr.l	#2,d1
	add.l	d1,d1
	addq.l	#4,d1
	lsr.l	#1,d0
	and.l	#1,d0
	add.l	d1,d0
	lea	g_8NzLeft(a4),a0
	move.l	(sp),d1
	move.b	d1,(a0,d0.l)
	move.l	d7,d0
	sub.l	#16,d0
	move.l	d0,d1
	lsr.l	#2,d1
	add.l	d1,d1
	addq.l	#4,d1
	and.l	#1,d0
	add.l	d1,d0
	move.l	(sp)+,d1
	move.b	d1,(a5,d0.l)
	addq.l	#1,d7
	cmp.l	#24,d7
	blo	.uvb
.x:	movem.l	(sp)+,d5-d7/a5-a6
	rts

; TypeProba - g_8TProba = the token probabilities of type d0
TypeProba:
	mulu.w	#8*3*11,d0
	add.l	g_8Proba(a4),d0
	move.l	d0,g_8TProba(a4)
	rts

; Code - the code of block d7 (a6) after Coeffs returned d0 (d5 = the
; first position): 2 if coefficients past the DC, 1 if just a DC, 0;
; Out: d0 = 1 if nz > first (the context)
Code:
	moveq	#0,d1
	cmp.l	#1,d0
	bhi.s	.more
	tst.w	(a6)
	beq.s	.c
	moveq	#1,d1
	bra.s	.c
.more:	moveq	#2,d1
.c:	lea	g_8BNz(a4),a0
	move.b	d1,(a0,d7.l)
	beq.s	.z
	moveq	#1,d1
	move.l	d1,g_8MNz(a4)
.z:	cmp.l	d5,d0
	shi	d0
	and.l	#1,d0
	rts

;--------------------------------------------------------------------
; Coeffs - the tokens of a block (libwebp's GetCoeffs)
; In:  g_8TProba = probabilities of its type, d6 = context, d5 =
;      first position, a6 = the block (16 words), a1 = steps (dc, ac)
; Out: d0 = position after the last nonzero coefficient
;--------------------------------------------------------------------
Coeffs:
	movem.l	d5-d7/a5,-(sp)
	move.l	a1,a5			; a5 = steps
	moveq	#0,d0			; p = probabilities of band(n), ctx
	move.b	BandOff(pc,d5.l),d0
	move.l	g_8TProba(a4),a0
	add.l	d0,a0
	move.l	d6,d0
	mulu.w	#11,d0
	add.l	d0,a0
.n:	cmp.l	#16,d5
	bhs.s	.r16
	moveq	#0,d0			; the end?
	move.b	(a0),d0
	bsr	Get
	beq.s	.rn
.z:	moveq	#0,d0			; zeros
	move.b	1(a0),d0
	bsr	Get
	bne.s	.nz
	addq.l	#1,d5
	cmp.l	#16,d5
	bhs.s	.r16
	moveq	#0,d0
	move.b	BandOff(pc,d5.l),d0
	move.l	g_8TProba(a4),a0
	add.l	d0,a0
	bra.s	.z
.nz:	moveq	#0,d0			; a coefficient: 1, or larger
	move.b	2(a0),d0
	bsr	Get
	bne.s	.lg
	moveq	#1,d7
	moveq	#11,d6			; (next: context 1)
	bra.s	.sg
.lg:	bsr	Large
	moveq	#22,d6			; (next: context 2)
.sg:	bsr	Flag			; its sign
	beq.s	.pos
	neg.l	d7
.pos:	move.w	2(a5),d0		; times its step
	tst.l	d5
	bne.s	.ac
	move.w	(a5),d0
.ac:	muls.w	d0,d7
	moveq	#0,d0
	move.b	Zigzag(pc,d5.l),d0
	move.w	d7,(a6,d0.l*2)
	addq.l	#1,d5			; next: band(n + 1), context
	moveq	#0,d0
	move.b	BandOff(pc,d5.l),d0
	move.l	g_8TProba(a4),a0
	add.l	d0,a0
	add.l	d6,a0
	bra.s	.n
.rn:	move.l	d5,d0
	bra.s	.x
.r16:	moveq	#16,d0
.x:	movem.l	(sp)+,d5-d7/a5
	rts

; bands of positions 0..16, times 33 (3 contexts x 11)
BandOff:
	dc.b	0*33,1*33,2*33,3*33,6*33,4*33,5*33,6*33
	dc.b	6*33,6*33,6*33,6*33,6*33,6*33,6*33,7*33,0
Zigzag:	dc.b	0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15
	even

; Large - a coefficient of 2 or more (p = a0); Out: d7 (a0 kept)
Large:
	moveq	#0,d0
	move.b	3(a0),d0
	bsr	Get
	bne.s	.g1
	moveq	#0,d0
	move.b	4(a0),d0
	bsr	Get
	bne.s	.v3
	moveq	#2,d7
	rts
.v3:	moveq	#0,d0
	move.b	5(a0),d0
	bsr	Get
	addq.l	#3,d0
	move.l	d0,d7
	rts
.g1:	moveq	#0,d0
	move.b	6(a0),d0
	bsr	Get
	bne.s	.cat
	moveq	#0,d0
	move.b	7(a0),d0
	bsr	Get
	bne.s	.v7
	move.l	#159,d0
	bsr	Get
	addq.l	#5,d0
	move.l	d0,d7
	rts
.v7:	move.l	#165,d0
	bsr	Get
	add.l	d0,d0
	addq.l	#7,d0
	move.l	d0,d7
	move.l	#145,d0
	bsr	Get
	add.l	d0,d7
	rts
.cat:	moveq	#0,d0			; categories 3-6
	move.b	8(a0),d0
	bsr	Get
	move.l	d0,d7			; bit 1
	moveq	#0,d0
	move.b	9(a0,d7.l),d0
	bsr	Get
	add.l	d7,d7
	add.l	d0,d7			; cat
	move.l	a0,-(sp)
	lea	Cats(pc),a0
	move.b	(a0,d7.l),d0
	ext.w	d0
	lea	(a0,d0.w),a1		; a1 = its probabilities
	moveq	#8,d0			; v = 3 + (8 << cat) + the bits
	lsl.l	d7,d0
	addq.l	#3,d0
	move.l	d0,-(sp)
	moveq	#0,d7
.b:	moveq	#0,d0
	move.b	(a1)+,d0
	beq.s	.bd
	bsr	Get
	add.l	d7,d7
	add.l	d0,d7
	bra.s	.b
.bd:	add.l	(sp)+,d7
	move.l	(sp)+,a0
	rts
Cats:	dc.b	Cat3-Cats,Cat4-Cats,Cat5-Cats,Cat6-Cats
Cat3:	dc.b	173,148,140,0
Cat4:	dc.b	176,155,140,135,0
Cat5:	dc.b	180,157,141,134,130,0
Cat6:	dc.b	254,254,243,230,196,177,153,140,133,130,129,0
	even

; WHT - the inverse Walsh-Hadamard transform of g_8Dc: the DCs of the
; 16 Y blocks
WHT:
	movem.l	d2-d7,-(sp)
	lea	g_8Dc(a4),a0
	lea	-64(sp),sp		; tmp[16] (longs)
	move.l	sp,a1
	moveq	#4-1,d7
.v:	move.w	(a0),d0			; a0 = in[i] + in[12 + i] ...
	ext.l	d0
	move.w	24(a0),d1
	ext.l	d1
	move.w	8(a0),d2
	ext.l	d2
	move.w	16(a0),d3
	ext.l	d3
	move.l	d0,d4
	add.l	d1,d4			; a0
	sub.l	d1,d0			; a3
	move.l	d2,d5
	add.l	d3,d5			; a1
	sub.l	d3,d2			; a2
	move.l	d4,d6
	add.l	d5,d6
	move.l	d6,(a1)			; tmp[i] = a0 + a1
	sub.l	d5,d4
	move.l	d4,32(a1)		; tmp[8 + i] = a0 - a1
	move.l	d0,d6
	add.l	d2,d6
	move.l	d6,16(a1)		; tmp[4 + i] = a3 + a2
	sub.l	d2,d0
	move.l	d0,48(a1)		; tmp[12 + i] = a3 - a2
	addq.l	#2,a0
	addq.l	#4,a1
	dbf	d7,.v
	move.l	sp,a1
	move.l	g_8Coef(a4),a0
	moveq	#4-1,d7
.h:	move.l	(a1),d0			; dc = tmp[4i] + 3
	addq.l	#3,d0
	move.l	12(a1),d1
	move.l	d0,d2
	add.l	d1,d2			; a0 = dc + tmp[3]
	sub.l	d1,d0			; a3 = dc - tmp[3]
	move.l	4(a1),d3
	move.l	8(a1),d4
	move.l	d3,d5
	add.l	d4,d5			; a1
	sub.l	d4,d3			; a2
	move.l	d2,d6
	add.l	d5,d6
	asr.l	#3,d6
	move.w	d6,(a0)			; out[0] = (a0 + a1) >> 3
	move.l	d0,d6
	add.l	d3,d6
	asr.l	#3,d6
	move.w	d6,32(a0)		; out[16] = (a3 + a2) >> 3
	sub.l	d5,d2
	asr.l	#3,d2
	move.w	d2,64(a0)		; out[32] = (a0 - a1) >> 3
	sub.l	d3,d0
	asr.l	#3,d0
	move.w	d0,96(a0)		; out[48] = (a3 - a2) >> 3
	lea	16(a1),a1
	lea	128(a0),a0
	dbf	d7,.h
	lea	64(sp),sp
	movem.l	(sp)+,d2-d7
	rts

;--------------------------------------------------------------------
; Reconstruct - predict the macroblock, add the residuals, keep its
; bottom rows for the next row, copy it to the planes, note its loop
; filter
;--------------------------------------------------------------------
Reconstruct:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	move.l	g_8WB(a4),a6		; a6 = the work block
	move.l	g_8MbX(a4),d7
	beq.s	.left
	; the left column: the last 4 columns of the previous macroblock
	lea	WB_Y-BPS(a6),a0
	moveq	#17-1,d0
.ry:	move.l	12(a0),-4(a0)
	lea	BPS(a0),a0
	dbf	d0,.ry
	lea	WB_U-BPS(a6),a0
	bsr	RotUV
	lea	WB_V-BPS(a6),a0
	bsr	RotUV
	bra.s	.top
.left:	lea	WB_Y-1(a6),a0		; at the left edge: 129
	moveq	#16-1,d0
.ly:	move.b	#129,(a0)
	lea	BPS(a0),a0
	dbf	d0,.ly
	lea	WB_U-1(a6),a0
	bsr	LeftUV
	lea	WB_V-1(a6),a0
	bsr	LeftUV
	tst.l	g_8MbY(a4)		; (the top left too, below the top)
	beq.s	.top
	move.b	#129,WB_Y-BPS-1(a6)
	move.b	#129,WB_U-BPS-1(a6)
	move.b	#129,WB_V-BPS-1(a6)
.top:	tst.l	g_8MbY(a4)		; the top row: kept from above
	beq.s	.pred
	move.l	d7,d0
	lsl.l	#5,d0
	move.l	g_8Top(a4),a0
	add.l	d0,a0
	lea	WB_Y-BPS(a6),a1
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	lea	WB_U-BPS(a6),a1
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	lea	WB_V-BPS(a6),a1
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
.pred:	tst.l	g_8MI4(a4)
	beq	.p16
	; 4x4: the top right 4 pixels (from the next macroblock above), also
	; for the blocks on the right below
	tst.l	g_8MbY(a4)
	beq.s	.trd
	move.l	g_8Top(a4),a0
	move.l	d7,d0
	lsl.l	#5,d0
	add.l	d0,a0
	move.l	g_8MbW(a4),d1
	subq.l	#1,d1
	cmp.l	d1,d7
	blo.s	.trn
	move.b	15(a0),d0		; the last column: its last pixel
	lsl.w	#8,d0
	move.b	15(a0),d0
	move.w	d0,d1
	swap	d0
	move.w	d1,d0
	bra.s	.trs
.trn:	move.l	32(a0),d0
.trs:	move.l	d0,WB_Y-BPS+16(a6)
.trd:	move.l	WB_Y-BPS+16(a6),d0
	move.l	d0,WB_Y+3*BPS+16(a6)
	move.l	d0,WB_Y+7*BPS+16(a6)
	move.l	d0,WB_Y+11*BPS+16(a6)
	moveq	#0,d6			; block
.b4:	move.l	d6,d0			; a2 = its place
	lsr.l	#2,d0
	mulu.w	#4*BPS,d0
	moveq	#3,d1
	and.l	d6,d1
	lsl.l	#2,d1
	add.l	d1,d0
	lea	WB_Y(a6,d0.l),a2
	lea	g_8MModes(a4),a0
	moveq	#0,d0
	move.b	(a0,d6.l),d0
	bsr	Pred4
	move.l	d6,d0
	bsr	AddBlock
	addq.l	#1,d6
	cmp.l	#16,d6
	blo.s	.b4
	bra.s	.uv
.p16:	moveq	#0,d0			; 16x16
	move.b	g_8MModes(a4),d0
	lea	WB_Y(a6),a2
	moveq	#16,d1
	bsr	PredBig
	moveq	#0,d6
.b16:	move.l	d6,d0
	lsr.l	#2,d0
	mulu.w	#4*BPS,d0
	moveq	#3,d1
	and.l	d6,d1
	lsl.l	#2,d1
	add.l	d1,d0
	lea	WB_Y(a6,d0.l),a2
	move.l	d6,d0
	bsr	AddBlock
	addq.l	#1,d6
	cmp.l	#16,d6
	blo.s	.b16
.uv:	move.l	g_8MUV(a4),d0		; chroma
	lea	WB_U(a6),a2
	moveq	#8,d1
	bsr	PredBig
	move.l	g_8MUV(a4),d0
	lea	WB_V(a6),a2
	moveq	#8,d1
	bsr	PredBig
	moveq	#16,d6
.bc:	move.l	d6,d0			; U: 16-19, V: 20-23
	sub.l	#16,d0
	moveq	#3,d1
	and.l	d0,d1
	move.l	d1,d2
	lsr.l	#1,d2
	mulu.w	#4*BPS,d2
	and.l	#1,d1
	lsl.l	#2,d1
	add.l	d1,d2
	lea	WB_U(a6,d2.l),a2
	cmp.l	#20,d6
	blo.s	.bu
	lea	WB_V(a6,d2.l),a2
.bu:	move.l	d6,d0
	bsr	AddBlock
	addq.l	#1,d6
	cmp.l	#24,d6
	blo.s	.bc
	; the bottom rows for the next row of macroblocks
	move.l	d7,d0
	lsl.l	#5,d0
	move.l	g_8Top(a4),a0
	add.l	d0,a0
	lea	WB_Y+15*BPS(a6),a1
	move.l	(a1)+,(a0)+
	move.l	(a1)+,(a0)+
	move.l	(a1)+,(a0)+
	move.l	(a1)+,(a0)+
	lea	WB_U+7*BPS(a6),a1
	move.l	(a1)+,(a0)+
	move.l	(a1)+,(a0)+
	lea	WB_V+7*BPS(a6),a1
	move.l	(a1)+,(a0)+
	move.l	(a1)+,(a0)+
	; to the planes
	move.l	g_8MbY(a4),d0		; Y: + (mby * 16) * YS + mbx * 16
	lsl.l	#4,d0
	mulu.l	g_8YS(a4),d0
	move.l	d7,d1
	lsl.l	#4,d1
	add.l	d1,d0
	move.l	g_8Y(a4),a0
	add.l	d0,a0
	lea	WB_Y(a6),a1
	moveq	#16-1,d1
.cy:	move.l	(a1),(a0)
	move.l	4(a1),4(a0)
	move.l	8(a1),8(a0)
	move.l	12(a1),12(a0)
	lea	BPS(a1),a1
	add.l	g_8YS(a4),a0
	dbf	d1,.cy
	move.l	g_8MbY(a4),d0		; U, V: + (mby * 8) * US + mbx * 8
	lsl.l	#3,d0
	mulu.l	g_8US(a4),d0
	move.l	d7,d1
	lsl.l	#3,d1
	add.l	d1,d0
	move.l	d0,d2
	move.l	g_8U(a4),a0
	add.l	d0,a0
	lea	WB_U(a6),a1
	bsr	Copy8
	move.l	g_8V(a4),a0
	add.l	d2,a0
	lea	WB_V(a6),a1
	bsr	Copy8
	; the loop filter of this macroblock: segment, 4x4, coefficients
	move.l	g_8MbY(a4),d0
	mulu.l	g_8MbW(a4),d0
	add.l	d7,d0
	lsl.l	#2,d0
	move.l	g_8Info(a4),a0
	add.l	d0,a0
	move.l	g_8MSeg(a4),d0
	add.l	d0,d0
	add.l	g_8MI4(a4),d0
	move.l	g_8Strength(a4,d0.l*4),d0
	move.l	d0,(a0)			; limit, ilevel, hev,
	moveq	#1,d1
	tst.l	g_8MI4(a4)		; inner edges: 4x4 or coefficients
	bne.s	.in
	move.l	g_8MNz(a4),d1
.in:	move.b	d1,3(a0)
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; RotUV - U/V rows -1..7 at a0: columns 4-7 to -4..-1 (a6 kept)
RotUV:
	moveq	#9-1,d0
.r:	move.l	4(a0),-4(a0)
	lea	BPS(a0),a0
	dbf	d0,.r
	rts

; LeftUV - the left column of U/V at a0: 129 (a6 kept)
LeftUV:
	moveq	#8-1,d0
.l:	move.b	#129,(a0)
	lea	BPS(a0),a0
	dbf	d0,.l
	rts

; Copy8 - an 8x8 block of the work block a1 to the plane a0 (U/V
; rows) (a6 kept)
Copy8:
	moveq	#8-1,d1
.c:	move.l	(a1),(a0)
	move.l	4(a1),4(a0)
	lea	BPS(a1),a1
	add.l	g_8US(a4),a0
	dbf	d1,.c
	rts

;--------------------------------------------------------------------
; AddBlock - add the residual of block d0 (inverse DCT) to a2 (a6 kept)
;--------------------------------------------------------------------
AddBlock:
	lea	g_8BNz(a4),a0
	move.b	(a0,d0.l),d1
	beq.s	.x
	lsl.l	#5,d0
	move.l	g_8Coef(a4),a0
	add.l	d0,a0
	cmp.b	#1,d1
	beq	IdctDC
	bra	Idct
.x:	rts

; IdctDC - only a DC: add (dc + 4) >> 3 to the 4x4 pixels at a2
IdctDC:
	move.w	(a0),d0
	ext.l	d0
	addq.l	#4,d0
	asr.l	#3,d0
	move.l	a2,a1
	moveq	#4-1,d1
.r:	bsr.s	DcPx
	bsr.s	DcPx
	bsr.s	DcPx
	bsr.s	DcPx
	lea	BPS-4(a1),a1
	dbf	d1,.r
	rts

; DcPx - pixel a1 += d0, clipped; Out: a1 advanced (d0, d1 kept)
DcPx:
	move.l	d2,-(sp)
	moveq	#0,d2
	move.b	(a1),d2
	add.l	d0,d2
	bsr	Clip255
	move.b	d2,(a1)+
	move.l	(sp)+,d2
	rts

; Clip255 - d2 to 0..255; Out: d2 (d0, d1, a1 kept)
Clip255:
	tst.l	d2
	bpl.s	.p
	moveq	#0,d2
	rts
.p:	cmp.l	#255,d2
	bls.s	.x
	move.l	#255,d2
.x:	rts

; Idct - the 4x4 inverse DCT of block a0, added to the pixels at a2
; (libwebp's TransformOne); MUL1(x) = (x * 20091 >> 16) + x,
; MUL2(x) = x * 35468 >> 16 (swap + ext: >> 16, rounding down)
MUL1	MACRO				; \2 = MUL1(\1)
	move.l	\1,\2
	muls.l	#20091,\2
	swap	\2
	ext.l	\2
	add.l	\1,\2
	ENDM
MUL2	MACRO				; \2 = MUL2(\1)
	move.l	\1,\2
	muls.l	#35468,\2
	swap	\2
	ext.l	\2
	ENDM
; ISTORE - pixel (a3)+ += \1 >> 3, clipped to 0..255 (d0 changed)
ISTORE	MACRO
	asr.l	#3,\1
	moveq	#0,d0
	move.b	(a3),d0
	add.l	\1,d0
	cmp.l	#255,d0
	bls.s	.s\@
	smi	d0
	not.b	d0
.s\@:	move.b	d0,(a3)+
	ENDM
Idct:
	movem.l	d2-d7/a3,-(sp)
	lea	-64(sp),sp		; C[16] (longs)
	move.l	sp,a1
	moveq	#4-1,d7
.v:	move.w	(a0),d0			; in[0], in[4], in[8], in[12]
	ext.l	d0
	move.w	8(a0),d1
	ext.l	d1
	move.w	16(a0),d2
	ext.l	d2
	move.w	24(a0),d3
	ext.l	d3
	move.l	d0,d4
	add.l	d2,d4			; a = in0 + in8
	sub.l	d2,d0			; b = in0 - in8
	MUL2	d1,d5
	MUL1	d3,d6
	sub.l	d6,d5			; c = MUL2(in4) - MUL1(in12)
	MUL1	d1,d6
	MUL2	d3,d2
	add.l	d2,d6			; d = MUL1(in4) + MUL2(in12)
	move.l	d4,d2
	add.l	d6,d2
	move.l	d2,(a1)+		; a + d
	move.l	d0,d2
	add.l	d5,d2
	move.l	d2,(a1)+		; b + c
	sub.l	d5,d0
	move.l	d0,(a1)+		; b - c
	sub.l	d6,d4
	move.l	d4,(a1)+		; a - d
	addq.l	#2,a0
	dbf	d7,.v
	move.l	sp,a1
	move.l	a2,a3
	moveq	#4-1,d7
.h:	move.l	(a1),d4			; dc = tmp[0] + 4
	addq.l	#4,d4
	move.l	32(a1),d2
	move.l	d4,d1
	add.l	d2,d4			; a = dc + tmp[8]
	sub.l	d2,d1			; b = dc - tmp[8]
	move.l	16(a1),d2		; tmp[4]
	move.l	48(a1),d3		; tmp[12]
	MUL2	d2,d5
	MUL1	d3,d6
	sub.l	d6,d5			; c
	MUL1	d2,d6
	MUL2	d3,d3
	add.l	d3,d6			; d
	move.l	d4,d2			; a + d, b + c, b - c, a - d
	add.l	d6,d2
	ISTORE	d2
	move.l	d1,d2
	add.l	d5,d2
	ISTORE	d2
	sub.l	d5,d1
	ISTORE	d1
	sub.l	d6,d4
	ISTORE	d4
	lea	BPS-4(a3),a3
	addq.l	#4,a1
	dbf	d7,.h
	lea	64(sp),sp
	movem.l	(sp)+,d2-d7/a3
	rts

;--------------------------------------------------------------------
; PredBig - 16x16 (d1 = 16) or chroma 8x8 (d1 = 8) prediction of mode
; d0 at a2 (DC by what there is: top, left, neither) (a6 kept)
;--------------------------------------------------------------------
PredBig:
	movem.l	d2-d7/a3,-(sp)
	move.l	d1,d7			; d7 = size
	cmp.l	#1,d0
	beq	.tm
	cmp.l	#2,d0
	beq	.ve
	cmp.l	#3,d0
	beq	.he
	; DC: the sum of the top and left that exist
	moveq	#0,d2			; sum
	moveq	#0,d3			; how many
	tst.l	g_8MbY(a4)
	beq.s	.nt
	lea	-BPS(a2),a0
	move.l	d7,d1
	subq.l	#1,d1
.st:	moveq	#0,d0
	move.b	(a0)+,d0
	add.l	d0,d2
	dbf	d1,.st
	add.l	d7,d3
.nt:	tst.l	g_8MbX(a4)
	beq.s	.nl
	lea	-1(a2),a0
	move.l	d7,d1
	subq.l	#1,d1
.sl:	moveq	#0,d0
	move.b	(a0),d0
	add.l	d0,d2
	lea	BPS(a0),a0
	dbf	d1,.sl
	add.l	d7,d3
.nl:	move.l	#128,d0
	tst.l	d3
	beq.s	.fill
	move.l	d3,d0			; (sum + n/2) / n
	lsr.l	#1,d0
	add.l	d2,d0
	divu.w	d3,d0
	and.l	#$ffff,d0
.fill:	move.l	a2,a0			; all of it d0
	move.l	d7,d2
	subq.l	#1,d2
.fr:	move.l	d7,d1
	subq.l	#1,d1
	move.l	a0,a1
.fc:	move.b	d0,(a1)+
	dbf	d1,.fc
	lea	BPS(a0),a0
	dbf	d2,.fr
	bra	.x
.ve:	move.l	a2,a0			; each row: the top row
	move.l	d7,d2
	subq.l	#1,d2
.vr:	move.l	d7,d1
	subq.l	#1,d1
	lea	-BPS(a2),a1
	move.l	a0,a3
.vc:	move.b	(a1)+,(a3)+
	dbf	d1,.vc
	lea	BPS(a0),a0
	dbf	d2,.vr
	bra.s	.x
.he:	move.l	a2,a0			; each row: its left pixel
	move.l	d7,d2
	subq.l	#1,d2
.hr:	move.b	-1(a0),d0
	move.l	d7,d1
	subq.l	#1,d1
	move.l	a0,a1
.hc:	move.b	d0,(a1)+
	dbf	d1,.hc
	lea	BPS(a0),a0
	dbf	d2,.hr
	bra.s	.x
.tm:	moveq	#0,d5			; top + left - top left
	move.b	-BPS-1(a2),d5
	move.l	a2,a0
	moveq	#0,d6			; row
.tr:	moveq	#0,d4
	move.b	-1(a0),d4
	sub.l	d5,d4			; left - top left
	moveq	#0,d3			; column
.tc:	moveq	#0,d2
	move.b	-BPS(a2,d3.l),d2
	add.l	d4,d2
	bsr	Clip255
	move.b	d2,(a0,d3.l)
	addq.l	#1,d3
	cmp.l	d7,d3
	blo.s	.tc
	lea	BPS(a0),a0
	addq.l	#1,d6
	cmp.l	d7,d6
	blo.s	.tr
.x:	movem.l	(sp)+,d2-d7/a3
	rts

;--------------------------------------------------------------------
; Pred4 - 4x4 prediction of mode d0 at a2
;--------------------------------------------------------------------
Pred4:
	movem.l	d2-d6,-(sp)
	lea	-16(sp),sp		; the edge: L K J I X A B C D E F G H
	move.b	3*BPS-1(a2),(sp)
	move.b	2*BPS-1(a2),1(sp)
	move.b	BPS-1(a2),2(sp)
	move.b	-1(a2),3(sp)
	move.b	-BPS-1(a2),4(sp)
	lea	-BPS(a2),a0
	lea	5(sp),a1
	moveq	#8-1,d1
.e:	move.b	(a0)+,(a1)+
	dbf	d1,.e
	cmp.l	#1,d0
	bhi.s	.tab
	beq.s	.tm
	moveq	#4,d2			; DC: (top + left + 4) >> 3
	moveq	#0,d1
	moveq	#4-1,d3
.dc:	move.b	(sp,d3.l),d1
	add.l	d1,d2
	move.b	5(sp,d3.l),d1
	add.l	d1,d2
	dbf	d3,.dc
	lsr.l	#3,d2
	move.l	a2,a0
	moveq	#4-1,d3
.dr:	move.b	d2,(a0)
	move.b	d2,1(a0)
	move.b	d2,2(a0)
	move.b	d2,3(a0)
	lea	BPS(a0),a0
	dbf	d3,.dr
	bra	.x
.tm:	moveq	#0,d5			; TM: top + left - top left
	move.b	4(sp),d5
	moveq	#0,d4			; row
.tr:	moveq	#3,d0			; left of row y: edge[3 - y]
	sub.l	d4,d0
	moveq	#0,d6
	move.b	(sp,d0.l),d6
	sub.l	d5,d6
	move.l	d4,d0
	lsl.l	#5,d0			; (BPS)
	lea	(a2,d0.l),a0
	moveq	#0,d3
.tc:	moveq	#0,d2
	move.b	5(sp,d3.l),d2
	add.l	d6,d2
	bsr	Clip255
	move.b	d2,(a0)+
	addq.l	#1,d3
	cmp.l	#4,d3
	blo.s	.tc
	addq.l	#1,d4
	cmp.l	#4,d4
	blo.s	.tr
	bra.s	.x
.tab:	subq.l	#2,d0			; the others: straight code
	move.w	Pred4Modes(pc,d0.l*2),d0
	jsr	Pred4Modes(pc,d0.w)
.x:	lea	16(sp),sp
	movem.l	(sp)+,d2-d6
	rts

;--------------------------------------------------------------------
; Filter - the loop filter, macroblock by macroblock (as libwebp)
;--------------------------------------------------------------------
Filter:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	bsr	FilterTabs
	move.l	g_8Info(a4),a6
	moveq	#0,d7			; y
.y:	cmp.l	g_8MbH(a4),d7
	bhs	.x
	moveq	#0,d6			; x
.mb:	cmp.l	g_8MbW(a4),d6
	bhs	.yn
	moveq	#0,d5
	move.b	(a6),d5			; limit
	beq	.next
	move.l	d7,d0			; a2 = Y, a3 = U, a5 = V
	lsl.l	#4,d0
	mulu.l	g_8YS(a4),d0
	move.l	d6,d1
	lsl.l	#4,d1
	add.l	d1,d0
	move.l	g_8Y(a4),a2
	add.l	d0,a2
	move.l	d7,d0
	lsl.l	#3,d0
	mulu.l	g_8US(a4),d0
	move.l	d6,d1
	lsl.l	#3,d1
	add.l	d1,d0
	move.l	g_8U(a4),a3
	add.l	d0,a3
	move.l	g_8V(a4),a5
	add.l	d0,a5
	moveq	#0,d0
	move.b	1(a6),d0
	move.l	d0,g_8FI(a4)		; interior limit
	move.b	2(a6),d0
	move.l	d0,g_8FHev(a4)		; high edge variance
	; the left edge (vertical: across it is 1, along it a row)
	tst.l	d6
	beq.s	.nl
	move.l	d5,d0
	addq.l	#4,d0
	moveq	#2,d1			; (MB edge: 6 taps)
	bsr	.vert
.nl:	tst.b	3(a6)			; the inner vertical edges
	beq.s	.ni
	moveq	#4,d4
.iv:	move.l	d5,d0
	moveq	#1,d1			; (inner: 4 taps)
	add.l	d4,a2
	add.l	d4,a3
	add.l	d4,a5
	bsr	.vert
	sub.l	d4,a2
	sub.l	d4,a3
	sub.l	d4,a5
	addq.l	#4,d4
	cmp.l	#16,d4
	blo.s	.iv
.ni:	tst.l	d7			; the top edge
	beq.s	.nt
	move.l	d5,d0
	addq.l	#4,d0
	moveq	#2,d1
	bsr	.horz
.nt:	tst.b	3(a6)			; inner horizontal edges
	beq.s	.next
	moveq	#4,d4
.ih:	move.l	d4,d0
	mulu.l	g_8YS(a4),d0
	add.l	d0,a2
	move.l	d0,-(sp)
	move.l	d4,d0			; (U/V: only at 4, filtered then)
	mulu.l	g_8US(a4),d0
	move.l	d0,-(sp)
	add.l	d0,a3
	add.l	d0,a5
	move.l	d5,d0
	moveq	#1,d1
	bsr	.horz
	move.l	(sp)+,d0
	sub.l	d0,a3
	sub.l	d0,a5
	move.l	(sp)+,d0
	sub.l	d0,a2
	addq.l	#4,d4
	cmp.l	#16,d4
	blo.s	.ih
.next:	addq.l	#4,a6
	addq.l	#1,d6
	bra	.mb
.yn:	addq.l	#1,d7
	bra	.y
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts
; .vert - a vertical edge at a2 (Y), a3/a5 (U/V unless inner Y-only
; positions); d0 = limit, d1 = 2 (MB edge) or 1 (inner)
.vert:	move.l	d0,g_8FT(a4)
	move.l	d1,g_8FKind(a4)
	moveq	#1,d0
	move.l	d0,g_8FH(a4)		; across: 1
	move.l	g_8YS(a4),g_8FV(a4)	; along: a row
	move.l	a2,a0
	moveq	#16,d0
	bsr	Edge
	cmp.l	#1,g_8FType(a4)		; simple: luma only
	beq.s	.v1
	cmp.l	#1,d1			; inner: U/V only at 4
	bne.s	.vuv
	cmp.l	#4,d4
	bne.s	.v1
.vuv:	move.l	g_8US(a4),g_8FV(a4)
	move.l	a3,a0
	moveq	#8,d0
	bsr	Edge
	move.l	a5,a0
	moveq	#8,d0
	bsr	Edge
.v1:	rts
.horz:	move.l	d0,g_8FT(a4)
	move.l	d1,g_8FKind(a4)
	move.l	g_8YS(a4),g_8FH(a4)	; across: a row
	moveq	#1,d0
	move.l	d0,g_8FV(a4)		; along: 1
	move.l	a2,a0
	moveq	#16,d0
	bsr	Edge
	cmp.l	#1,g_8FType(a4)
	beq.s	.h1
	cmp.l	#1,g_8FKind(a4)
	bne.s	.huv
	cmp.l	#4,d4
	bne.s	.h1
.huv:	move.l	g_8US(a4),g_8FH(a4)
	move.l	a3,a0
	moveq	#8,d0
	bsr	Edge
	move.l	a5,a0
	moveq	#8,d0
	bsr	Edge
.h1:	rts

; loop filter tables (FilterTabs): word tables, offsets of their centre
TAB_AB		equ	255*2			; |v|, v = -255..255
TAB_SC1		equ	511*2+1020*2		; clip -128..127 of -1020..1020
TAB_SC2		equ	(511+2041)*2+112*2	; clip -16..15 of -112..112
TAB_C1		equ	(511+2041+225)*2+255*2	; clip 0..255 of -255..511
TAB_27		equ	(511+2041+225+767)*2+128*2	; (27a + 63) >> 7
TAB_18		equ	TAB_27+256*2		; (18a + 63) >> 7
TAB_9		equ	TAB_18+256*2		; (9a + 63) >> 7


;--------------------------------------------------------------------
; Edge - filter d0 pixels along an edge at a0 (q0 of the first):
; g_8FH = step across it, g_8FV = step along it, g_8FT = limit,
; g_8FI = interior limit, g_8FHev = high edge variance threshold,
; g_8FKind = 2 (6 taps on MB edges) or 1 (4 taps inside); the simple
; filter (2 taps) if g_8FType = 1.  libwebp's filters, with its tables
; (FilterTabs); the taps are read where they are: p1 = (a0,-2s),
; p0 = (a0,-s), q1 = (a0,s), q2 = (a0,2s), p2/p3 from a1 = a0 - 3s,
; q3 = (a2) = a0 + 3s
; (d1 kept)
;--------------------------------------------------------------------
Edge:
	movem.l	d1-d7/a1-a3/a6,-(sp)
	lea	g_8FTab(a4),a6
	move.l	d0,g_8FCnt(a4)
	move.l	g_8FH(a4),d6		; d6 = s, d5 = -s
	move.l	d6,d5
	neg.l	d5
	move.l	g_8FT(a4),d0		; thresh2 = 2 * limit + 1
	add.l	d0,d0
	addq.l	#1,d0
	move.w	d0,g_8FT2(a4)
	move.l	g_8FV(a4),a3		; a3 = step along
	lea	(a0,d5.l*2),a1
	add.l	d5,a1			; a1 = p2
	lea	(a0,d6.l*2),a2
	add.l	d6,a2			; a2 = q3
.px:	moveq	#0,d0
	move.b	(a0,d5.l*2),d0		; p1
	moveq	#0,d1
	move.b	(a0,d5.l),d1		; p0
	moveq	#0,d2
	move.b	(a0),d2			; q0
	moveq	#0,d3
	move.b	(a0,d6.l),d3		; q1
	move.w	d1,d4			; 4 |p0 - q0| + |p1 - q1| <= thresh2
	sub.w	d2,d4
	move.w	TAB_AB(a6,d4.w*2),d4
	add.w	d4,d4
	add.w	d4,d4
	move.w	d0,d7
	sub.w	d3,d7
	add.w	TAB_AB(a6,d7.w*2),d4
	cmp.w	g_8FT2(a4),d4
	bhi	.next
	cmp.l	#1,g_8FType(a4)		; simple: 2 taps, always
	beq	.f2
	moveq	#0,d4			; d4 = high edge variance
	move.w	d0,d7			; interior differences <= ilevel
	sub.w	d1,d7
	move.w	TAB_AB(a6,d7.w*2),d7	; |p1 - p0|
	cmp.w	g_8FI+2(a4),d7
	bhi	.next
	cmp.w	g_8FHev+2(a4),d7
	bls.s	.h1
	moveq	#1,d4
.h1:	move.w	d3,d7
	sub.w	d2,d7
	move.w	TAB_AB(a6,d7.w*2),d7	; |q1 - q0|
	cmp.w	g_8FI+2(a4),d7
	bhi	.next
	cmp.w	g_8FHev+2(a4),d7
	bls.s	.h2
	moveq	#1,d4
.h2:	moveq	#0,d7
	move.b	(a1),d7			; p2
	move.w	d7,g_8FTmp(a4)
	sub.w	d0,d7
	move.w	TAB_AB(a6,d7.w*2),d7	; |p2 - p1|
	cmp.w	g_8FI+2(a4),d7
	bhi	.next
	moveq	#0,d7
	move.b	(a1,d5.l),d7		; p3
	sub.w	g_8FTmp(a4),d7
	move.w	TAB_AB(a6,d7.w*2),d7	; |p3 - p2|
	cmp.w	g_8FI+2(a4),d7
	bhi	.next
	moveq	#0,d7
	move.b	(a0,d6.l*2),d7		; q2
	move.w	d7,g_8FTmp(a4)
	sub.w	d3,d7
	move.w	TAB_AB(a6,d7.w*2),d7	; |q2 - q1|
	cmp.w	g_8FI+2(a4),d7
	bhi	.next
	moveq	#0,d7
	move.b	(a2),d7			; q3
	sub.w	g_8FTmp(a4),d7
	move.w	TAB_AB(a6,d7.w*2),d7	; |q3 - q2|
	cmp.w	g_8FI+2(a4),d7
	bhi	.next
	tst.w	d4			; high variance: 2 taps
	bne.s	.f2
	cmp.l	#2,g_8FKind(a4)
	beq.s	.f6
	; 4 taps: a = 3 (q0 - p0)
	move.w	d2,d4
	sub.w	d1,d4
	move.w	d4,d7
	add.w	d4,d4
	add.w	d7,d4
	move.w	d4,d7
	addq.w	#4,d4
	asr.w	#3,d4
	move.w	TAB_SC2(a6,d4.w*2),d4	; a1
	addq.w	#3,d7
	asr.w	#3,d7
	move.w	TAB_SC2(a6,d7.w*2),d7	; a2
	add.w	d7,d1			; p0 + a2
	move.w	TAB_C1(a6,d1.w*2),d1
	move.b	d1,(a0,d5.l)
	sub.w	d4,d2			; q0 - a1
	move.w	TAB_C1(a6,d2.w*2),d2
	move.b	d2,(a0)
	addq.w	#1,d4			; a3 = (a1 + 1) >> 1
	asr.w	#1,d4
	add.w	d4,d0			; p1 + a3
	move.w	TAB_C1(a6,d0.w*2),d0
	move.b	d0,(a0,d5.l*2)
	sub.w	d4,d3			; q1 - a3
	move.w	TAB_C1(a6,d3.w*2),d3
	move.b	d3,(a0,d6.l)
	bra	.next
.f2:	; 2 taps: a = 3 (q0 - p0) + sclip1(p1 - q1)
	move.w	d2,d4
	sub.w	d1,d4
	move.w	d4,d7
	add.w	d4,d4
	add.w	d7,d4
	move.w	d0,d7
	sub.w	d3,d7
	add.w	TAB_SC1(a6,d7.w*2),d4
	move.w	d4,d7
	addq.w	#4,d4
	asr.w	#3,d4
	move.w	TAB_SC2(a6,d4.w*2),d4	; a1
	addq.w	#3,d7
	asr.w	#3,d7
	move.w	TAB_SC2(a6,d7.w*2),d7	; a2
	add.w	d7,d1
	move.w	TAB_C1(a6,d1.w*2),d1
	move.b	d1,(a0,d5.l)
	sub.w	d4,d2
	move.w	TAB_C1(a6,d2.w*2),d2
	move.b	d2,(a0)
	bra.s	.next
.f6:	; 6 taps: a = sclip1(3 (q0 - p0) + sclip1(p1 - q1))
	move.w	d2,d4
	sub.w	d1,d4
	move.w	d4,d7
	add.w	d4,d4
	add.w	d7,d4
	move.w	d0,d7
	sub.w	d3,d7
	add.w	TAB_SC1(a6,d7.w*2),d4
	move.w	TAB_SC1(a6,d4.w*2),d4	; a
	move.w	TAB_27(a6,d4.w*2),d7	; p0 + a1, q0 - a1
	add.w	d7,d1
	move.w	TAB_C1(a6,d1.w*2),d1
	move.b	d1,(a0,d5.l)
	sub.w	d7,d2
	move.w	TAB_C1(a6,d2.w*2),d2
	move.b	d2,(a0)
	move.w	TAB_18(a6,d4.w*2),d7	; p1 + a2, q1 - a2
	add.w	d7,d0
	move.w	TAB_C1(a6,d0.w*2),d0
	move.b	d0,(a0,d5.l*2)
	sub.w	d7,d3
	move.w	TAB_C1(a6,d3.w*2),d3
	move.b	d3,(a0,d6.l)
	move.w	TAB_9(a6,d4.w*2),d7	; p2 + a3, q2 - a3
	moveq	#0,d0
	move.b	(a1),d0
	add.w	d7,d0
	move.w	TAB_C1(a6,d0.w*2),d0
	move.b	d0,(a1)
	moveq	#0,d0
	move.b	(a0,d6.l*2),d0
	sub.w	d7,d0
	move.w	TAB_C1(a6,d0.w*2),d0
	move.b	d0,(a0,d6.l*2)
.next:	add.l	a3,a0
	add.l	a3,a1
	add.l	a3,a2
	subq.l	#1,g_8FCnt(a4)
	bne	.px
	movem.l	(sp)+,d1-d7/a1-a3/a6
	rts

; FilterTabs - the loop filter's tables (once)
FilterTabs:
	tst.l	g_8FTabOk(a4)
	bne	.x
	movem.l	d2-d3,-(sp)
	lea	g_8FTab(a4),a0
	move.l	#-255,d1		; |v|
.ab:	move.l	d1,d0
	bpl.s	.ab1
	neg.l	d0
.ab1:	move.w	d0,(a0)+
	addq.l	#1,d1
	cmp.l	#255,d1
	ble.s	.ab
	move.l	#-1020,d1		; -128..127
	moveq	#-128,d2
	moveq	#127,d3
	move.l	#1020,d0
	bsr.s	.clip
	moveq	#-112,d1		; -16..15
	moveq	#-16,d2
	moveq	#15,d3
	moveq	#112,d0
	bsr.s	.clip
	move.l	#-255,d1		; 0..255
	moveq	#0,d2
	move.l	#255,d3
	move.l	#511,d0
	bsr.s	.clip
	moveq	#27,d2			; (k a + 63) >> 7
	bsr.s	.mul
	moveq	#18,d2
	bsr.s	.mul
	moveq	#9,d2
	bsr.s	.mul
	moveq	#1,d0
	move.l	d0,g_8FTabOk(a4)
	movem.l	(sp)+,d2-d3
.x:	rts
.clip:	move.l	d0,-(sp)		; v = d1 .. (sp): clamp to d2 .. d3
.cl:	move.l	d1,d0
	cmp.l	d2,d0
	bge.s	.c1
	move.l	d2,d0
.c1:	cmp.l	d3,d0
	ble.s	.c2
	move.l	d3,d0
.c2:	move.w	d0,(a0)+
	addq.l	#1,d1
	cmp.l	(sp),d1
	ble.s	.cl
	addq.l	#4,sp
	rts
.mul:	move.l	#-128,d1
.m:	move.l	d1,d0
	muls.l	d2,d0
	add.l	#63,d0
	asr.l	#7,d0
	move.w	d0,(a0)+
	addq.l	#1,d1
	cmp.l	#127,d1
	ble.s	.m
	rts

; A12 - from a (d0)
; Out: d1 = sclip2((a + 4) >> 3), d2 = sclip2((a + 3) >> 3)
A12:
	move.l	d0,-(sp)
	addq.l	#4,d0
	asr.l	#3,d0
	bsr.s	Sat16
	move.l	d0,d1
	move.l	(sp)+,d0
	addq.l	#3,d0
	asr.l	#3,d0
	bsr.s	Sat16
	move.l	d0,d2
	rts

; Abs - |d0|; Out: d0 (d1 kept)
Abs:
	tst.l	d0
	bpl.s	.x
	neg.l	d0
.x:	rts
; Sat128 - d0 to -128..127; Out: d0 (d1 kept)
Sat128:
	cmp.l	#-128,d0
	bge.s	.h
	moveq	#-128,d0
	rts
.h:	cmp.l	#127,d0
	ble.s	.x
	moveq	#127,d0
.x:	rts
; Sat16 - d0 to -16..15; Out: d0 (d1 kept)
Sat16:
	cmp.l	#-16,d0
	bge.s	.h
	moveq	#-16,d0
	rts
.h:	cmp.l	#15,d0
	ble.s	.x
	moveq	#15,d0
.x:	rts
; Clip0 - d0 to 0..255; Out: d0 (d1, a6 kept)
Clip0:
	tst.l	d0
	bpl.s	.p
	moveq	#0,d0
	rts
.p:	cmp.l	#255,d0
	bls.s	.x
	move.l	#255,d0
.x:	rts

;--------------------------------------------------------------------
; ToARGB - the planes to the ARGB image: libwebp's YUV to RGB, with
; its "fancy" upsampling of the chroma (each pixel 9:3:3:1 from the
; four nearest samples, mirrored at the edges)
;--------------------------------------------------------------------
ToARGB:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	move.l	g_8Rgb(a4),a5		; tables: (v * k) >> 8 (- offset)
	moveq	#0,d1
.t:	move.l	d1,d0
	mulu.w	#19077,d0
	lsr.l	#8,d0
	move.w	d0,(a5,d1.l*2)		; Y
	move.l	d1,d0
	mulu.w	#26149,d0
	lsr.l	#8,d0
	sub.l	#14234,d0
	move.w	d0,512(a5,d1.l*2)	; V -> R
	move.l	d1,d0
	mulu.w	#6419,d0
	lsr.l	#8,d0
	move.w	d0,1024(a5,d1.l*2)	; U -> G
	move.l	d1,d0
	mulu.w	#13320,d0
	lsr.l	#8,d0
	move.w	d0,1536(a5,d1.l*2)	; V -> G
	move.l	d1,d0
	mulu.w	#33050,d0
	lsr.l	#8,d0
	sub.l	#17685,d0
	move.w	d0,2048(a5,d1.l*2)	; U -> B
	addq.l	#1,d1
	cmp.w	#256,d1
	blo.s	.t
	move.l	g_8Clip(a4),a6		; clip: (v >> 6) + 256
	moveq	#0,d1
.c:	move.l	d1,d0
	sub.l	#256,d0
	bsr	Clip0
	move.b	d0,(a6,d1.l)
	addq.l	#1,d1
	cmp.w	#1024,d1
	blo.s	.c
	moveq	#0,d7			; row
.y:	cmp.l	g_8H(a4),d7
	bhs	.x
	; the chroma rows: row 0 and the last of an even height mirror;
	; row 2k+1: near k, far k+1; row 2k+2: near k+1, far k
	move.l	d7,d5			; d5 = near, d6 = far
	move.l	d7,d6
	beq.s	.nf
	move.l	d7,d0
	subq.l	#1,d0
	lsr.l	#1,d0			; k
	move.l	d0,d5
	move.l	d0,d6
	addq.l	#1,d6
	btst	#0,d7
	bne.s	.odd
	exg	d5,d6
	bra.s	.nf
.odd:	move.l	d7,d0			; the last row of an even height
	addq.l	#1,d0
	cmp.l	g_8H(a4),d0
	bne.s	.nf
	move.l	d5,d6
.nf:	mulu.l	g_8US(a4),d5
	mulu.l	g_8US(a4),d6
	move.l	g_8U(a4),a0
	add.l	d5,a0
	move.l	g_8U(a4),a1
	add.l	d6,a1
	move.l	g_8Rgb(a4),a2		; (the row of U after the tables)
	lea	2560(a2),a2
	move.l	a2,-(sp)
	bsr	UpLine
	move.l	g_8V(a4),a0
	add.l	d5,a0
	move.l	g_8V(a4),a1
	add.l	d6,a1
	move.l	(sp),a2
	add.l	g_8YS(a4),a2
	bsr	UpLine
	move.l	(sp)+,a1		; a1 = U, a2 = V of each pixel
	move.l	a1,a2
	add.l	g_8YS(a4),a2
	move.l	d7,d0			; a0 = Y row
	mulu.l	g_8YS(a4),d0
	move.l	g_8Y(a4),a0
	add.l	d0,a0
	move.l	d7,d0			; a3 = the pixels
	mulu.l	g_8W(a4),d0
	move.l	g_PicData(a4),a3
	lea	(a3,d0.l*4),a3
	move.l	g_8W(a4),d6
	subq.l	#1,d6
.px:	moveq	#0,d0
	move.b	(a0)+,d0
	move.w	(a5,d0.l*2),d2		; d2 = Y term
	ext.l	d2
	moveq	#0,d3
	move.b	(a1)+,d3		; d3 = U
	moveq	#0,d4
	move.b	(a2)+,d4		; d4 = V
	move.b	#$ff,(a3)+
	move.w	512(a5,d4.l*2),d0	; R = Y + V
	ext.l	d0
	add.l	d2,d0
	asr.l	#6,d0
	add.l	#256,d0
	and.l	#1023,d0
	move.b	(a6,d0.l),(a3)+
	move.l	d2,d0			; G = Y - U - V + 8708
	move.w	1024(a5,d3.l*2),d1
	ext.l	d1
	sub.l	d1,d0
	move.w	1536(a5,d4.l*2),d1
	ext.l	d1
	sub.l	d1,d0
	add.l	#8708,d0
	asr.l	#6,d0
	add.l	#256,d0
	and.l	#1023,d0
	move.b	(a6,d0.l),(a3)+
	move.w	2048(a5,d3.l*2),d0	; B = Y + U
	ext.l	d0
	add.l	d2,d0
	asr.l	#6,d0
	add.l	#256,d0
	and.l	#1023,d0
	move.b	(a6,d0.l),(a3)+
	dbf	d6,.px
	addq.l	#1,d7
	bra	.y
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; UpLine - one row of upsampled chroma (g_8W samples) to a2 from the
; nearer row a0 and the farther row a1 of chroma samples (libwebp's
; arithmetic, so that the result is the same)
UpLine:
	movem.l	d2-d7/a2,-(sp)
	moveq	#0,d2			; x = 0: (3 near + far + 2) >> 2
	move.b	(a0),d2
	moveq	#0,d3
	move.b	(a1),d3
	move.l	d2,d0
	add.l	d0,d0
	add.l	d2,d0
	add.l	d3,d0
	addq.l	#2,d0
	lsr.l	#2,d0
	move.b	d0,(a2)+
	move.l	g_8W(a4),d7		; pairs: x = 1 .. (W - 1) / 2
	subq.l	#1,d7
	lsr.l	#1,d7
	moveq	#1,d6
.p:	cmp.l	d7,d6
	bhi.s	.end
	moveq	#0,d4			; near[x], far[x]
	move.b	(a0,d6.l),d4
	moveq	#0,d5
	move.b	(a1,d6.l),d5
	move.l	d2,d1			; avg = near[x-1] + near[x] +
	add.l	d3,d1			;	far[x-1] + far[x] + 8
	add.l	d4,d1
	add.l	d5,d1
	addq.l	#8,d1
	move.l	d4,d0			; 2x-1: ((avg + 2 (near[x] +
	add.l	d3,d0			; far[x-1])) >> 3 + near[x-1]) >> 1
	add.l	d0,d0
	add.l	d1,d0
	lsr.l	#3,d0
	add.l	d2,d0
	lsr.l	#1,d0
	move.b	d0,(a2)+
	move.l	d2,d0			; 2x: ((avg + 2 (near[x-1] +
	add.l	d5,d0			; far[x])) >> 3 + near[x]) >> 1
	add.l	d0,d0
	add.l	d1,d0
	lsr.l	#3,d0
	add.l	d4,d0
	lsr.l	#1,d0
	move.b	d0,(a2)+
	move.l	d4,d2
	move.l	d5,d3
	addq.l	#1,d6
	bra.s	.p
.end:	btst	#0,g_8W+3(a4)		; an even width: the last pixel
	bne.s	.x
	move.l	d2,d0
	add.l	d0,d0
	add.l	d2,d0
	add.l	d3,d0
	addq.l	#2,d0
	lsr.l	#2,d0
	move.b	d0,(a2)+
.x:	movem.l	(sp)+,d2-d7/a2
	rts

	include	"vp8tab.i"

; the 4x4 predictions of modes 2-9 (VE HE RD VR LD VL HD HU) as
; straight code, generated from libwebp's formulas: each value once,
; then to every pixel that has it; the edge (L K J I X A..H, bytes)
; is on the stack at (sp) (0 L .. 12 H), a2 = the block, BPS a row
Pred4Modes:
	dc.w	P4_VE-Pred4Modes
	dc.w	P4_HE-Pred4Modes
	dc.w	P4_RD-Pred4Modes
	dc.w	P4_VR-Pred4Modes
	dc.w	P4_LD-Pred4Modes
	dc.w	P4_VL-Pred4Modes
	dc.w	P4_HD-Pred4Modes
	dc.w	P4_HU-Pred4Modes
P4_VE:
	moveq	#0,d0
	move.b	4+4(sp),d0
	moveq	#0,d1
	move.b	5+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,(a2)
	move.b	d0,32(a2)
	move.b	d0,64(a2)
	move.b	d0,96(a2)
	moveq	#0,d0
	move.b	5+4(sp),d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,1(a2)
	move.b	d0,33(a2)
	move.b	d0,65(a2)
	move.b	d0,97(a2)
	moveq	#0,d0
	move.b	6+4(sp),d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,2(a2)
	move.b	d0,34(a2)
	move.b	d0,66(a2)
	move.b	d0,98(a2)
	moveq	#0,d0
	move.b	7+4(sp),d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	9+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,3(a2)
	move.b	d0,35(a2)
	move.b	d0,67(a2)
	move.b	d0,99(a2)
	rts
P4_HE:
	moveq	#0,d0
	move.b	4+4(sp),d0
	moveq	#0,d1
	move.b	3+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,(a2)
	move.b	d0,1(a2)
	move.b	d0,2(a2)
	move.b	d0,3(a2)
	moveq	#0,d0
	move.b	3+4(sp),d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,32(a2)
	move.b	d0,33(a2)
	move.b	d0,34(a2)
	move.b	d0,35(a2)
	moveq	#0,d0
	move.b	2+4(sp),d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	0+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,64(a2)
	move.b	d0,65(a2)
	move.b	d0,66(a2)
	move.b	d0,67(a2)
	moveq	#0,d0
	move.b	1+4(sp),d0
	moveq	#0,d1
	move.b	0+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	0+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,96(a2)
	move.b	d0,97(a2)
	move.b	d0,98(a2)
	move.b	d0,99(a2)
	rts
P4_RD:
	moveq	#0,d0
	move.b	2+4(sp),d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	0+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,96(a2)
	moveq	#0,d0
	move.b	3+4(sp),d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,97(a2)
	move.b	d0,64(a2)
	moveq	#0,d0
	move.b	4+4(sp),d0
	moveq	#0,d1
	move.b	3+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,98(a2)
	move.b	d0,65(a2)
	move.b	d0,32(a2)
	moveq	#0,d0
	move.b	5+4(sp),d0
	moveq	#0,d1
	move.b	4+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	3+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,99(a2)
	move.b	d0,66(a2)
	move.b	d0,33(a2)
	move.b	d0,(a2)
	moveq	#0,d0
	move.b	6+4(sp),d0
	moveq	#0,d1
	move.b	5+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	4+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,67(a2)
	move.b	d0,34(a2)
	move.b	d0,1(a2)
	moveq	#0,d0
	move.b	7+4(sp),d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	5+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,35(a2)
	move.b	d0,2(a2)
	moveq	#0,d0
	move.b	8+4(sp),d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,3(a2)
	rts
P4_VR:
	moveq	#0,d0
	move.b	4+4(sp),d0
	moveq	#0,d1
	move.b	5+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,(a2)
	move.b	d0,65(a2)
	moveq	#0,d0
	move.b	5+4(sp),d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,1(a2)
	move.b	d0,66(a2)
	moveq	#0,d0
	move.b	6+4(sp),d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,2(a2)
	move.b	d0,67(a2)
	moveq	#0,d0
	move.b	7+4(sp),d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,3(a2)
	moveq	#0,d0
	move.b	1+4(sp),d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	3+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,96(a2)
	moveq	#0,d0
	move.b	2+4(sp),d0
	moveq	#0,d1
	move.b	3+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	4+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,64(a2)
	moveq	#0,d0
	move.b	3+4(sp),d0
	moveq	#0,d1
	move.b	4+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	5+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,32(a2)
	move.b	d0,97(a2)
	moveq	#0,d0
	move.b	4+4(sp),d0
	moveq	#0,d1
	move.b	5+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,33(a2)
	move.b	d0,98(a2)
	moveq	#0,d0
	move.b	5+4(sp),d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,34(a2)
	move.b	d0,99(a2)
	moveq	#0,d0
	move.b	6+4(sp),d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,35(a2)
	rts
P4_LD:
	moveq	#0,d0
	move.b	5+4(sp),d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,(a2)
	moveq	#0,d0
	move.b	6+4(sp),d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,1(a2)
	move.b	d0,32(a2)
	moveq	#0,d0
	move.b	7+4(sp),d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	9+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,2(a2)
	move.b	d0,33(a2)
	move.b	d0,64(a2)
	moveq	#0,d0
	move.b	8+4(sp),d0
	moveq	#0,d1
	move.b	9+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	10+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,3(a2)
	move.b	d0,34(a2)
	move.b	d0,65(a2)
	move.b	d0,96(a2)
	moveq	#0,d0
	move.b	9+4(sp),d0
	moveq	#0,d1
	move.b	10+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	11+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,35(a2)
	move.b	d0,66(a2)
	move.b	d0,97(a2)
	moveq	#0,d0
	move.b	10+4(sp),d0
	moveq	#0,d1
	move.b	11+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	12+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,67(a2)
	move.b	d0,98(a2)
	moveq	#0,d0
	move.b	11+4(sp),d0
	moveq	#0,d1
	move.b	12+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	12+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,99(a2)
	rts
P4_VL:
	moveq	#0,d0
	move.b	5+4(sp),d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,(a2)
	moveq	#0,d0
	move.b	6+4(sp),d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,1(a2)
	move.b	d0,64(a2)
	moveq	#0,d0
	move.b	7+4(sp),d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,2(a2)
	move.b	d0,65(a2)
	moveq	#0,d0
	move.b	8+4(sp),d0
	moveq	#0,d1
	move.b	9+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,3(a2)
	move.b	d0,66(a2)
	moveq	#0,d0
	move.b	5+4(sp),d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,32(a2)
	moveq	#0,d0
	move.b	6+4(sp),d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,33(a2)
	move.b	d0,96(a2)
	moveq	#0,d0
	move.b	7+4(sp),d0
	moveq	#0,d1
	move.b	8+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	9+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,34(a2)
	move.b	d0,97(a2)
	moveq	#0,d0
	move.b	8+4(sp),d0
	moveq	#0,d1
	move.b	9+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	10+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,35(a2)
	move.b	d0,98(a2)
	moveq	#0,d0
	move.b	9+4(sp),d0
	moveq	#0,d1
	move.b	10+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	11+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,67(a2)
	moveq	#0,d0
	move.b	10+4(sp),d0
	moveq	#0,d1
	move.b	11+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	12+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,99(a2)
	rts
P4_HD:
	moveq	#0,d0
	move.b	3+4(sp),d0
	moveq	#0,d1
	move.b	4+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,(a2)
	move.b	d0,34(a2)
	moveq	#0,d0
	move.b	2+4(sp),d0
	moveq	#0,d1
	move.b	3+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,32(a2)
	move.b	d0,66(a2)
	moveq	#0,d0
	move.b	1+4(sp),d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,64(a2)
	move.b	d0,98(a2)
	moveq	#0,d0
	move.b	0+4(sp),d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,96(a2)
	moveq	#0,d0
	move.b	5+4(sp),d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	7+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,3(a2)
	moveq	#0,d0
	move.b	4+4(sp),d0
	moveq	#0,d1
	move.b	5+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	6+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,2(a2)
	moveq	#0,d0
	move.b	3+4(sp),d0
	moveq	#0,d1
	move.b	4+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	5+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,1(a2)
	move.b	d0,35(a2)
	moveq	#0,d0
	move.b	2+4(sp),d0
	moveq	#0,d1
	move.b	3+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	4+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,33(a2)
	move.b	d0,67(a2)
	moveq	#0,d0
	move.b	1+4(sp),d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	3+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,65(a2)
	move.b	d0,99(a2)
	moveq	#0,d0
	move.b	0+4(sp),d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,97(a2)
	rts
P4_HU:
	moveq	#0,d0
	move.b	3+4(sp),d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,(a2)
	moveq	#0,d0
	move.b	2+4(sp),d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,2(a2)
	move.b	d0,32(a2)
	moveq	#0,d0
	move.b	1+4(sp),d0
	moveq	#0,d1
	move.b	0+4(sp),d1
	add.w	d1,d0
	addq.w	#1,d0
	lsr.w	#1,d0
	move.b	d0,34(a2)
	move.b	d0,64(a2)
	moveq	#0,d0
	move.b	3+4(sp),d0
	moveq	#0,d1
	move.b	2+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,1(a2)
	moveq	#0,d0
	move.b	2+4(sp),d0
	moveq	#0,d1
	move.b	1+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	0+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,3(a2)
	move.b	d0,33(a2)
	moveq	#0,d0
	move.b	1+4(sp),d0
	moveq	#0,d1
	move.b	0+4(sp),d1
	add.w	d1,d1
	add.w	d1,d0
	moveq	#0,d1
	move.b	0+4(sp),d1
	add.w	d1,d0
	addq.w	#2,d0
	lsr.w	#2,d0
	move.b	d0,35(a2)
	move.b	d0,65(a2)
	move.b	0+4(sp),d0
	move.b	d0,67(a2)
	move.b	d0,66(a2)
	move.b	d0,96(a2)
	move.b	d0,97(a2)
	move.b	d0,98(a2)
	move.b	d0,99(a2)
	rts
