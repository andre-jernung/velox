;
; tabs.s - tabs: several pages, each loading on its own
;
; G holds one tab's state at a time: its globals are in two blocks
; (velox.i: g_TabA .. g_TabAEnd in reach of 16-bit offsets, g_TabB ..
; g_TabBEnd with the big buffers), and the other tabs keep theirs in a
; save area each.  The scheduler brings a tab's in (TabSelect) before
; it runs that tab's loader or handles events for it.  TabTab lists the
; blocks; strings are copied up to their NUL, the screen's band
; signatures (g_Bands) not at all (painting starts anew on a switch).
;

	include	"velox.i"

	xdef	TabSave,TabLoad

	section	code,code

;--------------------------------------------------------------------
; TabTab - the tab's globals, in order: start, bytes, kind (0 copied,
; 1 a string: up to its NUL, 2 not kept).  Every byte of the two blocks
; is in an entry (TABBEG/TABEND check it), so a new global between them
; must be put in one.
;--------------------------------------------------------------------
TBPOS	set	0
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
	ENDM
TB	MACRO
	TABE	0,\1,\2
	ENDM
TS	MACRO
	TABE	1,\1,\2
	ENDM
TX	MACRO
	TABE	2,\1,\2
	ENDM
TABEND	MACRO
	IFNE	(\1)-TBPOS
	FAIL	"TabTab does not reach \1"
	ENDC
	ENDM
VBANDS	equ	g_Bands-g_View		; the bands in a view
VBANDE	equ	g_PageBgRec-g_View

TabTab:
	TABBEG	g_TabA
	TB	g_TabA,g_Parts+up_Host
	TS	g_Parts+up_Host,g_Parts+UP_SIZEOF
	TB	g_ReqBuf,g_Resp+r_CType
	TS	g_Resp+r_CType,g_Resp+r_Url
	TS	g_Resp+r_Url,g_Resp+r_Location
	TS	g_Resp+r_Location,g_Resp+r_ETag
	TS	g_Resp+r_ETag,g_Resp+r_LastMod
	TS	g_Resp+r_LastMod,g_Resp+r_MaxAge
	TB	g_Resp+r_MaxAge,g_Bands
	TX	g_Bands,g_PageBgRec
	TB	g_PageBgRec,g_DcETag
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
	TB	g_FrCount,g_ViewTop+VBANDS
	TX	g_ViewTop+VBANDS,g_ViewTop+VBANDE
	TB	g_ViewTop+VBANDE,g_TabBEnd
	TABEND	g_TabBEnd
	dc.l	0

;--------------------------------------------------------------------
; TabSave - copy the tab's globals from G to save area a0 (TAB_SAVE
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
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	d0,d4
	move.l	a0,a3			; a3 = the area, as the entries go
	lea	TabTab(pc),a2
.e:	move.l	(a2)+,d0		; start (0: the end)
	beq.s	.x
	lea	(a4,d0.l),a0		; a0 = in G
	moveq	#0,d2
	move.w	(a2)+,d2		; d2 = bytes
	move.w	(a2)+,d3		; d3 = kind
	move.l	a3,a1			; a1 = in the area
	add.l	d2,a3
	tst.l	d4			; a0 = from, a1 = to
	beq.s	.dir
	exg	a0,a1
.dir:
	cmp.w	#2,d3
	beq.s	.e			; (not kept)
	tst.w	d3
	bne.s	.str
	move.l	d2,d1			; copied: longs, then the bytes left
	lsr.l	#2,d1
	bra.s	.ls
.l:	move.l	(a0)+,(a1)+
.ls:	dbf	d1,.l
	and.w	#3,d2
	bra.s	.bs
.b:	move.b	(a0)+,(a1)+
.bs:	dbf	d2,.b
	bra.s	.e
.str:	subq.w	#1,d2			; a string: up to its NUL
.s:	move.b	(a0)+,(a1)+
	dbeq	d2,.s
	bra.s	.e
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts
