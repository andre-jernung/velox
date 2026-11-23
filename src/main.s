;
; main.s - Velox entry point, startup/shutdown, main window and event loop
;

	include	"velox.i"

	xdef	G
	xref	MemInit,MemExit,NetExit,HttpGet,UrlFixup
	xref	PutStr,PutBuf,PutNum,PutNL,FlushOut,ErrorText

;====================================================================
	section	code,code
;====================================================================

Start:
	movem.l	d2-d7/a2-a6,-(sp)
	lea	G,a4
	move.l	4.w,a6
	move.l	a6,g_SysBase(a4)

	; Started from Workbench?  Then we must collect the WBStartup
	; message before doing anything else and reply it on exit.
	suba.l	a1,a1
	jsr	_LVOFindTask(a6)
	move.l	d0,a2
	tst.l	pr_CLI(a2)
	bne.s	.cli
	lea	pr_MsgPort(a2),a0
	jsr	_LVOWaitPort(a6)
	lea	pr_MsgPort(a2),a0
	jsr	_LVOGetMsg(a6)
	move.l	d0,g_WBMsg(a4)
.cli:
	bsr.s	Main
	move.l	d0,d2			; return code

	tst.l	g_WBMsg(a4)
	beq.s	.exit
	EXEC	Forbid			; stay forbidden until we are gone,
	move.l	g_WBMsg(a4),a1		; so Workbench cannot UnLoadSeg()
	jsr	_LVOReplyMsg(a6)	; us while we still run
.exit:
	move.l	d2,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

	dc.b	"$VER: Velox "
	VERSION_STR
	dc.b	" (23.11.2026)",0
	even

;--------------------------------------------------------------------
; Main - set up, run the event loop or a CLI command, tear down.
; Out: d0 = DOS return code
;--------------------------------------------------------------------
ARG_URL		equ	0
ARG_DUMP	equ	4
ARG_INFO	equ	8

Main:
	movem.l	d2-d3,-(sp)
	moveq	#RC_FAIL,d2
	bsr	OpenLibs
	beq.s	.cleanup
	bsr	MemInit
	beq.s	.cleanup
	tst.l	g_WBMsg(a4)
	bne.s	.gui
	DOS	Output
	move.l	d0,g_StdOut(a4)
	lea	ArgTemplate(pc),a0
	move.l	a0,d1
	lea	g_ArgArray(a4),a0
	move.l	a0,d2
	moveq	#0,d3
	DOS	ReadArgs
	move.l	d0,g_RDArgs(a4)
	bne.s	.args
	DOS	IoErr
	move.l	d0,d1
	lea	ProgName(pc),a0
	move.l	a0,d2
	DOS	PrintFault
	moveq	#RC_FAIL,d2
	bra.s	.cleanup
.args:
	tst.l	g_ArgArray+ARG_DUMP(a4)
	bne.s	.cli
	tst.l	g_ArgArray+ARG_INFO(a4)
	beq.s	.gui
.cli:	bsr	CliFetch
	move.l	d0,d2
	bra.s	.cleanup
.gui:
	moveq	#RC_FAIL,d2
	bsr	OpenMainWindow
	beq.s	.cleanup
	bsr	RedrawWindow
	bsr	EventLoop
	moveq	#RC_OK,d2
.cleanup:
	bsr	CloseMainWindow
	move.l	g_RDArgs(a4),d1
	beq.s	.noargs
	clr.l	g_RDArgs(a4)
	DOS	FreeArgs
.noargs:
	bsr	FlushOut
	bsr	NetExit
	bsr	MemExit
	bsr	CloseLibs
	move.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

ArgTemplate:	dc.b	"URL,DUMP/S,INFO/S",0
ProgName:	dc.b	"velox",0
	even

;--------------------------------------------------------------------
; CliFetch - fetch the URL argument; INFO prints status and headers we
; parsed, DUMP prints the body.
; Out: d0 = DOS return code
;--------------------------------------------------------------------
CliFetch:
	movem.l	a2-a3,-(sp)
	move.l	g_ArgArray+ARG_URL(a4),d0
	bne.s	.url
	lea	MsgNoUrl(pc),a0
	bsr	PutStr
	moveq	#RC_FAIL,d0
	bra	.x
.url:	move.l	d0,a0
	lea	g_UrlTmp2(a4),a1
	bsr	UrlFixup
	move.l	#SIGBREAKF_CTRL_C,g_AbortMask(a4)
	lea	g_UrlTmp2(a4),a0
	bsr	HttpGet
	bne.s	.ok
	lea	ProgNameColon(pc),a0
	bsr	PutStr
	move.l	g_Error(a4),d0
	bsr	ErrorText
	bsr	PutStr
	bsr	PutNL
	moveq	#RC_FAIL,d0
	bra.s	.x
.ok:	lea	g_Resp(a4),a3
	tst.l	g_ArgArray+ARG_INFO(a4)
	beq.s	.dump
	lea	MsgStatus(pc),a0
	bsr	PutStr
	move.l	r_Status(a3),d0
	bsr	PutNum
	lea	MsgUrl(pc),a0
	bsr	PutStr
	lea	r_Url(a3),a0
	bsr	PutStr
	lea	MsgType(pc),a0
	bsr	PutStr
	lea	r_CType(a3),a0
	bsr	PutStr
	lea	MsgLength(pc),a0
	bsr	PutStr
	move.l	r_Body+buf_Len(a3),d0
	bsr	PutNum
	bsr	PutNL
.dump:	tst.l	g_ArgArray+ARG_DUMP(a4)
	beq.s	.done
	move.l	r_Body+buf_Data(a3),d0
	beq.s	.done
	move.l	d0,a0
	move.l	r_Body+buf_Len(a3),d0
	bsr	PutBuf
.done:	moveq	#RC_OK,d0
	move.l	r_Status(a3),d1
	cmp.l	#400,d1
	blo.s	.x
	moveq	#RC_WARN,d0
.x:	movem.l	(sp)+,a2-a3
	rts

MsgNoUrl:	dc.b	"velox: URL required",10,0
ProgNameColon:	dc.b	"velox: ",0
MsgStatus:	dc.b	"status: ",0
MsgUrl:		dc.b	10,"url: ",0
MsgType:	dc.b	10,"type: ",0
MsgLength:	dc.b	10,"length: ",0
	even

;--------------------------------------------------------------------
; OpenLibs - open every library listed in LibTable.
; Out: d0 = 0 (Z set) if any library failed to open
;--------------------------------------------------------------------
OpenLibs:
	move.l	a2,-(sp)
	lea	LibTable(pc),a2
.loop:
	move.w	(a2)+,d0		; name offset, 0 = end
	beq.s	.ok
	lea	LibTable(pc),a1
	adda.w	d0,a1
	moveq	#0,d0			; version is a ULONG, upper word must
	move.w	(a2)+,d0		; be clear (d0 held the last lib base)
	EXEC	OpenLibrary
	move.w	(a2)+,d1		; global slot
	move.l	d0,(a4,d1.w)
	bne.s	.loop
	bra.s	.done			; d0 = 0
.ok:
	moveq	#1,d0
.done:
	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; CloseLibs - close every library from LibTable that is open.
; Safe to call when only some (or none) were opened.
;--------------------------------------------------------------------
CloseLibs:
	move.l	a2,-(sp)
	lea	LibTable(pc),a2
.loop:
	tst.w	(a2)
	beq.s	.done
	move.w	4(a2),d0		; global slot
	move.l	(a4,d0.w),d1
	beq.s	.next
	clr.l	(a4,d0.w)
	move.l	d1,a1
	EXEC	CloseLibrary
.next:
	addq.l	#6,a2
	bra.s	.loop
.done:
	move.l	(sp)+,a2
	rts

; name offset (from LibTable), minimum version, global slot
LibTable:
	dc.w	DosName-LibTable,39,g_DOSBase
	dc.w	IntuitionName-LibTable,39,g_IntuitionBase
	dc.w	GfxName-LibTable,39,g_GfxBase
	dc.w	0

DosName:	dc.b	"dos.library",0
IntuitionName:	dc.b	"intuition.library",0
GfxName:	dc.b	"graphics.library",0
	even

;--------------------------------------------------------------------
; OpenMainWindow - open the browser window on the default public screen.
; Out: d0 = window or 0 (Z set on failure)
;--------------------------------------------------------------------
OpenMainWindow:
	suba.l	a0,a0			; no NewWindow
	lea	WindowTags,a1
	INTUI	OpenWindowTagList
	move.l	d0,g_Window(a4)
	beq.s	.fail
	move.l	d0,a0
	move.l	wd_UserPort(a0),a0
	moveq	#0,d0
	move.b	MP_SIGBIT(a0),d1
	bset	d1,d0
	move.l	d0,g_WinSigMask(a4)
.fail:
	rts

;--------------------------------------------------------------------
; CloseMainWindow - close the main window if it is open.
;--------------------------------------------------------------------
CloseMainWindow:
	move.l	g_Window(a4),d0
	beq.s	.done
	clr.l	g_Window(a4)
	move.l	d0,a0
	INTUI	CloseWindow
