;
; inflate.s - deflate decompression (RFC 1951), for PNG (and gzip)
;
; Huffman codes up to FAST_BITS long are decoded by one table look-up
; (indexed by the next FAST_BITS bits of the stream, which come LSB
; first: the codes are bit-reversed in it); longer codes bit by bit,
; canonically (as zlib's puff does).  Input past the end reads as zero
; bits, and a little of that is an error; output never goes past the
; end of the buffer.
;

	include	"velox.i"

	xdef	Inflate
	xref	PicAlloc,PicFreeMem

FAST_BITS	equ	10
FAST_SIZE	equ	1<<FAST_BITS
OVER		equ	8		; bytes read past the end that are ok

; a Huffman table (in the working memory)
	RSRESET
hu_Fast		rs.w	FAST_SIZE	; len<<12 | symbol, 0: longer code
hu_Count	rs.w	16		; codes of each length
hu_Sym		rs.w	320		; symbols by code
hu_SIZEOF	rs.b	0

	RSRESET
iw_Lit		rs.b	hu_SIZEOF	; literals/lengths
iw_Dist		rs.b	hu_SIZEOF	; distances
iw_Len		rs.b	320		; code lengths being read
iw_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; Inflate - decompress a deflate stream
; In:  a0 = data, d0 = its length, a1 = output buffer, d1 = its size
; Out: d0 = bytes written, or -1 if the stream is damaged (what was
;      written is still there)
;--------------------------------------------------------------------
Inflate:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	move.l	a0,a2			; a2 = input
	lea	(a0,d0.l),a3		; a3 = its end
	move.l	a1,g_InfOut(a4)		; (start, for distances)
	move.l	a1,a5			; a5 = output
	move.l	d1,-(sp)
	clr.l	g_InfOver(a4)
	move.l	#iw_SIZEOF,d0
	jsr	PicAlloc		; (a6 is the library's here)
	move.l	(sp)+,d1
	move.l	d0,g_InfWork(a4)
	beq	.bad
	lea	(a5,d1.l),a6		; a6 = end of the output
	moveq	#0,d2			; d2 = bit buffer
	moveq	#0,d3			; d3 = bits in it
.block:	moveq	#3,d0
	bsr	Bits
	move.l	d0,d7			; bit 0: last block
	lsr.l	#1,d0
	beq.s	.stored
	subq.l	#1,d0
	beq.s	.fixed
	subq.l	#1,d0
	bne	.bad
	bsr	Dynamic
	beq	.bad
	bra.s	.codes
.fixed:	bsr	Fixed
.codes:	bsr	Codes			; d0 = 0: ok
	bne	.bad
	bra.s	.next
.stored:
	move.l	d3,d0			; to a byte boundary
	and.l	#7,d0
	lsr.l	d0,d2
	sub.l	d0,d3
	moveq	#16,d0
	bsr	Bits
	move.l	d0,d4			; length
	moveq	#16,d0
	bsr	Bits
	not.w	d0
	cmp.w	d0,d4			; its complement
	bne	.bad
.copy:	subq.l	#1,d4
	bmi.s	.next
	moveq	#8,d0
	bsr	Bits
	cmp.l	#OVER,g_InfOver(a4)
	bhi.s	.bad
	cmp.l	a6,a5
	bhs.s	.done			; (full: enough)
	move.b	d0,(a5)+
	bra.s	.copy
.next:	cmp.l	#OVER,g_InfOver(a4)
	bhi.s	.bad
	btst	#0,d7
	beq	.block
.done:	move.l	a5,d0
	sub.l	g_InfOut(a4),d0
	bra.s	.x
.bad:	moveq	#-1,d0
.x:	move.l	d0,d2
	move.l	g_InfWork(a4),a1
	jsr	PicFreeMem
	move.l	d2,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

;--------------------------------------------------------------------
; the bit stream (d2 = buffer, d3 = bits in it, a2/a3 = input)
;--------------------------------------------------------------------

; Fill - at least 25 bits in the buffer
Fill:
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
.over:	addq.l	#1,g_InfOver(a4)	; past the end: zero bits (a few are
	addq.l	#8,d3			; read ahead at the end; more is an
	bra.s	.l			; error: OVER)
.x:	rts

; Bits - the next d0 bits (up to 16); Out: d0
Bits:
	cmp.l	d0,d3
	bge.s	.h
	move.l	d0,-(sp)
	bsr.s	Fill
	move.l	(sp)+,d0
.h:	moveq	#1,d1
	lsl.l	d0,d1
	subq.l	#1,d1
	and.l	d2,d1
	lsr.l	d0,d2
	sub.l	d0,d3
	move.l	d1,d0
	rts

; Decode - the next symbol of Huffman table a0
; Out: d0 = symbol, -1 if no code matches
Decode:
	cmp.l	#15,d3
	bge.s	.h
	bsr.s	Fill
.h:	move.w	d2,d0
	and.w	#FAST_SIZE-1,d0
	move.w	hu_Fast(a0,d0.w*2),d0
	beq.s	.slow
	moveq	#0,d1
	move.w	d0,d1
	lsr.w	#8,d1
	lsr.w	#4,d1			; length
	lsr.l	d1,d2
	sub.l	d1,d3
	and.l	#$fff,d0
	rts
.slow:	; bit by bit: code, first code and index of each length
	movem.l	d4-d6,-(sp)
	moveq	#0,d0			; code
	moveq	#0,d4			; first
	moveq	#0,d5			; index
	moveq	#1,d6			; length
.l:	moveq	#1,d1
	and.l	d2,d1
	or.l	d1,d0
	lsr.l	#1,d2
	subq.l	#1,d3
	moveq	#0,d1
	move.w	hu_Count(a0,d6.l*2),d1	; count
	move.l	d4,a1
	add.l	d1,a1
	cmp.l	a1,d0			; code < first + count?
	blt.s	.found
	add.l	d1,d5			; index += count
	move.l	a1,d4			; first = (first + count) << 1
	add.l	d4,d4
	add.l	d0,d0
	addq.l	#1,d6
	cmp.l	#15,d6
	bls.s	.l
	moveq	#-1,d0
	bra.s	.x
.found:	sub.l	d4,d0			; symbol[index + code - first]
	add.l	d5,d0
	move.w	hu_Sym(a0,d0.l*2),d0
	ext.l	d0
.x:	movem.l	(sp)+,d4-d6
	rts

;--------------------------------------------------------------------
; Build - make Huffman table a0 from d0 code lengths (bytes) at a1
; Out: d0 = 0 if the lengths are not a usable code (CCR set)
;--------------------------------------------------------------------
Build:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	move.l	d0,d7			; symbols
	lea	hu_Count(a2),a0		; counts
	moveq	#16-1,d1
.c0:	clr.w	(a0)+
	dbf	d1,.c0
	moveq	#0,d1
.c1:	cmp.l	d7,d1
	bhs.s	.c2
	moveq	#0,d0
	move.b	(a3,d1.l),d0
	addq.w	#1,hu_Count(a2,d0.l*2)
	addq.l	#1,d1
	bra.s	.c1
.c2:	clr.w	hu_Count(a2)		; (length 0: no code)
	; offsets of each length in hu_Sym (on the stack), symbols sorted
	lea	-32(sp),sp
	moveq	#0,d0
	moveq	#1,d1
.o:	move.w	d0,(sp,d1.l*2)
	add.w	hu_Count(a2,d1.l*2),d0
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
	move.w	d1,hu_Sym(a2,d2.w*2)
.sn:	addq.l	#1,d1
	bra.s	.s
.f:	lea	32(sp),sp
	; the fast table: codes up to FAST_BITS long, bit-reversed
	lea	hu_Fast(a2),a0
	move.w	#FAST_SIZE-1,d0
.z:	clr.w	(a0)+
	dbf	d0,.z
	moveq	#0,d4			; code
	moveq	#0,d5			; index in hu_Sym
	moveq	#1,d6			; length
.len:	moveq	#0,d7
	move.w	hu_Count(a2,d6.l*2),d7	; codes of this length
	bra.s	.ne
.n:	moveq	#1,d0			; too many codes for the length?
	lsl.l	d6,d0
	cmp.l	d0,d4
	bhs.s	.no
	cmp.l	#FAST_BITS,d6
	bhi.s	.skip
	move.l	d4,d0			; reverse the code
	moveq	#0,d1
	move.l	d6,d2
.r:	lsr.l	#1,d0
	addx.l	d1,d1
	subq.l	#1,d2
	bne.s	.r
	move.w	hu_Sym(a2,d5.l*2),d0	; the entry
	move.w	d6,d2
	lsl.w	#8,d2
	lsl.w	#4,d2
	or.w	d2,d0
	moveq	#1,d2			; every FAST_BITS index ending in it
	lsl.l	d6,d2
.fill:	move.w	d0,hu_Fast(a2,d1.l*2)
	add.l	d2,d1
	cmp.l	#FAST_SIZE,d1
	blo.s	.fill
.skip:	addq.l	#1,d4
	addq.l	#1,d5
.ne:	dbf	d7,.n
	add.l	d4,d4
	addq.l	#1,d6
	cmp.l	#15,d6
	bls.s	.len
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

;--------------------------------------------------------------------
; Fixed - the tables of a block with fixed codes
;--------------------------------------------------------------------
Fixed:
	move.l	g_InfWork(a4),a1
	lea	iw_Len(a1),a0
	moveq	#0,d1
.l:	moveq	#8,d0			; 0-143: 8, 144-255: 9, 256-279: 7,
	cmp.w	#144,d1			; 280-287: 8
	blo.s	.p
	moveq	#9,d0
	cmp.w	#256,d1
	blo.s	.p
	moveq	#7,d0
	cmp.w	#280,d1
	blo.s	.p
	moveq	#8,d0
.p:	move.b	d0,(a0)+
	addq.w	#1,d1
	cmp.w	#288,d1
	blo.s	.l
	move.l	g_InfWork(a4),a1
	lea	iw_Lit(a1),a0
	lea	iw_Len(a1),a1
	move.l	#288,d0
	bsr	Build
	move.l	g_InfWork(a4),a1	; distances: 30, all 5 bits
	lea	iw_Len(a1),a0
	moveq	#30-1,d0
.d:	move.b	#5,(a0)+
	dbf	d0,.d
	lea	iw_Dist(a1),a0
	lea	iw_Len(a1),a1
	moveq	#30,d0
	bra	Build

;--------------------------------------------------------------------
; Dynamic - read the tables of a block with dynamic codes
; Out: d0 = 0 if they are damaged (CCR set)
;--------------------------------------------------------------------
Dynamic:
	movem.l	d4-d7,-(sp)
	moveq	#5,d0
	bsr	Bits
	add.l	#257,d0
	move.l	d0,d4			; literal/length codes
	moveq	#5,d0
	bsr	Bits
	addq.l	#1,d0
	move.l	d0,d5			; distance codes
	moveq	#4,d0
	bsr	Bits
	addq.l	#4,d0
	move.l	d0,d6			; code length codes
	cmp.l	#286,d4
	bhi	.no
	cmp.l	#30,d5
	bhi	.no
	; (a2 is the input: the working memory is g_InfWork)
	move.l	g_InfWork(a4),a0	; their lengths, in that odd order
	lea	iw_Len(a0),a0
	moveq	#19-1,d0
.c:	clr.b	(a0)+
	dbf	d0,.c
	moveq	#0,d7
.cl:	moveq	#3,d0
	bsr	Bits
	lea	ClOrder(pc),a1
	moveq	#0,d1
	move.b	(a1,d7.l),d1
	move.l	g_InfWork(a4),a0
	move.b	d0,iw_Len(a0,d1.l)
	addq.l	#1,d7
	cmp.l	d6,d7
	blo.s	.cl
	move.l	g_InfWork(a4),a1	; (the code length code in iw_Lit)
	lea	iw_Lit(a1),a0
	lea	iw_Len(a1),a1
	moveq	#19,d0
	bsr	Build
	beq	.no
	; the code lengths of both tables, in iw_Len
	move.l	d4,d6
	add.l	d5,d6			; d6 = lengths to read
	moveq	#0,d7			; d7 = read
.ln:	cmp.l	d6,d7
	bhs.s	.built
	move.l	g_InfWork(a4),a0
	bsr	Decode			; (iw_Lit is at 0)
	tst.l	d0
	bmi.s	.no
	cmp.l	#16,d0
	bhs.s	.rep
	move.l	g_InfWork(a4),a0
	move.b	d0,iw_Len(a0,d7.l)
	addq.l	#1,d7
	bra.s	.ln
.rep:	bne.s	.z
	tst.l	d7			; 16: the previous one 3-6 times
	beq.s	.no
	moveq	#2,d0
	bsr	Bits
	addq.l	#3,d0
	move.l	g_InfWork(a4),a0
	moveq	#0,d1
	move.b	iw_Len-1(a0,d7.l),d1
	bra.s	.put
.z:	cmp.l	#17,d0			; 17: zero 3-10 times
	bne.s	.z18
	moveq	#3,d0
	bsr	Bits
	addq.l	#3,d0
	moveq	#0,d1
	bra.s	.put
.z18:	moveq	#7,d0			; 18: zero 11-138 times
	bsr	Bits
	add.l	#11,d0
	moveq	#0,d1
.put:	move.l	d7,a0
	add.l	d0,a0
	cmp.l	d6,a0
	bhi.s	.no
	move.l	g_InfWork(a4),a0
.pl:	move.b	d1,iw_Len(a0,d7.l)
	addq.l	#1,d7
	subq.l	#1,d0
	bne.s	.pl
	bra.s	.ln
.built:	move.l	g_InfWork(a4),a1
	lea	iw_Lit(a1),a0
	lea	iw_Len(a1),a1
	move.l	d4,d0
	bsr	Build
	beq.s	.no
	move.l	g_InfWork(a4),a1
	lea	iw_Dist(a1),a0
	lea	iw_Len(a1,d4.l),a1
	move.l	d5,d0
	bsr	Build
	beq.s	.no
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d4-d7
	rts

ClOrder:	dc.b	16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15
	even

;--------------------------------------------------------------------
; Codes - decode the literals and matches of a block
; Out: d0 = 0 when the block ended, else damaged (CCR set)
;--------------------------------------------------------------------
Codes:
	movem.l	d4-d7,-(sp)
	move.l	g_InfWork(a4),d7
.sym:	cmp.l	#OVER,g_InfOver(a4)
	bhi.s	.bad
	move.l	d7,a0
	bsr	Decode			; (iw_Lit is at 0)
	cmp.l	#256,d0
	bhs.s	.len
	cmp.l	a6,a5
	bhs.s	.end			; full: enough
	move.b	d0,(a5)+
	bra.s	.sym
.len:	beq.s	.end			; 256: end of block
	sub.l	#257,d0
	cmp.l	#29,d0
	bhs.s	.bad			; (also -1-257: no code)
	moveq	#0,d4
	move.b	LExtra(pc,d0.l),d4
	move.w	LBase(pc,d0.l*2),d5	; d5 = length
	ext.l	d5
	move.l	d4,d0
	beq.s	.d
	bsr	Bits
	add.l	d0,d5
.d:	move.l	d7,a0
	lea	iw_Dist(a0),a0
	bsr	Decode
	cmp.l	#30,d0
	bhs.s	.bad
	moveq	#0,d4
	move.b	DExtra(pc,d0.l),d4
	move.w	DBase(pc,d0.l*2),d6	; d6 = distance
	and.l	#$ffff,d6
	move.l	d4,d0
	beq.s	.c
	bsr	Bits
	add.l	d0,d6
.c:	move.l	a5,d0			; not before the start
	sub.l	g_InfOut(a4),d0
	cmp.l	d0,d6
	bhi.s	.bad
	move.l	a5,a0
	sub.l	d6,a0
.cp:	cmp.l	a6,a5
	bhs.s	.end
	move.b	(a0)+,(a5)+
	subq.l	#1,d5
	bne.s	.cp
	bra.s	.sym
.end:	moveq	#0,d0
	bra.s	.x
.bad:	moveq	#1,d0
.x:	movem.l	(sp)+,d4-d7
	rts

LExtra:	dc.b	0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0
DExtra:	dc.b	0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11
	dc.b	12,12,13,13
	even
LBase:	dc.w	3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59
	dc.w	67,83,99,115,131,163,195,227,258
DBase:	dc.w	1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513
	dc.w	769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577
