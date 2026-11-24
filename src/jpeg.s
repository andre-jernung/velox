;
; jpeg.s - JPEG decoder: baseline and progressive (Huffman coding),
; greyscale and YCbCr (or RGB), chroma subsampled by 1, 2 or 4, restart
; intervals.  Not: arithmetic coding, lossless, 12 bits, CMYK.
;
; Baseline images with one interleaved scan are decoded a row of MCUs
; at a time (little memory); others keep all coefficients until the
; end.  The inverse DCT is libjpeg's "ifast" (Arai, Agui, Nakajima) in
; fixed point; a block with no AC coefficients costs almost nothing.
; When the image is shown at 1/8 of its size or less, only the DC
; coefficients are used (no inverse DCT at all).  Huffman codes up to
; 9 bits are decoded by one table look-up of the next bits (bfextu
; peeks them); YCbCr to RGB with libjpeg's integer tables.
;

	include	"velox.i"

	xdef	JpegInfo,JpegDecode
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	PicNew,PicAlloc,PicFreeMem

; a Huffman table
	RSRESET
jh_Look		rs.w	512		; next 9 bits: length<<8 | value
jh_Max		rs.l	18		; largest code of each length
jh_Off		rs.l	18		; value index - code, by length
jh_Val		rs.b	256		; the values
jh_SIZEOF	rs.b	0

; the working memory
	RSRESET
jw_Huff		rs.b	8*jh_SIZEOF	; DC 0-3, AC 0-3
jw_Q		rs.w	4*64		; quantization (natural order)
jw_QA		rs.w	4*64		; ... scaled for the AAN inverse DCT
jw_WS		rs.l	64		; inverse DCT workspace
jw_Range	rs.b	1024		; (v >> 5) + 512 & 1023 -> v + 128
jw_Clip		rs.b	1024		; v + 256 -> v, clipped to 0..255
jw_CrR		rs.w	256		; YCbCr -> RGB
jw_CbB		rs.w	256
jw_CrG		rs.l	256
jw_CbG		rs.l	256
jw_SIZEOF	rs.b	0

; a component
	RSRESET
jc_Id		rs.b	1
jc_H		rs.b	1		; sampling factors
jc_V		rs.b	1
jc_Tq		rs.b	1		; quantization table
jc_Td		rs.b	1		; Huffman tables (this scan)
jc_Ta		rs.b	1
jc_XS		rs.b	1		; Hmax/H, V/Vmax as shifts
jc_YS		rs.b	1
jc_Pred		rs.l	1		; DC predictor
jc_BW		rs.l	1		; blocks per row (MCUs * H)
jc_BH		rs.l	1		; block rows (MCUs * V)
jc_CW		rs.l	1		; blocks really in the image
jc_CH		rs.l	1
jc_Coef		rs.l	1		; coefficients (BW x BH or V rows)
jc_Plane	rs.l	1		; output samples of an MCU row
jc_PW		rs.l	1		; its width
JC_SIZEOF	rs.b	0
	IFNE	JC_SIZEOF-40
	FAIL	"JC_SIZEOF changed: g_JComp in velox.i too"
	ENDIF

	section	code,code

;--------------------------------------------------------------------
; JpegInfo - In: a0 = data, d0 = length; Out: d0 = width, d1 = height
;--------------------------------------------------------------------
JpegInfo:
	move.l	a2,-(sp)
	lea	(a0,d0.l),a1		; end
	lea	2(a0),a2
.m:	lea	9(a2),a0
	cmp.l	a1,a0
	bhi.s	.no
	cmp.b	#$ff,(a2)+
	bne.s	.m
	move.b	(a2),d0
	cmp.b	#$c0,d0			; SOFn (not DHT, JPG, DAC)
	blo.s	.skip
	cmp.b	#$cf,d0
	bhi.s	.skip
	cmp.b	#$c4,d0
	beq.s	.skip
	cmp.b	#$c8,d0
	beq.s	.skip
	cmp.b	#$cc,d0
	beq.s	.skip
	moveq	#0,d1
	move.b	4(a2),d1
	lsl.w	#8,d1
	move.b	5(a2),d1
	moveq	#0,d0
	move.b	6(a2),d0
	lsl.w	#8,d0
	move.b	7(a2),d0
	bra.s	.x
.skip:	cmp.b	#$ff,d0			; (fill)
	beq.s	.m
	cmp.b	#$d0,d0			; no length: RSTn, SOI, EOI
	blo.s	.len
	cmp.b	#$d9,d0
	bls.s	.m
.len:	moveq	#0,d0			; skip the segment
	move.b	1(a2),d0
	lsl.w	#8,d0
	move.b	2(a2),d0
	lea	1(a2,d0.l),a2
	bra.s	.m
.no:	moveq	#0,d0
	moveq	#0,d1
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; JpegDecode - In: a0 = data, d0 = length; Out: d0 = 1 if decoded
;--------------------------------------------------------------------
JpegDecode:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	lea	(a0,d0.l),a5		; a5 = end
	lea	2(a0),a2		; a2 = after SOI
	clr.l	g_JFrame(a4)
	clr.l	g_JScans(a4)
	clr.l	g_JRestart(a4)
	moveq	#-1,d0
	move.l	d0,g_JAdobe(a4)
	lea	g_JComp(a4),a0		; (nothing allocated yet)
	moveq	#4*JC_SIZEOF/4-1,d0
.cc:	clr.l	(a0)+
	dbf	d0,.cc
	move.l	#jw_SIZEOF,d0
	jsr	PicAlloc
	move.l	d0,g_JWork(a4)
	beq	.fail
	bsr	Tables
.mark:	bsr	NextMarker		; d0 = marker, a2 after it
	bmi	.end			; (no more data)
	cmp.b	#$d9,d0			; EOI
	beq	.end
	cmp.b	#$d8,d0
	beq.s	.mark
	cmp.b	#$d0,d0			; stray RSTn
	blo.s	.seg
	cmp.b	#$d7,d0
	bls.s	.mark
.seg:	; a segment: a2 = its data, d2 = its length, a3 = after it
	lea	2(a2),a0
	cmp.l	a5,a0
	bhi	.end
	moveq	#0,d2
	move.b	(a2)+,d2
	lsl.w	#8,d2
	move.b	(a2)+,d2
	subq.l	#2,d2
	bmi	.end
	lea	(a2,d2.l),a3
	cmp.l	a5,a3
	bhi	.end			; cut short
	cmp.b	#$c4,d0
	beq.s	.dht
	cmp.b	#$db,d0
	beq.s	.dqt
	cmp.b	#$dd,d0
	beq.s	.dri
	cmp.b	#$da,d0
	beq.s	.sos
	cmp.b	#$ee,d0
	beq	.adobe
	cmp.b	#$c0,d0
	beq.s	.sof
	cmp.b	#$c1,d0
	beq.s	.sof
	cmp.b	#$c2,d0
	beq.s	.sof
	cmp.b	#$c3,d0			; other frames: not ours
	blo.s	.next
	cmp.b	#$cf,d0
	bhi.s	.next
	cmp.b	#$c8,d0
	beq.s	.next
	cmp.b	#$cc,d0
	bne	.fail
.next:	move.l	a3,a2
	bra.s	.mark
.dht:	bsr	ReadDHT
	beq	.fail
	bra.s	.next
.dqt:	bsr	ReadDQT
	beq	.fail
	bra.s	.next
.dri:	cmp.l	#2,d2
	blo.s	.next
	moveq	#0,d0
	move.b	(a2),d0
	lsl.w	#8,d0
	move.b	1(a2),d0
	move.l	d0,g_JRestart(a4)
	bra.s	.next
.sof:	tst.l	g_JFrame(a4)		; one frame
	bne	.fail
	bsr	ReadSOF
	beq	.fail
	bra.s	.next
.sos:	tst.l	g_JFrame(a4)
	beq	.fail
	bsr	ReadSOS
	beq	.fail
	move.l	a3,a2
	PROFB	2
	bsr	Scan			; a2: after the entropy-coded data
	PROFE	2
	beq	.fail
	addq.l	#1,g_JScans(a4)
	bra	.mark
.adobe:	cmp.l	#12,d2			; APP14 "Adobe": the colour transform
	blo.s	.next
	cmp.l	#'Adob',(a2)
	bne.s	.next
	moveq	#0,d0
	move.b	11(a2),d0
	move.l	d0,g_JAdobe(a4)
	bra	.next
.end:	tst.l	g_JScans(a4)
	beq.s	.fail
	tst.l	g_JStream(a4)		; kept coefficients: the image now
	bne.s	.ok
	moveq	#0,d7
.rows:	cmp.l	g_JMcuY(a4),d7
	bhs.s	.ok
	move.l	d7,d0
	bsr	OutputRow
	addq.l	#1,d7
	bra.s	.rows
