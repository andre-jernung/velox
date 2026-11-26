;
; tabs.s - tabs: several pages, each loading on its own
;
; G holds one tab's state at a time: its globals are in two blocks
; (velox.i: g_TabA .. g_TabAEnd in reach of 16-bit offsets, g_TabB ..
; g_TabBEnd with the big buffers), and the other tabs keep theirs in a
; save area each.  The scheduler brings a tab's in (TabSelect) before
; it runs that tab's loader or handles events for it.  TabTab lists the
; blocks.  A save area holds the copied parts first, in TabTab's order
; (so it begins with g_TabA .. g_TkEnd, the loader's state the
; scheduler reads), then the strings, each up to its NUL.
;

	include	"velox.i"

	xdef	TabSave,TabLoad,TabInit,TabSelect,TabRec,TabBase

	section	code,code

;--------------------------------------------------------------------
; TabTab - the tab's globals, in order: start, bytes, kind (0 copied,
; 1 a string: up to its NUL, 2 not kept).  Every byte of the two blocks
; is in an entry (TABBEG/TABEND check it), so a new global between them
; must be put in one.
;--------------------------------------------------------------------
TBPOS	set	0
TBBIN	set	0
TABBEG	MACRO
TBPOS	set	\1
	ENDM
TABE	MACRO				; kind, start, end
	IFNE	(\2)-TBPOS
	FAIL	"TabTab: a gap or an overlap before \2"
	ENDC
	IFLE	(\3)-(\2)
	FAIL	"TabTab: \2 .. \3 is empty"
	ENDC
	dc.l	\2
	dc.w	(\3)-(\2),\1
TBPOS	set	\3
	IFEQ	\1
TBBIN	set	TBBIN+(\3)-(\2)
	ENDC
	ENDM
TB	MACRO
	TABE	0,\1,\2
	ENDM
TS	MACRO
	TABE	1,\1,\2
	ENDM
TABEND	MACRO
	IFNE	(\1)-TBPOS
	FAIL	"TabTab does not reach \1"
	ENDC
	ENDM

TabTab:
	TABBEG	g_TabA
	TB	g_TabA,g_Parts+up_Host
	IFGT	g_TkEnd-(g_Parts+up_Host)
	FAIL	"TabTab: the first entry must hold g_TabA .. g_TkEnd"
	ENDC
	TS	g_Parts+up_Host,g_Parts+UP_SIZEOF
	TB	g_ReqBuf,g_Resp+r_CType
	TS	g_Resp+r_CType,g_Resp+r_Url
	TS	g_Resp+r_Url,g_Resp+r_Location
	TS	g_Resp+r_Location,g_Resp+r_ETag
	TS	g_Resp+r_ETag,g_Resp+r_LastMod
	TS	g_Resp+r_LastMod,g_Resp+r_MaxAge
	TB	g_Resp+r_MaxAge,g_DcETag
	TS	g_DcETag,g_DcLM
	TS	g_DcLM,g_CondETag
	TS	g_CondETag,g_CondLM
	TS	g_CondLM,g_NavStopped
	TB	g_NavStopped,g_DownloadName
	TS	g_DownloadName,g_NoCache
	TB	g_NoCache,g_KeepHost
	TS	g_KeepHost,g_ProgressHook
	TB	g_ProgressHook,g_TabAEnd
	TABEND	g_TabAEnd
	TABBEG	g_TabB
	TB	g_TabB,g_Find
	TS	g_Find,g_StatusText
	TS	g_StatusText,g_TitleText
	TS	g_TitleText,g_FragName
	TB	g_FragName,g_PageUrl
	TS	g_PageUrl,g_NavUrl
	TS	g_NavUrl,g_BgUrl
	TS	g_BgUrl,g_BgAbs
	TS	g_BgAbs,g_RespSave
	TB	g_RespSave,g_RespSave+r_CType
	TS	g_RespSave+r_CType,g_RespSave+r_Url
	TS	g_RespSave+r_Url,g_RespSave+r_Location
	TS	g_RespSave+r_Location,g_RespSave+r_ETag
	TS	g_RespSave+r_ETag,g_RespSave+r_LastMod
	TS	g_RespSave+r_LastMod,g_RespSave+r_MaxAge
	TB	g_RespSave+r_MaxAge,g_ImgUrl
	TS	g_ImgUrl,g_ImgKey
	TS	g_ImgKey,g_RefreshUrl
	TS	g_RefreshUrl,g_NavNext
	TS	g_NavNext,g_NavFlags
	TB	g_NavFlags,g_FrOv
	TS	g_FrOv,g_NavKey
	TS	g_NavKey,g_FrTmp
	TS	g_FrTmp,g_FrNav
	TS	g_FrNav,g_FrCount
	TB	g_FrCount,g_TabBEnd
	TABEND	g_TabBEnd
	dc.l	0
TAB_BIN	equ	TBBIN			; the copied parts' bytes

;--------------------------------------------------------------------
; TabSave - copy the tab's globals from G to save area a0 (TabNeed
; bytes)
; TabLoad - copy them from save area a0 to G
;--------------------------------------------------------------------
TabSave:
	moveq	#0,d0
	bra.s	TabCopy
TabLoad:
	moveq	#1,d0
	; fall through

; TabCopy - In: a0 = save area, d0 = 0 G to it, 1 it to G
TabCopy:
	movem.l	d2-d4/a2-a3/a5,-(sp)
	move.l	d0,d4
	move.l	a0,a3			; a3 = the copied parts,
	lea	TAB_BIN(a0),a5		; a5 = the strings, as they go
	lea	TabTab(pc),a2
