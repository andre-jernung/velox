;
; drop.s - the list under the address field: the pages visited that
; complete what is typed (visits.s), filtered as it is typed
;
; Intuition edits the address field itself (in input.device's task):
; typing never waits for Velox.  The field's edit hook (UrlHook, also in
; that task) only notes Up, Down and Esc and signals Velox.  The event
; loop runs DropUpdate after the window's messages, before the loaders:
; it moves the choice (Up, Down), and when the text changed, filters
; the visits again (VisitMatch stops if more is typed meanwhile: then
; next time) and shows them in a window of its own under the field (not
; activated: the field keeps the keys; no page painting reaches it).
; Return goes to the one chosen, a click to the one clicked; Esc, the
; field left, the window inactive close the list.
;

	include	"velox.i"
	include	"devices/inputevent.i"
	include	"intuition/sghooks.i"
	include	"lvo/gadtools_lib.i"

	xdef	DropInit,DropExit,DropUpdate,DropCheck,DropHide,DropClick
	xdef	DropChosen,UrlHook
	xref	G,VisitMatch,GetPen,LogEvent

DROP_MAX	equ	8		; entries shown at most

	section	code,code

;--------------------------------------------------------------------
; DropInit - (GuiOpen) the signal the field's hook gives
;--------------------------------------------------------------------
DropInit:
	clr.l	g_DropWin(a4)
	moveq	#-1,d0
	move.l	d0,g_DropSel(a4)
	EXEC	AllocSignal
	move.l	d0,g_DropSigBit(a4)
	bmi.s	.x
	moveq	#0,d1
	bset	d0,d1
	move.l	d1,g_DropSigMask(a4)
	suba.l	a1,a1
	EXEC	FindTask
	move.l	d0,g_DropTask(a4)
.x:	rts

;--------------------------------------------------------------------
; DropExit - (GuiClose, before the main window goes) the list closed,
; the signal freed
;--------------------------------------------------------------------
DropExit:
	bsr	DropHide
	clr.l	g_DropTask(a4)		; (the hook signals no more)
	clr.l	g_DropSigMask(a4)
	move.l	g_DropSigBit(a4),d0
	bmi.s	.x
	moveq	#-1,d1
	move.l	d1,g_DropSigBit(a4)
	EXEC	FreeSignal
.x:	rts

;--------------------------------------------------------------------
; UrlHook - the address field's edit hook (GTST_EditHook): in Intuition's
; task, after it edited the text: Up, Down, Esc noted, Velox signalled
; In: a0 = hook, a1 = message (SGH_KEY ...), a2 = SGWork
;--------------------------------------------------------------------
UrlHook:
	cmp.l	#SGH_KEY,(a1)
	bne.s	.no
	movem.l	d0-d1/a0-a1/a4/a6,-(sp)
	lea	G,a4
	move.l	sgw_IEvent(a2),a0
	move.w	ie_Code(a0),d0
	cmp.w	#$4d,d0			; Down
	bne.s	.u
	addq.l	#1,g_DropMove(a4)
	bra.s	.sig
.u:	cmp.w	#$4c,d0			; Up
	bne.s	.e
	subq.l	#1,g_DropMove(a4)
	bra.s	.sig
.e:	cmp.w	#$45,d0			; Esc
	bne.s	.sig
	st	g_DropEsc(a4)
.sig:	move.l	g_DropTask(a4),d0
	beq.s	.x
	move.l	d0,a1
	move.l	g_DropSigMask(a4),d0
	beq.s	.x
	move.l	4.w,a6
	jsr	_LVOSignal(a6)
.x:	movem.l	(sp)+,d0-d1/a0-a1/a4/a6
	moveq	#-1,d0			; (understood)
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; DropUpdate - (event loop, the shown tab in G) the list as the field
; and the keys say: the choice moved, filtered again if the text
; changed, shown or closed
;--------------------------------------------------------------------
DropUpdate:
	movem.l	d2/a2,-(sp)
	clr.l	g_DropDirty(a4)
	bsr	UrlActive		; a2 = the field's text, if it is
	beq	.hide			; active
	tst.b	g_DropEsc(a4)		; Esc: closed until the text changes
	beq.s	.ne
	clr.b	g_DropEsc(a4)
	clr.l	g_DropMove(a4)
	bsr	DropHide
	st	g_DropShut(a4)
	bra	.same
.ne:	move.l	g_DropMove(a4),d0	; Up, Down: another choice
	beq.s	.same
	clr.l	g_DropMove(a4)
	tst.l	g_DropWin(a4)
	beq.s	.same
	add.l	g_DropSel(a4),d0
	cmp.l	#-1,d0
	bge.s	.lo
	moveq	#-1,d0
.lo:	cmp.l	g_DropN(a4),d0
	blt.s	.hi
	move.l	g_DropN(a4),d0
	subq.l	#1,d0
.hi:	move.l	d0,g_DropSel(a4)
	bsr	DropDraw
.same:	lea	g_DropText(a4),a0	; the text: changed?
	move.l	a2,a1
.c:	move.b	(a1)+,d0
	cmp.b	(a0)+,d0
	bne.s	.chg
	tst.b	d0
	bne.s	.c
	bra	.x
.chg:	lea	g_DropText(a4),a0	; (noted: filtered for this one)
	move.l	a2,a1
	move.w	#DROP_TEXT-2,d0
.cp:	move.b	(a1)+,(a0)+
	dbeq	d0,.cp
	clr.b	(a0)
	clr.b	g_DropShut(a4)
	moveq	#-1,d0
	move.l	d0,g_DropSel(a4)
	tst.b	g_DropText(a4)		; nothing typed: no list
	beq.s	.hide
	moveq	#0,d0			; (new keys from now on stop it)
	move.l	g_DropSigMask(a4),d1
	EXEC	SetSignal
	lea	g_DropText(a4),a0
	lea	g_DropItems(a4),a1
	moveq	#DROP_MAX,d0
	move.l	g_DropSigMask(a4),d1
	jsr	VisitMatch
	bpl.s	.got
	clr.b	g_DropText(a4)		; more typed meanwhile: again, after
	moveq	#1,d0			; its keys
	move.l	d0,g_DropDirty(a4)
	bra.s	.x
.got:	move.l	d0,g_DropN(a4)
	beq.s	.hide
	bsr	DropShow
	bra.s	.x
.hide:	bsr	DropHide
.x:	movem.l	(sp)+,d2/a2
	rts

; UrlActive - Out: d0 = 1 if the address field is being edited (CCR
; set), a2 = its text
UrlActive:
	moveq	#0,d0
	move.l	g_GadUrl(a4),d1
	beq.s	.x
	move.l	d1,a2
	btst	#7,gg_Flags+1(a2)	; GFLG_SELECTED: active
	beq.s	.x
	move.l	gg_SpecialInfo(a2),a2
	move.l	si_Buffer(a2),a2
	moveq	#1,d0
.x:	tst.l	d0
	rts

;--------------------------------------------------------------------
; DropCheck - (after window messages) the field no longer edited, or
; the window inactive: the list closes
;--------------------------------------------------------------------
DropCheck:
	tst.l	g_DropWin(a4)
	beq.s	.x
	move.l	a2,-(sp)
	bsr	UrlActive
	movem.l	(sp)+,a2
	bne.s	.x
	clr.b	g_DropText(a4)		; (typed in again: filtered anew)
	bra	DropHide
.x:	rts

;--------------------------------------------------------------------
; DropChosen - (Return in the address field) the address chosen in the
; list, if one is; the list closes
; Out: d0 = it, or 0 (CCR set)
;--------------------------------------------------------------------
DropChosen:
	moveq	#0,d0
	tst.l	g_DropWin(a4)
	beq.s	.h
	move.l	g_DropSel(a4),d1
	bmi.s	.h
	lea	g_DropItems(a4),a0
	move.l	(a0,d1.l*4),d0
.h:	move.l	d0,-(sp)
	clr.b	g_DropText(a4)
	bsr	DropHide
	move.l	(sp)+,d0
	rts