.ok:	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	move.l	d0,d2
	lea	g_JComp(a4),a2		; free everything
	moveq	#4-1,d3
.fc:	move.l	jc_Coef(a2),a1
	jsr	PicFreeMem
	move.l	jc_Plane(a2),a1
	jsr	PicFreeMem
	lea	JC_SIZEOF(a2),a2
	dbf	d3,.fc
	move.l	g_JWork(a4),a1
	jsr	PicFreeMem
	clr.l	g_JWork(a4)
	move.l	d2,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; NextMarker - the next marker at or after a2 (a5 = end)
; Out: d0 = marker code (a2 after it), -1 if none (CCR set)
NextMarker:
.l:	lea	1(a2),a0
	cmp.l	a5,a0
	bhs.s	.no
	cmp.b	#$ff,(a2)+
	bne.s	.l
.f:	cmp.l	a5,a2
	bhs.s	.no
	moveq	#0,d0
	move.b	(a2)+,d0
	cmp.b	#$ff,d0			; fill bytes
	beq.s	.f
	tst.l	d0			; (FF 00: not a marker)
	beq.s	.l
	rts
.no:	moveq	#-1,d0
	rts

;--------------------------------------------------------------------
; Tables - the range, clip and colour tables (in the working memory)
;--------------------------------------------------------------------
Tables:
	movem.l	d2-d3/a2,-(sp)
	move.l	g_JWork(a4),a2
	lea	jw_Range(a2),a0		; index i: v = i - 512, gives v + 128
	moveq	#0,d3
.r:	move.l	d3,d0
	sub.l	#512-128,d0
	bsr.s	.clip
	move.b	d0,(a0)+
	addq.l	#1,d3
	cmp.w	#1024,d3
	blo.s	.r
	lea	jw_Clip(a2),a0		; index i: v = i - 256
	moveq	#0,d3
.c:	move.l	d3,d0
	sub.l	#256,d0
	bsr.s	.clip
	move.b	d0,(a0)+
	addq.l	#1,d3
	cmp.w	#1024,d3
	blo.s	.c
	moveq	#0,d1			; colour: x = i - 128
.t:	move.l	d1,d2
	sub.l	#128,d2
	move.l	d2,d0			; Cr -> R: 1.40200 x
	muls.l	#91881,d0
	add.l	#32768,d0
	asr.l	#8,d0
	asr.l	#8,d0
	move.w	d0,jw_CrR(a2,d1.l*2)
	move.l	d2,d0			; Cb -> B: 1.77200 x
	muls.l	#116130,d0
	add.l	#32768,d0
	asr.l	#8,d0
	asr.l	#8,d0
	move.w	d0,jw_CbB(a2,d1.l*2)
	move.l	d2,d0			; Cr -> G: -0.71414 x
	muls.l	#-46802,d0
	move.l	d0,jw_CrG(a2,d1.l*4)
	move.l	d2,d0			; Cb -> G: -0.34414 x (+ 1/2)
	muls.l	#-22554,d0
	add.l	#32768,d0
	move.l	d0,jw_CbG(a2,d1.l*4)
	addq.l	#1,d1
	cmp.w	#256,d1
	blo.s	.t
	movem.l	(sp)+,d2-d3/a2
	rts
.clip:	tst.l	d0
	bpl.s	.c1
	moveq	#0,d0
.c1:	cmp.l	#255,d0
	bls.s	.c2
	move.l	#255,d0
.c2:	rts

;--------------------------------------------------------------------
; ReadDHT - Huffman tables of the segment a2 (d2 bytes, a3 after it)
; Out: d0 = 0 if damaged (CCR set)
;--------------------------------------------------------------------
ReadDHT:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	move.l	a3,a5			; a5 = end of the segment
.t:	lea	17(a2),a0
	cmp.l	a5,a0
	bhi	.done
	moveq	#0,d0
	move.b	(a2)+,d0		; class (0 DC, 1 AC) and number
	move.l	d0,d1
	lsr.b	#4,d1
	cmp.b	#1,d1
	bhi	.no
	and.b	#$0f,d0
	cmp.b	#3,d0
	bhi	.no
	lsl.b	#2,d1
	add.b	d1,d0
	mulu.w	#jh_SIZEOF,d0
	move.l	g_JWork(a4),a3
	lea	jw_Huff(a3,d0.l),a3	; a3 = the table
	move.l	a2,a6			; a6 = the 16 counts
	moveq	#0,d1			; values in all
	moveq	#16-1,d0
.n:	moveq	#0,d2
	move.b	(a2)+,d2
	add.l	d2,d1
	dbf	d0,.n
	cmp.l	#256,d1
	bhi	.no
	lea	(a2,d1.l),a0
	cmp.l	a5,a0
	bhi	.no
	lea	jh_Val(a3),a1		; the values
	move.l	d1,d0
	bra.s	.ve
.vl:	move.b	(a2)+,(a1)+
.ve:	dbf	d0,.vl
	; codes: canonical, by length; Max, Off, and the look-up table
	lea	jh_Look(a3),a0
	move.w	#512-1,d0
.lz:	clr.w	(a0)+
	dbf	d0,.lz
	moveq	#0,d4			; code
	moveq	#0,d5			; value index
	moveq	#1,d6			; length
.len:	moveq	#0,d7
	move.b	-1(a6,d6.l),d7		; codes of this length
	bne.s	.has
	moveq	#-1,d0
	move.l	d0,jh_Max(a3,d6.l*4)
	bra.s	.nl
.has:	move.l	d5,d0
	sub.l	d4,d0
	move.l	d0,jh_Off(a3,d6.l*4)
.c:	cmp.l	#9,d6			; short: into the look-up table
	bhi.s	.long
	moveq	#9,d1			; index = code << (9 - length)
	sub.l	d6,d1
	move.l	d4,d0
	lsl.l	d1,d0
	moveq	#1,d2
	lsl.l	d1,d2			; entries
	move.w	d6,d3
	lsl.w	#8,d3
	move.b	jh_Val(a3,d5.l),d3
	cmp.l	#512,d0
	bhs.s	.long			; (too many codes: damaged)
.f:	move.w	d3,jh_Look(a3,d0.l*2)
	addq.l	#1,d0
	subq.l	#1,d2
	bne.s	.f
.long:	addq.l	#1,d4
	addq.l	#1,d5
	subq.l	#1,d7
	bne.s	.c
	move.l	d4,d0
	subq.l	#1,d0
	move.l	d0,jh_Max(a3,d6.l*4)
.nl:	add.l	d4,d4
	addq.l	#1,d6
	cmp.l	#16,d6
	bls.s	.len
	move.l	#$7fffffff,jh_Max+17*4(a3)
	bra	.t
.done:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

;--------------------------------------------------------------------
; ReadDQT - quantization tables of the segment a2 (a3 after it)
; Out: d0 = 0 if damaged (CCR set)
;--------------------------------------------------------------------
ReadDQT:
	movem.l	d2-d5/a2/a5,-(sp)
.t:	cmp.l	a3,a2
	bhs.s	.done
	moveq	#0,d0
	move.b	(a2)+,d0		; precision and number
	moveq	#$0f,d2
	and.l	d0,d2
	cmp.l	#3,d2
	bhi.s	.no
	lsr.b	#4,d0
	move.l	d0,d3			; 1: 16-bit values
	moveq	#64,d1
	lsl.l	d3,d1
	lea	(a2,d1.l),a0
	cmp.l	a3,a0
	bhi.s	.no
	lsl.l	#7,d2			; 64 words a table
	move.l	g_JWork(a4),a5
	lea	jw_Q(a5,d2.l),a1
	lea	jw_QA(a5,d2.l),a5
	lea	Natural(pc),a0
	moveq	#0,d4			; k (zigzag)
.v:	moveq	#0,d0
	move.b	(a2)+,d0
	tst.l	d3
	beq.s	.v8
	lsl.w	#8,d0
	move.b	(a2)+,d0
	cmp.l	#32767,d0
	bls.s	.v8
	move.l	#32767,d0
.v8:	moveq	#0,d5
	move.b	(a0,d4.l),d5		; natural index
	move.w	d0,(a1,d5.l*2)
	lea	AanScale(pc),a6
	mulu.w	(a6,d5.l*2),d0		; q * scale (14 bits) >> 12
	add.l	#2048,d0
	moveq	#12,d1
	lsr.l	d1,d0
	cmp.l	#32767,d0
	bls.s	.qa
	move.l	#32767,d0
.qa:	move.w	d0,(a5,d5.l*2)
	addq.l	#1,d4
	cmp.l	#64,d4
	blo.s	.v
	bra.s	.t
.done:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d5/a2/a5
	rts

;--------------------------------------------------------------------
; ReadSOF - the frame header a2 (d2 bytes); sets up the components,
; the image (scaled) and the memory
; Out: d0 = 0 if not decodable (CCR set)
;--------------------------------------------------------------------
ReadSOF:
	movem.l	d2-d7/a2-a3,-(sp)
	move.b	-3(a2),d0		; the marker: progressive?
	moveq	#0,d1
	cmp.b	#$c2,d0
	bne.s	.seq
	moveq	#1,d1
.seq:	move.l	d1,g_JProg(a4)
	cmp.l	#6,d2
	blo	.no
	cmp.b	#8,(a2)			; 8 bits only
	bne	.no
	moveq	#0,d0
	move.b	1(a2),d0
	lsl.w	#8,d0
	move.b	2(a2),d0
	move.l	d0,g_JH(a4)
	beq	.no			; (height from DNL: no)
	move.b	3(a2),d0
	lsl.w	#8,d0
	move.b	4(a2),d0
	move.l	d0,g_JW(a4)
	beq	.no
	moveq	#0,d0
	move.b	5(a2),d0
	move.l	d0,g_JNf(a4)
	cmp.l	#1,d0			; grey or three components
	beq.s	.nf
	cmp.l	#3,d0
	bne	.no
.nf:	mulu.w	#3,d0
	addq.l	#6,d0
	cmp.l	d0,d2
	blo	.no
	; the components: factors 1, 2 or 4
	lea	6(a2),a0
	lea	g_JComp(a4),a1
	moveq	#1,d6			; Hmax
	moveq	#1,d7			; Vmax
	move.l	g_JNf(a4),d5
	subq.l	#1,d5
.c:	move.b	(a0)+,jc_Id(a1)
	moveq	#0,d0
	move.b	(a0)+,d0
	move.l	d0,d1
	lsr.b	#4,d0
	and.b	#$0f,d1
	bsr	OkFactor
	beq	.no
	exg	d0,d1
	bsr	OkFactor
	beq	.no
	exg	d0,d1
	move.b	d0,jc_H(a1)
	move.b	d1,jc_V(a1)
	cmp.l	d0,d6
	bhs.s	.h
	move.l	d0,d6
.h:	cmp.l	d1,d7
	bhs.s	.v
	move.l	d1,d7
.v:	move.b	(a0)+,d0
	and.b	#3,d0
	move.b	d0,jc_Tq(a1)
	lea	JC_SIZEOF(a1),a1
	dbf	d5,.c
	move.l	d6,g_JHmax(a4)
	move.l	d7,g_JVmax(a4)
	; the scale: 1/8 (DC only) when that is still big enough
	moveq	#0,d0
	move.l	g_PicWant(a4),d1
	beq.s	.sc
	move.l	g_JW(a4),d2
	addq.l	#7,d2
	lsr.l	#3,d2
	cmp.l	d1,d2
	blo.s	.sc
	moveq	#3,d0
.sc:	move.l	d0,g_JShift(a4)
	moveq	#8,d1
	lsr.l	d0,d1
	move.l	d1,g_JBs(a4)		; output pixels of a block side
	moveq	#1,d1
	lsl.l	d0,d1
	subq.l	#1,d1
	move.l	g_JW(a4),d2
	add.l	d1,d2
	lsr.l	d0,d2
	move.l	d2,g_JOutW(a4)
	move.l	g_JH(a4),d3
	add.l	d1,d3
	lsr.l	d0,d3
	move.l	d3,g_JOutH(a4)
	; MCUs
	move.l	d6,d0			; 8 * Hmax pixels across
	lsl.l	#3,d0
	move.l	g_JW(a4),d1
	add.l	d0,d1
	subq.l	#1,d1
	divu.w	d0,d1
	and.l	#$ffff,d1
	move.l	d1,g_JMcuX(a4)
	move.l	d7,d0
	lsl.l	#3,d0
	move.l	g_JH(a4),d1
	add.l	d0,d1
	subq.l	#1,d1
	divu.w	d0,d1
	and.l	#$ffff,d1
	move.l	d1,g_JMcuY(a4)
	; streamed: baseline (one interleaved scan, checked by ReadSOS)
	moveq	#1,d0
	tst.l	g_JProg(a4)
	beq.s	.st
	moveq	#0,d0
.st:	move.l	d0,g_JStream(a4)
	move.l	g_JOutW(a4),d0
	move.l	g_JOutH(a4),d1
	jsr	PicNew
	beq	.no
	; each component's blocks, coefficients and samples
	lea	g_JComp(a4),a3
	move.l	g_JNf(a4),d5
	subq.l	#1,d5
.cm:	moveq	#0,d2
	move.b	jc_H(a3),d2
	moveq	#0,d3
	move.b	jc_V(a3),d3
	move.l	g_JHmax(a4),d0		; upsampling shifts
	divu.w	d2,d0
	bsr	Log2
	move.b	d0,jc_XS(a3)
	move.l	g_JVmax(a4),d0
	divu.w	d3,d0
	bsr	Log2
	move.b	d0,jc_YS(a3)
	move.l	g_JMcuX(a4),d0
	mulu.w	d2,d0
	move.l	d0,jc_BW(a3)
	move.l	g_JMcuY(a4),d0
	mulu.w	d3,d0
	move.l	d0,jc_BH(a3)
	move.l	g_JW(a4),d0		; ceil(ceil(W * H / Hmax) / 8)
	mulu.l	d2,d0
	add.l	g_JHmax(a4),d0
	subq.l	#1,d0
	divu.l	g_JHmax(a4),d0
	addq.l	#7,d0
	lsr.l	#3,d0
	move.l	d0,jc_CW(a3)
	move.l	g_JH(a4),d0
	mulu.l	d3,d0
	add.l	g_JVmax(a4),d0
	subq.l	#1,d0
	divu.l	g_JVmax(a4),d0
	addq.l	#7,d0
	lsr.l	#3,d0
	move.l	d0,jc_CH(a3)
	move.l	jc_BW(a3),d0		; coefficients: V rows or all
	tst.l	g_JStream(a4)
	bne.s	.cv
	mulu.l	jc_BH(a3),d0
	bra.s	.ca
.cv:	mulu.l	d3,d0
.ca:	lsl.l	#7,d0			; 64 words a block
	jsr	PicAlloc
	move.l	d0,jc_Coef(a3)
	beq	.no
	move.l	jc_BW(a3),d0		; samples: an MCU row
	mulu.l	g_JBs(a4),d0
	move.l	d0,jc_PW(a3)
	mulu.l	d3,d0
	mulu.l	g_JBs(a4),d0
	jsr	PicAlloc
	move.l	d0,jc_Plane(a3)
	beq	.no
	lea	JC_SIZEOF(a3),a3
	dbf	d5,.cm
	moveq	#1,d0
	move.l	d0,g_JFrame(a4)
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; OkFactor - is d0 a sampling factor we take (1, 2 or 4)?
; Out: Z set if not (d0 = 0); d1, a0, a1 kept
OkFactor:
	cmp.b	#1,d0
	beq.s	.ok
	cmp.b	#2,d0
	beq.s	.ok
	cmp.b	#4,d0
	beq.s	.ok
	moveq	#0,d0
	rts
.ok:	tst.b	d0
	rts

; Log2 - 1, 2, 4 (low word of d0) -> 0, 1, 2; Out: d0
Log2:
	and.l	#$ffff,d0
	lsr.l	#1,d0
	cmp.l	#2,d0
	bne.s	.x
	moveq	#2,d0
.x:	rts

;--------------------------------------------------------------------
; ReadSOS - the scan header a2 (d2 bytes)
; Out: d0 = 0 if not decodable (CCR set)
;--------------------------------------------------------------------
ReadSOS:
	movem.l	d2-d3,-(sp)
	moveq	#0,d0
	move.b	(a2)+,d0
	move.l	d0,g_JNs(a4)
	beq.s	.no
	cmp.l	g_JNf(a4),d0
	bhi.s	.no
	mulu.w	#2,d0
	addq.l	#4,d0
	cmp.l	d0,d2
	blo.s	.no
	lea	g_JScanC(a4),a1		; the components, by index
	move.l	g_JNs(a4),d3
	subq.l	#1,d3
.c:	move.b	(a2)+,d0		; find the id
	lea	g_JComp(a4),a0
	moveq	#0,d1
.f:	cmp.b	jc_Id(a0),d0
	beq.s	.got
	lea	JC_SIZEOF(a0),a0
	addq.l	#1,d1
	cmp.l	g_JNf(a4),d1
	blo.s	.f
	bra.s	.no
.got:	move.l	a0,(a1)+
	move.b	(a2)+,d0
	move.b	d0,d1
	lsr.b	#4,d0
	and.b	#3,d0
	move.b	d0,jc_Td(a0)
	and.b	#3,d1
	move.b	d1,jc_Ta(a0)
	dbf	d3,.c
	moveq	#0,d0
	move.b	(a2)+,d0
	move.l	d0,g_JSs(a4)
	move.b	(a2)+,d0
	move.l	d0,g_JSe(a4)
	move.b	(a2),d0
	lsr.b	#4,d0
	move.l	d0,g_JAh(a4)
	move.b	(a2)+,d0
	and.l	#$0f,d0
	move.l	d0,g_JAl(a4)
	tst.l	g_JProg(a4)
	bne.s	.ok
	move.l	g_JNs(a4),d0		; baseline: one scan with all of it
	cmp.l	g_JNf(a4),d0
	bne.s	.no
	tst.l	g_JScans(a4)
	bne.s	.no
	clr.l	g_JSs(a4)
	moveq	#63,d0
	move.l	d0,g_JSe(a4)
	clr.l	g_JAh(a4)
	clr.l	g_JAl(a4)
.ok:	cmp.l	#63,g_JSe(a4)
	bhi.s	.no
	move.l	g_JSs(a4),d0
	cmp.l	g_JSe(a4),d0
	bhi.s	.no
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3
	rts

;--------------------------------------------------------------------
; Scan - decode the entropy-coded data of a scan at a2
; Out: d0 = 0 if damaged beyond use; a2 after the data (CCR set)
; In the scan: d2 = bit buffer (MSB first), d3 = bits in it, a2/a5 =
; the data, a6 = the working memory, a3 = the block being decoded
;--------------------------------------------------------------------
Scan:
	movem.l	d4-d7/a3/a6,-(sp)
	move.l	g_JWork(a4),a6
	moveq	#0,d2
	moveq	#0,d3
	clr.l	g_JMarker(a4)
	clr.l	g_JEob(a4)
	bsr	ResetPreds
	move.l	g_JRestart(a4),g_JToGo(a4)
	; which block decoder
	lea	DecSeq(pc),a0
	tst.l	g_JProg(a4)
	beq.s	.dec
	lea	DecDCFirst(pc),a0
	tst.l	g_JSs(a4)
	bne.s	.ac
	tst.l	g_JAh(a4)
	beq.s	.dec
	lea	DecDCRefine(pc),a0
	bra.s	.dec
.ac:	cmp.l	#1,g_JNs(a4)		; AC scans: one component
	bne	.bad
	lea	DecACFirst(pc),a0
	tst.l	g_JAh(a4)
	beq.s	.dec
	lea	DecACRefine(pc),a0
.dec:	move.l	a0,g_JDec(a4)
	cmp.l	#1,g_JNs(a4)
	bne	.mcus
	; one component: its blocks in the image, one an "MCU"
	move.l	g_JScanC(a4),a0
	moveq	#0,d5			; d5 = block row
.br:	move.l	g_JScanC(a4),a0
	cmp.l	jc_CH(a0),d5
	bhs	.done
	moveq	#0,d4			; d4 = block
.bc:	move.l	g_JScanC(a4),a0
	cmp.l	jc_CW(a0),d4
	bhs.s	.brn
	bsr	Restart
	move.l	jc_BW(a0),d0		; the block
	move.l	d5,d1
	tst.l	g_JStream(a4)
	beq.s	.b1
	moveq	#0,d1			; (streamed: one row kept)
.b1:	mulu.l	d0,d1
	add.l	d4,d1
	lsl.l	#7,d1
	move.l	jc_Coef(a0),a3
	add.l	d1,a3
	move.l	g_JDec(a4),a1
	jsr	(a1)
	addq.l	#1,d4
	bra.s	.bc
.brn:	tst.l	g_JStream(a4)		; streamed (greyscale): this row
	beq.s	.brx
	move.l	d5,d0
	bsr	OutputRow
.brx:	addq.l	#1,d5
	bra.s	.br
.mcus:	; interleaved: MCU by MCU, each component's H x V blocks
	moveq	#0,d5			; d5 = MCU row
.mr:	cmp.l	g_JMcuY(a4),d5
	bhs	.done
	moveq	#0,d4			; d4 = MCU
.mc:	cmp.l	g_JMcuX(a4),d4
	bhs.s	.mrn
	bsr	Restart
	lea	g_JScanC(a4),a0
	move.l	g_JNs(a4),d6
	subq.l	#1,d6
.comp:	move.l	(a0)+,a1		; a component
	movem.l	d6/a0,-(sp)
	move.l	a1,g_JCur(a4)
	moveq	#0,d7			; v
.vv:	move.l	g_JCur(a4),a1
	moveq	#0,d0
	move.b	jc_V(a1),d0
	cmp.l	d0,d7
	bhs.s	.cn
	moveq	#0,d6			; h
.hh:	move.l	g_JCur(a4),a1
	moveq	#0,d0
	move.b	jc_H(a1),d0
	cmp.l	d0,d6
	bhs.s	.vn
	; block (MCU x * H + h, MCU y * V + v)
	move.l	d4,d1
	mulu.w	d0,d1
	add.l	d6,d1			; x
	moveq	#0,d0
	move.b	jc_V(a1),d0
	tst.l	g_JStream(a4)
	beq.s	.y
	moveq	#0,d0			; (streamed: this row only)
.y:	mulu.w	d5,d0
	add.l	d7,d0			; y
	mulu.l	jc_BW(a1),d0
	add.l	d1,d0
	lsl.l	#7,d0
	move.l	jc_Coef(a1),a3
	add.l	d0,a3
	move.l	a1,a0
	move.l	g_JDec(a4),a1
	jsr	(a1)
	addq.l	#1,d6
	bra.s	.hh
.vn:	addq.l	#1,d7
	bra.s	.vv
.cn:	movem.l	(sp)+,d6/a0
	dbf	d6,.comp
	addq.l	#1,d4
	bra	.mc
.mrn:	tst.l	g_JStream(a4)		; streamed: out with the row
	beq.s	.mrx
	move.l	d5,d0
	bsr	OutputRow
.mrx:	addq.l	#1,d5
	bra	.mr
.done:	moveq	#1,d0
	bra.s	.x
.bad:	moveq	#0,d0
.x:	movem.l	(sp)+,d4-d7/a3/a6
	rts

; ResetPreds - the DC predictors to 0
ResetPreds:
	lea	g_JComp(a4),a0
	moveq	#4-1,d0
.l:	clr.l	jc_Pred(a0)
	lea	JC_SIZEOF(a0),a0
	dbf	d0,.l
	rts

; Restart - count an MCU; at the end of a restart interval, skip the
; RSTn marker and start over (a0 kept)
Restart:
	tst.l	g_JRestart(a4)
	beq.s	.x
	tst.l	g_JToGo(a4)
	bne.s	.c
	move.l	a0,-(sp)
	moveq	#0,d2			; drop the bits; find the marker
	moveq	#0,d3
	clr.l	g_JMarker(a4)
.f:	lea	1(a2),a0
	cmp.l	a5,a0
	bhs.s	.r
	cmp.b	#$ff,(a2)
	bne.s	.s
	move.b	1(a2),d0
	and.b	#$f8,d0
	cmp.b	#$d0,d0
	bne.s	.s
	addq.l	#2,a2
	bra.s	.r
.s:	addq.l	#1,a2
	bra.s	.f
.r:	bsr	ResetPreds
	clr.l	g_JEob(a4)
	move.l	g_JRestart(a4),g_JToGo(a4)
	move.l	(sp)+,a0
.c:	subq.l	#1,g_JToGo(a4)
.x:	rts

;--------------------------------------------------------------------
; the bits (d2/d3, a2/a5); a marker or the end gives zeros
;--------------------------------------------------------------------

; Fill - at least 25 bits in d2 (a6 kept)
Fill:
.l:	cmp.l	#24,d3
	bgt.s	.x
	tst.l	g_JMarker(a4)
	bne.s	.zero
	cmp.l	a5,a2
	bhs.s	.zero
	moveq	#0,d0
	move.b	(a2)+,d0
	cmp.b	#$ff,d0
	bne.s	.put
	cmp.l	a5,a2
	bhs.s	.zero
	tst.b	(a2)			; FF 00: an FF
	bne.s	.mark
	addq.l	#1,a2
.put:	moveq	#24,d1
	sub.l	d3,d1
	lsl.l	d1,d0
	or.l	d0,d2
	addq.l	#8,d3
	bra.s	.l
.mark:	subq.l	#1,a2			; (stays before the marker)
	st	g_JMarker(a4)
.zero:	addq.l	#8,d3
	bra.s	.l
.x:	rts

; Get - the next d0 bits (1-16) as a number (a6 kept)
Get:
	cmp.l	d0,d3
	bge.s	.h
	move.l	d0,-(sp)
	bsr.s	Fill
	move.l	(sp)+,d0
.h:	bfextu	d2{0:d0},d1
	lsl.l	d0,d2
	sub.l	d0,d3
	move.l	d1,d0
	rts

