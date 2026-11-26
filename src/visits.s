;
; visits.s - the pages visited, for completing what is typed in the
; address field (gui.s: the list under it)
;
; A list of addresses (http and https ones, without a #fragment), the
; one visited last first, VISIT_MAX at most, kept in
; ENVARC:Velox/Visited between runs (a line each: visits, address).
; VisitMatch finds those for a text typed: the ones that begin with it
; first (http://, https:// and www. left out, case ignored), then those
; that have it anywhere; it stops when the user goes on typing.
;

	include	"velox.i"

	xdef	VisitAdd,VisitMatch,VisitsLoad,VisitsSave
	xref	Alloc,Free,StrLen,StrIPrefix,ParseDec,FmtDec,ToLower

VISIT_MAX	equ	500
	RSRESET
vs_Next		rs.l	1
vs_Count	rs.l	1		; visits
vs_Url		rs.b	0		; the address, NUL terminated
VS_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; VisitAdd - page a0 was visited: first in the list (counted)
;--------------------------------------------------------------------
VisitAdd:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	lea	SHttp(pc),a1		; http and https only
	jsr	StrIPrefix
	bne.s	.ok
	move.l	a2,a0
	lea	SHttps(pc),a1
	jsr	StrIPrefix
	beq	.x
.ok:	move.l	a2,a0			; d2 = its length, to a # or the
	moveq	#0,d2			; frames' addresses
.len:	move.b	(a0)+,d0
	beq.s	.le
	cmp.b	#'#',d0
	beq.s	.le
	cmp.b	#1,d0			; (frames.s FR_SEP)
	beq.s	.le
	addq.l	#1,d2
	bra.s	.len
.le:	suba.l	a3,a3			; a3 = the one before, d3 = this one
	move.l	g_Visits(a4),d3		; (there already?)
.f:	tst.l	d3
	beq.s	.new
	move.l	d3,a0
	lea	vs_Url(a0),a0
	move.l	a2,a1
	move.l	d2,d1
.c:	subq.l	#1,d1
	bmi.s	.end
	cmpm.b	(a0)+,(a1)+
	beq.s	.c
	bra.s	.nx
.end:	tst.b	(a0)
	beq.s	.found
.nx:	move.l	d3,a3
	move.l	d3,a0
	move.l	vs_Next(a0),d3
	bra.s	.f
.found:	move.l	d3,a0			; counted, to the front
	addq.l	#1,vs_Count(a0)
	move.l	a3,d0
	beq.s	.dirty			; (first already)
	move.l	vs_Next(a0),vs_Next(a3)
	bra.s	.head
.new:	move.l	d2,d0			; a new one
	add.l	#VS_SIZEOF+1,d0
	jsr	Alloc
	beq.s	.x
	move.l	d0,a0
	moveq	#1,d0
	move.l	d0,vs_Count(a0)
	lea	vs_Url(a0),a1
	move.l	a2,a3
	move.l	d2,d1
	bra.s	.ce
.cp:	move.b	(a3)+,(a1)+
.ce:	subq.l	#1,d1
	bpl.s	.cp
	clr.b	(a1)
	addq.l	#1,g_VisitN(a4)
.head:	move.l	g_Visits(a4),vs_Next(a0)
	move.l	a0,g_Visits(a4)
	cmp.l	#VISIT_MAX,g_VisitN(a4)	; too many: the oldest goes
	bls.s	.dirty
	bsr.s	DropLast
.dirty:	moveq	#1,d0
	move.l	d0,g_VisitsDirty(a4)
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

SHttp:	dc.b	"http://",0
SHttps:	dc.b	"https://",0
SWww:	dc.b	"www.",0
	even

; DropLast - the last (oldest) visit out of the list
DropLast:
	move.l	g_Visits(a4),d0
	beq.s	.x
	move.l	d0,a0
	tst.l	vs_Next(a0)
	bne.s	.l
	clr.l	g_Visits(a4)		; (the only one)
	bra.s	.free
.l:	move.l	vs_Next(a0),a1		; a0 = the one before the last
	tst.l	vs_Next(a1)
	beq.s	.last
	move.l	a1,a0
	bra.s	.l
.last:	clr.l	vs_Next(a0)
	move.l	a1,a0
.free:	subq.l	#1,g_VisitN(a4)
	move.l	a0,a1
	jmp	Free
.x:	rts

; Bare - a0 = an address without its http://, https:// and www.
; Out: a0 (d2, a2 kept)
Bare:
	move.l	a0,-(sp)
	lea	SHttp(pc),a1
	jsr	StrIPrefix
	bne.s	.w
	move.l	(sp),a0
	lea	SHttps(pc),a1
	jsr	StrIPrefix
	bne.s	.w
	move.l	(sp),a0
.w:	move.l	a0,(sp)
	lea	SWww(pc),a1
	jsr	StrIPrefix
	bne.s	.x
	move.l	(sp),a0
.x:	addq.l	#4,sp
	rts

;--------------------------------------------------------------------
; VisitMatch - the visits for text a0: those that begin with it, then
; those that have it, the latest first; it stops if a window message
; or signal d1 comes (the user goes on typing)
; In:  a1 = room for d0 pointers (to the addresses)
; Out: d0 = how many found, -1 if it stopped (CCR set)
;--------------------------------------------------------------------
VisitMatch:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a1,a5			; a5 = the room,
	move.l	d0,d6			; d6 = for how many
	move.l	d1,d7			; d7 = the signals that stop it
	or.l	g_WinSigMask(a4),d7
	bsr	Bare
	move.l	a0,a3			; a3 = the text, bare
	moveq	#0,d5			; d5 = found
	tst.b	(a3)
	beq	.done
	moveq	#0,d4			; d4 = the pass: 0 begins with, 1 has
.pass:	moveq	#0,d3			; d3 = visits looked at
	move.l	g_Visits(a4),a2
.v:	move.l	a2,d0
	beq	.np
	cmp.l	d6,d5
	bhs	.done
	addq.l	#1,d3			; now and then: the user typing?
	moveq	#31,d0
	and.l	d3,d0
	bne.s	.look
	moveq	#0,d0
	moveq	#0,d1
	EXEC	SetSignal
	and.l	d7,d0
	bne	.stop
.look:	lea	vs_Url(a2),a0
	bsr	Bare
	tst.l	d4
	bne.s	.any
	bsr	Begins			; pass 0: begins with it
	bne.s	.add
	bra.s	.nv
.any:	move.l	a0,-(sp)		; pass 1: has it, not at the start
	bsr	Begins
	movem.l	(sp)+,a0
	bne.s	.nv
.sub:	addq.l	#1,a0
	tst.b	(a0)
	beq.s	.nv
	bsr	Begins
	beq.s	.sub
.add:	lea	vs_Url(a2),a0
	move.l	a0,(a5,d5.l*4)
	addq.l	#1,d5
.nv:	move.l	vs_Next(a2),a2
	bra	.v
.np:	addq.l	#1,d4
	cmp.l	#2,d4
	blo	.pass
.done:	move.l	d5,d0
	bra.s	.x
.stop:	moveq	#-1,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	tst.l	d0
	rts

; Begins - (VisitMatch, a3 = the text) does a0 begin with it (case
; ignored)?  Out: d0 = 1 if so (CCR set; a0 kept)
Begins:
	movem.l	d2/a0-a1,-(sp)
	move.l	a3,a1
.l:	move.b	(a1)+,d0
	beq.s	.y
	jsr	ToLower
	move.b	d0,d2
	move.b	(a0)+,d0
	beq.s	.n
	jsr	ToLower
	cmp.b	d0,d2
	beq.s	.l
.n:	moveq	#0,d0
	bra.s	.x
.y:	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a0-a1
	tst.l	d0
	rts

;--------------------------------------------------------------------
; VisitsSave - write the visits (if they changed)
;--------------------------------------------------------------------
VisitsSave:
	movem.l	d2-d4/a2,-(sp)
	tst.l	g_VisitsDirty(a4)
	beq.s	.x
	lea	VsDir(pc),a0		; ENVARC:Velox may not exist yet
	move.l	a0,d1
	DOS	CreateDir
	move.l	d0,d1
	beq.s	.nodir
	DOS	UnLock
.nodir:	lea	VsFile(pc),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.x
	move.l	g_Visits(a4),a2
.l:	move.l	a2,d0
	beq.s	.done
	lea	-16(sp),sp		; visits, a blank, the address
	move.l	sp,a0
	move.l	vs_Count(a2),d0
	jsr	FmtDec
	move.b	#' ',(a0)+
	clr.b	(a0)
	move.l	sp,d2
	move.l	d4,d1
	DOS	FPuts
	lea	16(sp),sp
	lea	vs_Url(a2),a0
	move.l	a0,d2
	move.l	d4,d1
	DOS	FPuts
	moveq	#10,d2
	move.l	d4,d1
	DOS	FPutC
	move.l	vs_Next(a2),a2
	bra.s	.l
.done:	move.l	d4,d1
	DOS	Close
	clr.l	g_VisitsDirty(a4)
.x:	movem.l	(sp)+,d2-d4/a2
	rts

;--------------------------------------------------------------------
; VisitsLoad - read the visits of earlier runs
;--------------------------------------------------------------------
VisitsLoad:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	lea	VsFile(pc),a0
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d7
	beq	.x
	move.l	#VS_MAXFILE,d0
	jsr	Alloc
	move.l	d0,a5
	tst.l	d0
	beq	.close
	move.l	d7,d1
	move.l	a5,d2
	move.l	#VS_MAXFILE-1,d3
	DOS	Read
	tst.l	d0
	bpl.s	.rd
	moveq	#0,d0
.rd:	clr.b	(a5,d0.l)
	move.l	d7,d1
	DOS	Close
	suba.l	a2,a2			; a2 = the last one so far
	move.l	a5,a3			; a3 = the next line
.line:	tst.b	(a3)
	beq.s	.free
	cmp.l	#VISIT_MAX,g_VisitN(a4)
	bhs.s	.free
	move.l	a3,a0			; visits
	jsr	ParseDec
	move.l	d0,d6
	cmp.b	#' ',(a0)+
	bne.s	.skip
	move.l	a0,d5			; d5 = the address, d2 its length
	moveq	#0,d2
.ln:	move.b	(a0)+,d0
	beq.s	.lz
	cmp.b	#10,d0
	beq.s	.lz
	addq.l	#1,d2
	bra.s	.ln
.lz:	tst.l	d2
	beq.s	.skip
	move.l	d2,d0
	add.l	#VS_SIZEOF+1,d0
	jsr	Alloc
	beq.s	.free
	move.l	d0,a0
	move.l	d6,vs_Count(a0)
	lea	vs_Url(a0),a1
	move.l	d5,a3
	move.l	d2,d1
	bra.s	.ce
.cp:	move.b	(a3)+,(a1)+
.ce:	subq.l	#1,d1
	bpl.s	.cp
	clr.b	(a1)
	move.l	a2,d0			; at the end of the list
	bne.s	.app
	move.l	a0,g_Visits(a4)
	bra.s	.ad
.app:	move.l	a0,vs_Next(a2)
.ad:	move.l	a0,a2
	addq.l	#1,g_VisitN(a4)
.skip:	move.b	(a3)+,d0		; the next line
	beq.s	.free
	cmp.b	#10,d0
	bne.s	.skip
	bra.s	.line
.free:	move.l	a5,a1
	jsr	Free
	bra.s	.x
.close:	move.l	d7,d1
	DOS	Close
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

VS_MAXFILE	equ	64*1024
VsDir:		dc.b	"ENVARC:Velox",0
VsFile:		dc.b	"ENVARC:Velox/Visited",0
	even
