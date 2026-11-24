;
; pagefile.s - laid-out pages in the disk cache
;
; A page that has been shown is saved as it is in memory: its arena
; blocks (DOM, attributes, styles, CSS rules, form state), its source,
; runs and anchors, and its globals (a KeepPage record, keep.s).  The
; next time it comes from the disk cache, it is read back instead of
; being parsed and laid out: 0.x s instead of seconds.
;
; Pointers are what makes memory hard to save.  PfBuild copies the
; parts one after the other into one buffer: an "offset" is a place in
; that sequence.  Then it walks the page's structures the way the rest
; of Velox does and, for each pointer field, writes the offset of what
; it points to into the copy and marks the field in a bitmap (one bit a
; long).  Marking twice does no harm, so a structure reached twice is
; fine.  A pointer to anything outside the page fails the save (it is
; not saved, never wrong).  Loading (PfApply) needs no walk: it reads
; the parts into new memory and turns each marked long back into an
; address.
;
; Some pointers lead out of the page on purpose: attribute names that
; html.s knows point to its table of them (AttrNames).  That table is a
; part too, after the others, not saved: its offsets stay right as long
; as the build is the same.
;
; Not saved: images (n_Data2 of <img>, bg_Info): they come back from
; the disk cache as shown (img.s), and CSS match caches (n_Css).
;
; The file is only used for the same source (a hash of the page as it
; came, which the HTML entry of the disk cache has), the same build of
; Velox (BUILD_ID, a hash of the sources) and the same fonts.  Pages
; the user typed into are not saved.
;

	include	"velox.i"
	include	"buildid.i"

	xdef	PfSave,PfLoad,PfBuild,PfApply,PfFonts
	xref	KeepCopy,Alloc,Free,BufReserve,BufFree,PageNew,PageFree
	xref	ArenaBlock,TaskPoll,DcPathOf,DcAdded,LogEvent,StrLen
	xref	AttrNames,AttrNamesEnd
	IFD	PROFILE
	xref	ProfLog,ProfRead
	ENDC

PF_MAGIC	equ	'VXP1'
PF_CHUNK	equ	16384		; bytes written between yields

	RSRESET				; the file: this, the key (pf_KeyLen),
pf_Magic	rs.l	1		; a KeepPage, the parts, the bitmap
pf_Build	rs.l	1		; BUILD_ID
pf_Fonts	rs.l	1		; PfFonts
pf_Hash		rs.l	1		; g_PageHash
pf_Width	rs.l	1		; laid out for (g_LayWidth)
pf_Arena	rs.l	1		; bytes of the parts: arena,
pf_Src		rs.l	1		; source,
pf_Runs		rs.l	1		; runs,
pf_Anch		rs.l	1		; anchors
pf_KeyLen	rs.l	1		; bytes of the key (with NUL, to 4)
PF_SIZEOF	rs.b	0

; the buffer PfBuild makes: the header, the key, a KeepPage, the parts,
; the bitmap; PB_ is where the key starts
PB_KEY		equ	PF_SIZEOF

	section	code,code

;--------------------------------------------------------------------
; PfFonts - a signature of the fonts: their heights, baselines and the
; widths of some text in each, plain and bold
; Out: d0 = it
;--------------------------------------------------------------------
PfFonts:
	movem.l	d2-d3,-(sp)
	moveq	#0,d2			; d2 = the signature
	moveq	#0,d3			; d3 = font | soft << 8
.l:	moveq	#7,d0
	and.l	d3,d0
	cmp.l	#FONT_SIZES,d0		; (size classes, mono or not)
	bhs.s	.n
	moveq	#15,d1
	and.l	d3,d1
	lea	g_FontH(a4),a0
	move.w	(a0,d1.l*2),d0
	rol.l	#5,d2
	add.w	d0,d2
	lea	g_FontBase(a4),a0
	move.w	(a0,d1.l*2),d0
	rol.l	#5,d2
	add.w	d0,d2
	move.l	d3,d0
	lea	Sample(pc),a0
	moveq	#SampleEnd-Sample,d1
	move.l	g_MeasureFn(a4),a1
	jsr	(a1)
	rol.l	#5,d2
	add.l	d0,d2
.n:	addq.l	#1,d3
	cmp.l	#FONT_COUNT,d3
	bne.s	.b
	move.l	#SOFT_BOLD<<8,d3	; then bold
.b:	cmp.l	#SOFT_BOLD<<8+FONT_COUNT,d3
	blo.s	.l
	move.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

Sample:	dc.b	"Velox Wim 0129 lil MW,."
SampleEnd:
	even

;--------------------------------------------------------------------
; PfSave - (the loader, after the page and its images) save the page
; shown to the disk cache, if it can be: it came over HTTP (a source
; hash), all of it, not typed into, not shown from its file already.
; Building and writing the file yield to the event loop (TaskPoll); if
; the page changes meanwhile, it is not saved.
;--------------------------------------------------------------------
PfSave:
	movem.l	d2-d5/a2,-(sp)
	tst.l	g_DcOn(a4)
	beq	.x
	tst.l	g_PageHash(a4)
	beq	.x
	tst.l	g_PageDone(a4)
	ble	.x
	tst.l	g_FormTouched(a4)
	bne	.x
	tst.l	g_PfFresh(a4)
	bne	.x
	lea	g_PageUrl(a4),a0	; its HTML in the cache too (not
	moveq	#0,d0			; no-store): else it is never used
	jsr	DcPathOf
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	moveq	#ACCESS_READ,d2
	DOS	Lock
	move.l	d0,d1
	beq	.x
	DOS	UnLock
	PROFB	17
	bsr	PfBuild			; d0 = buffer, d1 = its bytes
	PROFE	17
	IFD	PROFILE
	movem.l	d0-d1,-(sp)
	jsr	ProfLog
	movem.l	(sp)+,d0-d1
	tst.l	d0
	ENDC
	beq	.no
	move.l	d0,a2
	move.l	d1,d5
	lea	g_PageUrl(a4),a0	; the file
	moveq	#2,d0
	jsr	DcPathOf
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.free
	moveq	#0,d3			; d3 = written
.w:	move.l	d5,d0
	sub.l	d3,d0
	beq.s	.done
	cmp.l	#PF_CHUNK,d0
	bls.s	.wl
	move.l	#PF_CHUNK,d0
.wl:	move.l	d0,-(sp)		; (this chunk)
	move.l	d3,-(sp)
	move.l	d4,d1
	lea	(a2,d3.l),a0
	move.l	a0,d2
	move.l	d0,d3
	DOS	Write
	movem.l	(sp)+,d3
	movem.l	(sp)+,d1
	cmp.l	d1,d0
	bne.s	.fail			; (the disk is full)
	add.l	d1,d3
	jsr	TaskPoll		; the window first
	beq.s	.w
.fail:	move.l	d4,d1			; stopped or failed: no file
	DOS	Close
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	DOS	DeleteFile
	bra.s	.free
.done:	move.l	d4,d1
	DOS	Close
	move.l	d5,d0
	jsr	DcAdded
	lea	LogSaved(pc),a0		; (for tests)
	lea	g_PageUrl(a4),a1
	move.l	d5,d0
	jsr	LogEvent
.free:	move.l	a2,a1
	EXEC	FreeVec
	bra.s	.x
.no:	lea	LogNoSave(pc),a0	; (for tests: a pointer it could not
	lea	g_PageUrl(a4),a1	;  save)
	move.l	#$80000000,d0
	jsr	LogEvent
.x:	movem.l	(sp)+,d2-d5/a2
	rts

LogSaved:	dc.b	"pfsaved",0
LogNoSave:	dc.b	"pfnosave",0
LogLoaded:	dc.b	"pfloaded",0
	even

;--------------------------------------------------------------------
; PfLoad - the page of URL a0 from its page file, if there is one for
; source hash d0, this build and these fonts: it becomes the page shown
; (the old one is left: kept or freed), its images to be loaded
; (g_ImgCut); the caller shows it
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
PfLoad:
	movem.l	d2-d7/a2-a3,-(sp)
	PROFB	16
	move.l	a0,a3			; a3 = URL
	move.l	d0,d6			; d6 = hash
	suba.l	a2,a2			; a2 = the head (header, key, KeepPage)
	moveq	#0,d4			; d4 = the file
	moveq	#0,d7			; d7 = result
	tst.l	g_DcOn(a4)
	beq	.x
	moveq	#2,d0
	jsr	DcPathOf
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq	.x
	lea	-PF_SIZEOF(sp),sp	; the header: for this?
	move.l	d4,d1
	move.l	sp,d2
	moveq	#PF_SIZEOF,d3
	DOS	Read
	move.l	sp,a0
	moveq	#0,d5			; d5 = the head's bytes
	cmp.l	#PF_SIZEOF,d0
	bne.s	.hd
	cmp.l	#PF_MAGIC,pf_Magic(a0)
	bne.s	.hd
	cmp.l	#BUILD_ID,pf_Build(a0)
	bne.s	.hd
	cmp.l	pf_Hash(a0),d6
	bne.s	.hd
	cmp.l	#URL_MAX,pf_KeyLen(a0)
	bhi.s	.hd
	bsr	PfFonts
	move.l	sp,a0
	cmp.l	pf_Fonts(a0),d0
	bne.s	.hd
	move.l	#PF_SIZEOF+KP_SIZEOF,d5
	add.l	pf_KeyLen(a0),d5
	move.l	d5,d0
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,a2
	tst.l	d0
	beq.s	.hd
	move.l	sp,a0			; (the header first)
	move.l	a2,a1
	moveq	#PF_SIZEOF/4-1,d0
.hc:	move.l	(a0)+,(a1)+
	dbf	d0,.hc
.hd:	lea	PF_SIZEOF(sp),sp
	move.l	a2,d0
	beq.s	.x
	move.l	d4,d1			; the key and the KeepPage
	lea	PF_SIZEOF(a2),a0
	move.l	a0,d2
	move.l	d5,d3
	sub.l	#PF_SIZEOF,d3
	DOS	Read
	move.l	d5,d1
	sub.l	#PF_SIZEOF,d1
	cmp.l	d1,d0
	bne.s	.x
	lea	PB_KEY(a2),a0		; the key: this URL?
	move.l	a3,a1
.k:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.x
	tst.b	d0
	bne.s	.k
	move.l	d4,g_PfFH(a4)		; the parts from the file
	move.l	a2,a0
	bsr	PfApplyHead
	clr.l	g_PfFH(a4)
	move.l	d0,d7
	beq.s	.x
	moveq	#1,d0
	move.l	d0,g_PfFresh(a4)
	lea	LogLoaded(pc),a0	; (for tests)
	move.l	a3,a1
	move.l	a2,a0
	bsr	PfTotal
	add.l	d1,d0
	add.l	d5,d0
	lea	LogLoaded(pc),a0
	jsr	LogEvent
.x:	tst.l	d4
	beq.s	.nf
	move.l	d4,d1
	DOS	Close
.nf:	move.l	a2,d0
	beq.s	.nb
	move.l	d0,a1
	EXEC	FreeVec
.nb:	PROFE	16
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3
	rts

; PfTotal - In: a0 = header; Out: d0 = bytes of the parts, d1 = of the
; bitmap (a bit a long, in longs)
PfTotal:
	move.l	pf_Arena(a0),d0
	add.l	pf_Src(a0),d0
	add.l	pf_Runs(a0),d0
	add.l	pf_Anch(a0),d0
	move.l	d0,d1
	add.l	#127,d1			; longs / 8, to whole longs
	lsr.l	#7,d1
	lsl.l	#2,d1
	rts

;--------------------------------------------------------------------
; PfBuild - the page shown as a page file in memory (AllocVec)
; Out: d0 = the buffer or 0 (it cannot be saved, or no memory; CCR
;      set), d1 = its bytes
;--------------------------------------------------------------------
PfBuild:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	clr.l	g_PfFail(a4)
	moveq	#0,d7			; d7 = the buffer
	tst.l	g_Doc(a4)
	beq	.no
	; the parts: the arena's blocks, the source, the runs, the anchors
	clr.l	g_PfRegN(a4)
	moveq	#0,d2			; d2 = offset
	move.l	g_PagePool(a4),d0
.ab:	beq.s	.abd
	move.l	d0,a2
	lea	AB_SIZEOF(a2),a0
	move.l	ab_Used(a2),d0
	bsr	PfRegion
	move.l	ab_Next(a2),d0
	bra.s	.ab
.abd:	move.l	d2,d5			; d5 = arena bytes
	move.l	g_PageSrc+buf_Data(a4),a0
	move.l	g_PageSrc+buf_Len(a4),d0
	addq.l	#4,d0			; (its NUL, to whole longs: within
	moveq	#-4,d1			;  buf_Cap, a multiple of 256)
	and.l	d1,d0
	move.l	a0,d1
	bne.s	.src
	moveq	#0,d0
.src:	move.l	d0,d6			; d6 = source bytes
	bsr	PfRegion
	move.l	g_Runs+buf_Data(a4),a0
	move.l	g_Runs+buf_Len(a4),d0
	move.l	d0,d3			; d3 = runs bytes
	bsr	PfRegion
	move.l	g_Anchors+buf_Data(a4),a0
	move.l	g_Anchors+buf_Len(a4),d0
	move.l	d0,d4			; d4 = anchor bytes
	bsr	PfRegion
	tst.l	g_PfFail(a4)
	bne	.no
	move.l	d2,g_PfSize(a4)
	; the buffer: header, key, KeepPage, parts, bitmap
	lea	g_PageUrl(a4),a0
	jsr	StrLen
	addq.l	#4,d0
	moveq	#-4,d1
	and.l	d1,d0
	move.l	d0,a3			; a3 = key bytes
	lea	-PF_SIZEOF(sp),sp
	move.l	sp,a0
	move.l	#PF_MAGIC,pf_Magic(a0)
	move.l	#BUILD_ID,pf_Build(a0)
	move.l	g_PageHash(a4),pf_Hash(a0)
	move.l	g_LayWidth(a4),pf_Width(a0)
	move.l	d5,pf_Arena(a0)
	move.l	d6,pf_Src(a0)
	move.l	d3,pf_Runs(a0)
	move.l	d4,pf_Anch(a0)
	move.l	a3,pf_KeyLen(a0)
	bsr	PfFonts
	move.l	sp,a0
	move.l	d0,pf_Fonts(a0)
	bsr	PfTotal
	move.l	d1,d3			; d3 = bitmap bytes
	moveq	#PF_SIZEOF,d2
	add.l	a3,d2
	add.l	#KP_SIZEOF,d2		; d2 = where the parts go
	move.l	d2,d4
	add.l	d0,d4
	add.l	d3,d4			; d4 = all
	move.l	d4,d0
	moveq	#MEMF_ANY,d1		; (cleared below: the key, the bitmap)
	EXEC	AllocVec
	move.l	d0,d7
	beq.s	.nomem
	move.l	d7,a0
	lea	PF_SIZEOF(a0,a3.l),a1
.ck:	clr.l	(a0)+
	cmp.l	a1,a0
	blo.s	.ck
	move.l	d7,a0
	add.l	d4,a0
	sub.l	d3,a0
	move.l	d3,d0
	lsr.l	#2,d0
	bra.s	.cbe
.cb:	clr.l	(a0)+
.cbe:	dbf	d0,.cb
	move.l	sp,a0
	move.l	d7,a1
	moveq	#PF_SIZEOF/4-1,d0
.hc:	move.l	(a0)+,(a1)+
	dbf	d0,.hc
	lea	g_PageUrl(a4),a0	; the key
.kc:	move.b	(a0)+,(a1)+
	bne.s	.kc
.nomem:	lea	PF_SIZEOF(sp),sp
	tst.l	d7
	beq	.no
	move.l	d7,a5
	lea	(a5,d2.l),a0
	move.l	a0,g_PfData(a4)
	add.l	g_PfSize(a4),a0
	move.l	a0,g_PfBits(a4)
	; the parts copied, the window served in between (PfPoll)
	move.l	g_LayGen(a4),g_PfGen(a4)
	lea	g_PfReg(a4),a2
	move.l	g_PfRegN(a4),d5
	bra.s	.ce
.cp:	move.l	(a2)+,a0		; start, end, offset
	move.l	(a2)+,d6
	sub.l	a0,d6			; d6 = bytes
	move.l	g_PfData(a4),a1
	add.l	(a2)+,a1
.cc:	move.l	#PF_CHUNK,d0
	cmp.l	d6,d0
	bls.s	.cn
	move.l	d6,d0
.cn:	sub.l	d0,d6
	movem.l	d0/a0-a1,-(sp)
	EXEC	CopyMem
	movem.l	(sp)+,d0/a0-a1
	add.l	d0,a0
	add.l	d0,a1
	movem.l	a0-a1,-(sp)
	bsr	PfPoll
	movem.l	(sp)+,a0-a1
	bne	.no
	tst.l	d6
	bne.s	.cc
.ce:	dbf	d5,.cp
	; the names of attributes (not saved: the build's own)
	move.l	g_PfSize(a4),d2
	bsr	PfStatic
	lea	g_PfReg(a4),a0		; (PfWhere: the parts found last)
	move.l	a0,g_PfHit(a4)
	move.l	a0,g_PfHit2(a4)
	; the pointers in them
	bsr	PfWalk
	; the globals
	lea	PB_KEY(a5,a3.l),a0
	moveq	#0,d0
	jsr	KeepCopy
	lea	PB_KEY(a5,a3.l),a0
	bsr	PfGlobals
	tst.l	g_PfFail(a4)
	bne.s	.no
	move.l	d7,d0
	move.l	d4,d1
	bra.s	.x
.no:	move.l	d7,d0
	beq.s	.n0
	move.l	d0,a1
	EXEC	FreeVec
.n0:	moveq	#0,d0
	moveq	#0,d1
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	tst.l	d0
	rts

; PfPoll - (PfBuild) the window first (TaskPoll); the save fails if
; the loader is stopped, or the page changed meanwhile (laid out again,
; typed into)
; Out: d0 <> 0 if so (g_PfFail set; CCR set)
PfPoll:
	jsr	TaskPoll
	bne.s	.fail
	move.l	g_LayGen(a4),d0
	cmp.l	g_PfGen(a4),d0
	bne.s	.fail
	move.l	g_FormTouched(a4),d0
	bne.s	.fail
	move.l	g_PfFail(a4),d0
	rts
.fail:	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
	rts

; PfStatic - the parts in Velox itself, at offset d2 on
PfStatic:
	lea	AttrNames,a0
	lea	AttrNamesEnd,a1
	move.l	a1,d0
	sub.l	a0,d0
	; (fall through)

; PfRegion - a part: a0 = start, d0 = bytes, at offset d2 (d2 goes on)
PfRegion:
	move.l	g_PfRegN(a4),d1
	cmp.l	#PF_REGMAX,d1
	bhs.s	.full
	addq.l	#1,g_PfRegN(a4)
	mulu.l	#12,d1
	lea	g_PfReg(a4),a1
	add.l	d1,a1
	move.l	a0,(a1)+
	add.l	d0,a0
	move.l	a0,(a1)+
	move.l	d2,(a1)
	add.l	d0,d2
	rts
.full:	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
	rts

;--------------------------------------------------------------------
; PfWhere - the offset of address d0 in the parts; the two parts found
; last are tried first (a field and what it points to)
; Out: d0 = the offset, -1 if it is in none (CCR set)
;--------------------------------------------------------------------
PfWhere:
	move.l	g_PfHit(a4),a1
	cmp.l	(a1),d0
	blo.s	.h2
	cmp.l	4(a1),d0
	blo.s	.hit
.h2:	move.l	g_PfHit2(a4),a1
	cmp.l	(a1),d0
	blo.s	.scan
	cmp.l	4(a1),d0
	bhs.s	.scan
	move.l	g_PfHit(a4),g_PfHit2(a4)
	move.l	a1,g_PfHit(a4)
.hit:	sub.l	(a1),d0
	add.l	8(a1),d0
	rts
.scan:	movem.l	d2,-(sp)
	lea	g_PfReg(a4),a1
	move.l	g_PfRegN(a4),d2
	bra.s	.e
.l:	cmp.l	(a1),d0
	blo.s	.n
	cmp.l	4(a1),d0
	bhs.s	.n
	move.l	g_PfHit(a4),g_PfHit2(a4)
	move.l	a1,g_PfHit(a4)
	movem.l	(sp)+,d2
	bra.s	.hit
.n:	lea	12(a1),a1
.e:	dbf	d2,.l
	movem.l	(sp)+,d2
	moveq	#-1,d0
	rts

;--------------------------------------------------------------------
; PfFix - pointer field a0 (in the page): in the copy, the offset of what
; it points to, marked; a pointer out of the page fails the save
; (a0 kept)
;--------------------------------------------------------------------
PfFix:
	move.l	(a0),d0
	beq.s	.x
	bsr.s	PfWhere			; what it points to
	bmi.s	.bad
	move.l	d0,-(sp)
	move.l	a0,d0			; where it is
	bsr.s	PfWhere
	movem.l	(sp)+,d1
	tst.l	d0
	bmi.s	.bad
	btst	#0,d0			; (a long in a whole long)
	bne.s	.bad
	btst	#1,d0
	bne.s	.bad
	move.l	g_PfData(a4),a1
	move.l	d1,(a1,d0.l)
	lsr.l	#2,d0
	move.l	g_PfBits(a4),a1
	bfset	(a1){d0:1}
.x:	rts
.bad:	move.l	a0,g_PfFail(a4)		; (the field: tests)
	rts

;--------------------------------------------------------------------
; PfSet - field a0 (in the page) is d1 in the copy, not a pointer
; (a0 kept)
;--------------------------------------------------------------------
PfSet:
	move.l	d1,-(sp)
	move.l	a0,d0
	bsr.s	PfWhere
	movem.l	(sp)+,d1
	tst.l	d0
	bmi.s	.bad
	move.l	g_PfData(a4),a1
	move.l	d1,(a1,d0.l)
	rts
.bad:	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
	rts

; PfZap - field a0 is 0 in the copy (a0 kept)
PfZap:
	moveq	#0,d1
	bra.s	PfSet

; FIX - PfFix of field \1 of the structure at \2
FIX	MACRO
	lea	\1(\2),a0
	bsr	PfFix
	ENDM

;--------------------------------------------------------------------
; PfWalk - every pointer of the page: the DOM (nodes, attributes, form
; state, styles), the CSS rules, the images' records, runs, anchors
;--------------------------------------------------------------------
PfWalk:
	movem.l	d2-d3/a2-a3,-(sp)
	moveq	#0,d3			; d3 = steps (PfPoll now and then)
	move.l	g_Doc(a4),d0		; the DOM, in document order
	beq.s	.css
.node:	move.l	d0,a2
	bsr	PfNode
	addq.b	#1,d3
	bne.s	.np
	bsr	PfPoll
	bne	.x
.np:	move.l	n_First(a2),d0
	bne.s	.node
.up:	move.l	n_Next(a2),d0
	bne.s	.node
	move.l	n_Parent(a2),d0
	beq.s	.css
	move.l	d0,a2
	bra.s	.up
.css:	move.l	g_CssIdTab(a4),d0	; the rules, bucket by bucket
	beq.s	.img
	move.l	d0,a2
	move.l	#CSS_IDBUCKETS+CSS_CLBUCKETS+TAG_COUNT+1-1,d2
.b:	move.l	a2,a0
	bsr	PfFix
	move.l	(a2)+,d0
	bsr	PfRules
	dbf	d2,.b
.img:	bsr	PfPoll
	bne	.x
	move.l	g_ImgQueue(a4),d0	; <img>s to load
	beq.s	.bg
	move.l	d0,a2
	move.l	g_ImgCount(a4),d2
	bra.s	.qe
.q:	move.l	a2,a0
	bsr	PfFix
	addq.l	#4,a2
.qe:	dbf	d2,.q
.bg:	move.l	g_BgList(a4),d0		; background images: loaded again
.bl:	beq.s	.runs
	move.l	d0,a2
	FIX	bg_Next,a2
	tst.l	bg_Info(a2)
	beq.s	.bn
	lea	bg_Info(a2),a0
	bsr	PfZap
	lea	bg_State(a2),a0		; (ImagesAgain)
	moveq	#2,d1
	bsr	PfSet
.bn:	move.l	bg_Next(a2),d0
	bra.s	.bl
.runs:	bsr	PfPoll
	bne	.x
	move.l	g_Runs+buf_Data(a4),a2
	move.l	g_Runs+buf_Len(a4),d2
	lsr.l	#5,d2			; (RUN_SIZEOF = 32)
	bra.s	.re
.r:	FIX	ru_Text,a2
	FIX	ru_Link,a2
	lea	RUN_SIZEOF(a2),a2
	addq.b	#1,d3
	bne.s	.re
	bsr	PfPoll
	bne	.x
.re:	dbf	d2,.r
	move.l	g_Anchors+buf_Data(a4),a2	; anchors: name, y
	move.l	g_Anchors+buf_Len(a4),d2
	lsr.l	#3,d2
	bra.s	.ae
.a:	move.l	a2,a0
	bsr	PfFix
	addq.l	#8,a2
.ae:	dbf	d2,.a
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

	IFNE	RUN_SIZEOF-32
	FAIL	"PfWalk: RUN_SIZEOF changed"
	ENDC

; PfNode - the pointers of node a2: links, text or attributes, its
; style kept, form state; images and CSS matches are not saved
PfNode:
	movem.l	a3,-(sp)
	FIX	n_Parent,a2
	FIX	n_First,a2
	FIX	n_Last,a2
	FIX	n_Next,a2
	FIX	n_Data,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne	.x
	lea	n_Css(a2),a0
	bsr	PfZap
	FIX	n_Style,a2
	move.l	n_Style(a2),d0
	beq.s	.ns
	move.l	d0,a3
	FIX	SK_PARENT+st_Link,a3
	FIX	SK_PARENT+st_BgImg,a3
	FIX	SK_STYLE+st_Link,a3
	FIX	SK_STYLE+st_BgImg,a3
.ns:	move.l	n_Data2(a2),d0		; aux: an image (not saved) or form
	beq.s	.at			; state
	lea	n_Data2(a2),a0
	cmp.w	#TAG_IMG,n_Tag(a2)
	bne.s	.fs
	bsr	PfZap
	bra.s	.at
.fs:	bsr	PfFix
	move.l	n_Data2(a2),a3
	FIX	fs_Value,a3
	FIX	fs_Label,a3
.at:	move.l	n_Data(a2),d0		; attributes
.al:	beq.s	.x
	move.l	d0,a3
	FIX	at_Next,a3
	FIX	at_Name,a3
	FIX	at_Value,a3
	move.l	at_Next(a3),d0
	bra.s	.al
.x:	movem.l	(sp)+,a3
	rts

; PfRules - the rules from d0 on (cs_Next), their selectors
PfRules:
	movem.l	a3,-(sp)
.l:	tst.l	d0
	beq.s	.x
	move.l	d0,a3
	FIX	cs_Next,a3
	FIX	cs_Sel,a3
	FIX	cs_Decls,a3
	FIX	cs_Base,a3
	move.l	cs_Sel(a3),d0
	bsr.s	PfComp
	move.l	cs_Next(a3),d0
	bra.s	.l
.x:	movem.l	(sp)+,a3
	rts

; PfComp - compound selector d0, those to its left, its :not() and
; :is() lists and its alternatives
PfComp:
	movem.l	a2-a3,-(sp)
.l:	tst.l	d0
	beq.s	.x
	move.l	d0,a2
	FIX	cm_Prev,a2
	FIX	cm_Id,a2
	FIX	cm_Classes,a2
	FIX	cm_Attrs,a2
	FIX	cm_Not,a2
	FIX	cm_Is,a2
	FIX	cm_Alt,a2
	move.l	cm_Attrs(a2),d0
.a:	beq.s	.ad
	move.l	d0,a3
	FIX	as_Next,a3
	FIX	as_Name,a3
	FIX	as_Value,a3
	move.l	as_Next(a3),d0
	bra.s	.a
.ad:	move.l	cm_Not(a2),d0
	bsr.s	PfComp
	move.l	cm_Is(a2),d0
	bsr.s	PfComp
	move.l	cm_Alt(a2),d0
	bsr.s	PfComp
	move.l	cm_Prev(a2),d0
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; PfGlobals - the KeepPage at a0 (a copy of the page's globals) made
; portable: pointers into the page become offsets + 1 (0: none); its
; memory, buffers and images are not in it; its images are to load
;--------------------------------------------------------------------
PfGlobals:
	movem.l	a2,-(sp)
	move.l	a0,a2
	lea	KpPtrs(pc),a1
.p:	move.w	(a1)+,d0		; the pointers
	bmi.s	.pd
	lea	(a2,d0.w),a0
	move.l	(a0),d0
	beq.s	.p
	move.l	a1,-(sp)
	move.l	a0,-(sp)
	bsr	PfWhere
	movem.l	(sp)+,a0/a1
	bmi.s	.bad
	addq.l	#1,d0
	move.l	d0,(a0)
	bra.s	.p
.bad:	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
	bra.s	.p
.pd:	lea	KpZero(pc),a1		; what is made anew
.z:	move.w	(a1)+,d0
	bmi.s	.zd
	clr.l	(a2,d0.w)
	bra.s	.z
.zd:	clr.l	kp_Img+8(a2)		; (g_ImgNext)
	moveq	#1,d0
	move.l	d0,kp_Done(a2)		; complete,
	moveq	#-1,d0
	move.l	d0,kp_Done+4(a2)	; in no entry yet,
	moveq	#1,d0
	move.l	d0,kp_Done+8(a2)	; images to load
	moveq	#-1,d0
	move.l	d0,kp_Focus+4(a2)	; no focus
	movem.l	(sp)+,a2
	rts

; the KeepPage's pointers into the page
KpPtrs:	dc.w	kp_Pool+16,kp_Pool+20,kp_Pool+24	; g_Doc, g_Title, g_BaseHref
	dc.w	kp_Css,kp_Css+4,kp_Css+8,kp_Css+12	; the CSS tables
	dc.w	kp_Img				; g_ImgQueue
	dc.w	kp_Bg,kp_Bg+8			; g_PageBgRec, g_BgList
	dc.w	-1
; what PfApply makes anew or leaves out
KpZero:	dc.w	kp_Pool,kp_Pool+4,kp_Pool+12	; pool, source data and cap
	dc.w	kp_Runs,kp_Runs+8,kp_Runs+12,kp_Runs+20	; runs, anchors
	dc.w	kp_Img+12,kp_Img+16,kp_Img+20	; loaded, relayout, list
	dc.w	kp_Focus,kp_Edit,kp_Done+16	; focus, editing, g_PfFresh
	dc.w	-1

	IFNE	BUF_SIZEOF-12
	FAIL	"KpZero: BUF_SIZEOF changed"
	ENDC

;--------------------------------------------------------------------
; PfApply - make page file a0 (all of it in memory) the page shown, as
; PfApplyHead
; Out: d0 = 1, or 0 (CCR set)
;--------------------------------------------------------------------
PfApply:
	clr.l	g_PfFH(a4)
	move.l	pf_KeyLen(a0),d0
	lea	PB_KEY+KP_SIZEOF(a0,d0.l),a1
	move.l	a1,g_PfPtr(a4)
	; (fall through)

;--------------------------------------------------------------------
; PfApplyHead - make the page file whose head (header, key, KeepPage)
; is at a0 the page shown, its parts and bitmap read with PfRead (from
; g_PfFH or g_PfPtr): the old page is left (kept or freed); the parts
; go into new memory, the marked longs become addresses again
; Out: d0 = 1, or 0 if out of memory or the file is wrong (no page then;
;      CCR set)
;--------------------------------------------------------------------
PfApplyHead:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a5			; a5 = the head
	suba.l	a2,a2			; a2 = the bitmap
	move.l	pf_KeyLen(a5),d0
	lea	PB_KEY(a5,d0.l),a3	; a3 = the KeepPage
	move.l	kp_Pool+8(a3),d0	; (the lengths of the buffers: in
	cmp.l	pf_Src(a5),d0		;  their parts)
	bhs	.no
	move.l	kp_Runs+4(a3),d0
	cmp.l	pf_Runs(a5),d0
	bhi	.no
	move.l	kp_Runs+16(a3),d0
	cmp.l	pf_Anch(a5),d0
	bhi	.no
	jsr	PageNew
	beq	.no
	moveq	#0,d7			; d7 = arena data
	move.l	pf_Arena(a5),d0		; the arena: one block
	beq.s	.ar
	jsr	ArenaBlock
	beq	.fail
	move.l	d0,a0
	move.l	pf_Arena(a5),ab_Used(a0)
	move.l	g_PagePool(a4),a1	; (after the block being used)
	move.l	ab_Next(a1),ab_Next(a0)
	move.l	a0,ab_Next(a1)
	lea	AB_SIZEOF(a0),a0
	move.l	a0,d7
	move.l	pf_Arena(a5),d0
	bsr	PfRead
	beq	.fail
.ar:	lea	g_PageSrc(a4),a0	; the source, runs, anchors
	move.l	pf_Src(a5),d3
	bsr	.buf
	beq	.fail
	lea	g_Runs(a4),a0
	move.l	pf_Runs(a5),d3
	bsr	.buf
	beq	.fail
	lea	g_Anchors(a4),a0
	move.l	pf_Anch(a5),d3
	bsr	.buf
	beq	.fail
	move.l	a5,a0			; the bitmap
	bsr	PfTotal
	move.l	d0,d5			; d5 = the parts' bytes
	move.l	d1,d4			; d4 = the bitmap's
	move.l	d4,d0
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,a2
	tst.l	d0
	beq	.fail
	move.l	a2,a0
	move.l	d4,d0
	bsr	PfRead
	beq	.fail
	; the regions, for the offsets
	clr.l	g_PfRegN(a4)
	moveq	#0,d2
	move.l	d7,a0
	move.l	pf_Arena(a5),d0
	bsr	PfRegion
	move.l	g_PageSrc+buf_Data(a4),a0
	move.l	pf_Src(a5),d0
	bsr	PfRegion
	move.l	g_Runs+buf_Data(a4),a0
	move.l	pf_Runs(a5),d0
	bsr	PfRegion
	move.l	g_Anchors+buf_Data(a4),a0
	move.l	pf_Anch(a5),d0
	bsr	PfRegion
	bsr	PfStatic
	move.l	d2,d6			; d6 = all the parts' bytes
	; the marked longs, a bitmap long (32 longs) at a time
	lsr.l	#2,d4			; d4 = bitmap longs
	moveq	#0,d2			; d2 = which
	bra.s	.be
.bl:	move.l	(a2,d2.l*4),d3		; d3 = its bits
	beq.s	.bn
.bit:	bfffo	d3{0:32},d1		; the next one
	bfclr	d3{d1:1}
	move.l	d2,d0			; its offset: (which * 32 + bit) * 4
	lsl.l	#5,d0
	add.l	d1,d0
	lsl.l	#2,d0
	cmp.l	d5,d0
	bhs	.fail			; (a wrong file)
	bsr	PfAddr
	move.l	d0,a0
	move.l	(a0),d0
	cmp.l	d6,d0
	bhs	.fail
	bsr	PfAddr
	move.l	d0,(a0)
	tst.l	d3
	bne.s	.bit
.bn:	addq.l	#1,d2
.be:	cmp.l	d4,d2
	blo.s	.bl
	; the globals
	lea	KpPtrs(pc),a1
.gp:	move.w	(a1)+,d1
	bmi.s	.gd
	move.l	(a3,d1.w),d0
	beq.s	.gp
	subq.l	#1,d0
	cmp.l	d6,d0
	bhs.s	.fail
	bsr	PfAddr
	move.l	d0,(a3,d1.w)
	bra.s	.gp
.gd:	move.l	g_PagePool(a4),kp_Pool(a3)	; the memory there now (the
	move.l	g_PageSrc+buf_Data(a4),kp_Pool+4(a3)	; lengths: the file's)
	move.l	g_PageSrc+buf_Cap(a4),kp_Pool+12(a3)
	move.l	g_Runs+buf_Data(a4),kp_Runs(a3)
	move.l	g_Runs+buf_Cap(a4),kp_Runs+8(a3)
	move.l	g_Anchors+buf_Data(a4),kp_Runs+12(a3)
	move.l	g_Anchors+buf_Cap(a4),kp_Runs+20(a3)
	move.l	a3,a0
	moveq	#1,d0
	jsr	KeepCopy
	moveq	#1,d7
	bra.s	.x
.fail:	jsr	PageFree		; (nothing of it)
.no:	moveq	#0,d7
.x:	move.l	a2,d0
	beq.s	.nb
	move.l	d0,a1
	EXEC	FreeVec
.nb:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts
; .buf - Buf a0 gets d3 bytes read (PfRead); its length: the
; KeepPage's; Out: d0 = 0 if out of memory or not read
.buf:	move.l	a0,-(sp)
	jsr	BufFree
	move.l	(sp),a0
	move.l	d3,d0
	jsr	BufReserve
	movem.l	(sp)+,a1
	beq.s	.bx
	move.l	buf_Data(a1),a0
	move.l	d3,d0
	bsr	PfRead
.bx:	rts

; PfRead - read d0 bytes of the parts to a0: from file g_PfFH, or
; from memory at g_PfPtr
; Out: d0 = 0 if they are not all there (CCR set)
PfRead:
	movem.l	d2-d3,-(sp)
	move.l	d0,d3
	beq.s	.ok
	move.l	g_PfFH(a4),d1
	beq.s	.mem
	move.l	a0,d2
	DOS	Read
	cmp.l	d3,d0
	bne.s	.no
.ok:	moveq	#1,d0
	bra.s	.x
.mem:	move.l	a0,a1
	move.l	g_PfPtr(a4),a0
	add.l	d3,g_PfPtr(a4)
	move.l	d3,d0
	EXEC	CopyMem
	bra.s	.ok
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3
	rts

; PfAddr - offset d0 of the parts back to an address (g_PfReg as
; PfApply set it); Out: d0 (d1/a0/a1 kept)
PfAddr:
	movem.l	d1/a0-a1,-(sp)
	lea	g_PfReg(a4),a1
.l:	move.l	4(a1),d1		; (end - start: the region's bytes)
	sub.l	(a1),d1
	add.l	8(a1),d1
	cmp.l	d1,d0
	blo.s	.in
	lea	12(a1),a1
	bra.s	.l
.in:	sub.l	8(a1),d0
	add.l	(a1),d0
	movem.l	(sp)+,d1/a0-a1
	rts