; Extend - the next d0 bits (1-16) as a signed coefficient (JPEG's
; EXTEND: below half the range is negative)
; Out: d0 (a6 kept)
Extend:
	move.l	d0,-(sp)
	bsr.s	Get
	move.l	(sp)+,d1		; s
	subq.l	#1,d1
	btst	d1,d0
	bne.s	.x
	addq.l	#1,d1			; v + 1 - 2^s
	move.l	d0,a0
	moveq	#1,d0
	lsl.l	d1,d0
	sub.l	d0,a0
	addq.l	#1,a0
	move.l	a0,d0
.x:	rts

; Huff - the next value of Huffman table a1
; Out: d0 = value (a6 kept)
Huff:
	cmp.l	#16,d3
	bge.s	.h
	bsr.s	Fill
.h:	bfextu	d2{0:9},d0
	move.w	jh_Look(a1,d0.l*2),d0
	beq.s	.slow
	moveq	#0,d1
	move.w	d0,d1
	lsr.w	#8,d1
	lsl.l	d1,d2
	sub.l	d1,d3
	and.l	#$ff,d0
	rts
.slow:	moveq	#10,d1			; longer: compare with the largest
.sl:	bfextu	d2{0:d1},d0		; code of each length
	cmp.l	jh_Max(a1,d1.l*4),d0
	ble.s	.f
	addq.l	#1,d1
	cmp.l	#16,d1
	bls.s	.sl
	moveq	#0,d0			; damaged: a 0
	rts
.f:	lsl.l	d1,d2
	sub.l	d1,d3
	add.l	jh_Off(a1,d1.l*4),d0
	and.l	#$ff,d0
	move.b	jh_Val(a1,d0.l),d0
	rts

;--------------------------------------------------------------------
; the block decoders: a0 = component, a3 = its block (64 words,
; natural order); d2/d3/a2/a5 the bits, a6 the working memory
;--------------------------------------------------------------------

; HuffDC - a1 = component a0's DC table
HuffDC	MACRO
	moveq	#0,d0
	move.b	jc_Td(\1),d0
	mulu.w	#jh_SIZEOF,d0
	lea	jw_Huff(a6,d0.l),a1
	ENDM
; HuffAC - a1 = component a0's AC table
HuffAC	MACRO
	moveq	#0,d0
	move.b	jc_Ta(\1),d0
	addq.l	#4,d0
	mulu.w	#jh_SIZEOF,d0
	lea	jw_Huff(a6,d0.l),a1
	ENDM

; DecSeq - a block of a sequential scan (DC and all AC)
DecSeq:
	movem.l	d4-d6,-(sp)
	move.l	a0,d6			; d6 = component
	HuffDC	a0
	bsr	Huff
	tst.l	d0
	beq.s	.dc
	bsr	Extend
.dc:	move.l	d6,a0
	add.l	jc_Pred(a0),d0
	move.l	d0,jc_Pred(a0)
	move.w	d0,(a3)
	HuffAC	a0
	move.l	a1,d5			; d5 = AC table
	moveq	#1,d4			; d4 = k
.ac:	move.l	d5,a1
	bsr	Huff			; run, size
	moveq	#15,d1
	and.l	d0,d1
	lsr.l	#4,d0
	tst.l	d1
	beq.s	.zs
	add.l	d0,d4
	move.l	d1,d0
	bsr	Extend
	lea	Natural(pc),a0
	moveq	#0,d1
	move.b	(a0,d4.l),d1
	move.w	d0,(a3,d1.l*2)
	addq.l	#1,d4
	cmp.l	#64,d4
	blo.s	.ac
	bra.s	.x
.zs:	cmp.l	#15,d0			; 16 zeros, else the end
	bne.s	.x
	add.l	#16,d4
	cmp.l	#64,d4
	blo.s	.ac
.x:	movem.l	(sp)+,d4-d6
	rts

; DecDCFirst - progressive: the DC coefficient (shifted by Al)
DecDCFirst:
	move.l	a0,-(sp)
	HuffDC	a0
	bsr	Huff
	tst.l	d0
	beq.s	.d
	bsr	Extend
.d:	move.l	(sp)+,a0
	add.l	jc_Pred(a0),d0
	move.l	d0,jc_Pred(a0)
	move.l	g_JAl(a4),d1
	lsl.l	d1,d0
	move.w	d0,(a3)
	rts

; DecDCRefine - progressive: one more bit of the DC coefficient
DecDCRefine:
	moveq	#1,d0
	bsr	Get
	tst.l	d0
	beq.s	.x
	move.l	g_JAl(a4),d0
	move.w	(a3),d1
	bset	d0,d1
	move.w	d1,(a3)
.x:	rts

; DecACFirst - progressive: AC coefficients Ss..Se (shifted by Al)
DecACFirst:
	movem.l	d4-d6,-(sp)
	tst.l	g_JEob(a4)		; in a run of empty blocks
	beq.s	.go
	subq.l	#1,g_JEob(a4)
	bra.s	.x
.go:	HuffAC	a0
	move.l	a1,d5
	move.l	g_JSs(a4),d4		; d4 = k
.ac:	cmp.l	g_JSe(a4),d4
	bhi.s	.x
	move.l	d5,a1
	bsr	Huff
	moveq	#15,d1
	and.l	d0,d1
	lsr.l	#4,d0
	tst.l	d1
	beq.s	.zs
	add.l	d0,d4
	move.l	d1,d0
	bsr	Extend
	move.l	g_JAl(a4),d1
	lsl.l	d1,d0
	lea	Natural(pc),a0
	moveq	#0,d1
	move.b	(a0,d4.l),d1
	move.w	d0,(a3,d1.l*2)
	addq.l	#1,d4
	bra.s	.ac
.zs:	cmp.l	#15,d0
	bne.s	.eob
	add.l	#16,d4
	bra.s	.ac
.eob:	moveq	#1,d6			; a run of 2^r (+ r bits) blocks
	lsl.l	d0,d6
	tst.l	d0
	beq.s	.e
	bsr	Get
	add.l	d0,d6
.e:	subq.l	#1,d6			; (this one)
	move.l	d6,g_JEob(a4)
.x:	movem.l	(sp)+,d4-d6
	rts