;--------------------------------------------------------------------
; DropClick - a message of the list's window (In: d2 = class, d3 =
; code, d6 = y in it)
; Out: d0 = the address clicked, or 0 (CCR set)
;--------------------------------------------------------------------
DropClick:
	moveq	#0,d0
	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	bne.s	.x
	cmp.w	#IECODE_LBUTTON,d3
	bne.s	.x
	move.l	d6,d1
	subq.l	#2,d1
	bmi.s	.x
	move.l	g_DropLineH(a4),-(sp)
	divu.l	(sp)+,d1
	cmp.l	g_DropN(a4),d1
	bhs.s	.x
	move.l	d1,g_DropSel(a4)
	bra.s	DropChosen
.x:	tst.l	d0
	rts

;--------------------------------------------------------------------
; DropShow - the list (g_DropN entries) in its window: opened under the
; field, or made the right size
;--------------------------------------------------------------------
DropShow:
	movem.l	d2-d5/a2,-(sp)
	move.l	g_Screen(a4),a0		; a line: the screen's font + 2
	move.l	sc_Font(a0),a0
	moveq	#0,d0
	move.w	ta_YSize(a0),d0
	addq.l	#2,d0
	move.l	d0,g_DropLineH(a4)
	move.l	g_DropN(a4),-(sp)
	mulu.l	(sp)+,d0
	addq.l	#4,d0
	move.l	d0,d5			; d5 = its height
	move.l	g_Window(a4),a0
	move.l	g_GadUrl(a4),a1
	moveq	#0,d2			; d2/d3 = under the field, on the
	move.w	wd_LeftEdge(a0),d2	; screen
	add.w	gg_LeftEdge(a1),d2
	moveq	#0,d3
	move.w	wd_TopEdge(a0),d3
	add.w	gg_TopEdge(a1),d3
	add.w	gg_Height(a1),d3
	moveq	#0,d4
	move.w	gg_Width(a1),d4		; d4 = its width
	move.l	g_DropWin(a4),d0	; open, another size: anew
	beq.s	.open
	move.l	d0,a0
	cmp.w	wd_Height(a0),d5
	beq	.draw
	bsr	DropHide
.open:	lea	DropTags,a1
	move.l	d2,4(a1)		; WA_Left
	move.l	d3,12(a1)		; WA_Top
	move.l	d4,20(a1)		; WA_Width
	move.l	d5,28(a1)		; WA_Height
	move.l	g_Screen(a4),36(a1)	; WA_CustomScreen
	suba.l	a0,a0
	INTUI	OpenWindowTagList
	move.l	d0,g_DropWin(a4)
	beq.s	.x
	move.l	d0,a0			; its messages: to the main window's
	move.l	g_Window(a4),a1		; port
	move.l	wd_UserPort(a1),wd_UserPort(a0)
	move.l	#IDCMP_MOUSEBUTTONS,d0
	INTUI	ModifyIDCMP
.draw:	bsr	DropDraw
	lea	LogDrop(pc),a0		; (for tests: "drop N")
	suba.l	a1,a1
	move.l	g_DropN(a4),d0
	jsr	LogEvent
.x:	movem.l	(sp)+,d2-d5/a2
	rts
LogDrop:	dc.b	"drop",0
	even

;--------------------------------------------------------------------
; DropHide - the list's window closed (its messages taken back from the
; shared port first)
;--------------------------------------------------------------------
DropHide:
	move.l	g_DropWin(a4),d0
	beq.s	.x
	movem.l	a2-a3,-(sp)
	move.l	d0,a3
	clr.l	g_DropWin(a4)
	moveq	#-1,d0
	move.l	d0,g_DropSel(a4)
	EXEC	Forbid
	move.l	wd_UserPort(a3),a0	; those still waiting
	move.l	MP_MSGLIST+LH_HEAD(a0),a2
.m:	move.l	LN_SUCC(a2),d0
	beq.s	.md
	cmp.l	im_IDCMPWindow(a2),a3
	bne.s	.mn
	move.l	a2,a1
	EXEC	Remove
	move.l	a2,a1
	EXEC	ReplyMsg
.mn:	move.l	d0,a2
	bra.s	.m
.md:	clr.l	wd_UserPort(a3)
	move.l	a3,a0
	moveq	#0,d0
	INTUI	ModifyIDCMP
	EXEC	Permit
	move.l	a3,a0
	INTUI	CloseWindow
	lea	LogDrop(pc),a0		; ("drop 0")
	suba.l	a1,a1
	moveq	#0,d0
	jsr	LogEvent
	movem.l	(sp)+,a2-a3