.done:
	rts

;--------------------------------------------------------------------
; EventLoop - wait for and dispatch IDCMP messages until the user
; closes the window or sends Ctrl-C.
;--------------------------------------------------------------------
EventLoop:
	move.l	d2,-(sp)
.wait:
	move.l	g_WinSigMask(a4),d0
	ori.l	#SIGBREAKF_CTRL_C,d0
	EXEC	Wait
	btst	#SIGBREAKB_CTRL_C,d0
	bne.s	.quit
.next:
	move.l	g_Window(a4),a0
	move.l	wd_UserPort(a0),a0
	EXEC	GetMsg
	tst.l	d0
	beq.s	.wait
	move.l	d0,a1
	move.l	im_Class(a1),d2
	jsr	_LVOReplyMsg(a6)	; a6 is still SysBase

	cmpi.l	#IDCMP_CLOSEWINDOW,d2
	beq.s	.quit
	cmpi.l	#IDCMP_REFRESHWINDOW,d2
	bne.s	.notrefresh
	move.l	g_Window(a4),a0
	INTUI	BeginRefresh
	bsr.s	RedrawWindow
	move.l	g_Window(a4),a0
	moveq	#-1,d0			; complete = TRUE
	INTUI	EndRefresh
	bra.s	.next
.notrefresh:
	cmpi.l	#IDCMP_NEWSIZE,d2
	bne.s	.next
	bsr.s	RedrawWindow
	bra.s	.next
.quit:
	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; RedrawWindow - clear the inner area and draw the placeholder text.
; Temporary until the renderer exists.
;--------------------------------------------------------------------
RedrawWindow:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	g_Window(a4),a3
	move.l	wd_RPort(a3),a2

	move.l	a2,a1
	moveq	#0,d0			; background pen
	GFX	SetAPen
	moveq	#0,d0			; RectFill takes LONGs: keep the upper
	moveq	#0,d2			; words of d0-d3 clear
	moveq	#0,d3
	move.b	wd_BorderRight(a3),d0
	move.w	wd_Width(a3),d2
	sub.w	d0,d2
	subq.w	#1,d2			; x max
	move.b	wd_BorderBottom(a3),d0
	move.w	wd_Height(a3),d3
	sub.w	d0,d3
	subq.w	#1,d3			; y max
	moveq	#0,d1
	move.b	wd_BorderLeft(a3),d0	; x min
	move.b	wd_BorderTop(a3),d1	; y min
	move.l	a2,a1
	jsr	_LVORectFill(a6)

	move.l	a2,a1
	moveq	#1,d0			; text pen
	jsr	_LVOSetAPen(a6)
	moveq	#0,d0
	moveq	#0,d1
	move.b	wd_BorderLeft(a3),d0
	addq.w	#8,d0
	move.b	wd_BorderTop(a3),d1
	add.w	rp_TxBaseline(a2),d1
	addq.w	#8,d1
	move.l	a2,a1
	jsr	_LVOMove(a6)
	move.l	a2,a1
	lea	HelloText(pc),a0
	moveq	#HelloTextLen,d0
	jsr	_LVOText(a6)

	movem.l	(sp)+,d2-d3/a2-a3
	rts

HelloText:	dc.b	"Velox - nothing to show yet."
HelloTextLen	equ	*-HelloText
	even

;====================================================================
	section	data,data
;====================================================================

WindowTags:
	dc.l	WA_Title,WindowTitle
	dc.l	WA_ScreenTitle,ScreenTitle
	dc.l	WA_Left,0
	dc.l	WA_Top,0
	dc.l	WA_Width,640
	dc.l	WA_Height,400
	dc.l	WA_MinWidth,240
	dc.l	WA_MinHeight,80
	dc.l	WA_MaxWidth,-1
	dc.l	WA_MaxHeight,-1
	dc.l	WA_AutoAdjust,1
	dc.l	WA_DragBar,1
	dc.l	WA_DepthGadget,1
	dc.l	WA_CloseGadget,1
	dc.l	WA_SizeGadget,1
	dc.l	WA_SizeBBottom,1
	dc.l	WA_SimpleRefresh,1
	dc.l	WA_Activate,1
	dc.l	WA_NewLookMenus,1
	dc.l	WA_IDCMP,IDCMP_CLOSEWINDOW|IDCMP_NEWSIZE|IDCMP_REFRESHWINDOW
	dc.l	TAG_DONE

WindowTitle:	dc.b	"Velox",0
ScreenTitle:	dc.b	"Velox 0.1",0
	even

;====================================================================
	section	bss,bss
;====================================================================

G:	ds.b	g_SIZEOF