; DecACRefine - progressive: the next bit of AC coefficients Ss..Se,
; and new coefficients of +-1 << Al (libjpeg's decode_mcu_AC_refine)
DecACRefine:
	movem.l	d4-d7,-(sp)
	move.l	g_JSs(a4),d4		; d4 = k
	moveq	#1,d6
	move.l	g_JAl(a4),d0
	lsl.l	d0,d6			; d6 = p1 (m1 = -p1)
	tst.l	g_JEob(a4)
	bne	.run
	HuffAC	a0
	move.l	a1,g_JAcTab(a4)
.ac:	cmp.l	g_JSe(a4),d4
	bhi	.x
	move.l	g_JAcTab(a4),a1
	bsr	Huff
	moveq	#15,d7
	and.l	d0,d7			; d7 = s (0 or 1)
	lsr.l	#4,d0
	move.l	d0,d5			; d5 = r
	tst.l	d7
	beq.s	.zs
	moveq	#1,d0			; new: +p1 or -p1
	bsr	Get
	move.l	d6,d7
	tst.l	d0
	bne.s	.adv
	neg.l	d7
	bra.s	.adv
.zs:	cmp.l	#15,d5
	beq.s	.adv
	moveq	#1,d0			; a run of empty blocks
	lsl.l	d5,d0
	move.l	d0,g_JEob(a4)
	tst.l	d5
	beq.s	.run
	move.l	d5,d0
	bsr	Get
	add.l	d0,g_JEob(a4)
	bra.s	.run
.adv:	; past nonzero coefficients (refining them) and r zeros
	cmp.l	g_JSe(a4),d4
	bhi.s	.set
	bsr	Refine			; d0 = 1 if it was zero
	beq.s	.nz
	subq.l	#1,d5
	bmi.s	.set
.nz:	addq.l	#1,d4
	bra.s	.adv
.set:	tst.l	d7
	beq.s	.nn
	cmp.l	#63,d4
	bhi.s	.nn
	lea	Natural(pc),a0
	moveq	#0,d0
	move.b	(a0,d4.l),d0
	move.w	d7,(a3,d0.l*2)
.nn:	addq.l	#1,d4
	bra.s	.ac
.run:	; the rest of a block in a run: refine its nonzero coefficients
	cmp.l	g_JSe(a4),d4
	bhi.s	.rx
	bsr	Refine
	addq.l	#1,d4
	bra.s	.run
.rx:	subq.l	#1,g_JEob(a4)
.x:	movem.l	(sp)+,d4-d7
	rts

; Refine - coefficient k (d4) of block a3: if nonzero, read a bit and
; correct it (d6 = p1)
; Out: d0 = 1 if it was zero (CCR set)
Refine:
	lea	Natural(pc),a0
	moveq	#0,d0
	move.b	(a0,d4.l),d0
	lea	(a3,d0.l*2),a0
	tst.w	(a0)
	beq.s	.zero
	move.l	a0,-(sp)
	moveq	#1,d0
	bsr	Get
	move.l	(sp)+,a0
	tst.l	d0
	beq.s	.done
	move.w	(a0),d0
	move.w	d0,d1
	and.w	d6,d1
	bne.s	.done			; (that bit is set already)
	tst.w	d0
	bmi.s	.neg
	add.w	d6,(a0)
	bra.s	.done
.neg:	sub.w	d6,(a0)
.done:	moveq	#0,d0
	rts
.zero:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; OutputRow - MCU row d0 to pixels: the inverse DCT of each component's
; blocks into its plane, then the colour conversion
;--------------------------------------------------------------------
OutputRow:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	move.l	d0,d7			; d7 = MCU row
	move.l	g_JWork(a4),a6
	PROFB	3
	lea	g_JComp(a4),a5
	move.l	g_JNf(a4),d6
	subq.l	#1,d6
.comp:	moveq	#0,d5
	move.b	jc_V(a5),d5		; d5 = V
	move.l	jc_Coef(a5),a3		; a3 = the first block of the row
	tst.l	g_JStream(a4)
	bne.s	.c0
	move.l	jc_BW(a5),d0
	mulu.l	d5,d0
	mulu.l	d7,d0
	lsl.l	#7,d0
	add.l	d0,a3
.c0:	moveq	#0,d4			; v
.v:	cmp.l	d5,d4
	bhs.s	.cd
	moveq	#0,d3			; block
.b:	cmp.l	jc_BW(a5),d3
	bhs.s	.vn
	move.l	d4,d0			; to plane + v * bs * PW + b * bs
	mulu.l	g_JBs(a4),d0
	mulu.l	jc_PW(a5),d0
	move.l	d3,d1
	mulu.l	g_JBs(a4),d1
	add.l	d1,d0
	move.l	jc_Plane(a5),a2
	add.l	d0,a2
	move.l	a3,a0
	moveq	#0,d0
	move.b	jc_Tq(a5),d0
	move.l	jc_PW(a5),d1
	bsr	Idct
	lea	128(a3),a3
	addq.l	#1,d3
	bra.s	.b
.vn:	addq.l	#1,d4
	bra.s	.v
.cd:	tst.l	g_JStream(a4)		; streamed: the next row comes there
	beq.s	.cn
	move.l	jc_Coef(a5),a0
	move.l	jc_BW(a5),d0
	mulu.l	d5,d0
	lsl.l	#5,d0			; longs
	bra.s	.cle
.cl:	clr.l	(a0)+
.cle:	subq.l	#1,d0
	bpl.s	.cl
.cn:	lea	JC_SIZEOF(a5),a5
	dbf	d6,.comp
	PROFE	3
	; the lines of this row
	PROFB	4
	move.l	g_JVmax(a4),d0
	mulu.l	g_JBs(a4),d0
	move.l	d0,d6			; d6 = lines in an MCU row
	mulu.l	d7,d0			; first line
	move.l	g_JOutH(a4),d1
	sub.l	d0,d1
	ble	.x
	cmp.l	d6,d1
	bhs.s	.n
	move.l	d1,d6
.n:	move.l	d0,g_JLine(a4)
	clr.l	g_JLy(a4)
.line:	move.l	g_JLy(a4),d0
	cmp.l	d6,d0
	bhs	.x
	lea	jw_Clip+256(a6),a5	; a5 = clip (signed index)
	move.l	g_PicData(a4),a3	; a3 = the pixels
	move.l	g_JLine(a4),d1
	add.l	d0,d1
	mulu.l	g_JOutW(a4),d1
	lea	(a3,d1.l*4),a3
	lea	g_JComp(a4),a0		; rows of each component's samples
	bsr	PlaneRow
	move.l	d1,d3			; d3/a0 = component 0: shift, row
	move.l	a1,-(sp)
	cmp.l	#1,g_JNf(a4)
	beq	.grey
	lea	g_JComp+JC_SIZEOF(a4),a0
	bsr	PlaneRow
	move.l	d1,d4			; d4/a1 = component 1
	move.l	a1,-(sp)
	lea	g_JComp+2*JC_SIZEOF(a4),a0
	bsr	PlaneRow
	move.l	d1,d5			; d5/a2 = component 2
	move.l	a1,a2
	move.l	(sp)+,a1
	move.l	(sp)+,a0
	moveq	#0,d7			; x
	bsr	IsRGB
	bne	.rgb
	tst.l	d3			; Y 1:1 and chroma 1:1 or 1:2 across
	bne.s	.ycc			; (4:4:4, 4:2:2, 4:2:0): a quick loop
	cmp.l	d4,d5
	bne.s	.ycc
	cmp.l	#1,d4
	bhi.s	.ycc
	move.l	g_JOutW(a4),d7		; d7 = pixels left
	tst.l	d4
	beq	.q1
.q2:	bsr	.uv			; two pixels a chroma sample
	bsr	.px
	subq.l	#1,d7
	beq	.ln
	bsr	.px
	subq.l	#1,d7
	bne.s	.q2
	bra	.ln
.q1:	bsr	.uv			; one
	bsr	.px
	subq.l	#1,d7
	bne.s	.q1
	bra	.ln
; .uv - the next chroma sample: d2 = R term, d3 = G, d4 = B
.uv:	moveq	#0,d0
	move.b	(a1)+,d0		; Cb
	moveq	#0,d1
	move.b	(a2)+,d1		; Cr
	move.w	jw_CbB(a6,d0.w*2),d4
	move.l	jw_CbG(a6,d0.w*4),d3
	add.l	jw_CrG(a6,d1.w*4),d3
	swap	d3
	move.w	jw_CrR(a6,d1.w*2),d2
	rts
; .px - the next pixel: Y + the chroma terms, as $ffRRGGBB
.px:	moveq	#0,d5
	move.b	(a0)+,d5
	moveq	#-1,d1
	move.w	d2,d0
	add.w	d5,d0
	move.b	(a5,d0.w),d1
	lsl.l	#8,d1
	move.w	d3,d0
	add.w	d5,d0
	move.b	(a5,d0.w),d1
	lsl.l	#8,d1
	move.w	d4,d0
	add.w	d5,d0
	move.b	(a5,d0.w),d1
	move.l	d1,(a3)+
	rts
.ycc:	move.l	d7,d0
	lsr.l	d3,d0
	moveq	#0,d1
	move.b	(a0,d0.l),d1		; Y
	move.l	d7,d0
	lsr.l	d4,d0
	moveq	#0,d2
	move.b	(a1,d0.l),d2		; Cb
	move.l	d7,d0
	lsr.l	d5,d0
	move.b	(a2,d0.l),d0
	and.w	#$ff,d0			; Cr
	move.b	#$ff,(a3)+
	move.l	d0,-(sp)
	move.w	jw_CrR(a6,d0.w*2),d0	; R
	add.w	d1,d0
	move.b	(a5,d0.w),(a3)+
	move.l	(sp),d0
	move.l	jw_CrG(a6,d0.w*4),d0	; G
	add.l	jw_CbG(a6,d2.w*4),d0
	swap	d0
	add.w	d1,d0
	move.b	(a5,d0.w),(a3)+
	move.w	jw_CbB(a6,d2.w*2),d0	; B
	add.w	d1,d0
	move.b	(a5,d0.w),(a3)+
	addq.l	#4,sp
	addq.l	#1,d7
	cmp.l	g_JOutW(a4),d7
	blo.s	.ycc
	bra.s	.ln
.rgb:	move.l	d7,d0
	lsr.l	d3,d0
	move.b	#$ff,(a3)+
	move.b	(a0,d0.l),(a3)+
	move.l	d7,d0
	lsr.l	d4,d0
	move.b	(a1,d0.l),(a3)+
	move.l	d7,d0
	lsr.l	d5,d0
	move.b	(a2,d0.l),(a3)+
	addq.l	#1,d7
	cmp.l	g_JOutW(a4),d7
	blo.s	.rgb
	bra.s	.ln
.grey:	move.l	(sp)+,a0
	moveq	#0,d7
.g:	move.l	d7,d0
	lsr.l	d3,d0
	moveq	#0,d1
	move.b	(a0,d0.l),d1
	move.b	#$ff,(a3)+
	move.b	d1,(a3)+
	move.b	d1,(a3)+
	move.b	d1,(a3)+
	addq.l	#1,d7
	cmp.l	g_JOutW(a4),d7
	blo.s	.g
.ln:	addq.l	#1,g_JLy(a4)
	bra	.line
.x:	PROFE	4
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; PlaneRow - component a0's samples for output line g_JLy of the row
; Out: a1 = them, d1 = its x shift
PlaneRow:
	moveq	#0,d1
	move.b	jc_YS(a0),d1
	move.l	g_JLy(a4),d0
	lsr.l	d1,d0
	mulu.l	jc_PW(a0),d0
	move.l	jc_Plane(a0),a1
	add.l	d0,a1
	moveq	#0,d1
	move.b	jc_XS(a0),d1
	rts

; IsRGB - three components that are R, G, B (not YCbCr)?
; Out: d0 = 1 if so (CCR set)
IsRGB:
	move.l	g_JAdobe(a4),d0		; Adobe: transform 0
	beq.s	.yes
	bpl.s	.no
	cmp.b	#'R',g_JComp+jc_Id(a4)	; or the components' names
	bne.s	.no
	cmp.b	#'G',g_JComp+JC_SIZEOF+jc_Id(a4)
	bne.s	.no
	cmp.b	#'B',g_JComp+2*JC_SIZEOF+jc_Id(a4)
	bne.s	.no
.yes:	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; Idct - block a0 (coefficients) with quantization table d0 to samples
; at a2 (d1 bytes per row): 8x8, or 1x1 (DC only) at 1/8 (a6 = work)
;--------------------------------------------------------------------
Idct:
	tst.l	g_JShift(a4)
	bne.s	.dc
	lsl.l	#7,d0
	lea	jw_QA(a6,d0.l),a1
	bra	IdctFull
.dc:	lsl.l	#7,d0			; (DC * q + 4) >> 3, + 128
	move.w	(a0),d1
	muls.w	jw_Q(a6,d0.l),d1
	addq.l	#4,d1
	asr.l	#3,d1
	add.l	#512,d1
	and.l	#1023,d1
	move.b	jw_Range(a6,d1.l),(a2)
	rts

; IdctFull - 8x8 inverse DCT (libjpeg's jidctfst): a0 = coefficients,
; a1 = AAN-scaled quantization, a2 = output, d1 = bytes per row
FIX_1_082	equ	277			; 1.082392200 << 8
FIX_1_414	equ	362			; 1.414213562
FIX_1_847	equ	473			; 1.847759065
FIX_2_613	equ	669			; 2.613125930
IdctFull:
	move.w	2(a0),d0		; no AC at all: one value (often)
	or.l	4(a0),d0
	or.l	8(a0),d0
	or.l	12(a0),d0
	or.l	16(a0),d0
	or.l	20(a0),d0
	or.l	24(a0),d0
	or.l	28(a0),d0
	or.l	32(a0),d0
	or.l	36(a0),d0
	or.l	40(a0),d0
	or.l	44(a0),d0
	or.l	48(a0),d0
	or.l	52(a0),d0
	or.l	56(a0),d0
	or.l	60(a0),d0
	or.l	64(a0),d0
	or.l	68(a0),d0
	or.l	72(a0),d0
	or.l	76(a0),d0
	or.l	80(a0),d0
	or.l	84(a0),d0
	or.l	88(a0),d0
	or.l	92(a0),d0
	or.l	96(a0),d0
	or.l	100(a0),d0
	or.l	104(a0),d0
	or.l	108(a0),d0
	or.l	112(a0),d0
	or.l	116(a0),d0
	or.l	120(a0),d0
	or.l	124(a0),d0
	bne.s	.full
	move.w	(a0),d0
	muls.w	(a1),d0
	add.l	#512<<5,d0
	asr.l	#5,d0
	and.l	#1023,d0
	move.b	jw_Range(a6,d0.l),d0
	and.l	#$ff,d0
	mulu.l	#$01010101,d0
	move.l	a2,a0			; (d1 = bytes a row)
	move.l	d0,(a0)
	move.l	d0,4(a0)
	add.l	d1,a0
	move.l	d0,(a0)
	move.l	d0,4(a0)
	add.l	d1,a0
	move.l	d0,(a0)
	move.l	d0,4(a0)
	add.l	d1,a0
	move.l	d0,(a0)
	move.l	d0,4(a0)
	add.l	d1,a0
	move.l	d0,(a0)
	move.l	d0,4(a0)
	add.l	d1,a0
	move.l	d0,(a0)
	move.l	d0,4(a0)
	add.l	d1,a0
	move.l	d0,(a0)
	move.l	d0,4(a0)
	add.l	d1,a0
	move.l	d0,(a0)
	move.l	d0,4(a0)
	add.l	d1,a0
	rts
.full:	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	d1,-(sp)		; (row stride)
	lea	jw_WS(a6),a5
	moveq	#8-1,d0
	move.l	d0,-(sp)		; columns to go
	; pass 1: columns, into the workspace (longs, rows 32 bytes)
.col:	move.w	16(a0),d0		; no AC: all the DC
	or.w	32(a0),d0
	or.w	48(a0),d0
	or.w	64(a0),d0
	or.w	80(a0),d0
	or.w	96(a0),d0
	or.w	112(a0),d0
	bne.s	.c2
	move.w	(a0),d0
	muls.w	(a1),d0
	move.l	d0,(a5)
	move.l	d0,32(a5)
	move.l	d0,64(a5)
	move.l	d0,96(a5)
	move.l	d0,128(a5)
	move.l	d0,160(a5)
	move.l	d0,192(a5)
	move.l	d0,224(a5)
	bra	.cnext
.c2:	move.w	32(a0),d0		; rows 2-7 empty?
	or.w	48(a0),d0
	or.w	64(a0),d0
	or.w	80(a0),d0
	or.w	96(a0),d0
	or.w	112(a0),d0
	bne.s	.cfull
	move.w	(a0),d0
	muls.w	(a1),d0			; w0
	move.w	16(a0),d1
	muls.w	16(a1),d1		; w1
	move.l	d1,d2			; only w0, w1: the butterflies with
	muls.l	#FIX_1_414,d2		; zeros (3 multiplications, not 5)
	asr.l	#8,d2			; tmp11
	move.l	d1,d3
	muls.l	#FIX_1_847,d3
	asr.l	#8,d3			; z5
	move.l	d1,d4
	muls.l	#FIX_1_082,d4
	asr.l	#8,d4
	sub.l	d3,d4			; tmp10
	sub.l	d1,d3			; tmp6 = z5 - w1
	sub.l	d3,d2			; tmp5 = tmp11 - tmp6
	add.l	d2,d4			; tmp4 = tmp10 + tmp5
	move.l	d0,d5
	add.l	d1,d5
	move.l	d5,0(a5)
	move.l	d0,d5
	sub.l	d1,d5
	move.l	d5,224(a5)
	move.l	d0,d5
	add.l	d3,d5
	move.l	d5,32(a5)
	move.l	d0,d5
	sub.l	d3,d5
	move.l	d5,192(a5)
	move.l	d0,d5
	add.l	d2,d5
	move.l	d5,64(a5)
	move.l	d0,d5
	sub.l	d2,d5
	move.l	d5,160(a5)
	move.l	d0,d5
	add.l	d4,d5
	move.l	d5,128(a5)
	move.l	d0,d5
	sub.l	d4,d5
	move.l	d5,96(a5)
	bra	.cnext
.cfull:	move.w	(a0),d0			; even part: rows 0, 2, 4, 6
	muls.w	(a1),d0
	move.w	32(a0),d1
	muls.w	32(a1),d1
	move.w	64(a0),d2
	muls.w	64(a1),d2
	move.w	96(a0),d3
	muls.w	96(a1),d3
	move.l	d0,d4			; tmp10 = tmp0 + tmp2
	add.l	d2,d4
	sub.l	d2,d0			; tmp11 = tmp0 - tmp2
	move.l	d1,d5			; tmp13 = tmp1 + tmp3
	add.l	d3,d5
	sub.l	d3,d1			; tmp12 = (tmp1 - tmp3) * 1.414 - tmp13
	muls.l	#FIX_1_414,d1
	asr.l	#8,d1
	sub.l	d5,d1
	move.l	d4,d2
	add.l	d5,d2
	move.l	d2,(a5)			; e0 = tmp10 + tmp13
	sub.l	d5,d4
	move.l	d4,96(a5)		; e3 = tmp10 - tmp13
	move.l	d0,d2
	add.l	d1,d2
	move.l	d2,32(a5)		; e1 = tmp11 + tmp12
	sub.l	d1,d0
	move.l	d0,64(a5)		; e2 = tmp11 - tmp12
	move.w	16(a0),d0		; odd part: rows 1, 3, 5, 7
	muls.w	16(a1),d0
	move.w	48(a0),d1
	muls.w	48(a1),d1
	move.w	80(a0),d2
	muls.w	80(a1),d2
	move.w	112(a0),d3
	muls.w	112(a1),d3
	bsr	Odd
	move.l	(a5),d1			; out: e0 +- tmp7 ...
	move.l	d1,d3
	add.l	d7,d1
	move.l	d1,(a5)
	sub.l	d7,d3
	move.l	d3,224(a5)
	move.l	32(a5),d1
	move.l	d1,d3
	add.l	d2,d1
	move.l	d1,32(a5)
	sub.l	d2,d3
	move.l	d3,192(a5)
	move.l	64(a5),d1
	move.l	d1,d3
	add.l	d5,d1
	move.l	d1,64(a5)
	sub.l	d5,d3
	move.l	d3,160(a5)
	move.l	96(a5),d1
	move.l	d1,d3
	add.l	d0,d1
	move.l	d1,128(a5)
	sub.l	d0,d3
	move.l	d3,96(a5)
.cnext:	addq.l	#2,a0
	addq.l	#2,a1
	addq.l	#4,a5
	subq.l	#1,(sp)
	bpl	.col
	; pass 2: rows, to samples (+16384: the +512 of the range table)
	lea	jw_WS(a6),a5
	lea	jw_Range(a6),a3
	moveq	#8-1,d0
	move.l	d0,(sp)
.row:	add.l	#512<<5,(a5)
	move.l	4(a5),d0		; no AC
	or.l	8(a5),d0
	or.l	12(a5),d0
	or.l	16(a5),d0
	or.l	20(a5),d0
	or.l	24(a5),d0
	or.l	28(a5),d0
	bne.s	.r2
	move.l	(a5),d0
	asr.l	#5,d0
	and.l	#1023,d0
	move.b	(a3,d0.l),d0
	move.b	d0,(a2)
	move.b	d0,1(a2)
	move.b	d0,2(a2)
	move.b	d0,3(a2)
	move.b	d0,4(a2)
	move.b	d0,5(a2)
	move.b	d0,6(a2)
	move.b	d0,7(a2)
	bra	.rnext
.r2:	move.l	8(a5),d0		; w2-w7 empty?
	or.l	12(a5),d0
	or.l	16(a5),d0
	or.l	20(a5),d0
	or.l	24(a5),d0
	or.l	28(a5),d0
	bne.s	.rfull
	move.l	(a5),d0			; w0 (+ the range offset)
	move.l	4(a5),d1		; w1
	move.l	d1,d2			; only w0, w1: the butterflies with
	muls.l	#FIX_1_414,d2		; zeros (3 multiplications, not 5)
	asr.l	#8,d2			; tmp11
	move.l	d1,d3
	muls.l	#FIX_1_847,d3
	asr.l	#8,d3			; z5
	move.l	d1,d4
	muls.l	#FIX_1_082,d4
	asr.l	#8,d4
	sub.l	d3,d4			; tmp10
	sub.l	d1,d3			; tmp6 = z5 - w1
	sub.l	d3,d2			; tmp5 = tmp11 - tmp6
	add.l	d2,d4			; tmp4 = tmp10 + tmp5
	move.l	d0,d5
	add.l	d1,d5
	asr.l	#5,d5
	and.l	#1023,d5
	move.b	(a3,d5.l),(a2)
	move.l	d0,d5
	sub.l	d1,d5
	asr.l	#5,d5
	and.l	#1023,d5
	move.b	(a3,d5.l),7(a2)
	move.l	d0,d5
	add.l	d3,d5
	asr.l	#5,d5
	and.l	#1023,d5
	move.b	(a3,d5.l),1(a2)
	move.l	d0,d5
	sub.l	d3,d5
	asr.l	#5,d5
	and.l	#1023,d5
	move.b	(a3,d5.l),6(a2)
	move.l	d0,d5
	add.l	d2,d5
	asr.l	#5,d5
	and.l	#1023,d5
	move.b	(a3,d5.l),2(a2)
	move.l	d0,d5
	sub.l	d2,d5
	asr.l	#5,d5
	and.l	#1023,d5
	move.b	(a3,d5.l),5(a2)
	move.l	d0,d5
	add.l	d4,d5
	asr.l	#5,d5
	and.l	#1023,d5
	move.b	(a3,d5.l),4(a2)
	move.l	d0,d5
	sub.l	d4,d5
	asr.l	#5,d5
	and.l	#1023,d5
	move.b	(a3,d5.l),3(a2)
	bra	.rnext
.rfull:	move.l	(a5),d0			; even: 0, 2, 4, 6
	move.l	8(a5),d1
	move.l	16(a5),d2
	move.l	24(a5),d3
	move.l	d0,d4
	add.l	d2,d4			; tmp10
	sub.l	d2,d0			; tmp11
	move.l	d1,d5
	add.l	d3,d5			; tmp13
	sub.l	d3,d1
	muls.l	#FIX_1_414,d1
	asr.l	#8,d1
	sub.l	d5,d1			; tmp12
	move.l	d4,d2
	add.l	d5,d2
	move.l	d2,(a5)			; e0
	sub.l	d5,d4
	move.l	d4,24(a5)		; e3
	move.l	d0,d2
	add.l	d1,d2
	move.l	d2,8(a5)		; e1
	sub.l	d1,d0
	move.l	d0,16(a5)		; e2
	move.l	4(a5),d0		; odd: 1, 3, 5, 7
	move.l	12(a5),d1
	move.l	20(a5),d2
	move.l	28(a5),d3
	bsr	Odd
	move.l	(a5),d1
	move.l	d1,d3
	add.l	d7,d1
	asr.l	#5,d1
	and.l	#1023,d1
	move.b	(a3,d1.l),(a2)
	sub.l	d7,d3
	asr.l	#5,d3
	and.l	#1023,d3
	move.b	(a3,d3.l),7(a2)
	move.l	8(a5),d1
	move.l	d1,d3
	add.l	d2,d1
	asr.l	#5,d1
	and.l	#1023,d1
	move.b	(a3,d1.l),1(a2)
	sub.l	d2,d3
	asr.l	#5,d3
	and.l	#1023,d3
	move.b	(a3,d3.l),6(a2)
	move.l	16(a5),d1
	move.l	d1,d3
	add.l	d5,d1
	asr.l	#5,d1
	and.l	#1023,d1
	move.b	(a3,d1.l),2(a2)
	sub.l	d5,d3
	asr.l	#5,d3
	and.l	#1023,d3
	move.b	(a3,d3.l),5(a2)
	move.l	24(a5),d1
	move.l	d1,d3
	add.l	d0,d1
	asr.l	#5,d1
	and.l	#1023,d1
	move.b	(a3,d1.l),4(a2)
	sub.l	d0,d3
	asr.l	#5,d3
	and.l	#1023,d3
	move.b	(a3,d3.l),3(a2)
.rnext:	add.l	4(sp),a2
	lea	32(a5),a5
	subq.l	#1,(sp)
	bpl	.row
	addq.l	#8,sp
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; Odd - the odd part: d0-d3 = rows/columns 1, 3, 5, 7
; Out: d7 = tmp7, d2 = tmp6, d5 = tmp5, d0 = tmp4
Odd:
	move.l	d2,d4
	add.l	d1,d4			; z13 = 5 + 3
	sub.l	d1,d2			; z10 = 5 - 3
	move.l	d0,d5
	add.l	d3,d5			; z11 = 1 + 7
	sub.l	d3,d0			; z12 = 1 - 7
	move.l	d5,d7
	add.l	d4,d7			; tmp7 = z11 + z13
	sub.l	d4,d5
	muls.l	#FIX_1_414,d5
	asr.l	#8,d5			; tmp11
	move.l	d2,d6
	add.l	d0,d6
	muls.l	#FIX_1_847,d6
	asr.l	#8,d6			; z5
	muls.l	#FIX_1_082,d0
	asr.l	#8,d0
	sub.l	d6,d0			; tmp10 = z12 * 1.082 - z5
	muls.l	#-FIX_2_613,d2
	asr.l	#8,d2
	add.l	d6,d2			; tmp12 = z10 * -2.613 + z5
	sub.l	d7,d2			; tmp6 = tmp12 - tmp7
	sub.l	d2,d5			; tmp5 = tmp11 - tmp6
	add.l	d5,d0			; tmp4 = tmp10 + tmp5
	rts

; zigzag -> natural order (16 more: damaged runs stay in the block)
Natural:
	dc.b	0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5
	dc.b	12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28
	dc.b	35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51
	dc.b	58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63
	dc.b	63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63
	even
; the AAN scale factors (14 bits), natural order
AanScale:
	dc.w	16384,22725,21407,19266,16384,12873,8867,4520
	dc.w	22725,31521,29692,26722,22725,17855,12299,6270
	dc.w	21407,29692,27969,25172,21407,16819,11585,5906
	dc.w	19266,26722,25172,22654,19266,15137,10426,5315
	dc.w	16384,22725,21407,19266,16384,12873,8867,4520
	dc.w	12873,17855,16819,15137,12873,10114,6967,3552
	dc.w	8867,12299,11585,10426,8867,6967,4799,2446
	dc.w	4520,6270,5906,5315,4520,3552,2446,1247
