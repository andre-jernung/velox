;
; keep.s - pages kept for Back and Forward
;
; A page that is left is not freed: its memory (the page pool with the
; DOM, styles, CSS and form state; the source, the runs, the anchors;
; its images' bitmaps) is put aside with its history entry, and its
; globals are copied into a KeepPage record.  Back or Forward to that
; entry copies them back: the page is there as it was left (scroll
; position, focus, what was typed), with nothing to fetch, parse or lay
; out; only painted (laid out again if the window's width changed).
;
; At most g_KeepMax pages are kept (Velox/KeepPages, default 4), and
; only while memory is left: the one farthest from the current entry
; goes first, also when a page or an image needs the memory.
;

	include	"velox.i"

	xdef	PageLeave,PageRestore,KeepEvict,KeepDrop,KeepFreeAll,KeepCopy
	xref	FramesFree
	xref	PageFree,Alloc,Free,BufFree,ImgListFree,LogEvent,ArenaFree,PfWrite

	section	code,code

;--------------------------------------------------------------------
; KeepTab - the page's globals: G offset (long), bytes, 1 if they are the
; page's own memory (cleared in G when it is kept); in kp_xxx order
;--------------------------------------------------------------------
KPOFF	set	0
KEEPG	MACRO
	IFNE	KPOFF-\2
	FAIL	"KeepTab: \2 is not where KEEPG puts it"
	ENDC
	dc.l	\1
	dc.w	\3,\4
KPOFF	set	KPOFF+\3
	ENDM
; (the fields copied together must be together in G)
	IFNE	g_BaseHref+4-g_PagePool-28
	FAIL	"g_PagePool .. g_BaseHref must stay together (KeepTab)"
	ENDC
	IFNE	g_Anchors-g_Runs-BUF_SIZEOF
	FAIL	"g_Runs, g_Anchors must stay together (KeepTab)"
	ENDC
	IFNE	g_CssCacheW+4-g_CssIdTab-28
	FAIL	"g_CssIdTab .. g_CssCacheW must stay together (KeepTab)"
	ENDC
	IFNE	g_ImgList+4-g_ImgQueue-24
	FAIL	"g_ImgQueue .. g_ImgList must stay together (KeepTab)"
	ENDC
	IFNE	g_BgList+4-g_PageBgRec-12
	FAIL	"g_PageBgRec .. g_BgList must stay together (KeepTab)"
	ENDC
	IFNE	g_FocusIdx+4-g_FocusLink-8
	FAIL	"g_FocusLink, g_FocusIdx must stay together (KeepTab)"
	ENDC
	IFNE	g_LinkColor+4-g_LayWidth-20
	FAIL	"g_LayWidth .. g_LinkColor must stay together (KeepTab)"
	ENDC
	IFNE	g_PfFresh+4-g_PageDone-20
	FAIL	"g_PageDone .. g_PfFresh must stay together (KeepTab)"
	ENDC

KeepTab:
	KEEPG	g_PagePool,kp_Pool,28,1
	KEEPG	g_Runs,kp_Runs,24,1
	KEEPG	g_CssIdTab,kp_Css,28,1
	KEEPG	g_ImgQueue,kp_Img,24,1
	KEEPG	g_PageBgRec,kp_Bg,12,1
	KEEPG	g_FocusLink,kp_Focus,8,1
	KEEPG	g_EditField,kp_Edit,4,1
	KEEPG	g_LayWidth,kp_Lay,20,0
	KEEPG	g_PageCharset,kp_Charset,4,0
	KEEPG	g_PageStatus,kp_Status,4,0
	KEEPG	g_StyleGen,kp_StyleGen,4,0
	KEEPG	g_ScrollY,kp_ScrollY,4,0
	KEEPG	g_PageDone,kp_Done,20,0
	KEEPG	g_FormTouched,kp_Touched,4,0
	KEEPG	g_PageUrl,kp_Url,URL_MAX,0
	KEEPG	g_TitleText,kp_Title,STATUS_MAX,0
	dc.l	0
	IFNE	KPOFF-KP_SIZEOF
	FAIL	"KeepTab does not fill KP_SIZEOF"
	ENDC

;--------------------------------------------------------------------
; KeepCopy - copy the page's globals between G and a KeepPage
; In: a0 = KeepPage, d0 = 0: from G into it, 1: from it into G
;--------------------------------------------------------------------
KeepCopy:
	movem.l	d2-d3/a2,-(sp)
	move.l	d0,d3
	lea	KeepTab(pc),a2
.e:	move.l	(a2)+,d0		; G offset (0: the end)
	beq.s	.x
	lea	(a4,d0.l),a1
	moveq	#0,d2
	move.w	(a2)+,d2		; bytes (even)
	addq.l	#2,a2
	lsr.l	#1,d2
	subq.l	#1,d2
	tst.l	d3
	bne.s	.in
.out:	move.w	(a1)+,(a0)+
	dbf	d2,.out
	bra.s	.e
.in:	move.w	(a0)+,(a1)+
	dbf	d2,.in
	bra.s	.e
.x:	movem.l	(sp)+,d2-d3/a2
	rts

; KeepClear - clear the page's own memory in G (it is kept now)
KeepClear:
	lea	KeepTab(pc),a0
.e:	move.l	(a0)+,d0
	beq.s	.x
	lea	(a4,d0.l),a1
	move.w	(a0)+,d1
	tst.w	(a0)+
	beq.s	.e
	lsr.w	#1,d1
	subq.w	#1,d1
.c:	clr.w	(a1)+
	dbf	d1,.c
	bra.s	.e
.x:	moveq	#-1,d0
	move.l	d0,g_FocusIdx(a4)
	clr.l	g_ViewLive(a4)
	rts

;--------------------------------------------------------------------
; PageLeave - the page shown goes (a new one comes): kept for its
; history entry if it can be, else freed
;--------------------------------------------------------------------
PageLeave:
	tst.l	g_Blank(a4)		; blank meanwhile: nothing comes back
	beq.s	.nb			; now (GuiUnblank)
	moveq	#2,d0
	move.l	d0,g_Blank(a4)
.nb:	jsr	FramesFree		; (a page of frames: their views)
	tst.l	g_PagePool(a4)
	beq.s	.free
	bsr.s	PageKeep
	bne.s	.x
.free:	jmp	PageFree
.x:	rts

;--------------------------------------------------------------------
; PageKeep - keep the page shown for its history entry: it is all
; there, the entry is its own, it is not replaced by itself (Reload, a
; newer version of a cached copy), and there is room
; Out: d0 = 1 if kept (CCR set)
;--------------------------------------------------------------------
PageKeep:
	movem.l	d2/a2,-(sp)
	tst.l	g_KeepMax(a4)
	beq	.no
	tst.l	g_Revalid(a4)		; a newer version replaces it
	bne	.no
	tst.l	g_PageDone(a4)
	ble	.no
	move.l	g_PageHist(a4),d2	; d2 = its entry
	bmi	.no
	cmp.l	g_HistCount(a4),d2
	bge	.no
	lea	g_Hist(a4),a0		; (still its URL?)
	move.l	(a0,d2.l*8),a0
	lea	g_PageUrl(a4),a1
	bsr	KeepSame
	beq	.no
	tst.l	g_TkIn(a4)		; loading the same page into the same
	beq.s	.room			; entry (Reload): it is replaced
	cmp.l	g_HistPos(a4),d2
	bne.s	.room
	lea	g_NavUrl(a4),a0
	lea	g_PageUrl(a4),a1
	bsr	KeepSame
	bne	.no
.room:	lea	g_HistKept(a4),a0	; an older copy kept there: this one
	move.l	(a0,d2.l*4),d0		; is newer
	beq.s	.n
	clr.l	(a0,d2.l*4)
	move.l	d0,a0
	bsr	KeepFree
.n:	bsr	KeepCount
	cmp.l	g_KeepMax(a4),d0
	blo.s	.mem
	bsr	KeepSaveNext		; (to disk first, if not there yet)
	bsr	KeepEvict
	bne.s	.n
	bra	.no
.mem:	move.l	#MEMF_ANY,d1		; memory left after it?
	EXEC	AvailMem
	cmp.l	#KEEP_FREE,d0
	bhs.s	.alloc
	bsr	KeepEvict
	bne.s	.mem
	bra.s	.no
.alloc:	move.l	#KP_SIZEOF,d0
	jsr	Alloc
	beq.s	.no
	move.l	d0,a2
	move.l	a2,a0
	moveq	#0,d0
	bsr	KeepCopy
	bsr	KeepClear
	lea	g_HistKept(a4),a0
	move.l	a2,(a0,d2.l*4)
	lea	LogKept(pc),a0		; (for tests)
	lea	g_PageUrl(a4),a1
	move.l	d2,d0
	jsr	LogEvent
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2
	rts

LogKept:	dc.b	"kept",0
LogDropped:	dc.b	"dropped",0
	even

; KeepSame - Out: d0 = 1 if strings a0 and a1 are the same (CCR set)
KeepSame:
.l:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.no
	tst.b	d0
	bne.s	.l
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; KeepCount - Out: d0 = pages kept
KeepCount:
	lea	g_HistKept(a4),a0
	moveq	#0,d0
	moveq	#HIST_ENTRIES-1,d1
.l:	tst.l	(a0)+
	beq.s	.n
	addq.l	#1,d0
.n:	dbf	d1,.l
	rts

;--------------------------------------------------------------------
; PageRestore - show the page kept as a0 instead of the one shown (that
; one is kept or freed); a0 is freed (out of g_HistKept already)
;--------------------------------------------------------------------
PageRestore:
	move.l	a2,-(sp)
	move.l	a0,a2
	bsr	PageLeave
	lea	g_Runs(a4),a0		; (freed with the page if not kept)
	jsr	BufFree
	lea	g_Anchors(a4),a0
	jsr	BufFree
	move.l	a2,a0
	moveq	#1,d0
	bsr	KeepCopy
	move.l	a2,a1
	jsr	Free
	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; KeepNext - the kept page to go first: the farthest from the current
; entry
; Out: d0 = its entry or -1 (CCR set)
;--------------------------------------------------------------------
KeepNext:
	movem.l	d2-d4,-(sp)
	moveq	#-1,d3			; d3 = the entry
	moveq	#-1,d4			; d4 = its distance
	moveq	#0,d2
	lea	g_HistKept(a4),a0
.l:	tst.l	(a0,d2.l*4)
	beq.s	.n
	move.l	d2,d0
	sub.l	g_HistPos(a4),d0
	bpl.s	.p
	neg.l	d0
.p:	cmp.l	d4,d0
	ble.s	.n
	move.l	d0,d4
	move.l	d2,d3
.n:	addq.l	#1,d2
	cmp.l	#HIST_ENTRIES,d2
	blo.s	.l
	move.l	d3,d0
	movem.l	(sp)+,d2-d4
	rts

;--------------------------------------------------------------------
; KeepSaveNext - (the loader) the kept page to go next, saved as its
; page file first if it has none yet (left before its images came):
; Back to it then comes from disk, not from the network
;--------------------------------------------------------------------
KeepSaveNext:
	move.l	a2,-(sp)
	tst.l	g_TkIn(a4)
	beq.s	.x
	bsr.s	KeepNext
	bmi.s	.x
	lea	g_HistKept(a4),a0
	move.l	(a0,d0.l*4),a2
	tst.l	kp_Done+16(a2)		; (g_PfFresh: it has one)
	bne.s	.x
	move.l	a2,a0
	jsr	PfWrite
	beq.s	.x
	lea	g_HistKept(a4),a0	; (still kept?)
	moveq	#HIST_ENTRIES-1,d0
.f:	cmp.l	(a0)+,a2
	dbeq	d0,.f
	bne.s	.x
	moveq	#1,d0
	move.l	d0,kp_Done+16(a2)
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; KeepEvict - free the kept page farthest from the current entry
; Out: d0 = 1 if there was one (CCR set)
;--------------------------------------------------------------------
KeepEvict:
	movem.l	d2-d4,-(sp)
	bsr	KeepNext
	move.l	d0,d3
	bmi.s	.x0
	bsr.s	KeepDrop
	lea	LogDropped(pc),a0	; (for tests)
	suba.l	a1,a1
	move.l	d3,d0
	jsr	LogEvent
	moveq	#1,d0
	bra.s	.x
.x0:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4
	rts

;--------------------------------------------------------------------
; KeepDrop - free the page kept for history entry d0, if there is one
; (and the page shown no longer has that entry if it is its)
;--------------------------------------------------------------------
KeepDrop:
	cmp.l	g_PageHist(a4),d0
	bne.s	.k
	moveq	#-1,d1
	move.l	d1,g_PageHist(a4)
.k:	lea	g_HistKept(a4),a0
	move.l	(a0,d0.l*4),d1
	beq.s	.x
	clr.l	(a0,d0.l*4)
	move.l	d1,a0
	bra.s	KeepFree
.x:	rts

; KeepFree - free kept page a0: its images, buffers, pool and record
KeepFree:
	move.l	a2,-(sp)
	move.l	a0,a2
	cmp.l	g_PfBusy(a4),a2		; being saved (pagefile.s): that ends
	bne.s	.nb
	clr.l	g_PfBusy(a4)
	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
.nb:	move.l	kp_Img+20(a2),a0	; (g_ImgList)
	jsr	ImgListFree
	lea	kp_Pool+4(a2),a0	; (g_PageSrc)
	jsr	BufFree
	lea	kp_Runs(a2),a0
	jsr	BufFree
	lea	kp_Runs+BUF_SIZEOF(a2),a0
	jsr	BufFree
	move.l	kp_Pool(a2),a0
	jsr	ArenaFree
	move.l	a2,a1
	jsr	Free
	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; KeepFreeAll - free all kept pages (before the screen goes)
;--------------------------------------------------------------------
KeepFreeAll:
	move.l	d2,-(sp)
	moveq	#HIST_ENTRIES-1,d2
.l:	move.l	d2,d0
	bsr	KeepDrop
	dbf	d2,.l
	movem.l	(sp)+,d2
	rts