.e:	move.l	(a2)+,d0		; start (0: the end)
	beq.s	.x
	lea	(a4,d0.l),a0		; a0 = in G
	moveq	#0,d2
	move.w	(a2)+,d2		; d2 = bytes
	move.w	(a2)+,d3		; d3 = kind
	bne.s	.str
	move.l	a3,a1			; a1 = in the area
	add.l	d2,a3
	tst.l	d4			; a0 = from, a1 = to
	beq.s	.cp
	exg	a0,a1
.cp:	move.l	d2,d1			; longs, then the bytes left
	lsr.l	#2,d1
	bra.s	.ls
.l:	move.l	(a0)+,(a1)+
.ls:	dbf	d1,.l
	and.w	#3,d2
	bra.s	.bs
.b:	move.b	(a0)+,(a1)+
.bs:	dbf	d2,.b
	bra.s	.e
.str:	move.l	a5,a1			; a string, up to its NUL
	tst.l	d4
	beq.s	.sc
	exg	a0,a1
.sc:	subq.w	#1,d2
.s:	move.b	(a0)+,(a1)+
	dbeq	d2,.s
	tst.l	d4
	bne.s	.sl
	move.l	a1,a5			; (saving: a1 is in the area
	bra.s	.e			;  loading: a0)
.sl:	move.l	a0,a5
	bra.s	.e
.x:	movem.l	(sp)+,d2-d4/a2-a3/a5
	rts

; TabNeed - Out: d0 = the bytes of a save area for the tab in G
TabNeed:
	move.l	a2,-(sp)
	move.l	#TAB_BIN,d0
	lea	TabTab(pc),a2
.e:	move.l	(a2)+,d1
	beq.s	.x
	lea	(a4,d1.l),a0
	move.w	(a2)+,d1		; bytes
	tst.w	(a2)+
	beq.s	.e
	subq.w	#1,d1
.s:	addq.l	#1,d0
	tst.b	(a0)+
	dbeq	d1,.s
	bra.s	.e
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; TabInit - one tab, the one in G (and shown)
;--------------------------------------------------------------------
TabInit:
	lea	g_Tabs(a4),a0
	move.w	#TAB_MAX*TB_SIZEOF/2-1,d0
.c:	clr.w	(a0)+
	dbf	d0,.c
	moveq	#1,d0
	move.l	d0,g_TabN(a4)
	clr.l	g_TabIn(a4)
	clr.l	g_TabFront(a4)
	clr.l	g_TabHidden(a4)
	clr.l	g_TabRR(a4)
	rts

; TabRec - In: d0 = tab; Out: a0 = its record (d0, d1 kept)
TabRec:
	move.l	d0,a0
	mulu.w	#TB_SIZEOF,d0
	exg	d0,a0
	add.l	a4,a0
	lea	g_Tabs(a0),a0
	rts

; TabBase - In: d0 = tab; Out: a0 = where its g_TabA .. g_TkEnd are
; (G or its save area): its loader's x at x-g_TabA(a0) (d0, d1 kept)
TabBase:
	cmp.l	g_TabIn(a4),d0
	beq.s	.g
	bsr.s	TabRec
	move.l	tb_Save(a0),a0
	rts
.g:	lea	g_TabA(a4),a0
	rts

;--------------------------------------------------------------------
; TabSelect - (event loop, not in a loader) tab d0's globals in G: the
; one there goes to its save area.  Its page area is the window's now.
; Out: d0 = 0 if there was no memory for the save area (CCR set; the
; tab in G stays)
;--------------------------------------------------------------------
TabSelect:
	movem.l	d2/a2,-(sp)
	move.l	d0,d2
	cmp.l	g_TabIn(a4),d2
	beq	.ok
	move.l	g_TabIn(a4),d0		; the one in G: its title (for the
	bsr.s	TabRec			;  tab strip) and its globals
	move.l	a0,a2
	lea	g_TitleText(a4),a0
	lea	tb_Title(a2),a1
	moveq	#TAB_TITLE-2,d0
.t:	move.b	(a0)+,(a1)+
	dbeq	d0,.t
	clr.b	(a1)
	bsr	TabNeed
	cmp.l	tb_SaveLen(a2),d0
	bls.s	.room
	move.l	d0,-(sp)		; a bigger area
	move.l	tb_Save(a2),a1
	EXEC	FreeVec
	clr.l	tb_Save(a2)
	clr.l	tb_SaveLen(a2)
	move.l	(sp)+,d0
	add.l	#256,d0			; (room for longer strings)
	move.l	d0,-(sp)
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	(sp)+,d1
	tst.l	d0
	beq.s	.x
	move.l	d0,tb_Save(a2)
	move.l	d1,tb_SaveLen(a2)
.room:	move.l	tb_Save(a2),a0
	bsr	TabSave
	move.l	d2,d0			; the other one's
	bsr	TabRec
	move.l	tb_Save(a0),a0
	bsr	TabLoad
	move.l	d2,g_TabIn(a4)
	bsr.s	TabWinPage
.ok:	moveq	#0,d0			; shown?
	cmp.l	g_TabFront(a4),d2
	sne	d0
	and.l	#1,d0
	move.l	d0,g_TabHidden(a4)
	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a2
	rts

; TabWinPage - the page area of the tab in G: the window's (g_WinPage)
TabWinPage:
	tst.l	g_Window(a4)
	beq.s	.x
	lea	g_PageX(a4),a1		; the page's view: in G, or kept in
	tst.l	g_ViewCur(a4)		; g_ViewTop while a frame's is there
	beq.s	.c
	lea	g_ViewTop+g_PageX-g_View(a4),a1
.c:	lea	g_WinPage(a4),a0
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
.x:	rts