.x:	rts

; DropDraw - the entries: the one chosen highlighted
DropDraw:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	g_DropWin(a4),d0
	beq	.x
	move.l	d0,a0
	move.l	wd_RPort(a0),a3		; a3 = its RastPort
	moveq	#0,d6
	move.w	wd_Width(a0),d6		; d6 = width
	moveq	#0,d7
	move.w	wd_Height(a0),d7	; d7 = height
	move.l	a3,a1
	move.l	g_ScreenFont(a4),a0
	GFX	SetFont
	move.l	a3,a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	move.l	#$ffffff,d0		; white, a black edge
	bsr	Pen
	move.l	a3,a1
	moveq	#0,d0
	moveq	#0,d1
	move.l	d6,d2
	subq.l	#1,d2
	move.l	d7,d3
	subq.l	#1,d3
	GFX	RectFill
	moveq	#0,d0
	bsr	Pen
	move.l	a3,a1
	moveq	#0,d0
	moveq	#0,d1
	GFX	Move
	move.l	a3,a1
	move.l	d6,d0
	subq.l	#1,d0
	moveq	#0,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d6,d0
	subq.l	#1,d0
	move.l	d7,d1
	subq.l	#1,d1
	GFX	Draw
	move.l	a3,a1
	moveq	#0,d0
	move.l	d7,d1
	subq.l	#1,d1
	GFX	Draw
	move.l	a3,a1
	moveq	#0,d0
	moveq	#0,d1
	GFX	Draw
	moveq	#0,d4			; d4 = the entry
.e:	cmp.l	g_DropN(a4),d4
	bhs	.x
	move.l	d4,d5			; d5 = its y
	move.l	g_DropLineH(a4),-(sp)
	mulu.l	(sp)+,d5
	addq.l	#2,d5
	move.l	#$000000,d0		; (its text's colour)
	cmp.l	g_DropSel(a4),d4
	bne.s	.t
	move.l	#$3b67a2,d0		; chosen: blue, white text
	bsr	Pen
	move.l	a3,a1
	moveq	#2,d0
	move.l	d5,d1
	move.l	d6,d2
	subq.l	#3,d2
	move.l	d5,d3
	add.l	g_DropLineH(a4),d3
	subq.l	#1,d3
	GFX	RectFill
	move.l	#$ffffff,d0
.t:	bsr	Pen
	lea	g_DropItems(a4),a0
	move.l	(a0,d4.l*4),a2		; a2 = its address
	move.l	a2,a0			; as much of it as fits
	moveq	#-1,d0
.len:	addq.l	#1,d0
	tst.b	(a0)+
	bne.s	.len
	lea	-16(sp),sp		; TextFit(rp, s, n, te, 0, 1, w, h)
	move.l	a2,a0
	move.l	a3,a1
	movem.l	d2-d3/a2-a3,-(sp)
	lea	16(sp),a2
	suba.l	a3,a3
	moveq	#1,d1
	move.l	d6,d2
	sub.l	#10,d2
	moveq	#127,d3
	GFX	TextFit
	movem.l	(sp)+,d2-d3/a2-a3
	lea	16(sp),sp
	move.l	d0,-(sp)
	move.l	a3,a1
	moveq	#5,d0
	move.l	g_ScreenFont(a4),a0
	moveq	#0,d1
	move.w	tf_Baseline(a0),d1
	add.l	d5,d1
	addq.l	#1,d1
	GFX	Move
	move.l	(sp)+,d0
	move.l	a3,a1
	move.l	a2,a0
	GFX	Text
	addq.l	#1,d4
	bra	.e
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; Pen - the A pen of a3 the pen for colour d0
Pen:
	jsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	rts

	section	data,data
DropTags:
	dc.l	WA_Left,0,WA_Top,0,WA_Width,0,WA_Height,0
	dc.l	WA_CustomScreen,0
	dc.l	WA_Borderless,1,WA_Activate,0,WA_RMBTrap,1
	dc.l	WA_SmartRefresh,1,WA_NoCareRefresh,1,WA_IDCMP,0
	dc.l	TAG_DONE
