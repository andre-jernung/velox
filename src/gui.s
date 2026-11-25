;
; gui.s - browser window: toolbar, page view, scroller, status line,
;         fonts, colours, painting and input
;

	include	"velox.i"
	include	"graphics/text.i"
	include	"graphics/gfx.i"
	include	"graphics/view.i"
	include	"graphics/clip.i"
	include	"graphics/layers.i"
	include	"devices/inputevent.i"
	include	"lvo/gadtools_lib.i"
	include	"lvo/layers_lib.i"
	include	"lvo/diskfont_lib.i"
	include	"lvo/asl_lib.i"

	xdef	GuiOpen,GuiClose,GuiEventLoop,GuiPaintAll,GuiStatus,GuiPaintNode,GuiPaintImage
	xdef	GuiSetUrl,GuiSetTitle,GuiScrollTo,GuiNetHook,GuiBusy
	xdef	GuiBlank,GuiUnblank,GuiProgSet,GuiBgCame
	xref	FrameShow,FramesPage,FramesLayout,FrameAt,ViewSelect,ViewSlot
	xdef	GuiLayout,BusyEvents,GuiRelayout,GuiRefresh,GuiPageWidth,GuiAbout,DrawStatus,ImgNetHook,GuiProgress
	IFD	PROFILE
	xref	ProfRead,ProfLog
	ENDC
	xref	FindStart,FindKey,FindHighlight,KeyToChars,NavRefresh
	xref	CopyAddress,ViewSource,SelPress,SelMove,SelRelease,SelHighlight,ParseDec,FmtDec,StrCopy
	xref	LayoutDocument,RunCount,RunPtr,StrLen,StrCopyN
	xref	NavGo,NavBack,NavForward,NavReload,NavHome,NavLink,UrlFixup
	xref	DomGetAttr,LogEvent,FormStateOf,FormIsControl,FormActivate
	xref	FormEditKey,FormLeave,SaveDownload,BookmarkAdd,BookmarksShow
	xref	PalFree,ImagesStop,ImagesPending,ImagesStep,ImagesFree,ImagePaint
	xref	KeepFreeAll
	xref	TaskResume,TaskLoopWait,TaskBusy,TaskAbort,NavStop,ImagesReap,ImagesReapNow,ImagesQuit,FragCheck,TaskNow

PROP_FONT	equ	0
SCROLL_W	equ	18

GID_BACK	equ	1
GID_FWD		equ	2
GID_RELOAD	equ	3
GID_HOME	equ	4
GID_URL		equ	5
GID_SCROLL	equ	6

RAW_UP		equ	$4c
RAW_DOWN	equ	$4d
RAW_SPACE	equ	$40
RAW_BACKSPACE	equ	$41
RAW_WHEELUP	equ	$7a
RAW_WHEELDOWN	equ	$7b
RAW_TAB		equ	$42
RAW_ENTER	equ	$43
RAW_RETURN	equ	$44
RAW_ESC		equ	$45
RAW_Q		equ	$10
RAW_R		equ	$13
RAW_F		equ	$23
RAW_H		equ	$25
RAW_L		equ	$28
RAW_B		equ	$35
RAW_D		equ	$22
RAW_K		equ	$27
WIDGET_FACE	equ	$aaaaaa		; button face colour
QUAL_COMMAND	equ	IEQUALIFIER_CONTROL|IEQUALIFIER_LCOMMAND|IEQUALIFIER_RCOMMAND

	section	code,code

;--------------------------------------------------------------------
; GuiOpen - lock the screen, load fonts, open the window
; Out: d0 = 0 on failure
;--------------------------------------------------------------------
GuiOpen:
	movem.l	d2/a2,-(sp)
	lea	g_PubScreen(a4),a0	; a named public screen, or the
	tst.b	(a0)			; default one
	beq.s	.def
	INTUI	LockPubScreen
	move.l	d0,g_Screen(a4)
	bne.s	.scr
.def:	suba.l	a0,a0
	INTUI	LockPubScreen
	move.l	d0,g_Screen(a4)
	beq	.fail
.scr:
	move.l	d0,a0
	move.l	sc_ViewPort+vp_ColorMap(a0),g_ColorMap(a4)
	suba.l	a1,a1
	move.l	a0,-(sp)
	GT	GetVisualInfoA
	movem.l	(sp)+,a0
	move.l	d0,g_VisualInfo(a4)
	beq	.fail
	bsr	ScreenPens
	bsr	FontsInit
	beq	.fail
	lea	DtName(pc),a1		; optional: images
	moveq	#39,d0
	EXEC	OpenLibrary
	move.l	d0,g_DataTypesBase(a4)
	lea	ImagesFree,a0
	move.l	a0,g_PageFreeHook(a4)
	lea	g_MeasRP(a4),a1
	GFX	InitRastPort
	moveq	#-1,d0
	move.l	d0,g_MeasFont(a4)
	move.l	d0,g_MeasFont+4(a4)
	lea	GuiMeasure(pc),a0
	move.l	a0,g_MeasureFn(a4)
	clr.l	g_PageFg(a4)
	move.l	#$ffffff,g_PageBg(a4)
	move.l	#$0000cc,g_LinkColor(a4)

	; window size: 640x400, or the screen if smaller
	move.l	g_Screen(a4),a0
	moveq	#0,d0
	move.w	sc_Width(a0),d0
	cmp.l	#640,d0
	bls.s	.w
	move.l	#640,d0
.w:	move.l	d0,WinTagW+4
	moveq	#0,d0
	move.w	sc_Height(a0),d0
	moveq	#0,d1
	move.b	sc_BarHeight(a0),d1
	addq.l	#1,d1
	sub.l	d1,d0
	cmp.l	#460,d0
	bls.s	.h
	move.l	#460,d0
.h:	move.l	d0,WinTagH+4
	move.l	d1,WinTagT+4
	bsr	WinGeometry		; as it was last time
	move.l	g_Screen(a4),WinTagScr+4
	suba.l	a0,a0
	lea	WinTags,a1
	INTUI	OpenWindowTagList
	move.l	d0,g_Window(a4)
	beq.s	.fail
	move.l	d0,a0
	move.l	wd_UserPort(a0),a1
	moveq	#0,d0
	move.b	MP_SIGBIT(a1),d1
	bset	d1,d0
	move.l	d0,g_WinSigMask(a4)
	move.l	wd_RPort(a0),a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	bsr	CreateGadgets
	beq.s	.fail
	move.l	g_Window(a4),a2		; (the page origin on the screen,
	moveq	#0,d0			; for tests that use the mouse)
	move.w	wd_LeftEdge(a2),d0
	add.l	g_PageX(a4),d0
	lea	LogPageX(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	moveq	#0,d0
	move.w	wd_TopEdge(a2),d0
	add.l	g_PageY(a4),d0
	lea	LogPageY(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	bsr	CreateMenus		; (no menus is not fatal)
	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2
	rts

; CreateMenus - GadTools menus for the window
CreateMenus:
	lea	NewMenus,a0
	suba.l	a1,a1
	GT	CreateMenusA
	move.l	d0,g_Menu(a4)
	beq.s	.x
	move.l	d0,a0
	move.l	g_VisualInfo(a4),a1
	lea	MenuTags(pc),a2
	GT	LayoutMenusA
	tst.l	d0
	beq.s	.x
	move.l	g_Window(a4),a0
	move.l	g_Menu(a4),a1
	INTUI	SetMenuStrip
.x:	rts

MenuTags:	dc.l	GTMN_NewLookMenus,1,TAG_DONE

;--------------------------------------------------------------------
; GuiClose - close everything GuiOpen opened (safe on partial opens)
;--------------------------------------------------------------------
GuiClose:
	bsr	StripFree
	move.l	g_Window(a4),d0
	beq.s	.nowin
	tst.l	g_Menu(a4)
	beq.s	.nomenu
	move.l	d0,a0
	INTUI	ClearMenuStrip
	move.l	g_Window(a4),d0
.nomenu:
	move.l	d0,a0
	move.l	g_GList(a4),d0
	beq.s	.nogl
	move.l	d0,a1
	moveq	#-1,d0
	INTUI	RemoveGList
.nogl:	bsr	SaveGeometry
	move.l	g_Window(a4),a0
	clr.l	g_Window(a4)
	INTUI	CloseWindow
.nowin:	move.l	g_Menu(a4),a0
	clr.l	g_Menu(a4)
	GT	FreeMenus
	move.l	g_GList(a4),a0
	clr.l	g_GList(a4)
	GT	FreeGadgets
	jsr	KeepFreeAll		; (pages kept for Back: their images)
	jsr	ImagesFree		; (before the screen goes)
	clr.l	g_PageFreeHook(a4)
	move.l	g_DataTypesBase(a4),d0
	beq.s	.nodt
	clr.l	g_DataTypesBase(a4)
	move.l	d0,a1
	EXEC	CloseLibrary
.nodt:	jsr	PalFree			; (the image pens)
	bsr	PensRelease
	bsr	FontsExit
	move.l	g_VisualInfo(a4),a0
	clr.l	g_VisualInfo(a4)
	GT	FreeVisualInfo
	move.l	g_Screen(a4),d0
	beq.s	.x
	clr.l	g_Screen(a4)
	move.l	d0,a1
	suba.l	a0,a0
	INTUI	UnlockPubScreen
.x:	rts

;--------------------------------------------------------------------
; Fonts
;--------------------------------------------------------------------
FontsInit:
	movem.l	d2-d3/a2-a3,-(sp)
	lea	DiskfontName(pc),a1
	moveq	#36,d0
	EXEC	OpenLibrary
	move.l	d0,g_DiskfontBase(a4)	; optional
	move.l	g_Screen(a4),a0
	move.l	sc_Font(a0),a0
	GFX	OpenFont
	move.l	d0,g_ScreenFont(a4)
	beq	.fail
	moveq	#0,d2			; font index
.l:	cmp.w	#FONT_COUNT,d2
	bhs	.done
	move.w	d2,d0
	and.w	#7,d0
	cmp.w	#FONT_SIZES-1,d0
	bls.s	.s
	moveq	#FONT_SIZES-1,d0
.s:	add.w	d0,d0
	lea	g_TextAttr(a4),a0
	btst	#3,d2			; FONT_MONO
	bne.s	.mono
	lea	PropName(pc),a1
	move.l	a1,ta_Name(a0)
	move.w	PropSizes(pc,d0.w),ta_YSize(a0)
	bra.s	.open
.mono:	lea	MonoName(pc),a1
	move.l	a1,ta_Name(a0)
	move.w	MonoSizes(pc,d0.w),ta_YSize(a0)
.open:	clr.w	ta_Style(a0)		; and ta_Flags
	bsr	OpenAFont
	bne.s	.got
	move.l	g_ScreenFont(a4),d0	; fall back to the screen font
	moveq	#0,d1
	bra.s	.set
.got:	moveq	#1,d1
.set:	lea	g_FontPtr(a4),a0
	move.l	d0,(a0,d2.w*4)
	lea	g_FontOwned(a4),a0
	move.b	d1,(a0,d2.w)
	move.l	d0,a1
	lea	g_FontH(a4),a0
	move.w	tf_YSize(a1),(a0,d2.w*2)
	lea	g_FontBase(a4),a0
	move.w	tf_Baseline(a1),(a0,d2.w*2)
	addq.w	#1,d2
	bra	.l
.done:	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

DtName:		dc.b	"datatypes.library",0
	even
PropSizes:	dc.w	9,11,13,15,18,24
MonoSizes:	dc.w	11,11,13,15,18,24
PropName:	dc.b	"helvetica.font",0
MonoName:	dc.b	"courier.font",0
DiskfontName:	dc.b	"diskfont.library",0
	even

; OpenAFont - open g_TextAttr from memory or disk; Out: d0 = font or 0
OpenAFont:
	lea	g_TextAttr(a4),a0
	GFX	OpenFont		; already in memory (or ROM)?
	tst.l	d0
	beq.s	.disk
	move.l	d0,a1			; only take an exact size
	lea	g_TextAttr(a4),a0
	move.w	ta_YSize(a0),d1
	cmp.w	tf_YSize(a1),d1
	beq.s	.x
	GFX	CloseFont
.disk:	move.l	g_DiskfontBase(a4),d0
	beq.s	.x
	move.l	d0,a6
	lea	g_TextAttr(a4),a0
	jsr	_LVOOpenDiskFont(a6)
.x:	tst.l	d0
	rts

FontsExit:
	movem.l	d2,-(sp)
	moveq	#FONT_COUNT-1,d2
.l:	lea	g_FontOwned(a4),a0
	tst.b	(a0,d2.w)
	beq.s	.n
	clr.b	(a0,d2.w)
	lea	g_FontPtr(a4),a0
	move.l	(a0,d2.w*4),a1
	GFX	CloseFont
.n:	dbf	d2,.l
	move.l	g_ScreenFont(a4),d0
	beq.s	.nsf
	clr.l	g_ScreenFont(a4)
	move.l	d0,a1
	GFX	CloseFont
.nsf:	move.l	g_DiskfontBase(a4),d0
	beq.s	.x
	clr.l	g_DiskfontBase(a4)
	move.l	d0,a1
	EXEC	CloseLibrary
.x:	movem.l	(sp)+,d2
	rts

; SetRPFont - select font/style in a RastPort, avoiding redundant calls
; In: a1 = RastPort, d0 = font | soft << 8, a0 = cache (2 longs)
SetRPFont:
	movem.l	d2/a2-a3,-(sp)
	move.l	a1,a2
	move.l	a0,a3
	move.l	d0,d2
	moveq	#0,d0
	move.b	d2,d0
	cmp.l	(a3),d0
	beq.s	.same
	move.l	d0,(a3)
	moveq	#-1,d0			; SetFont resets the soft style
	move.l	d0,4(a3)
	move.l	(a3),d0
	lea	g_FontPtr(a4),a0
	move.l	(a0,d0.w*4),a0
	move.l	a2,a1
	GFX	SetFont
.same:	move.w	d2,d0
	lsr.w	#8,d0
	and.l	#7,d0
	cmp.l	4(a3),d0
	beq.s	.x
	move.l	d0,4(a3)
	move.l	a2,a1
	moveq	#7,d1
	GFX	SetSoftStyle
.x:	movem.l	(sp)+,d2/a2-a3
	rts

; GuiMeasure - the layout measure function (see g_MeasureFn)
GuiMeasure:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	d1,d2
	lea	g_MeasRP(a4),a1
	lea	g_MeasFont(a4),a0
	bsr.s	SetRPFont
	lea	g_MeasRP(a4),a1
	move.l	a2,a0
	move.l	d2,d0
	GFX	TextLength
	ext.l	d0
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; Pens: RGB -> best pen of the screen, cached
;--------------------------------------------------------------------
; GetPen - In: d0 = $RRGGBB; Out: d0 = pen
GetPen:
	movem.l	d2-d4/a2,-(sp)
	move.l	d0,d4			; colour
	lea	g_PenCache(a4),a2
	move.l	g_PenCount(a4),d3
	bra.s	.s
.l:	cmp.l	(a2),d4
	beq.s	.hit
	addq.l	#8,a2
.s:	dbf	d3,.l
	; ObtainBestPenA(a0 = cm, d1 = r, d2 = g, d3 = b, a1 = tags),
	; components as 32 bit fractions
	move.l	d4,d1
	swap	d1
	and.l	#$ff,d1
	mulu.l	#$01010101,d1
	move.l	d4,d2
	lsr.l	#8,d2
	and.l	#$ff,d2
	mulu.l	#$01010101,d2
	move.l	d4,d3
	and.l	#$ff,d3
	mulu.l	#$01010101,d3
	move.l	g_ColorMap(a4),a0
	lea	PenTags(pc),a1
	GFX	ObtainBestPenA
	tst.l	d0
	bpl.s	.ok
	moveq	#1,d0			; no pen: use pen 1
	bra.s	.x
.ok:	cmp.l	#PEN_CACHE,g_PenCount(a4)
	bhs.s	.x			; cache full: released at exit anyway
	move.l	g_PenCount(a4),d1
	lea	g_PenCache(a4),a2
	lsl.l	#3,d1
	add.l	d1,a2
	move.l	d4,(a2)
	move.l	d0,4(a2)
	addq.l	#1,g_PenCount(a4)
	bra.s	.x
.hit:	move.l	4(a2),d0
.x:	movem.l	(sp)+,d2-d4/a2
	rts

PenTags:	dc.l	OBP_Precision,PRECISION_IMAGE,TAG_DONE

PensRelease:
	movem.l	d2/a2,-(sp)
	lea	g_PenCache(a4),a2
	move.l	g_PenCount(a4),d2
	clr.l	g_PenCount(a4)
	bra.s	.s
.l:	move.l	g_ColorMap(a4),a0
	move.l	4(a2),d0
	GFX	ReleasePen
	addq.l	#8,a2
.s:	dbf	d2,.l
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; Gadgets and window geometry
;--------------------------------------------------------------------

; CreateGadgets - compute geometry, build the gadget list, add it
; Out: d0 = 0 on failure
CreateGadgets:
	movem.l	d2-d6/a2-a3,-(sp)
	move.l	g_Window(a4),a3
	move.l	g_Screen(a4),a0
	move.l	sc_Font(a0),a0
	moveq	#0,d5
	move.w	ta_YSize(a0),d5		; d5 = screen font height
	move.l	d5,d6
	addq.l	#6,d6			; d6 = gadget height
	moveq	#0,d2
	move.b	wd_BorderLeft(a3),d2
	addq.l	#2,d2			; d2 = x
	moveq	#0,d3
	move.b	wd_BorderTop(a3),d3
	addq.l	#2,d3			; d3 = y of the toolbar
	; page area and status line
	move.l	d3,d0
	add.l	d6,d0
	addq.l	#3,d0
	move.l	d0,g_PageY(a4)
	moveq	#0,d0
	move.b	wd_BorderLeft(a3),d0
	move.l	d0,g_PageX(a4)
	move.w	wd_Width(a3),d0
	ext.l	d0
	moveq	#0,d1
	move.b	wd_BorderRight(a3),d1
	sub.l	d1,d0
	sub.l	#SCROLL_W,d0
	sub.l	g_PageX(a4),d0
	move.l	d0,g_PageW(a4)
	move.w	wd_Height(a3),d0
	ext.l	d0
	moveq	#0,d1
	move.b	wd_BorderBottom(a3),d1
	sub.l	d1,d0
	sub.l	d5,d0
	subq.l	#4,d0
	move.l	d0,g_StatusY(a4)
	sub.l	g_PageY(a4),d0
	subq.l	#1,d0
	bgt.s	.hok
	moveq	#1,d0
.hok:	move.l	d0,g_PageH(a4)

	; clear the toolbar and status areas
	bsr	ClearChrome

	lea	g_GList(a4),a0
	GT	CreateContext
	move.l	d0,a2			; previous gadget
	lea	g_NewGad(a4),a1
	move.l	g_VisualInfo(a4),gng_VisualInfo(a1)
	move.l	g_Screen(a4),a0
	move.l	sc_Font(a0),gng_TextAttr(a1)
	move.w	d3,gng_TopEdge(a1)
	move.w	d6,gng_Height(a1)
	clr.l	gng_Flags(a1)
	; buttons
	lea	ButtonDefs(pc),a3
.btn:	move.w	(a3)+,d4		; id, 0 = end
	beq.s	.btnd
	lea	ButtonDefs(pc),a0
	add.w	(a3)+,a0		; label
	lea	g_NewGad(a4),a1
	move.w	d4,gng_GadgetID(a1)
	move.w	d2,gng_LeftEdge(a1)
	move.l	a0,gng_GadgetText(a1)
	jsr	StrLen			; (keeps a0)
	move.l	g_Window(a4),a1
	move.l	wd_RPort(a1),a1
	GFX	TextLength
	ext.l	d0
	add.l	#16,d0
	lea	g_NewGad(a4),a1
	move.w	d0,gng_Width(a1)
	add.l	d0,d2
	addq.l	#2,d2
	moveq	#BUTTON_KIND,d0
	move.l	a2,a0			; previous gadget
	suba.l	a2,a2			; no tags
	GT	CreateGadgetA
	move.l	d0,a2
	bra.s	.btn
.btnd:	; URL string gadget fills the rest of the toolbar
	lea	g_NewGad(a4),a1
	addq.l	#2,d2
	move.w	d2,gng_LeftEdge(a1)
	move.l	g_Window(a4),a0
	move.w	wd_Width(a0),d0
	moveq	#0,d1
	move.b	wd_BorderRight(a0),d1
	sub.w	d1,d0
	sub.w	d2,d0
	subq.w	#4,d0
	cmp.w	#40,d0
	bge.s	.uw
	moveq	#40,d0
.uw:	move.w	d0,gng_Width(a1)
	clr.l	gng_GadgetText(a1)
	move.w	#GID_URL,gng_GadgetID(a1)
	lea	g_PageUrl(a4),a0
	move.l	a0,UrlTags+12
	move.l	a2,a0
	lea	UrlTags,a2
	moveq	#STRING_KIND,d0
	GT	CreateGadgetA
	move.l	d0,g_GadUrl(a4)
	move.l	d0,a2
	; scroller at the right of the page
	lea	g_NewGad(a4),a1
	move.l	g_PageX(a4),d0
	add.l	g_PageW(a4),d0
	move.w	d0,gng_LeftEdge(a1)
	move.w	g_PageY+2(a4),gng_TopEdge(a1)
	move.w	#SCROLL_W,gng_Width(a1)
	move.w	g_PageH+2(a4),gng_Height(a1)
	move.w	#GID_SCROLL,gng_GadgetID(a1)
	move.l	a2,a0
	lea	ScrollTags,a2
	moveq	#SCROLLER_KIND,d0
	GT	CreateGadgetA
	move.l	d0,g_GadScroll(a4)
	beq.s	.fail
	move.l	g_Window(a4),a0
	move.l	g_GList(a4),a1
	moveq	#-1,d0
	moveq	#-1,d1
	suba.l	a2,a2
	INTUI	AddGList
	move.l	g_GList(a4),a0
	move.l	g_Window(a4),a1
	suba.l	a2,a2
	moveq	#-1,d0
	INTUI	RefreshGList
	move.l	g_Window(a4),a0
	suba.l	a1,a1
	GT	GT_RefreshWindow
	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d6/a2-a3
	rts

ButtonDefs:
	dc.w	GID_BACK,LBack-ButtonDefs
	dc.w	GID_FWD,LFwd-ButtonDefs
	dc.w	GID_RELOAD,LReload-ButtonDefs
	dc.w	GID_HOME,LHome-ButtonDefs
	dc.w	0
LBack:		dc.b	"<",0
LFwd:		dc.b	">",0
LReload:	dc.b	"Reload",0
LHome:		dc.b	"Home",0
	even

; ClearChrome - clear the window inside its borders (toolbar, status)
ClearChrome:
	movem.l	d2-d3/a2,-(sp)
	move.l	g_Window(a4),a2
	move.l	wd_RPort(a2),a1
	moveq	#0,d0
	GFX	SetAPen
	bsr	InnerBox
	move.l	wd_RPort(a2),a1
	cmp.l	d0,d2
	ble.s	.x
	cmp.l	d1,d3
	ble.s	.x
	GFX	RectFill
.x:	movem.l	(sp)+,d2-d3/a2
	rts

; InnerBox - In: a2 = window; Out: d0-d3 = inner MinX, MinY, MaxX, MaxY
InnerBox:
	moveq	#0,d0
	move.b	wd_BorderLeft(a2),d0
	moveq	#0,d1
	move.b	wd_BorderTop(a2),d1
	move.w	wd_Width(a2),d2
	ext.l	d2
	moveq	#0,d3
	move.b	wd_BorderRight(a2),d3
	sub.l	d3,d2
	subq.l	#1,d2
	move.w	wd_Height(a2),d3
	ext.l	d3
	move.l	d0,-(sp)
	moveq	#0,d0
	move.b	wd_BorderBottom(a2),d0
	sub.l	d0,d3
	subq.l	#1,d3
	movem.l	(sp)+,d0
	rts

; GuiPageWidth - Out: d0 = width available for layout
GuiPageWidth:
	move.l	g_PageW(a4),d0
	rts

;--------------------------------------------------------------------
; Painting
;--------------------------------------------------------------------

; GuiPaintAll - repaint page, status line and scroller
GuiPaintAll:
	clr.l	g_BandsOk(a4)
	move.l	g_FrViewN(a4),d1	; (the frames' views too)
	beq.s	GuiRefresh
.fa:	cmp.l	g_ViewCur(a4),d1
	beq.s	.fn
	move.l	d1,d0
	jsr	ViewSlot
	clr.l	g_BandsOk-g_View(a0)
.fn:	subq.l	#1,d1
	bne.s	.fa
	; fall through

;--------------------------------------------------------------------
; GuiRefresh - bring the view up to date after the runs changed:
; only the bands (BAND_H lines) whose runs look different from what is
; on the screen are painted (all of them if that is not known)
;--------------------------------------------------------------------
GuiRefresh:
	tst.l	g_Blank(a4)		; a new page loading: blank
	bne	PaintBlank
	tst.l	g_FrN(a4)		; a page of frames: each frame's view
	beq.s	RefreshView
	tst.l	g_InFrames(a4)
	beq	RefreshFrames
; RefreshView - GuiRefresh of the view in G
RefreshView:
	movem.l	d2-d6/a2-a3,-(sp)
	tst.l	g_Window(a4)
	beq	.x
	moveq	#0,d6			; lines painted (logged for tests)
	move.l	g_PageH(a4),d2
	addq.l	#BAND_H-1,d2
	lsr.l	#BAND_SHIFT,d2		; d2 = bands
	cmp.l	#BANDS_MAX,d2
	bls.s	.fits
	clr.l	g_BandsOk(a4)		; too tall to keep track of
	bra.s	.all
.fits:	move.l	d2,g_BandN(a4)
	lea	ViewKey(pc),a0		; the same view as on the screen?
	lea	g_BandView(a4),a1
.k:	move.w	(a0)+,d0
	beq.s	.samev
	move.l	(a4,d0.w),d0
	cmp.l	(a1),d0
	beq.s	.ks
	clr.l	g_BandsOk(a4)
	move.l	d0,(a1)
.ks:	addq.l	#4,a1
	bra.s	.k
.samev:	lea	g_BandsNew(a4),a0
	bsr	ViewBands
	tst.l	g_BandsOk(a4)
	beq.s	.all
	lea	g_Bands(a4),a2
	lea	g_BandsNew(a4),a3
	moveq	#0,d3			; band
.f:	cmp.l	d2,d3
	bhs.s	.keep
	move.l	(a2,d3.l*4),d0
	cmp.l	(a3,d3.l*4),d0
	bne.s	.diff
	addq.l	#1,d3
	bra.s	.f
.diff:	move.l	d3,d4			; first changed band
	move.l	d3,d5			; last changed band
.g:	addq.l	#1,d3			; (close changes are painted together,
	cmp.l	d2,d3			;  64 lines at most: the user first)
	bhs.s	.p
	move.l	d3,d0
	sub.l	d4,d0
	cmp.l	#16,d0
	bhs.s	.p
	move.l	(a2,d3.l*4),d0
	cmp.l	(a3,d3.l*4),d0
	beq.s	.eq
	move.l	d3,d5
.eq:	move.l	d3,d0
	sub.l	d5,d0
	cmp.l	#BAND_GAP,d0
	blo.s	.g
.p:	move.l	d4,d0
	lsl.l	#BAND_SHIFT,d0
	add.l	g_ScrollY(a4),d0
	move.l	d5,d1
	addq.l	#1,d1
	lsl.l	#BAND_SHIFT,d1
	add.l	g_ScrollY(a4),d1
	add.l	d1,d6
	sub.l	d0,d6
	bsr	PaintRange
	move.l	d5,d3
	addq.l	#1,d3
	bsr	MsgWaiting		; the user first: the rest later
	beq.s	.f
	bra.s	.cut
.all:	cmp.l	#BANDS_MAX,d2		; all of it: 64 lines at a time, the
	bhi.s	.whole			; user first
	moveq	#0,d3
.ac:	move.l	d3,d4
	add.l	#16,d4
	cmp.l	d2,d4
	bls.s	.ae
	move.l	d2,d4
.ae:	move.l	d3,d0
	lsl.l	#BAND_SHIFT,d0
	move.l	d4,d1
	lsl.l	#BAND_SHIFT,d1
	cmp.l	g_PageH(a4),d1
	bls.s	.ah
	move.l	g_PageH(a4),d1
.ah:	add.l	d1,d6
	sub.l	d0,d6
	add.l	g_ScrollY(a4),d0
	add.l	g_ScrollY(a4),d1
	bsr	PaintRange
	move.l	d4,d3
	cmp.l	d2,d3
	bhs.s	.keep
	bsr	MsgWaiting
	beq.s	.ac
	lea	g_BandsNew(a4),a0	; (not painted yet: not what is on
	lea	g_Bands(a4),a1		;  the screen)
	move.l	d3,d0
.nv:	move.l	(a0,d0.l*4),d1
	not.l	d1
	move.l	d1,(a1,d0.l*4)
	addq.l	#1,d0
	cmp.l	d2,d0
	blo.s	.nv
.cut:	neg.l	d6			; (logged negative: cut short)
	lea	g_BandsNew(a4),a0	; cut short: the bands before d3 as
	lea	g_Bands(a4),a1		; now, the others as they were;
	move.l	d3,d0			; the event loop paints the rest
	bra.s	.cue			; (g_RefreshPend)
.cu:	move.l	(a0)+,(a1)+
.cue:	dbf	d0,.cu
	moveq	#1,d0
	move.l	d0,g_BandsOk(a4)
	move.l	d0,g_RefreshPend(a4)
	bra.s	.done
.whole:	move.l	g_ScrollY(a4),d0
	move.l	g_PageH(a4),d6
	move.l	d0,d1
	add.l	d6,d1
	bsr	PaintRange
	bra.s	.done
.keep:	lea	g_BandsNew(a4),a0	; that is on the screen now
	lea	g_Bands(a4),a1
	move.l	d2,d0
	bra.s	.ce
.c:	move.l	(a0)+,(a1)+
.ce:	dbf	d0,.c
	moveq	#1,d0
	move.l	d0,g_BandsOk(a4)
.done:	lea	LogPaint(pc),a0
	suba.l	a1,a1
	move.l	d6,d0
	jsr	LogEvent
	bsr	DrawStatus
	bsr	UpdateScroller
.x:	movem.l	(sp)+,d2-d6/a2-a3
	rts

; MsgWaiting - Out: d0 = 1 if a window message waits (CCR set)
MsgWaiting:
	move.l	g_Window(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	wd_UserPort(a0),a0
	lea	MP_MSGLIST(a0),a0
	cmp.l	LH_TAILPRED(a0),a0	; (an empty list points to itself)
	sne	d0
	and.l	#1,d0
.x:	rts

; RefreshFrames - (GuiRefresh, a page of frames) each frame's view up
; to date, the borders between them, the scroller the active frame's
RefreshFrames:
	move.l	d2,-(sp)
	move.l	g_ViewCur(a4),-(sp)
	moveq	#1,d0
	move.l	d0,g_InFrames(a4)
	moveq	#1,d2
.l:	cmp.l	g_FrN(a4),d2
	bhi.s	.d
	move.l	d2,d0
	jsr	ViewSelect
	bsr	RefreshView
	tst.l	g_RefreshPend(a4)	; (cut short for the user: the rest
	bne.s	.d			;  later)
	addq.l	#1,d2
	bra.s	.l
.d:	clr.l	g_InFrames(a4)
	bsr	PaintGaps
	move.l	g_FrActive(a4),d0
	jsr	ViewSelect
	bsr	UpdateScroller
	move.l	(sp)+,d0
	jsr	ViewSelect
	move.l	(sp)+,d2
	rts

; PaintGaps - the borders between the frames
PaintGaps:
	movem.l	d2-d4/a2,-(sp)
	move.l	g_Window(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	wd_RPort(a0),a2
	move.l	a2,a1
	moveq	#0,d0
	GFX	SetAPen
	moveq	#0,d4
.l:	cmp.l	g_FrGapN(a4),d4
	bhs.s	.x
	move.l	d4,d0
	lsl.l	#4,d0
	lea	g_FrGap(a4),a0
	add.l	d0,a0
	movem.l	(a0),d0-d3
	add.l	d0,d2
	subq.l	#1,d2
	add.l	d1,d3
	subq.l	#1,d3
	move.l	a2,a1
	GFX	RectFill
	addq.l	#1,d4
	bra.s	.l
.x:	movem.l	(sp)+,d2-d4/a2
	rts

; GuiBgCame - background image record a0 came: views whose page
; background it is are painted all again
GuiBgCame:
	move.l	a0,a1
	cmp.l	g_PageBgRec(a4),a1
	bne.s	.f
	clr.l	g_BandsOk(a4)
.f:	move.l	g_FrViewN(a4),d1
	beq.s	.x
.l:	cmp.l	g_ViewCur(a4),d1
	beq.s	.n
	move.l	d1,d0
	jsr	ViewSlot
	cmp.l	g_PageBgRec-g_View(a0),a1
	bne.s	.n
	clr.l	g_BandsOk-g_View(a0)
.n:	subq.l	#1,d1
	bne.s	.l
.x:	rts

; what the bands depend on besides the runs (a highlight cleared by a
; relayout, too)
ViewKey:	dc.w	g_PageW,g_PageH,g_PageBg,g_PageBgRec,g_FindRun,g_SelShown,0
	IFNE	(*-ViewKey)/2-1-VIEWKEYS
	FAIL	"ViewKey: VIEWKEYS (velox.i) must match"
	ENDIF
LogPaint:	dc.b	"paint",0
LogFScroll:	dc.b	"fscroll",0
	even

; ViewBands - the signature of each band of the view, into a0
; (g_BandN longs): a hash of the runs over it, in painting order
ViewBands:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	a0,a3
	move.l	g_BandN(a4),d0
	bra.s	.ce
.c:	clr.l	(a0)+
.ce:	dbf	d0,.c
	jsr	RunCount
	move.l	d0,d7
	moveq	#0,d6
.l:	cmp.l	d7,d6
	bhs.s	.x
	move.l	d6,d0
	jsr	RunPtr
	move.l	a0,a2
	move.l	ru_Y(a2),d4
	sub.l	g_ScrollY(a4),d4	; view y of the top
	moveq	#0,d5
	move.w	ru_H(a2),d5
	add.l	d4,d5			; ... and below the bottom
	ble.s	.n
	cmp.l	g_PageH(a4),d4
	bge.s	.n
	bsr	RunSig
	tst.l	d4
	bpl.s	.t
	moveq	#0,d4
.t:	cmp.l	g_PageH(a4),d5
	ble.s	.b
	move.l	g_PageH(a4),d5
.b:	subq.l	#1,d5
	lsr.l	#BAND_SHIFT,d4
	lsr.l	#BAND_SHIFT,d5
	lea	(a3,d4.l*4),a0
.m:	move.l	(a0),d1
	rol.l	#5,d1
	add.l	d0,d1
	move.l	d1,(a0)+
	addq.l	#1,d4
	cmp.l	d5,d4
	bls.s	.m
.n:	addq.l	#1,d6
	bra.s	.l
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; RunSig - a hash of how run a2 looks in the view
; Out: d0
RunSig:
	movem.l	d2,-(sp)
	move.l	ru_Y(a2),d0
	sub.l	g_ScrollY(a4),d0
	lea	ru_X(a2),a0		; X W H Base Type Font Soft Flags Color
	moveq	#4-1,d2
.f:	rol.l	#5,d0
	add.l	(a0)+,d0
	dbf	d2,.f
	rol.l	#5,d0
	add.l	ru_Len(a2),d0
	move.l	ru_Link(a2),d1		; the keyboard focus is drawn
	beq.s	.nf
	cmp.l	g_FocusLink(a4),d1
	bne.s	.nf
	addq.l	#1,d0
.nf:	cmp.b	#RT_TEXT,ru_Type(a2)
	beq.s	.text
	cmp.b	#RT_WIDGET,ru_Type(a2)	; controls and images: the same only
	beq.s	.page			; on the same page
	cmp.b	#RT_IMAGE,ru_Type(a2)
	beq.s	.img
	cmp.b	#RT_RECT,ru_Type(a2)	; a background image (its record
	bne.s	.x			; has bg_Info where n_Data2 is)
	tst.l	ru_Text(a2)
	beq.s	.x
.img:	move.l	ru_Text(a2),a0		; loaded or not
	rol.l	#5,d0
	add.l	n_Data2(a0),d0
.page:	rol.l	#5,d0
	add.l	ru_Text(a2),d0
	rol.l	#5,d0
	add.l	g_PageGen(a4),d0
	bra.s	.x
.text:	move.l	ru_Text(a2),a0		; the characters
	move.l	ru_Len(a2),d2
	beq.s	.x
.t:	rol.l	#5,d0
	moveq	#0,d1
	move.b	(a0)+,d1
	add.l	d1,d0
	subq.l	#1,d2
	bne.s	.t
.x:	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; PageBgImage - the page's background image (if loaded) over d0/d1 -
; d2/d3 (window coordinates as the view is set up), from the top left
; of the document
;--------------------------------------------------------------------
PageBgImage:
	movem.l	d0-d3,g_TlX0(a4)	; (TlX0, TlY0, TlX1, TlY1)
	move.l	g_PageBgRec(a4),d0
	beq.s	.x
	move.l	d0,a0
	tst.l	bg_Info(a0)
	beq.s	.x
	move.l	g_PageX(a4),g_TlOX(a4)
	move.l	g_PageY(a4),d0
	sub.l	g_ScrollY(a4),d0
	move.l	d0,g_TlOY(a4)
	move.l	g_PageBgRep(a4),g_TlRep(a4)
	move.l	a3,a1
	bra	TileRect
.x:	rts

;--------------------------------------------------------------------
; TileRect - a background image (record a0) repeated over the area
; g_TlX0/Y0 - X1/Y1 of RastPort a1, clipped to the view: tiles from the
; origin g_TlOX/OY, repeated across (g_TlRep bit 0) and down (bit 1)
;--------------------------------------------------------------------
TileRect:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a5			; a5 = record
	move.l	a1,a3			; a3 = RastPort
	move.l	bg_Info(a5),a2		; a2 = its ImageInfo
	; the area, within the view
	move.l	g_TlY0(a4),d0
	move.l	g_PageY(a4),d1
	cmp.l	d1,d0
	bge.s	.y0
	move.l	d1,d0
.y0:	move.l	d0,g_TlY0(a4)
	add.l	g_PageH(a4),d1
	subq.l	#1,d1
	cmp.l	g_TlY1(a4),d1
	bge.s	.y1
	move.l	d1,g_TlY1(a4)
.y1:	move.l	g_TlX0(a4),d0
	move.l	g_PageX(a4),d1
	cmp.l	d1,d0
	bge.s	.x0
	move.l	d1,d0
.x0:	move.l	d0,g_TlX0(a4)
	add.l	g_PageW(a4),d1
	subq.l	#1,d1
	cmp.l	g_TlX1(a4),d1
	bge.s	.x1
	move.l	d1,g_TlX1(a4)
.x1:	move.l	g_TlY0(a4),d0
	cmp.l	g_TlY1(a4),d0
	bgt	.x
	move.l	g_TlX0(a4),d0
	cmp.l	g_TlX1(a4),d0
	bgt	.x
	; tile size: the (tiled) bitmap when repeated, else one image
	moveq	#0,d4
	move.w	im_W(a2),d4
	btst	#0,g_TlRep+3(a4)
	bne.s	.w
	move.l	bg_W(a5),d4
.w:	moveq	#0,d5
	move.w	im_H(a2),d5
	btst	#1,g_TlRep+3(a4)
	bne.s	.h
	move.l	bg_H(a5),d5
.h:	; the first row and column of tiles in the area
	move.l	g_TlOY(a4),d6		; d6 = tile y
	btst	#1,g_TlRep+3(a4)
	beq.s	.fy
	move.l	g_TlY0(a4),d0
	sub.l	d6,d0
	bmi.s	.fy
	divul.l	d5,d1:d0
	mulu.l	d5,d0
	add.l	d0,d6
.fy:	move.l	g_TlOX(a4),d7		; d7 = first tile x
	btst	#0,g_TlRep+3(a4)
	beq.s	.fx
	move.l	g_TlX0(a4),d0
	sub.l	d7,d0
	bmi.s	.fx
	divul.l	d4,d1:d0
	mulu.l	d4,d0
	add.l	d0,d7
.fx:	move.l	d7,-(sp)		; (the first column again each row)
.ty:	cmp.l	g_TlY1(a4),d6
	bgt	.done
	move.l	(sp),d7
.tx:	cmp.l	g_TlX1(a4),d7
	bgt	.tyn
	; the tile at d7/d6 within the area
	move.l	d7,d2			; dest x0 = max(tile x, area x0)
	cmp.l	g_TlX0(a4),d2
	bge.s	.a
	move.l	g_TlX0(a4),d2
.a:	move.l	d7,d0			; x1 = min(tile x + w - 1, area x1)
	add.l	d4,d0
	subq.l	#1,d0
	cmp.l	g_TlX1(a4),d0
	ble.s	.b
	move.l	g_TlX1(a4),d0
.b:	sub.l	d2,d0
	bmi.s	.txn
	addq.l	#1,d0
	move.l	d0,-(sp)		; width
	move.l	d6,d3			; dest y0
	cmp.l	g_TlY0(a4),d3
	bge.s	.c
	move.l	g_TlY0(a4),d3
.c:	move.l	d6,d0
	add.l	d5,d0
	subq.l	#1,d0
	cmp.l	g_TlY1(a4),d0
	ble.s	.d
	move.l	g_TlY1(a4),d0
.d:	sub.l	d3,d0
	bmi.s	.skip
	addq.l	#1,d0
	movem.l	d4-d7,-(sp)
	move.l	d0,d5			; height
	move.l	16(sp),d4		; width
	move.l	d2,d0			; source: the offset in the tile
	sub.l	d7,d0
	move.l	d3,d1
	sub.l	d6,d1
	move.l	im_BitMap(a2),a0
	move.l	a3,a1
	move.l	im_Mask(a2),d6
	bne.s	.m
	move.l	#$c0,d6
	GFX	BltBitMapRastPort
	bra.s	.bd
.m:	move.l	a2,-(sp)
	move.l	d6,a2
	move.l	#$e0,d6
	GFX	BltMaskBitMapRastPort
	move.l	(sp)+,a2
.bd:	movem.l	(sp)+,d4-d7
.skip:	addq.l	#4,sp
.txn:	btst	#0,g_TlRep+3(a4)	; not repeated: one tile only
	beq.s	.tyn
	add.l	d4,d7
	bra	.tx
.tyn:	btst	#1,g_TlRep+3(a4)
	beq.s	.done
	add.l	d5,d6
	bra	.ty
.done:	addq.l	#4,sp
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

;--------------------------------------------------------------------
; PaintRange - repaint document lines [d0, d1) (clipped to the view).
; The runs are drawn into an off-screen strip, STRIP_H lines at a time,
; which is then copied to the window, so nothing is seen half drawn;
; without the strip they are drawn in the window directly
;--------------------------------------------------------------------
PaintRange:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	tst.l	g_Window(a4)
	beq	.x
	tst.l	g_PaintRect(a4)		; (from PaintRect: its columns)
	bne.s	.cols
	clr.l	g_PaintX0(a4)
	move.l	g_PageW(a4),g_PaintX1(a4)
.cols:
	move.l	g_ScrollY(a4),d2	; clip to the view
	cmp.l	d2,d0
	bge.s	.t
	move.l	d2,d0
.t:	add.l	g_PageH(a4),d2
	cmp.l	d2,d1
	ble.s	.b
	move.l	d2,d1
.b:	cmp.l	d0,d1
	ble	.x
	move.l	d0,d6			; doc top
	move.l	d1,d7			; doc bottom
	moveq	#-1,d0			; the font cache is for the window
	move.l	d0,g_PaintFont(a4)	; RastPort, not the strip's
	move.l	d0,g_PaintFont+4(a4)
	bsr	CollectRuns
	bsr	StripReady
	beq	.direct
	move.l	d0,a3			; a3 = the strip's RastPort
.sl:	cmp.l	d7,d6
	bge	.sdone
	move.l	d6,d5			; strip bottom
	add.l	#STRIP_H,d5
	cmp.l	d7,d5
	ble.s	.s1
	move.l	d7,d5
.s1:	move.l	g_PageX(a4),-(sp)	; draw with the strip as the view
	move.l	g_PageY(a4),-(sp)
	clr.l	g_PageX(a4)
	move.l	g_ScrollY(a4),d0
	sub.l	d6,d0
	move.l	d0,g_PageY(a4)
	move.l	g_PageBg(a4),d0
	bsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	move.l	a3,a1
	move.l	g_PaintX0(a4),d0	; (a rectangle: only its columns)
	moveq	#0,d1
	move.l	g_PaintX1(a4),d2
	subq.l	#1,d2
	moveq	#STRIP_H-1,d3
	GFX	RectFill
	move.l	g_PaintX0(a4),d0	; the page's background image
	moveq	#0,d1
	move.l	g_PaintX1(a4),d2
	subq.l	#1,d2
	moveq	#STRIP_H-1,d3
	bsr	PageBgImage
	bsr	StripClip		; (a rectangle: runs clipped to it)
	move.l	d6,d0
	move.l	d5,d1
	bsr	PaintRuns
	bsr	StripUnclip
	move.l	(sp)+,g_PageY(a4)
	move.l	(sp)+,g_PageX(a4)
	move.l	d5,-(sp)		; copy it to the window
	sub.l	d6,d5			; height
	move.l	d6,d3
	sub.l	g_ScrollY(a4),d3
	add.l	g_PageY(a4),d3
	move.l	g_PageX(a4),d2
	add.l	g_PaintX0(a4),d2
	move.l	g_PaintX1(a4),d4
	sub.l	g_PaintX0(a4),d4
	move.l	g_StripBM(a4),a0
	move.l	g_PaintX0(a4),d0
	moveq	#0,d1
	move.l	g_Window(a4),a1
	move.l	wd_RPort(a1),a1
	move.l	#$c0,d6
	GFX	BltBitMapRastPort
	move.l	(sp)+,d6
	bra	.sl
.sdone:	moveq	#-1,d0
	move.l	d0,g_PaintFont(a4)
	move.l	d0,g_PaintFont+4(a4)
	bra	.x
.direct:
	; window rectangle of the range
	move.l	d6,d0
	sub.l	g_ScrollY(a4),d0
	add.l	g_PageY(a4),d0
	move.l	d7,d1
	sub.l	g_ScrollY(a4),d1
	add.l	g_PageY(a4),d1
	subq.l	#1,d1
	lea	g_ClipRect(a4),a0
	move.l	g_PageX(a4),d2
	add.l	g_PaintX0(a4),d2
	move.w	d2,ra_MinX(a0)
	move.w	d0,ra_MinY(a0)
	move.l	g_PageX(a4),d2
	add.l	g_PaintX1(a4),d2
	subq.l	#1,d2
	move.w	d2,ra_MaxX(a0)
	move.w	d1,ra_MaxY(a0)
	GFX	NewRegion
	move.l	d0,a5
	tst.l	d0
	beq	.x
	move.l	a5,a0
	lea	g_ClipRect(a4),a1
	GFX	OrRectRegion
	move.l	g_Window(a4),a0
	move.l	wd_WLayer(a0),a0
	move.l	a5,a1
	LAYERS	InstallClipRegion
	move.l	d0,-(sp)		; previous region
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a3		; a3 = RastPort
	; background
	move.l	g_PageBg(a4),d0
	bsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	lea	g_ClipRect(a4),a0
	move.l	a3,a1
	movem.w	(a0),d0-d3		; MinX, MinY, MaxX, MaxY
	ext.l	d0
	ext.l	d1
	ext.l	d2
	ext.l	d3
	movem.l	d0-d3,-(sp)
	GFX	RectFill
	movem.l	(sp)+,d0-d3
	bsr	PageBgImage
	move.l	d6,d0
	move.l	d7,d1
	bsr	PaintRuns
	move.l	g_Window(a4),a0
	move.l	wd_WLayer(a0),a0
	move.l	(sp)+,a1
	LAYERS	InstallClipRegion
	move.l	a5,a0
	GFX	DisposeRegion
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; GuiPaintNode - repaint only the box of element a0's runs (a link or a
; form control whose state changed: typing, focus, a click), not the
; whole view
GuiPaintNode:
	movem.l	d2-d7/a2,-(sp)
	move.l	a0,a2
	move.l	#$7fffffff,d4		; d4/d5 = top/bottom, d6/d7 = left/
	moveq	#-1,d5			; right of its runs
	move.l	d4,d6
	moveq	#-1,d7
	jsr	RunCount
	move.l	d0,d3
	moveq	#0,d2
.l:	cmp.l	d3,d2
	bhs.s	.done
	move.l	d2,d0
	jsr	RunPtr
	addq.l	#1,d2
	cmp.l	ru_Link(a0),a2
	bne.s	.l
	bsr	RunBox
	cmp.l	d4,d1
	bge.s	.t
	move.l	d1,d4
.t:	cmp.l	d6,d0
	bge.s	.lf
	move.l	d0,d6
.lf:	moveq	#0,d1
	move.w	ru_H(a0),d1
	add.l	ru_Y(a0),d1
	cmp.l	d5,d1
	ble.s	.b
	move.l	d1,d5
.b:	moveq	#0,d1
	move.w	ru_W(a0),d1
	add.l	d0,d1
	cmp.l	d7,d1
	ble.s	.l
	move.l	d1,d7
	bra.s	.l
.done:	cmp.l	d4,d5
	ble.s	.x
	move.l	d6,d0			; (2 pixels more: the focus outline)
	subq.l	#2,d0
	move.l	d4,d1
	subq.l	#2,d1
	move.l	d7,d2
	addq.l	#2,d2
	move.l	d5,d3
	addq.l	#2,d3
	bsr	PaintRect
	bsr	BandsSync
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; RunBox - In: a0 = run; Out: d0 = its left (document x), d1 = its top
; (a0 kept)
RunBox:
	moveq	#0,d0
	move.w	ru_X(a0),d0
	ext.l	d0
	move.l	ru_Y(a0),d1
	rts

;--------------------------------------------------------------------
; GuiPaintImage - image a0 (an ImageInfo) was loaded: paint it where it
; is shown (every copy), and nothing around it
;--------------------------------------------------------------------
GuiPaintImage:
	tst.l	g_FrN(a4)		; a page of frames: in each
	beq.s	PaintImage1
	tst.l	g_InFrames(a4)
	bne.s	PaintImage1
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	g_ViewCur(a4),-(sp)
	moveq	#1,d0
	move.l	d0,g_InFrames(a4)
	moveq	#1,d2
.f:	cmp.l	g_FrN(a4),d2
	bhi.s	.fd
	move.l	d2,d0
	jsr	ViewSelect
	move.l	a2,a0
	bsr.s	PaintImage1
	addq.l	#1,d2
	bra.s	.f
.fd:	clr.l	g_InFrames(a4)
	move.l	(sp)+,d0
	jsr	ViewSelect
	movem.l	(sp)+,d2/a2
	rts
PaintImage1:
	movem.l	d2-d6/a2-a3,-(sp)
	move.l	a0,a3
	jsr	RunCount
	move.l	d0,d6			; d6 = runs, d5 = this one
	moveq	#0,d5
.l:	cmp.l	d6,d5
	bhs.s	.x
	move.l	d5,d0
	jsr	RunPtr
	addq.l	#1,d5
	cmp.b	#RT_IMAGE,ru_Type(a0)
	bne.s	.l
	move.l	ru_Text(a0),a1
	cmp.l	n_Data2(a1),a3
	bne.s	.l
	move.l	a0,a2
	bsr	RunBox			; d0 = left, d1 = top
	moveq	#0,d2
	move.w	ru_W(a2),d2
	add.l	d0,d2			; right
	moveq	#0,d3
	move.w	ru_H(a2),d3
	add.l	d1,d3			; bottom
	bsr	PaintRect
	bra.s	.l
.x:	bsr	BandsSync
	movem.l	(sp)+,d2-d6/a2-a3
	rts

;--------------------------------------------------------------------
; PaintRect - repaint the document rectangle d0/d1 - d2/d3 (left/top
; inclusive, right/bottom exclusive): only the runs over it, clipped to
; it, and only it copied to the window
;--------------------------------------------------------------------
PaintRect:
	tst.l	d0			; (within the page's columns)
	bpl.s	.l
	moveq	#0,d0
.l:	cmp.l	g_PageW(a4),d2
	ble.s	.r
	move.l	g_PageW(a4),d2
.r:	cmp.l	d2,d0
	bge.s	.x
	move.l	d0,g_PaintX0(a4)
	move.l	d2,g_PaintX1(a4)
	moveq	#1,d0
	move.l	d0,g_PaintRect(a4)
	move.l	d1,d0
	move.l	d3,d1
	bsr	PaintRange
	clr.l	g_PaintRect(a4)
	clr.l	g_PaintX0(a4)
	move.l	g_PageW(a4),g_PaintX1(a4)
.x:	rts

; StripClip - for a rectangle (g_PaintRect): the strip's layer (a3 is
; its RastPort) draws only within its columns
StripClip:
	tst.l	g_PaintRect(a4)
	beq.s	.x
	movem.l	d2-d3/a2,-(sp)
	lea	g_ClipRect(a4),a0
	move.w	g_PaintX0+2(a4),ra_MinX(a0)
	clr.w	ra_MinY(a0)
	move.l	g_PaintX1(a4),d0
	subq.l	#1,d0
	move.w	d0,ra_MaxX(a0)
	move.w	#STRIP_H-1,ra_MaxY(a0)
	GFX	NewRegion
	move.l	d0,g_StripRegion(a4)
	beq.s	.n
	move.l	d0,a0
	lea	g_ClipRect(a4),a1
	GFX	OrRectRegion
	move.l	g_StripLayer(a4),a0
	move.l	g_StripRegion(a4),a1
	LAYERS	InstallClipRegion
.n:	movem.l	(sp)+,d2-d3/a2
.x:	rts

; StripUnclip - and back (the region freed)
StripUnclip:
	move.l	g_StripRegion(a4),d0
	beq.s	.x
	move.l	g_StripLayer(a4),a0
	suba.l	a1,a1
	LAYERS	InstallClipRegion
	move.l	g_StripRegion(a4),a0
	clr.l	g_StripRegion(a4)
	GFX	DisposeRegion
.x:	rts

; BandsSync - what is on the screen now is what the runs show: the
; band hashes of the view (so that GuiRefresh does not paint it again)
BandsSync:
	tst.l	g_BandsOk(a4)
	beq.s	.x
	lea	g_Bands(a4),a0
	bsr	ViewBands
.x:	rts

; CollectRuns - note the runs over document lines [d6, d7) in g_Vis
; (g_VisN = -1 if there are more than VIS_MAX)
CollectRuns:
	movem.l	d2-d4/a2,-(sp)
	jsr	RunCount
	move.l	d0,d3
	moveq	#0,d2			; run
	moveq	#0,d4			; noted
	lea	g_Vis(a4),a2
.l:	cmp.l	d3,d2
	bhs.s	.x
	move.l	d2,d0
	jsr	RunPtr
	move.l	ru_Y(a0),d0
	cmp.l	d7,d0
	bge.s	.n
	moveq	#0,d1
	move.w	ru_H(a0),d1
	add.l	d1,d0
	cmp.l	d6,d0
	ble.s	.n
	moveq	#0,d0			; and the columns
	move.w	ru_X(a0),d0
	ext.l	d0
	cmp.l	g_PaintX1(a4),d0
	bge.s	.n
	moveq	#0,d1
	move.w	ru_W(a0),d1
	add.l	d1,d0
	cmp.l	g_PaintX0(a4),d0
	ble.s	.n
	cmp.l	#VIS_MAX,d4
	bhs.s	.many
	move.l	d2,(a2)+
	addq.l	#1,d4
.n:	addq.l	#1,d2
	bra.s	.l
.many:	moveq	#-1,d4
.x:	move.l	d4,g_VisN(a4)
	movem.l	(sp)+,d2-d4/a2
	rts

; PaintRuns - draw the runs over document lines [d0, d1) into a3, from
; g_Vis (or all runs if it overflowed)
PaintRuns:
	movem.l	d2-d7/a2,-(sp)
	move.l	d0,d6
	move.l	d1,d7
	move.l	g_VisN(a4),d5
	bpl.s	.list
	jsr	RunCount
	move.l	d0,d5
.list:	moveq	#0,d4
.l:	cmp.l	d5,d4
	bhs.s	.x
	move.l	d4,d0
	tst.l	g_VisN(a4)
	bmi.s	.i
	move.l	g_Vis(a4,d4.l*4),d0
.i:	move.l	d0,g_PaintIdx(a4)
	jsr	RunPtr
	move.l	a0,a2
	move.l	ru_Y(a2),d0
	cmp.l	d7,d0
	bge.s	.n
	moveq	#0,d1
	move.w	ru_H(a2),d1
	add.l	d1,d0
	cmp.l	d6,d0
	ble.s	.n
	bsr	PaintRun
.n:	addq.l	#1,d4
	bra.s	.l
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; StripReady - the off-screen strip for the current page width
; Out: d0 = its RastPort, or 0 if it cannot be had (CCR set)
StripReady:
	move.l	g_StripLayer(a4),d0
	beq.s	.new
	move.l	g_PageW(a4),d1
	cmp.l	g_StripW(a4),d1
	beq.s	.rp
	bsr	StripFree
.new:	movem.l	d2-d4/a2,-(sp)
	move.l	g_PageW(a4),d0
	ble.s	.fail
	move.l	g_Screen(a4),a0		; like the screen's bitmap
	move.l	sc_RastPort+rp_BitMap(a0),a2
	move.l	a2,a0
	moveq	#BMA_DEPTH,d1
	GFX	GetBitMapAttr
	move.l	d0,d2			; depth
	move.l	g_PageW(a4),d0
	moveq	#STRIP_H,d1
	moveq	#0,d3
	move.l	a2,a0
	GFX	AllocBitMap
	move.l	d0,g_StripBM(a4)
	beq.s	.fail
	LAYERS	NewLayerInfo
	move.l	d0,g_StripLI(a4)
	beq.s	.fail
	move.l	d0,a0			; a layer, for clipping
	move.l	g_StripBM(a4),a1
	moveq	#0,d0
	moveq	#0,d1
	move.l	g_PageW(a4),d2
	subq.l	#1,d2
	moveq	#STRIP_H-1,d3
	moveq	#LAYERSIMPLE,d4
	suba.l	a2,a2
	LAYERS	CreateUpfrontLayer
	move.l	d0,g_StripLayer(a4)
	beq.s	.fail
	move.l	g_PageW(a4),g_StripW(a4)
	move.l	d0,a0
	move.l	lr_rp(a0),a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	movem.l	(sp)+,d2-d4/a2
	move.l	g_StripLayer(a4),d0
.rp:	move.l	d0,a0
	move.l	lr_rp(a0),d0
	rts
.fail:	bsr	StripFree
	movem.l	(sp)+,d2-d4/a2
	moveq	#0,d0
	rts

; StripFree - free the off-screen strip (if there is one)
StripFree:
	move.l	g_StripLayer(a4),d0
	beq.s	.li
	clr.l	g_StripLayer(a4)
	move.l	d0,a1
	suba.l	a0,a0
	LAYERS	DeleteLayer
.li:	move.l	g_StripLI(a4),d0
	beq.s	.bm
	clr.l	g_StripLI(a4)
	move.l	d0,a0
	LAYERS	DisposeLayerInfo
.bm:	move.l	g_StripBM(a4),d0
	beq.s	.x
	clr.l	g_StripBM(a4)
	move.l	d0,-(sp)
	GFX	WaitBlit
	move.l	(sp)+,a0
	GFX	FreeBitMap
.x:	rts

; PaintRun - draw run a2 into RastPort a3
PaintRun:
	movem.l	d2-d5,-(sp)
	move.l	ru_Color(a2),d0
	bsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	; window position
	move.w	ru_X(a2),d2
	ext.l	d2
	add.l	g_PageX(a4),d2
	move.l	ru_Y(a2),d3
	sub.l	g_ScrollY(a4),d3
	add.l	g_PageY(a4),d3
	move.b	ru_Type(a2),d0
	cmp.b	#RT_TEXT,d0
	beq	.text
	cmp.b	#RT_WIDGET,d0
	bne.s	.notw
	bsr	PaintWidget
	bra	.x
.notw:
	; boxes: clamp to the view so coordinates fit in words
	moveq	#0,d4
	move.w	ru_W(a2),d4
	add.l	d2,d4
	subq.l	#1,d4			; x max
	moveq	#0,d5
	move.w	ru_H(a2),d5
	add.l	d3,d5
	subq.l	#1,d5			; y max
	move.l	g_PageY(a4),d1
	subq.l	#1,d1
	cmp.l	d1,d3
	bge.s	.c1
	move.l	d1,d3
.c1:	add.l	g_PageH(a4),d1
	addq.l	#1,d1
	cmp.l	d1,d5
	ble.s	.c2
	move.l	d1,d5
.c2:	cmp.l	d3,d5
	blt	.x
	cmp.l	d2,d4
	blt	.x
	cmp.b	#RT_BOX,d0
	beq.s	.box
	cmp.b	#RT_IMAGE,d0
	bne.s	.notimg
	movem.l	d4-d5,-(sp)		; a loaded image is blitted
	move.l	g_PageY(a4),d4
	move.l	d4,d5
	add.l	g_PageH(a4),d5
	subq.l	#1,d5
	move.l	a2,a0
	move.l	a3,a1
	movem.l	d2-d3,-(sp)
	move.l	ru_Y(a2),d3		; (unclamped window y)
	sub.l	g_ScrollY(a4),d3
	add.l	g_PageY(a4),d3
	jsr	ImagePaint
	movem.l	(sp)+,d2-d3
	movem.l	(sp)+,d4-d5
	tst.l	d0
	bne	.x
	bra.s	.box
.notimg:
	cmp.b	#RT_RECT,d0
	beq.s	.rect
	cmp.b	#RT_BULLET,d0
	bne.s	.fill
	cmp.l	#LIST_CIRCLE,ru_Len(a2)
	beq.s	.box
.fill:	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	move.l	d4,d2
	move.l	d5,d3
	GFX	RectFill
	bra.s	.x
.rect:	tst.l	ru_Color(a2)		; a background: its colour,
	bmi.s	.rimg
	movem.l	d2-d3,-(sp)
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	move.l	d4,d2
	move.l	d5,d3
	GFX	RectFill
	movem.l	(sp)+,d2-d3
.rimg:	move.l	ru_Text(a2),d0		; ... its image, repeated
	beq.s	.x
	move.l	d0,a0
	tst.l	bg_Info(a0)
	beq.s	.x
	move.l	d2,g_TlX0(a4)
	move.l	d3,g_TlY0(a4)
	move.l	d4,g_TlX1(a4)
	move.l	d5,g_TlY1(a4)
	move.l	d2,g_TlOX(a4)		; (from the box's top left)
	move.l	ru_Y(a2),d0
	sub.l	g_ScrollY(a4),d0
	add.l	g_PageY(a4),d0
	move.l	d0,g_TlOY(a4)
	move.l	ru_Len(a2),g_TlRep(a4)
	move.l	a3,a1
	bsr	TileRect
	bra.s	.x
.box:	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Move
	move.l	a3,a1
	move.l	d4,d0
	move.l	d3,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d2,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Draw
	bra.s	.x
.text:	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	move.l	a3,a1
	lea	g_PaintFont(a4),a0
	bsr	SetRPFont
	add.w	ru_Base(a2),d3
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Move
	move.l	a3,a1
	move.l	ru_Text(a2),a0
	move.l	ru_Len(a2),d0
	GFX	Text
	move.l	d3,-(sp)		; the find match, the selection
	sub.w	ru_Base(a2),d3
	jsr	FindHighlight
	jsr	SelHighlight
	move.l	(sp)+,d3
	move.l	ru_Link(a2),d0		; keyboard focus: outline the link
	beq.s	.x
	cmp.l	g_FocusLink(a4),d0
	bne.s	.x
	sub.w	ru_Base(a2),d3		; back to the top
	move.l	d2,d4
	moveq	#0,d0
	move.w	ru_W(a2),d0
	add.l	d0,d4
	move.l	d3,d5
	moveq	#0,d0
	move.w	ru_H(a2),d0
	add.l	d0,d5
	subq.l	#1,d5
	subq.l	#1,d2
	bra	.box
.x:	movem.l	(sp)+,d2-d5
	rts

;--------------------------------------------------------------------
; PaintWidget - draw a form control
; In: a2 = run, a3 = RastPort, d2/d3 = window x/y of the run
;--------------------------------------------------------------------
PaintWidget:
	movem.l	d2-d7/a2/a5,-(sp)
	move.l	ru_Text(a2),a0
	jsr	FormStateOf
	tst.l	d0
	beq	.x
	move.l	d0,a5			; a5 = state
	move.l	d2,d4
	moveq	#0,d0
	move.w	ru_W(a2),d0
	add.l	d0,d4
	subq.l	#1,d4			; x max
	move.l	d3,d5
	moveq	#0,d0
	move.w	ru_H(a2),d0
	add.l	d0,d5
	subq.l	#1,d5			; y max
	move.b	fs_Kind(a5),d0
	cmp.b	#FK_PASSWORD,d0
	bls	.field
	cmp.b	#FK_TEXTAREA,d0
	beq	.field
	cmp.b	#FK_CHECKBOX,d0
	beq	.check
	cmp.b	#FK_RADIO,d0
	beq	.radio
	; buttons and selects: raised box with the label
	move.l	#WIDGET_FACE,d0
	bsr	FillBox
	moveq	#1,d6			; raised
	bsr	Bevel
	move.l	fs_Label(a5),d0
	beq	.focus
	move.l	d0,a0
	jsr	StrLen
	move.l	d0,d7			; label length
	move.l	ru_Text(a2),a0		; label x: centred, or left in selects
	moveq	#8,d6
	cmp.b	#FK_SELECT,fs_Kind(a5)
	beq.s	.lx
	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	move.l	fs_Label(a5),a0
	move.l	d7,d1
	bsr	GuiMeasure
	move.l	d4,d6
	sub.l	d2,d6
	sub.l	d0,d6
	asr.l	#1,d6
.lx:	add.l	d2,d6
	move.l	fs_Label(a5),a0
	move.l	d7,d0
	bsr	WidgetText
	cmp.b	#FK_SELECT,fs_Kind(a5)	; a "v" mark at the right of selects
	bne	.focus
	moveq	#0,d0
	move.w	ru_H(a2),d0
	lsr.l	#2,d0			; mark size
	move.l	d4,d6
	sub.l	d0,d6
	sub.l	d0,d6
	subq.l	#4,d6			; left end of the mark
	move.l	d3,d7
	add.l	d0,d7
	add.l	d0,d7
	subq.l	#1,d7			; upper y of the mark
	move.l	d0,-(sp)
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d6,d0
	move.l	d7,d1
	GFX	Move
	movem.l	(sp)+,d0
	move.l	d0,-(sp)
	add.l	d0,d6
	add.l	d0,d7
	move.l	a3,a1
	move.l	d6,d0
	move.l	d7,d1
	GFX	Draw
	movem.l	(sp)+,d0
	add.l	d0,d6
	sub.l	d0,d7
	move.l	a3,a1
	move.l	d6,d0
	move.l	d7,d1
	GFX	Draw
	bra	.focus

.field:	move.l	#$ffffff,d0		; recessed white box with the text
	bsr	FillBox
	moveq	#0,d6
	bsr	Bevel
	cmp.b	#FK_TEXTAREA,fs_Kind(a5)
	beq.s	.area
	bsr	FieldText
	bra	.focus
.area:	bsr	AreaText
	bra	.focus

.check:	move.l	#$ffffff,d0
	bsr	FillBox
	moveq	#0,d6
	bsr	Bevel
	tst.b	fs_Checked(a5)
	beq.s	.focus
	move.l	g_PageFg(a4),d0		; a cross
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#2,d0
	move.l	d3,d1
	addq.l	#2,d1
	GFX	Move
	move.l	a3,a1
	move.l	d4,d0
	subq.l	#2,d0
	move.l	d5,d1
	subq.l	#2,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	subq.l	#2,d0
	move.l	d3,d1
	addq.l	#2,d1
	GFX	Move
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#2,d0
	move.l	d5,d1
	subq.l	#2,d1
	GFX	Draw
	bra.s	.focus

.radio:	move.l	#$ffffff,d0
	bsr	FillBox
	moveq	#0,d6
	bsr	Bevel
	tst.b	fs_Checked(a5)
	beq.s	.focus
	move.l	g_PageFg(a4),d0		; a filled centre
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#3,d0
	move.l	d3,d1
	addq.l	#3,d1
	movem.l	d2-d3,-(sp)
	move.l	d4,d2
	subq.l	#3,d2
	move.l	d5,d3
	subq.l	#3,d3
	GFX	RectFill
	movem.l	(sp)+,d2-d3

.focus:	move.l	ru_Text(a2),d0		; keyboard focus: dotted outline
	cmp.l	g_FocusLink(a4),d0
	bne.s	.x
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	a3,a1
	move.w	#$aaaa,rp_LinePtrn(a1)
	bset	#0,rp_Flags+1(a1)	; FRST_DOT: restart the pattern
	move.l	d2,d0
	subq.l	#1,d0
	subq.l	#1,d2
	addq.l	#1,d4
	subq.l	#1,d3
	addq.l	#1,d5
	bsr	Outline
	move.l	a3,a1
	move.w	#$ffff,rp_LinePtrn(a1)
.x:	movem.l	(sp)+,d2-d7/a2/a5
	rts

; FillBox - fill d2..d4 x d3..d5 with colour d0
FillBox:
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	movem.l	d2-d3,-(sp)
	move.l	d4,d2
	move.l	d5,d3
	GFX	RectFill
	movem.l	(sp)+,d2-d3
	rts

; Bevel - 3D edge around d2..d4 x d3..d5; d6 = 1 raised, 0 recessed
Bevel:
	move.l	#$ffffff,d0		; light edge: top and left when raised
	tst.l	d6
	bne.s	.l1
	move.l	#$000000,d0
.l1:	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	move.l	d5,d1
	GFX	Move
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d3,d1
	GFX	Draw
	move.l	#$000000,d0		; dark edge: bottom and right
	tst.l	d6
	bne.s	.l2
	move.l	#$ffffff,d0
.l2:	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d4,d0
	move.l	d3,d1
	addq.l	#1,d1
	GFX	Move
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#1,d0
	move.l	d5,d1
	GFX	Draw
	rts

; Outline - rectangle d0/d3 .. d4/d5 (d0 = left)
Outline:
	move.l	d0,-(sp)
	move.l	a3,a1
	move.l	d3,d1
	GFX	Move
	move.l	a3,a1
	move.l	d4,d0
	move.l	d3,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	(sp),d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	(sp)+,d0
	move.l	d3,d1
	GFX	Draw
	rts

; SetPenRGB - In: d0 = $RRGGBB; sets the A pen of a3
SetPenRGB:
	bsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	rts

; WidgetText - draw a0/d0 (text/length) at x d6 on the text line of the
; widget run a2 (font of the run, page text colour)
WidgetText:
	movem.l	d2/a2,-(sp)
	move.l	a0,-(sp)
	move.l	d0,-(sp)
	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	move.l	a3,a1
	lea	g_PaintFont(a4),a0
	bsr	SetRPFont
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d6,d0
	move.l	d3,d1
	add.w	ru_Base(a2),d1
	GFX	Move
	move.l	(sp)+,d0
	move.l	(sp)+,a0
	move.l	a3,a1
	GFX	Text
	movem.l	(sp)+,d2/a2
	rts

; FieldText - the text of a field (a5 = state, a2 = run), with the
; cursor when it is being edited.  Only what fits is drawn.
FieldText:
	movem.l	d2-d7/a2,-(sp)
	move.l	d4,d7
	sub.l	d2,d7
	subq.l	#6,d7			; room for text
	addq.l	#4,d2			; text x
	; keep the cursor in view: scroll so that the cursor fits
	move.l	fs_Cursor(a5),d0
	cmp.l	fs_Scroll(a5),d0
	bhs.s	.sc1
	move.l	d0,fs_Scroll(a5)
.sc1:	bsr	.width			; width from scroll to cursor
	cmp.l	d7,d0
	ble.s	.sok
	addq.l	#1,fs_Scroll(a5)
	bra.s	.sc1
.sok:	; characters that fit from the scroll position
	move.l	fs_Value(a5),a0
	add.l	fs_Scroll(a5),a0
	move.l	fs_Len(a5),d6
	sub.l	fs_Scroll(a5),d6	; d6 = characters after scroll
.fit:	tst.l	d6
	beq.s	.draw
	move.l	d6,d1
	bsr	.measure
	cmp.l	d7,d0
	ble.s	.draw
	subq.l	#1,d6
	bra.s	.fit
.draw:	tst.l	d6
	beq.s	.cursor
	move.l	fs_Value(a5),a0
	add.l	fs_Scroll(a5),a0
	cmp.b	#FK_PASSWORD,fs_Kind(a5)
	bne.s	.plain
	lea	Stars(pc),a0
	cmp.l	#STARS_MAX,d6
	bls.s	.plain
	moveq	#STARS_MAX,d6
.plain:	move.l	d6,d0
	movem.l	d6,-(sp)
	move.l	d2,d6
	bsr	WidgetText
	movem.l	(sp)+,d6
.cursor:
	move.l	ru_Text(a2),d0
	cmp.l	g_EditField(a4),d0
	bne.s	.x
	bsr	.width			; x of the cursor
	add.l	d2,d0
	move.l	d0,-(sp)
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	(sp)+,d0
	move.l	d3,d1
	addq.l	#2,d1
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	addq.l	#1,d2
	move.l	d5,d3
	subq.l	#2,d3
	move.l	a3,a1
	GFX	RectFill
	movem.l	(sp)+,d2-d3
.x:	movem.l	(sp)+,d2-d7/a2
	rts
; .width - Out: d0 = width of the text from fs_Scroll to the cursor
.width:	move.l	fs_Cursor(a5),d1
	sub.l	fs_Scroll(a5),d1
	move.l	fs_Value(a5),a0
	add.l	fs_Scroll(a5),a0
; .measure - In: a0 = text, d1 = length; Out: d0 = width (stars for
; passwords)
.measure:
	cmp.b	#FK_PASSWORD,fs_Kind(a5)
	bne.s	.m
	lea	Stars(pc),a0
	cmp.l	#STARS_MAX,d1
	bls.s	.m
	moveq	#STARS_MAX,d1
.m:	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	bra	GuiMeasure

STARS_MAX	equ	64
Stars:	dcb.b	STARS_MAX,'*'
	even

; AreaText - the lines of a textarea (a5 = state, a2 = run, a3 =
; RastPort); the view scrolls (fs_Scroll = first line shown) to keep the
; cursor visible.  d4 holds the current line.
AreaText:
	movem.l	d2-d7/a2/a5,-(sp)
	sub.l	#12,sp			; locals: 0 font h, 4 width, 8 line no.
	moveq	#0,d0
	move.b	ru_Font(a2),d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	moveq	#0,d1
	move.w	(a0,d0.w),d1
	move.l	d1,(sp)
	move.l	d4,d0
	sub.l	d2,d0
	subq.l	#6,d0
	move.l	d0,4(sp)
	addq.l	#4,d2			; text x
	; line of the cursor
	moveq	#0,d6
	move.l	fs_Value(a5),a0
	move.l	fs_Cursor(a5),d0
	bra.s	.cle
.cl:	cmp.b	#10,(a0)+
	bne.s	.cle
	addq.l	#1,d6
.cle:	dbf	d0,.cl
	cmp.l	fs_Scroll(a5),d6
	bhs.s	.s1
	move.l	d6,fs_Scroll(a5)
.s1:	moveq	#0,d0
	move.w	fs_Rows(a5),d0
	move.l	d6,d1
	sub.l	fs_Scroll(a5),d1
	cmp.l	d0,d1
	blo.s	.s2
	move.l	d6,d1
	sub.l	d0,d1
	addq.l	#1,d1
	move.l	d1,fs_Scroll(a5)
.s2:	; start of the first line shown
	move.l	fs_Value(a5),a0
	move.l	fs_Scroll(a5),d0
	bra.s	.sk
.skl:	tst.b	(a0)
	beq.s	.go
	cmp.b	#10,(a0)+
	bne.s	.skl
.sk:	subq.l	#1,d0
	bpl.s	.skl
.go:	move.l	a0,d4			; d4 = current line
	clr.l	8(sp)
.line:	moveq	#0,d0
	move.w	fs_Rows(a5),d0
	cmp.l	8(sp),d0
	bls	.x
	move.l	d4,a0			; length of this line
.ll:	move.b	(a0),d0
	beq.s	.le
	cmp.b	#10,d0
	beq.s	.le
	addq.l	#1,a0
	bra.s	.ll
.le:	move.l	a0,d7
	sub.l	d4,d7			; d7 = line length
	move.l	d7,d5
.fit:	tst.l	d5			; characters that fit
	beq.s	.draw
	move.l	d4,a0
	move.l	d5,d1
	bsr	.measure
	cmp.l	4(sp),d0
	ble.s	.draw
	subq.l	#1,d5
	bra.s	.fit
.draw:	move.l	d3,d6			; d6 = y of the box; d3 = of the line
	move.l	8(sp),d0
	mulu.l	(sp),d0
	add.l	d0,d3
	tst.l	d5
	beq.s	.cur
	move.l	d4,a0
	move.l	d5,d0
	move.l	d6,-(sp)
	move.l	d2,d6
	bsr	WidgetText
	move.l	(sp)+,d6
.cur:	move.l	ru_Text(a2),d0		; the cursor, if it is on this line
	cmp.l	g_EditField(a4),d0
	bne.s	.nocur
	move.l	fs_Value(a5),d1
	add.l	fs_Cursor(a5),d1
	cmp.l	d4,d1
	blo.s	.nocur
	move.l	d4,d0
	add.l	d7,d0
	cmp.l	d0,d1
	bhi.s	.nocur
	sub.l	d4,d1
	move.l	d4,a0
	bsr	.measure
	add.l	d2,d0
	move.l	d0,-(sp)
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	(sp)+,d0
	move.l	d3,d1
	addq.l	#3,d1
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	addq.l	#1,d2
	move.l	d1,d3
	add.l	8(sp),d3		; + font height (locals at 8 now)
	subq.l	#1,d3
	move.l	a3,a1
	GFX	RectFill
	movem.l	(sp)+,d2-d3
.nocur:	move.l	d6,d3
	add.l	d7,d4			; next line
	move.l	d4,a0
	tst.b	(a0)
	beq.s	.x
	addq.l	#1,d4
	addq.l	#1,8(sp)
	bra	.line
.x:	add.l	#12,sp
	movem.l	(sp)+,d2-d7/a2/a5
	rts
.measure:
	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	bra	GuiMeasure

; DrawStatus - draw g_StatusText in the status line (over the old
; text, then clearing what is right of it, so that it does not flicker)
DrawStatus:
	movem.l	d2-d5/a2,-(sp)
	move.l	g_Window(a4),d0
	beq	.x
	move.l	d0,a0
	move.l	wd_RPort(a0),a2
	move.l	a2,a1
	move.l	g_ScreenFont(a4),a0
	GFX	SetFont
	move.l	a2,a1
	moveq	#0,d0
	moveq	#7,d1
	GFX	SetSoftStyle
	moveq	#-1,d0			; the window font changed
	move.l	d0,g_PaintFont(a4)
	move.l	d0,g_PaintFont+4(a4)
	move.l	a2,a1
	moveq	#1,d0
	GFX	SetAPen
	move.l	a2,a1
	moveq	#0,d0
	GFX	SetBPen
	move.l	a2,a1
	moveq	#RP_JAM2,d0
	GFX	SetDrMd
	move.l	a2,a1
	move.l	g_PageX(a4),d0
	addq.l	#4,d0
	move.l	g_StatusY(a4),d1
	addq.l	#2,d1
	move.l	g_ScreenFont(a4),a0
	add.w	tf_Baseline(a0),d1
	GFX	Move
	lea	g_StatusText(a4),a0
	jsr	StrLen
	move.l	a2,a1
	lea	g_StatusText(a4),a0
	GFX	Text
	move.l	a2,a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	move.l	a2,a1
	moveq	#0,d0
	GFX	SetAPen
	moveq	#0,d4
	move.w	rp_cp_x(a2),d4		; right of the text
	move.l	a2,d5
	move.l	g_Window(a4),a2
	bsr	InnerBox		; to the right edge
	tst.l	g_PrgOn(a4)		; (not under the progress bar)
	beq.s	.cl
	sub.l	#PROG_W+4,d2
.cl:	move.l	d4,d0
	move.l	g_StatusY(a4),d1
	move.l	d5,a1
	cmp.l	d0,d2
	blt.s	.x
	GFX	RectFill
.x:	movem.l	(sp)+,d2-d5/a2
	bra	ProgDraw		; (over the text's end, if long)

; GuiStatus - set and show the status line
; In: a0 = text
GuiStatus:
	lea	g_StatusText(a4),a1
	move.l	#STATUS_MAX-1,d0
	jsr	StrCopyN
	bra	DrawStatus

;--------------------------------------------------------------------
; The progress bar, at the right end of the status line while
; something loads: filled as far as known (the page's bytes, then its
; images), else a block going back and forth (INTUITICKS)
;--------------------------------------------------------------------
PROG_W		equ	64		; its width

; GuiProgSet - show progress d0 of d1 (d1 <= 0: not known)
GuiProgSet:
	move.l	d0,g_PrgDone(a4)
	move.l	d1,g_PrgAll(a4)
	moveq	#1,d0
	move.l	d0,g_PrgOn(a4)
	bra.s	ProgDraw

; ProgOff - (event loop: nothing loads) the bar goes
ProgOff:
	clr.l	g_PrgOn(a4)
	bra	DrawStatus		; (cleared to the right end)

; ProgTick - (INTUITICKS) progress not known: the block moves on
ProgTick:
	tst.l	g_PrgOn(a4)
	beq.s	.x
	tst.l	g_PrgAll(a4)
	bgt.s	.x
	addq.l	#3,g_PrgAnim(a4)
	bra.s	ProgDraw
.x:	rts

; ProgDraw - draw the bar (nothing if it is off)
ProgDraw:
	tst.l	g_PrgOn(a4)
	beq	.x0
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	g_Window(a4),d0
	beq	.x
	move.l	d0,a2
	move.l	wd_RPort(a2),a3		; a3 = RastPort
	bsr	InnerBox		; d2 = right, d3 = bottom
	move.l	d2,d6
	subq.l	#4,d6			; d6 = x1
	move.l	d6,d4
	sub.l	#PROG_W-1,d4		; d4 = x0
	move.l	g_PageX(a4),d0		; (a window too narrow: none)
	add.l	#PROG_W,d0
	cmp.l	d0,d4
	blt	.x
	move.l	g_StatusY(a4),d5
	addq.l	#2,d5			; d5 = y0
	move.l	d3,d7
	subq.l	#2,d7			; d7 = y1
	move.l	d5,d0
	addq.l	#2,d0
	cmp.l	d0,d7
	blt	.x
	move.l	a3,a1			; the frame
	move.l	g_PenShadow(a4),d0
	GFX	SetAPen
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Move
	move.l	a3,a1
	move.l	d6,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d6,d0
	move.l	d7,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d7,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Draw
	addq.l	#1,d4			; inside it
	subq.l	#1,d6
	addq.l	#1,d5
	subq.l	#1,d7
	move.l	d6,d2
	sub.l	d4,d2
	addq.l	#1,d2			; d2 = its width
	move.l	g_PrgAll(a4),d1
	ble.s	.unk
	move.l	g_PrgDone(a4),d0	; known: filled from the left
	bpl.s	.pos
	moveq	#0,d0
.pos:	cmp.l	d1,d0
	bls.s	.f
	move.l	d1,d0
.f:	mulu.l	d2,d3:d0
	divu.l	d1,d3:d0
	move.l	d0,d3			; d3 = filled width
	moveq	#0,d1			; d1 = from
	bra.s	.draw
.unk:	move.l	d2,d3			; not known: a quarter of it, back
	lsr.l	#2,d3			; and forth
	sub.l	d3,d2			; d2 = the way it goes
	move.l	g_PrgAnim(a4),d0
	move.l	d2,d1
	add.l	d1,d1
	beq.s	.in
.m:	cmp.l	d1,d0
	blo.s	.in
	sub.l	d1,d0
	bra.s	.m
.in:	move.l	d0,g_PrgAnim(a4)
	cmp.l	d2,d0			; coming back
	bls.s	.o
	sub.l	d1,d0
	neg.l	d0
.o:	move.l	d0,d1
.draw:	move.l	d1,-(sp)		; empty left of it,
	move.l	d4,d0
	move.l	d4,d2
	add.l	d1,d2
	subq.l	#1,d2
	moveq	#0,d1
	bsr.s	PBox
	move.l	d4,d0			; the filled part,
	add.l	(sp)+,d0
	move.l	d0,d2
	add.l	d3,d2
	subq.l	#1,d2
	move.l	g_PenFill(a4),d1
	bsr.s	PBox
	move.l	d2,d0			; empty right of it
	addq.l	#1,d0
	move.l	d6,d2
	moveq	#0,d1
	bsr.s	PBox
.x:	movem.l	(sp)+,d2-d7/a2-a3
.x0:	rts

; PBox - (ProgDraw: a3 = RastPort) fill x d0..d2, y d5..d7 with pen d1
; if d0 <= d2 (d0, d2 kept)
PBox:
	cmp.l	d0,d2
	blt.s	.x
	movem.l	d0/d2-d3,-(sp)
	move.l	a3,a1
	move.l	d1,d0
	GFX	SetAPen
	movem.l	(sp),d0/d2
	move.l	a3,a1
	move.l	d5,d1
	move.l	d7,d3
	GFX	RectFill
	movem.l	(sp)+,d0/d2-d3
.x:	rts

;--------------------------------------------------------------------
; GuiBlank - (event loop) a new page is to be loaded: the page shown
; leaves the window at once, which stays blank (its address in the
; URL gadget) until the new one is laid out.  The page left stays in
; memory until the new one comes, and comes back if the load is
; stopped before (GuiUnblank).
;--------------------------------------------------------------------
GuiBlank:
	moveq	#0,d0			; (the page's view, not a frame's)
	jsr	ViewSelect
	tst.l	g_Blank(a4)
	bne.s	.p
	moveq	#2,d0			; (no page shown: none comes back)
	tst.l	g_ViewLive(a4)
	beq.s	.s
	moveq	#1,d0
.s:	move.l	d0,g_Blank(a4)
	clr.l	g_ViewLive(a4)		; (its runs: not used meanwhile)
.p:	lea	g_NavUrl(a4),a0
	bsr	GuiSetUrl
	moveq	#0,d0			; (how much: not known yet)
	moveq	#-1,d1
	bsr	GuiProgSet
	bra.s	PaintBlank

; GuiUnblank - (loader) stopped while blank: the page left comes back
; as it was, if it is still there
GuiUnblank:
	cmp.l	#1,g_Blank(a4)
	bne.s	.x
	clr.l	g_Blank(a4)
	lea	g_PageUrl(a4),a0
	bsr	GuiSetUrl
	bsr	GuiPageWidth
	cmp.l	g_LayWidth(a4),d0
	bne	GuiRelayout		; (another width meanwhile)
	moveq	#1,d0
	move.l	d0,g_ViewLive(a4)
	bra	GuiPaintAll
.x:	rts

; PaintBlank - the page area blank (white), the scroller with nothing
; to scroll, the status line
PaintBlank:
	moveq	#0,d0			; (all of the page area)
	jsr	ViewSelect
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	g_Window(a4),d0
	beq.s	.x
	move.l	#$ffffff,d0
	bsr	GetPen
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	GFX	SetAPen
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	move.l	g_PageX(a4),d0
	move.l	g_PageY(a4),d1
	move.l	d0,d2
	add.l	g_PageW(a4),d2
	subq.l	#1,d2
	move.l	d1,d3
	add.l	g_PageH(a4),d3
	subq.l	#1,d3
	GFX	RectFill
	move.l	g_GadScroll(a4),d0
	beq.s	.ns
	move.l	d0,a0
	clr.l	ScrTagTop+4
	move.l	g_PageH(a4),ScrTagTotal+4
	move.l	g_PageH(a4),ScrTagVis+4
	move.l	g_Window(a4),a1
	suba.l	a2,a2
	lea	ScrTags,a3
	GT	GT_SetGadgetAttrsA
.ns:	bsr	DrawStatus
.x:	movem.l	(sp)+,d2-d3/a2-a3
ScrollNone:
	rts

; ScreenPens - the screen's FILLPEN and SHADOWPEN (progress bar)
ScreenPens:
	moveq	#3,d0
	move.l	d0,g_PenFill(a4)
	moveq	#1,d0
	move.l	d0,g_PenShadow(a4)
	move.l	g_Screen(a4),a0
	INTUI	GetScreenDrawInfo
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.l	dri_Pens(a1),a0
	moveq	#0,d0
	move.w	FILLPEN*2(a0),d0
	move.l	d0,g_PenFill(a4)
	move.w	SHADOWPEN*2(a0),d0
	move.l	d0,g_PenShadow(a4)
	move.l	g_Screen(a4),a0
	INTUI	FreeScreenDrawInfo
.x:	rts

; UpdateScroller - give the scroller the document size and position
UpdateScroller:
	tst.l	g_Dragging(a4)		; (while the user drags it, the page
	bne.s	.x			;  changing must not move it back)
	tst.l	g_InFrames(a4)		; (a page of frames: the active one's)
	bne.s	.x
	tst.l	g_FrN(a4)
	beq.s	.go
	move.l	g_ViewCur(a4),d0
	cmp.l	g_FrActive(a4),d0
	bne.s	.x
.go:
	move.l	g_GadScroll(a4),d0
	beq.s	.x
	movem.l	a2-a3,-(sp)
	move.l	d0,a0
	move.l	g_ScrollY(a4),ScrTagTop+4
	move.l	g_DocHeight(a4),d0
	cmp.l	g_PageH(a4),d0
	bge.s	.t
	move.l	g_PageH(a4),d0
.t:	move.l	d0,ScrTagTotal+4
	move.l	g_PageH(a4),ScrTagVis+4
	move.l	g_Window(a4),a1
	suba.l	a2,a2
	lea	ScrTags,a3
	GT	GT_SetGadgetAttrsA
	movem.l	(sp)+,a2-a3
.x:	rts

; GuiScrollTo - scroll the page so that document line d0 is at the top
GuiScrollTo:
	tst.l	g_Blank(a4)		; (blank: nothing to scroll)
	bne	ScrollNone
	movem.l	d2-d3,-(sp)
	move.l	g_DocHeight(a4),d1
	sub.l	g_PageH(a4),d1
	bpl.s	.m
	moveq	#0,d1
.m:	cmp.l	d1,d0
	ble.s	.lo
	move.l	d1,d0
.lo:	tst.l	d0
	bpl.s	.ok
	moveq	#0,d0
.ok:	move.l	d0,d2
	sub.l	g_ScrollY(a4),d2	; dy
	beq	.x
	move.l	d0,g_ScrollY(a4)
	clr.l	g_BandsOk(a4)		; (the bands moved)
	lea	LogScroll(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	tst.l	g_FrN(a4)		; (a page of frames: which, for tests)
	beq.s	.nf
	lea	LogFScroll(pc),a0
	suba.l	a1,a1
	move.l	g_ViewCur(a4),d0
	jsr	LogEvent
.nf:
	move.l	d2,d0
	bpl.s	.abs
	neg.l	d0
.abs:	cmp.l	g_PageH(a4),d0
	bge.s	.full
	; move the visible part, then paint the uncovered strip
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	move.l	g_PageBg(a4),d0
	bsr	GetPen
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	GFX	SetBPen
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	moveq	#0,d0			; dx
	move.l	d2,d1			; dy
	movem.l	d2-d5,-(sp)
	move.l	g_PageX(a4),d2
	move.l	g_PageY(a4),d3
	move.l	d2,d4
	add.l	g_PageW(a4),d4
	subq.l	#1,d4
	move.l	d3,d5
	add.l	g_PageH(a4),d5
	subq.l	#1,d5
	GFX	ScrollRaster		; (rp, dx, dy, xmin, ymin, xmax, ymax)
	movem.l	(sp)+,d2-d5
	tst.l	d2
	bmi.s	.up
	move.l	g_ScrollY(a4),d0	; scrolled down: new lines at the bottom
	add.l	g_PageH(a4),d0
	move.l	d0,d1
	sub.l	d2,d0
	bra.s	.paint
.up:	move.l	g_ScrollY(a4),d0	; scrolled up: new lines at the top
	move.l	d0,d1
	sub.l	d2,d1
.paint:	bsr	PaintRange
	bra.s	.sc
.full:	move.l	g_ScrollY(a4),d0
	move.l	d0,d1
	add.l	g_PageH(a4),d1
	bsr	PaintRange
.sc:	bsr	UpdateScroller
.x:	movem.l	(sp)+,d2-d3
	rts

; GuiRelayout - lay the page out for the current width and repaint
; what changed.  From the event loop while the loader is in a layout
; (a new window size): that one starts again (g_LayAgain).
GuiRelayout:
	tst.l	g_TkIn(a4)		; blank, a new size (event loop): the
	bne.s	.lb			; page left is laid out if it comes
	tst.l	g_Blank(a4)		; back (GuiUnblank), the new one when
	bne	PaintBlank		; it is shown
.lb:	tst.l	g_TkIn(a4)		; (the loader lays out itself)
	bne.s	.go
	tst.l	g_CssBusy(a4)		; style sheets being read: the layout
	bne.s	.again			; after them (the loader's)
	tst.l	g_LayBusy(a4)
	beq.s	.go
.again:
	moveq	#1,d0
	move.l	d0,g_LayAgain(a4)
	rts
.go:	PROFB	11
	bsr.s	GuiLayout
	PROFE	11
	IFD	PROFILE
	jsr	ProfLog			; (each relayout's time)
	ENDC
	tst.l	d0			; stopped meanwhile: the view stays
	beq.s	.x
	move.l	g_ScrollY(a4),d0
	clr.l	g_ScrollY(a4)
	bsr	ClampScroll
	move.l	d0,g_ScrollY(a4)
	bsr	GuiRefresh
	jmp	FragCheck		; (a #fragment that just came)
.x:	rts

; GuiLayout - lay the page out for the current width; again if the
; window gets another size meanwhile
; Out: d0 = 0 if the load stopped meanwhile (the runs shown stay)
;      (CCR set)
GuiLayout:
.go:	clr.l	g_LayAgain(a4)
	jsr	FramesPage		; a page of frames: each frame
	beq.s	.doc
	move.l	d0,a0
	jsr	FramesLayout
	bra.s	.res
.doc:	bsr	GuiPageWidth
	jsr	LayoutDocument
.res:	bne.s	.x
	tst.l	g_TkAbort(a4)
	bne.s	.stop
	tst.l	g_LayAgain(a4)
	bne.s	.go
.stop:	moveq	#0,d0
.x:	rts

; ClampScroll - In/Out: d0 = scroll position kept in range
ClampScroll:
	move.l	g_DocHeight(a4),d1
	sub.l	g_PageH(a4),d1
	bpl.s	.m
	moveq	#0,d1
.m:	cmp.l	d1,d0
	ble.s	.lo
	move.l	d1,d0
.lo:	tst.l	d0
	bpl.s	.x
	moveq	#0,d0
.x:	rts

; GuiSetUrl - show a URL in the URL gadget, unless the user is typing
; in it (a page that comes meanwhile does not overwrite what is typed)
; In: a0 = URL
GuiSetUrl:
	move.l	g_GadUrl(a4),d0
	beq.s	UrlX
	move.l	d0,a1
	btst	#7,gg_Flags+1(a1)	; GFLG_SELECTED: active
	bne.s	UrlX
; UrlPut - (gui.s) a0 = URL: shown in the URL gadget even if active
UrlPut:	jsr	FrameShow		; (not the frames' URLs)
	move.l	a0,UrlSetTags+4
	move.l	g_GadUrl(a4),d0
	beq.s	UrlX
	move.l	d0,a0
	move.l	g_Window(a4),a1
	movem.l	a2-a3,-(sp)
	suba.l	a2,a2
	lea	UrlSetTags,a3
	GT	GT_SetGadgetAttrsA
	movem.l	(sp)+,a2-a3
UrlX:	rts

; GuiSetTitle - In: a0 = window title (kept by the caller)
GuiSetTitle:
	move.l	g_Window(a4),d0
	beq.s	.x
	move.l	a0,a1
	move.l	d0,a0
	move.l	a2,-(sp)
	lea	ScreenTitle(pc),a2
	INTUI	SetWindowTitles
	move.l	(sp)+,a2
.x:	rts

ScreenTitle:	dc.b	"Velox "
	VERSION_STR
	dc.b	0
	even

; GuiBusy - In: d0 = 1 busy pointer on, 0 off
GuiBusy:
	move.l	g_Window(a4),d1
	beq.s	.x
	move.l	d0,BusyTags+4
	move.l	d1,a0
	lea	BusyTags,a1
	INTUI	SetWindowPointerA
.x:	rts

;--------------------------------------------------------------------
; Input
;--------------------------------------------------------------------

; GuiEventLoop - run until the window is closed or Ctrl-C.  The window's
; messages always come first; then the loader (task.s) runs until it
; yields; with nothing to do, sleep until a message or what the loader
; waits for.  Ctrl-C stops a load, or quits when nothing loads.
GuiEventLoop:
	movem.l	d2-d7/a2,-(sp)
.loop:	tst.l	g_Quit(a4)
	bne.s	.x
	tst.l	g_RefreshPend(a4)	; a refresh cut short for the user:
	beq.s	.nrp			; the rest
	clr.l	g_RefreshPend(a4)
	bsr	GuiRefresh
.nrp:
	IFD	PROFILE
	jsr	TaskNow			; (window events taking long: "slowmsg")
	move.l	d0,-(sp)
	ENDC
	bsr	HandleMessages
	IFD	PROFILE
	jsr	TaskNow
	sub.l	(sp)+,d0
	cmp.l	#7,d0
	blt.s	.fast
	lea	LogSlowMsg(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
.fast:
	ENDC
	tst.l	g_Quit(a4)
	bne.s	.x
	cmp.l	#LS_RUN,g_TkState(a4)
	bne.s	.idle
	jsr	TaskResume
	tst.l	g_TkState(a4)		; done: a NavGo it asked for?
	bne.s	.loop
	move.l	g_NavPending(a4),d0
	bpl.s	.loop
	clr.l	g_NavPending(a4)
	bclr	#31,d0
	lea	g_NavNext(a4),a0
	jsr	NavGo
	bra.s	.loop
.idle:	tst.l	g_PrgOn(a4)		; nothing loads: no progress bar
	beq.s	.ir
	jsr	TaskBusy
	bne.s	.ir
	bsr	ProgOff
.ir:	jsr	ImagesReap		; (a stopped load's decoder)
	move.l	d0,d2
	jsr	TaskLoopWait
	move.l	d0,d3
	and.l	d2,d0
	beq.s	.nr
	jsr	ImagesReapNow
.nr:	btst	#SIGBREAKB_CTRL_C,d3
	beq.s	.loop
	jsr	TaskBusy
	beq.s	.x
	jsr	NavStop
	bra.s	.loop
.x:	jsr	TaskAbort		; (a load unwinds: connections close)
	jsr	ImagesQuit		; (and its decoder ends)
	movem.l	(sp)+,d2-d7/a2
	rts

	IFD	PROFILE
LogSlowMsg:	dc.b	"slowmsg",0
	even
	ENDC

; HandleMessages - process all pending window messages
HandleMessages:
	movem.l	d2-d7/a2,-(sp)
.ta:	tst.l	g_TaCount(a4)		; events kept while loading first
	beq.s	.next
	lea	g_TaKeys(a4),a0
	move.l	(a0)+,d2
	moveq	#0,d3
	move.w	(a0)+,d3
	moveq	#0,d4
	move.w	(a0)+,d4
	move.l	(a0)+,a2
	move.w	(a0)+,d5
	ext.l	d5
	move.w	(a0)+,d6
	ext.l	d6
	move.l	(a0),g_PrevKeys(a4)
	bsr	DropDeferred
	bsr	HandleEvent
	tst.l	g_Quit(a4)
	bne.s	.x
	bra.s	.ta
.next:	move.l	g_Window(a4),a0
	move.l	wd_UserPort(a0),a0
	GT	GT_GetIMsg
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.l	im_Class(a1),d2
	moveq	#0,d3
	move.w	im_Code(a1),d3
	moveq	#0,d4
	move.w	im_Qualifier(a1),d4
	move.l	im_IAddress(a1),a2
	cmp.l	#IDCMP_RAWKEY,d2	; dead key info for MapRawKey
	bne.s	.nk
	move.l	(a2),g_PrevKeys(a4)
.nk:	move.w	im_MouseX(a1),d5
	ext.l	d5
	move.w	im_MouseY(a1),d6
	ext.l	d6
	GT	GT_ReplyIMsg
	bsr	HandleEvent
	tst.l	g_Quit(a4)
	beq.s	.next
.x:	bsr	ScrollFlush
	movem.l	(sp)+,d2-d7/a2
	rts

; FrameRoute - (a page of frames) the view of the frame that event d2
; (d3 code, a2 IAddress, d5/d6 mouse) is for in G: the mouse's the one
; under it (a press makes it the active one; a selection or the
; scroller being dragged stays in the active one), the wheel's the one
; under it, the keys', the scroller's and the menus' the active one;
; the others the page's
FrameRoute:
	cmp.l	#IDCMP_MOUSEMOVE,d2
	beq.s	.move
	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	beq.s	.click
	cmp.l	#IDCMP_RAWKEY,d2
	beq.s	.key
	cmp.l	#IDCMP_GADGETUP,d2
	beq.s	.act
	cmp.l	#IDCMP_GADGETDOWN,d2
	beq.s	.act
	cmp.l	#IDCMP_MENUPICK,d2
	beq.s	.act
	moveq	#0,d0
	jmp	ViewSelect
.key:	cmp.w	#RAW_WHEELUP,d3
	beq.s	.under
	cmp.w	#RAW_WHEELDOWN,d3
	beq.s	.under
.act:	move.l	g_FrActive(a4),d0
	jmp	ViewSelect
.under:	move.l	d5,d0
	move.l	d6,d1
	jsr	FrameAt
	beq.s	.act
	jmp	ViewSelect
.click:	cmp.w	#IECODE_LBUTTON,d3	; a press: the frame under it, now
	bne.s	.act			; the active one (a release: that)
	move.l	d5,d0
	move.l	d6,d1
	jsr	FrameAt
	beq.s	.act
	move.l	d0,g_FrActive(a4)
	jsr	ViewSelect
	bra	UpdateScroller
.move:	cmp.l	g_GadScroll(a4),a2	; dragging the scroller or selecting:
	beq.s	.act			; the active one
	move.l	g_FrActive(a4),d0
	jsr	ViewSelect
	tst.l	g_SelOn(a4)
	bne.s	.x
	move.l	d5,d0			; the one under the mouse (leaving one:
	move.l	d6,d1			; its link not hovered any more)
	jsr	FrameAt
	cmp.l	g_FrHover(a4),d0
	beq.s	.sel
	move.l	d0,-(sp)
	move.l	g_FrHover(a4),d0
	beq.s	.nh
	jsr	ViewSelect
	movem.l	d5-d6,-(sp)
	moveq	#-1,d5
	moveq	#-1,d6
	bsr	OnHover
	movem.l	(sp)+,d5-d6
.nh:	move.l	(sp)+,d0
	move.l	d0,g_FrHover(a4)
.sel:	jmp	ViewSelect
.x:	rts

; FocusTab - (Tab) FocusNext d0; a page of frames: past the last link
; of the active frame, on in the next frame (that one active then)
FocusTab:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	bsr	FocusNext
	tst.l	g_FrN(a4)
	beq.s	.x
	move.l	g_FrN(a4),d3		; (each frame once at most)
.f:	tst.l	g_FocusLink(a4)
	bne.s	.x
	subq.l	#1,d3
	bmi.s	.x
	move.l	g_ViewCur(a4),d0	; the next frame
	add.l	d2,d0
	bgt.s	.lo
	move.l	g_FrN(a4),d0
.lo:	cmp.l	g_FrN(a4),d0
	bls.s	.hi
	moveq	#1,d0
.hi:	move.l	d0,g_FrActive(a4)
	jsr	ViewSelect
	moveq	#-1,d0			; (from its start, or its end)
	move.l	d0,g_FocusIdx(a4)
	move.l	d2,d0
	bsr	FocusNext
	bra.s	.f
.x:	bsr	UpdateScroller
	movem.l	(sp)+,d2-d3
	rts

; ScrollFlush - show the scroller move kept by HandleEvent, if any
ScrollFlush:
	move.l	g_ScrollPend(a4),d0
	beq.s	.x
	clr.l	g_ScrollPend(a4)
	subq.l	#1,d0
	tst.l	g_FrN(a4)		; (a page of frames: the active one)
	beq	GuiScrollTo
	move.l	g_ViewCur(a4),-(sp)
	move.l	d0,-(sp)
	move.l	g_FrActive(a4),d0
	jsr	ViewSelect
	move.l	(sp)+,d0
	bsr	GuiScrollTo
	move.l	(sp)+,d0
	jmp	ViewSelect
.x:	rts

; HandleEvent - d2 = class, d3 = code, d4 = qualifier, a2 = IAddress,
; d5/d6 = mouse position.  Moves of the scroller being dragged are
; only noted (g_ScrollPend): of those waiting, only the last is shown,
; after the others (ScrollFlush), so the page keeps up with the knob.
HandleEvent:
	tst.l	g_FrN(a4)		; a page of frames: the view of the
	beq.s	HandleEvent1		; event's frame in G, then the page's
	bsr	FrameRoute		; again
	bsr.s	HandleEvent1
	moveq	#0,d0
	jmp	ViewSelect
HandleEvent1:
	tst.l	g_ScrollPend(a4)
	beq.s	.np
	cmp.l	#IDCMP_MOUSEMOVE,d2
	bne.s	.fl
	cmp.l	g_GadScroll(a4),a2
	beq.s	.np
.fl:	bsr.s	ScrollFlush
.np:
	cmp.l	#IDCMP_RAWKEY,d2	; the user scrolls or types: a pending
	bne.s	.ngd0			; jump to a #fragment is off
	cmp.w	#$80,d3			; (presses: not releases)
	blo.s	.user
	bra.s	.nu
.ngd0:	cmp.l	#IDCMP_GADGETDOWN,d2
	bne.s	.nu
.user:	clr.l	g_FragPend(a4)
	movem.l	d0-d1/a0-a1,-(sp)	; (when: layout waits while the user
	jsr	TaskNow			;  scrolls)
	move.l	d0,g_UserTick(a4)
	movem.l	(sp)+,d0-d1/a0-a1
.nu:	cmp.l	#IDCMP_CLOSEWINDOW,d2
	bne.s	.nc
	moveq	#1,d0
	move.l	d0,g_Quit(a4)
	rts
.nc:	cmp.l	#IDCMP_NEWSIZE,d2
	beq	OnResize
	cmp.l	#IDCMP_REFRESHWINDOW,d2
	bne.s	.nr
	move.l	g_Window(a4),a0
	GT	GT_BeginRefresh
	move.l	g_Window(a4),a0
	moveq	#-1,d0
	GT	GT_EndRefresh
	bra	GuiPaintAll
.nr:	cmp.l	#IDCMP_GADGETUP,d2
	beq	OnGadget
	cmp.l	#IDCMP_MOUSEMOVE,d2
	bne.s	.nm
	cmp.l	g_GadScroll(a4),a2	; scroller being dragged
	bne	OnHover
	move.l	d3,d0
	addq.l	#1,d0
	move.l	d0,g_ScrollPend(a4)
	rts
.nm:	cmp.l	#IDCMP_GADGETDOWN,d2
	bne.s	.ngd
	cmp.l	g_GadScroll(a4),a2
	bne.s	.x
	moveq	#1,d0			; held: not moved under the mouse
	move.l	d0,g_Dragging(a4)
	move.l	d3,d0
	bra	GuiScrollTo
.ngd:	cmp.l	#IDCMP_INTUITICKS,d2	; a meta refresh counting down
	bne.s	.nt
	bsr	ProgTick		; (and the progress bar moving)
	tst.l	g_RefreshTicks(a4)
	beq.s	.x
	subq.l	#1,g_RefreshTicks(a4)
	bne.s	.x
	jmp	NavRefresh
.nt:	cmp.l	#IDCMP_MENUPICK,d2
	beq	OnMenu
	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	beq	OnClick
	cmp.l	#IDCMP_RAWKEY,d2
	bne.s	.x
	lea	LogKey(pc),a0		; (key events are logged for tests)
	suba.l	a1,a1
	move.l	d3,d0
	jsr	LogEvent
	bra	OnKey
.x:	rts

LogKey:	dc.b	"key",0
	even

; OnGadget - a gadget was released (a2 = gadget, d3 = code)
OnGadget:
	move.w	gg_GadgetID(a2),d0
	cmp.w	#GID_SCROLL,d0
	bne.s	.ns
	clr.l	g_Dragging(a4)		; let go: now it shows the page again
	move.l	d3,d0
	bsr	GuiScrollTo
	bra	UpdateScroller
.ns:	cmp.w	#GID_BACK,d0
	beq	ToNavBack
	cmp.w	#GID_FWD,d0
	beq	ToNavForward
	cmp.w	#GID_RELOAD,d0		; (while loading: stops it)
	bne.s	.nrl
	jsr	TaskBusy
	beq	ToNavReload
	jmp	NavStop
.nrl:
	cmp.w	#GID_HOME,d0
	beq	ToNavHome
	cmp.w	#GID_URL,d0
	bne.s	.x
	move.l	gg_SpecialInfo(a2),a0
	move.l	si_Buffer(a0),a0
	lea	g_UrlTmp2(a4),a1
	jsr	UrlFixup
	lea	g_UrlTmp2(a4),a0
	moveq	#1,d0
	jmp	NavGo
.x:	rts

; OnKey - raw keys: cursor up/down, space, backspace, mouse wheel
OnKey:
	tst.l	g_Blank(a4)		; blank (a new page loading): only the
	bne.s	.blank			; commands, Esc and Back
	tst.l	g_EditField(a4)		; a field being edited gets keys first
	beq.s	.noedit
	move.l	d3,d0
	move.l	d4,d1
	jsr	FormEditKey
	tst.l	d0
	bne	.x
.noedit:
	move.l	d3,d0			; then finding in the page
	move.l	d4,d1
	jsr	FindKey
	tst.l	d0
	bne	.x
	cmp.w	#$80,d3			; ignore key releases
	bhs	.x
.cmd:	move.w	d4,d0			; Ctrl / Amiga + key: commands
	and.w	#QUAL_COMMAND,d0
	beq.s	.plain
	cmp.w	#RAW_L,d3
	beq	ActivateUrl
	cmp.w	#RAW_B,d3
	beq	ToNavBack
	cmp.w	#RAW_F,d3
	beq	ToNavForward
	cmp.w	#RAW_R,d3
	beq	ToNavReload
	cmp.w	#RAW_H,d3
	beq	ToNavHome
	cmp.w	#RAW_D,d3
	beq	MenuAddBm
	cmp.w	#RAW_K,d3
	beq	MenuBookmarks
	cmp.w	#RAW_Q,d3
	bne.s	.nq
	moveq	#1,d0
	move.l	d0,g_Quit(a4)
	rts
.nq:	cmp.w	#RAW_UP,d3
	bne.s	.nt
	moveq	#0,d0			; top
	bra	GuiScrollTo
.nt:	cmp.w	#RAW_DOWN,d3
	bne.s	.plain
	move.l	g_DocHeight(a4),d0	; bottom
	bra	GuiScrollTo
.plain:	cmp.w	#RAW_ESC,d3		; Esc: no more images
	beq	ToImagesStop
	cmp.w	#RAW_TAB,d3
	bne.s	.ntab
	moveq	#1,d0
	move.w	d4,d1
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d1
	beq	FocusTab
	moveq	#-1,d0
	bra	FocusTab
.ntab:	cmp.w	#RAW_RETURN,d3
	beq.s	.follow
	cmp.w	#RAW_ENTER,d3
	bne.s	.scroll
.follow:
	move.l	g_FocusLink(a4),d0
	beq.s	.x
	move.l	d0,a0
	bra	Activate
.blank:	cmp.w	#$80,d3
	bhs.s	.x
	move.w	d4,d0
	and.w	#QUAL_COMMAND,d0
	bne	.cmd
	cmp.w	#RAW_ESC,d3
	beq	ToImagesStop
	cmp.w	#RAW_BACKSPACE,d3
	beq	ToNavBack
.x:	rts
.scroll:
	moveq	#0,d0
	move.w	g_FontH+2(a4),d0	; d0 = a line
	addq.l	#2,d0
	move.l	g_PageH(a4),d1
	sub.l	d0,d1			; d1 = a page minus a line
	move.l	d4,d7
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d7
	cmp.w	#RAW_UP,d3
	bne.s	.n1
	tst.w	d7
	beq.s	.up
	move.l	d1,d0
.up:	neg.l	d0
	bra.s	.go
.n1:	cmp.w	#RAW_DOWN,d3
	bne.s	.n2
	tst.w	d7
	beq.s	.go
	move.l	d1,d0
	bra.s	.go
.n2:	cmp.w	#RAW_SPACE,d3
	bne.s	.n3
	move.l	d1,d0
	tst.w	d7
	beq.s	.go
	neg.l	d0
	bra.s	.go
.n3:	cmp.w	#RAW_WHEELUP,d3
	bne.s	.n4
	mulu.w	#3,d0
	neg.l	d0
	bra.s	.go
.n4:	cmp.w	#RAW_WHEELDOWN,d3
	bne.s	.n5
	mulu.w	#3,d0
	bra.s	.go
.n5:	cmp.w	#RAW_BACKSPACE,d3
	beq	ToNavBack
	move.l	d3,d0			; '/' (wherever the keymap has it):
	move.l	d4,d1			; find in the page
	jsr	KeyToChars
	subq.l	#1,d0
	bne.s	.n6
	cmp.b	#'/',g_KeyChars(a4)
	beq	MenuFind
.n6:	rts
.go:	add.l	g_ScrollY(a4),d0
	bra	GuiScrollTo

; trampolines: conditional branches cannot reach other modules
ToNavBack:	jmp	NavBack
ToNavForward:	jmp	NavForward
ToNavReload:	jmp	NavReload
ToNavHome:	jmp	NavHome
ToImagesStop:	jmp	NavStop
ToNavLink:	jmp	NavLink
ToFormActivate:	jmp	FormActivate

; ActivateUrl - empty the URL gadget and put the cursor into it
; ("open location"; clicking the gadget edits the current URL instead)
ActivateUrl:
	movem.l	d2-d4/a2-a3,-(sp)
	; keys typed right after Ctrl-L may already be queued (when the
	; event loop was busy): they belong in the field
	lea	g_StatusBuf(a4),a3
	moveq	#0,d4			; length
.peek:	bsr	TypeAheadKey
	beq.s	.port
	move.l	d0,d2
	move.l	d1,d3
	bra.s	.key
.port:	move.l	g_Window(a4),a0
	move.l	wd_UserPort(a0),a2
	move.l	MP_MSGLIST+LH_HEAD(a2),a1
	tst.l	LN_SUCC(a1)
	beq.s	.set
	cmp.l	#IDCMP_RAWKEY,im_Class(a1)
	bne.s	.set
	move.l	a2,a0
	GT	GT_GetIMsg
	tst.l	d0
	beq.s	.set
	move.l	d0,a1
	moveq	#0,d2
	move.w	im_Code(a1),d2
	moveq	#0,d3
	move.w	im_Qualifier(a1),d3
	move.l	im_IAddress(a1),a0
	move.l	(a0),g_PrevKeys(a4)	; (dead keys)
	GT	GT_ReplyIMsg
.key:	cmp.w	#$80,d2			; releases
	bhs.s	.peek
	cmp.w	#RAW_RETURN,d2
	beq.s	.go
	cmp.w	#RAW_ENTER,d2
	beq.s	.go
	move.l	d2,d0
	move.l	d3,d1
	jsr	KeyToChars
	move.l	d0,d2
	ble.s	.peek
	lea	g_KeyChars(a4),a0
.ch:	move.b	(a0)+,d0
	cmp.b	#32,d0
	blo.s	.chn
	cmp.l	#STATUS_MAX-2,d4
	bhs.s	.chn
	move.b	d0,(a3,d4.l)
	addq.l	#1,d4
.chn:	subq.l	#1,d2
	bne.s	.ch
	bra.s	.peek
.set:	clr.b	(a3,d4.l)
	move.l	a3,a0
	bsr	UrlPut
	move.l	g_GadUrl(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	gg_SpecialInfo(a0),a1	; the cursor after the text
	move.w	d4,si_BufferPos(a1)
	move.l	g_Window(a4),a1
	suba.l	a2,a2
	INTUI	ActivateGadget
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts
.go:	clr.b	(a3,d4.l)		; Return was typed too: go there
	move.l	a3,a0
	lea	g_UrlTmp2(a4),a1
	jsr	UrlFixup
	movem.l	(sp)+,d2-d4/a2-a3
	lea	g_UrlTmp2(a4),a0
	moveq	#1,d0
	jmp	NavGo

; FocusNext - move the keyboard focus to the next/previous link
; In: d0 = 1 forward, -1 backward
FocusNext:
	movem.l	d2-d4/a2,-(sp)
	move.l	d0,d2
	jsr	RunCount
	move.l	d0,d3
	move.l	g_FocusIdx(a4),d4
	tst.l	d2
	bpl.s	.l
	tst.l	d4			; backwards from "no focus": the end
	bpl.s	.l
	move.l	d3,d4
.l:	add.l	d2,d4
	bmi.s	.none
	cmp.l	d3,d4
	bge.s	.none
	move.l	d4,d0
	jsr	RunPtr
	move.l	ru_Link(a0),d0
	beq.s	.l
	cmp.l	g_FocusLink(a4),d0
	beq.s	.l
	move.l	a0,a2
	move.l	g_FocusLink(a4),-(sp)	; (the old one: repainted too)
	move.l	d0,g_FocusLink(a4)
	move.l	d4,g_FocusIdx(a4)
	; scroll it into view
	move.l	ru_Y(a2),d0
	cmp.l	g_ScrollY(a4),d0
	blt.s	.show
	moveq	#0,d1
	move.w	ru_H(a2),d1
	add.l	d1,d0
	move.l	g_ScrollY(a4),d1
	add.l	g_PageH(a4),d1
	cmp.l	d1,d0
	ble.s	.paint
.show:	move.l	ru_Y(a2),d0
	move.l	g_PageH(a4),d1
	lsr.l	#2,d1
	sub.l	d1,d0
	addq.l	#4,sp
	bsr	GuiScrollTo
	bra.s	.pd
.paint:	move.l	(sp)+,d0		; in view: just the two links
	beq.s	.p1
	move.l	d0,a0
	bsr	GuiPaintNode
.p1:	move.l	g_FocusLink(a4),a0
	bsr	GuiPaintNode
.pd:	move.l	g_FocusLink(a4),a0
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	bne.s	.got
	move.l	g_FocusLink(a4),a0	; controls: their name
	lea	AnName(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
.got:
	move.l	d0,a1
	lea	LogFocus(pc),a0
	move.l	a1,-(sp)
	move.l	#$80000000,d0
	jsr	LogEvent
	move.l	(sp)+,a0
	bsr	GuiStatus
	bra.s	.x
.none:	move.l	g_FocusLink(a4),d0
	clr.l	g_FocusLink(a4)
	moveq	#-1,d1
	move.l	d1,g_FocusIdx(a4)
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	bsr	GuiPaintNode
.x:	movem.l	(sp)+,d2-d4/a2
	rts

EmptyStr:	dc.b	0
LogFocus:	dc.b	"focus",0
LogScroll:	dc.b	"scroll",0
	even

; LinkAt - link under a window position
; In: d5/d6 = mouse x/y; Out: d0 = <a> element or 0, a0 = run
LinkAt:
	movem.l	d2-d4,-(sp)
	move.l	d5,d2
	sub.l	g_PageX(a4),d2		; document x
	bmi.s	.none
	cmp.l	g_PageW(a4),d2
	bge.s	.none
	move.l	d6,d3
	sub.l	g_PageY(a4),d3
	bmi.s	.none
	cmp.l	g_PageH(a4),d3
	bge.s	.none
	add.l	g_ScrollY(a4),d3	; document y
	jsr	RunCount
	move.l	d0,d4
.l:	subq.l	#1,d4
	bmi.s	.none
	move.l	d4,d0
	jsr	RunPtr
	tst.l	ru_Link(a0)
	beq.s	.l
	move.l	ru_Y(a0),d0
	cmp.l	d0,d3
	blt.s	.l
	moveq	#0,d1
	move.w	ru_H(a0),d1
	add.l	d1,d0
	cmp.l	d0,d3
	bge.s	.l
	move.w	ru_X(a0),d0
	ext.l	d0
	cmp.l	d0,d2
	blt.s	.l
	move.w	ru_W(a0),d1
	ext.l	d1
	add.l	d1,d0
	cmp.l	d0,d2
	bge.s	.l
	move.l	ru_Link(a0),d0
	bra.s	.x
.none:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4
	rts

; OnHover - show the link under the mouse in the status line
OnHover:
	tst.l	g_Blank(a4)		; (blank: no links)
	bne	ScrollNone
	tst.l	g_SelOn(a4)		; selecting
	beq.s	.nosel
	jmp	SelMove
.nosel:	bsr	LinkAt
	cmp.l	g_HoverLink(a4),d0
	beq.s	.x
	move.l	d0,g_HoverLink(a4)
	beq.s	.nolink
	move.l	d0,a0
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	bra	GuiStatus
.nolink:
	lea	g_TitleText(a4),a0
	bra	GuiStatus
.x:	rts

AnHref:	dc.b	"href",0
AnName:	dc.b	"name",0
	even

; OnMenu - menu selection(s); d3 = menu number
OnMenu:
	movem.l	d2/a2,-(sp)
	move.l	d3,d2
.l:	cmp.w	#MENUNULL,d2
	beq.s	.x
	tst.l	g_Quit(a4)
	bne.s	.x
	move.l	g_Menu(a4),a0
	moveq	#0,d0
	move.w	d2,d0
	INTUI	ItemAddress
	tst.l	d0
	beq.s	.x
	move.l	d0,a2
	move.w	mi_NextSelect(a2),d2
	move.l	mi_SIZEOF(a2),d0	; user data: the action
	lea	MenuActions(pc),a0
	add.w	d0,d0
	add.w	(a0,d0.w),a0
	jsr	(a0)
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

MA_OPEN		equ	0
MA_SAVE		equ	1
MA_ABOUT	equ	2
MA_QUIT		equ	3
MA_BACK		equ	4
MA_FWD		equ	5
MA_RELOAD	equ	6
MA_HOME		equ	7
MA_ADDBM	equ	8
MA_BOOKMARKS	equ	9
MA_FIND		equ	10
MA_COPY		equ	11
MA_SOURCE	equ	12
MenuActions:
	dc.w	ActivateUrl-MenuActions,MenuSave-MenuActions
	dc.w	GuiAbout-MenuActions,MenuQuit-MenuActions
	dc.w	ToNavBack-MenuActions,ToNavForward-MenuActions
	dc.w	ToNavReload-MenuActions,ToNavHome-MenuActions
	dc.w	MenuAddBm-MenuActions,MenuBookmarks-MenuActions
	dc.w	MenuFind-MenuActions,MenuCopy-MenuActions
	dc.w	MenuSource-MenuActions

MenuSave:	jmp	SaveDownload
MenuAddBm:	jmp	BookmarkAdd
MenuBookmarks:	jmp	BookmarksShow
MenuFind:	jmp	FindStart
MenuCopy:	jmp	CopyAddress
MenuSource:	jmp	ViewSource
MenuQuit:	moveq	#1,d0
		move.l	d0,g_Quit(a4)
		rts

; GuiAbout - the About requester
GuiAbout:
	move.l	a2,-(sp)
	move.l	g_Window(a4),a0
	lea	AboutEasy(pc),a1
	suba.l	a2,a2
	move.l	a3,-(sp)
	suba.l	a3,a3
	INTUI	EasyRequestArgs
	move.l	(sp)+,a3
	move.l	(sp)+,a2
	rts

AboutEasy:
	dc.l	EasyStruct_SIZEOF,0,AboutTitle,AboutText,AboutOk

; OnClick - follow a link / use a control on button release over it
OnClick:
	tst.l	g_Blank(a4)		; (blank: no links)
	bne	ScrollNone
	cmp.w	#IECODE_LBUTTON,d3
	bne.s	.up
	bsr	LinkAt
	move.l	d0,g_PressLink(a4)
	bne.s	.link
	jsr	SelPress		; on text: a selection starts
	moveq	#0,d0
.link:	cmp.l	g_EditField(a4),d0	; clicking elsewhere ends editing
	beq.s	.x
	jmp	FormLeave
.up:	cmp.w	#IECODE_LBUTTON|IECODE_UP_PREFIX,d3
	bne.s	.x
	jsr	SelRelease
	bsr	LinkAt
	tst.l	d0
	beq.s	.x
	cmp.l	g_PressLink(a4),d0
	bne.s	.x
	clr.l	g_PressLink(a4)
	move.l	d0,a0
	bra	Activate
.x:	rts

; Activate - follow a link or use a form control
; In: a0 = <a> element or control; d4 = qualifier (Shift = backwards)
Activate:
	move.l	a0,-(sp)
	jsr	FormIsControl
	movem.l	(sp)+,a0
	tst.l	d0
	beq	ToNavLink
	moveq	#1,d0
	move.w	d4,d1
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d1
	beq	ToFormActivate
	moveq	#-1,d0
	jmp	FormActivate

; OnResize - new window size: rebuild gadgets, lay out again
OnResize:
	move.l	g_Window(a4),a0
	move.l	g_GList(a4),a1
	moveq	#-1,d0
	INTUI	RemoveGList
	move.l	g_GList(a4),a0
	clr.l	g_GList(a4)
	GT	FreeGadgets
	clr.l	g_GadUrl(a4)
	clr.l	g_GadScroll(a4)
	bsr	CreateGadgets
	clr.l	g_BandsOk(a4)
	bra	GuiRelayout

;--------------------------------------------------------------------
; GuiNetHook - called by the network code when a window message or
; Ctrl-C arrives while a page loads (BusyEvents)
; In:  d0 = signals received
; Out: d0 = 1 to abort the transfer
;--------------------------------------------------------------------
GuiNetHook:
	btst	#SIGBREAKB_CTRL_C,d0
	bne.s	.abort
	moveq	#1,d0
	bsr	BusyEvents
	move.l	g_AbortReq(a4),d0	; (stopped: it stays stopped)
	rts
.abort:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; BusyEvents - serve the window while loading.  Messages that only
; change the view (IsViewEvent) are handled at once; the others are kept
; for the event loop (Defer).
; In:  d0 = 0 while images load: the first event kept stops the image
;      (it is loaded again later), and the rest stay in the port;
;      d0 = 1 while a page loads: keys and new sizes are kept for after
;      it; gadgets, menus and links of the shown page are kept and stop
;      the load (g_AbortReq), "Reload" just stops it, closing the window
;      quits; other messages belong to the old page and are dropped
; Out: d0 = 1 if the image should stop (CCR set)
;--------------------------------------------------------------------
BusyEvents:
	movem.l	d2-d7/a2,-(sp)
	move.l	d0,d7			; d7 = mode
.next:	move.l	g_Window(a4),a0
	move.l	wd_UserPort(a0),a0
	GT	GT_GetIMsg
	tst.l	d0
	beq	.done
	move.l	d0,a1
	move.l	im_Class(a1),d2
	moveq	#0,d3
	move.w	im_Code(a1),d3
	moveq	#0,d4
	move.w	im_Qualifier(a1),d4
	move.l	im_IAddress(a1),a2
	cmp.l	#IDCMP_RAWKEY,d2	; (IAddress is only valid until
	bne.s	.nk			; the reply)
	move.l	(a2),g_PrevKeys(a4)
	suba.l	a2,a2
.nk:	move.w	im_MouseX(a1),d5
	ext.l	d5
	move.w	im_MouseY(a1),d6
	ext.l	d6
	GT	GT_ReplyIMsg
	cmp.l	#IDCMP_INTUITICKS,d2	; (a meta refresh waits)
	bne.s	.ntk
	bsr	ProgTick
	bra.s	.next
.ntk:
	cmp.l	#IDCMP_REFRESHWINDOW,d2
	bne.s	.nr
	move.l	g_Window(a4),a0
	GT	GT_BeginRefresh
	move.l	g_Window(a4),a0
	moveq	#-1,d0
	GT	GT_EndRefresh
	clr.l	g_BandsOk(a4)		; (painted now, or after the load)
	tst.l	g_Blank(a4)
	bne.s	.pa
	tst.l	g_ViewLive(a4)
	beq.s	.next
.pa:	bsr	GuiPaintAll
	bra.s	.next
.nr:	bsr	IsViewEvent
	beq.s	.other
	bsr	HandleEvent
	bra.s	.next
.other:	tst.l	d7
	bne.s	.page
	bsr	Defer			; images: the event loop does it now
	moveq	#1,d0
	bra.s	.x
.page:	cmp.l	#IDCMP_RAWKEY,d2
	beq.s	.key
	cmp.l	#IDCMP_NEWSIZE,d2
	beq.s	.keep
	cmp.l	#IDCMP_CLOSEWINDOW,d2
	beq.s	.close
	cmp.l	#IDCMP_MENUPICK,d2
	beq.s	.go
	cmp.l	#IDCMP_GADGETUP,d2
	beq.s	.gad
	cmp.l	#IDCMP_MOUSEBUTTONS,d2	; (a link released on)
	bne	.next
	tst.l	g_ViewLive(a4)
	beq	.next
	bra.s	.go
.gad:	cmp.w	#GID_RELOAD,gg_GadgetID(a2)	; "Reload" stops a load
	beq.s	.stop
.go:	bsr	Defer
.stop:	moveq	#1,d0
	move.l	d0,g_AbortReq(a4)
	bra	.next
.close:	moveq	#1,d0
	move.l	d0,g_Quit(a4)
	bra.s	.stop
.key:	cmp.w	#$80,d3			; (releases are not needed)
	bhs	.next
	cmp.w	#RAW_ESC,d3		; Esc stops the load
	beq.s	.stop
.keep:	bsr	Defer
	bra	.next
.done:	bsr	ScrollFlush
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2
	rts

;--------------------------------------------------------------------
; IsViewEvent - does event d2 (class), d3 (code), d4 (qualifier), a2
; (IAddress) only change the view, so that it can be handled while
; something loads?  Never while the runs are not those of the page.
; Out: d0 = 1 if yes (CCR set)
;--------------------------------------------------------------------
IsViewEvent:
	tst.l	g_ViewLive(a4)
	beq.s	.no
	cmp.l	#IDCMP_MOUSEMOVE,d2	; hovering, dragging the scroller
	beq.s	.yes
	cmp.l	#IDCMP_NEWSIZE,d2
	beq.s	.yes
	cmp.l	#IDCMP_GADGETDOWN,d2	; the scroller
	beq.s	.gad
	cmp.l	#IDCMP_GADGETUP,d2
	beq.s	.gad
	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	beq.s	.but
	cmp.l	#IDCMP_RAWKEY,d2
	bne.s	.no
	cmp.w	#$80,d3			; releases
	bhs.s	.yes
	cmp.w	#$60,d3			; Shift, Ctrl, Alt, Amiga alone
	blo.s	.k
	cmp.w	#$67,d3
	bls.s	.yes
.k:	tst.l	g_EditField(a4)		; typing into a field, keys kept:
	bne.s	.no			; in order
	tst.l	g_TaCount(a4)
	bne.s	.no
	cmp.w	#RAW_UP,d3		; scrolling keys
	beq.s	.yes
	cmp.w	#RAW_DOWN,d3
	beq.s	.yes
	move.w	d4,d0
	and.w	#QUAL_COMMAND,d0
	bne.s	.no
	cmp.w	#RAW_SPACE,d3
	beq.s	.yes
	cmp.w	#RAW_WHEELUP,d3
	beq.s	.yes
	cmp.w	#RAW_WHEELDOWN,d3
	beq.s	.yes
	bra.s	.no
.gad:	cmp.l	g_GadScroll(a4),a2
	beq.s	.yes
	bra.s	.no
.but:	cmp.w	#IECODE_LBUTTON,d3	; pressing: on a link nothing happens
	beq.s	.yes			; yet
	cmp.w	#IECODE_LBUTTON|IECODE_UP_PREFIX,d3
	bne.s	.no
	tst.l	g_PressLink(a4)		; releasing on a link follows it
	beq.s	.yes
.no:	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

; Defer - keep event d2-d6/a2 (and g_PrevKeys) for the event loop
; (TYPEAHEAD at most)
Defer:
	move.l	g_TaCount(a4),d0
	cmp.l	#TYPEAHEAD,d0
	bhs.s	.x
	addq.l	#1,g_TaCount(a4)
	mulu.w	#TA_SIZEOF,d0
	lea	g_TaKeys(a4),a0
	add.l	d0,a0
	move.l	d2,(a0)+
	move.w	d3,(a0)+
	move.w	d4,(a0)+
	move.l	a2,(a0)+
	move.w	d5,(a0)+
	move.w	d6,(a0)+
	move.l	g_PrevKeys(a4),(a0)
.x:	rts

; DropDeferred - remove the oldest kept event
DropDeferred:
	subq.l	#1,g_TaCount(a4)
	move.l	g_TaCount(a4),d0
	mulu.w	#TA_SIZEOF/4,d0
	lea	g_TaKeys(a4),a0
	bra.s	.e
.m:	move.l	TA_SIZEOF(a0),(a0)+
.e:	dbf	d0,.m
	rts

;--------------------------------------------------------------------
; WinGeometry - the window position and size of the last run
; (Velox/Window = "x y w h"), kept on the screen
;--------------------------------------------------------------------
WinGeometry:
	movem.l	d2-d6,-(sp)
	lea	VarWindow(pc),a0
	move.l	a0,d1
	lea	g_VarBuf(a4),a0
	move.l	a0,d2
	moveq	#63,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	ble.s	.x
	lea	g_VarBuf(a4),a0
	bsr	.num
	move.l	d0,d2			; x
	bsr	.num
	move.l	d0,d3			; y
	bsr	.num
	move.l	d0,d4			; w
	bsr	.num
	move.l	d0,d5			; h
	cmp.l	#200,d4			; (at least the minimum size)
	blo.s	.x
	cmp.l	#100,d5
	blo.s	.x
	move.l	g_Screen(a4),a1
	moveq	#0,d6
	move.w	sc_Width(a1),d6
	cmp.l	d6,d4			; no wider than the screen
	bls.s	.w
	move.l	d6,d4
.w:	sub.l	d4,d6			; nor off its right edge
	cmp.l	d6,d2
	bls.s	.xok
	move.l	d6,d2
.xok:	moveq	#0,d6
	move.w	sc_Height(a1),d6
	cmp.l	d6,d5
	bls.s	.h
	move.l	d6,d5
.h:	sub.l	d5,d6
	cmp.l	d6,d3
	bls.s	.yok
	move.l	d6,d3
.yok:	move.l	d2,WinTags+4
	move.l	d3,WinTagT+4
	move.l	d4,WinTagW+4
	move.l	d5,WinTagH+4
.x:	movem.l	(sp)+,d2-d6
	rts
.num:	cmp.b	#' ',(a0)
	bne.s	.n
	addq.l	#1,a0
	bra.s	.num
.n:	jmp	ParseDec

; SaveGeometry - remember the window position and size (ENVARC too)
SaveGeometry:
	movem.l	d2-d4/a2,-(sp)
	move.l	g_Window(a4),a2
	lea	g_VarBuf(a4),a0
	moveq	#0,d0
	move.w	wd_LeftEdge(a2),d0
	bsr.s	.put
	moveq	#0,d0
	move.w	wd_TopEdge(a2),d0
	bsr.s	.put
	moveq	#0,d0
	move.w	wd_Width(a2),d0
	bsr.s	.put
	moveq	#0,d0
	move.w	wd_Height(a2),d0
	bsr.s	.put
	clr.b	-(a0)			; (no blank at the end)
	lea	VarWindow(pc),a0
	move.l	a0,d1
	lea	g_VarBuf(a4),a0
	move.l	a0,d2
	moveq	#-1,d3			; (NUL terminated)
	move.l	#$1100,d4		; GVF_GLOBAL_ONLY|GVF_SAVE_VAR
	DOS	SetVar
	movem.l	(sp)+,d2-d4/a2
	rts
.put:	jsr	FmtDec			; a number and a blank
	move.b	#' ',(a0)+
	rts

VarWindow:	dc.b	"Velox/Window",0
	even

;--------------------------------------------------------------------
; GuiProgress - the progress of a transfer in the status line
; In: d0 = bytes so far, d1 = all bytes or -1
;--------------------------------------------------------------------
GuiProgress:
	movem.l	d0-d1,-(sp)		; the bar (it shows less than a KB)
	bsr	GuiProgSet
	movem.l	(sp)+,d0-d1
	movem.l	d2,-(sp)
	lsr.l	#8,d0			; KB
	lsr.l	#2,d0
	cmp.l	g_ProgKB(a4),d0		; only when that changes
	beq.s	.x
	move.l	d0,g_ProgKB(a4)
	move.l	d1,d2
	lea	LogRecv(pc),a0		; (for tests)
	suba.l	a1,a1
	jsr	LogEvent
	lea	MsgRecv(pc),a0
	lea	g_StatusBuf(a4),a1
	jsr	StrCopy
	move.l	a1,a0
	move.l	g_ProgKB(a4),d0
	jsr	FmtDec
	tst.l	d2
	ble.s	.kb
	move.l	a0,a1
	lea	MsgOf(pc),a0
	jsr	StrCopy
	move.l	a1,a0
	move.l	d2,d0
	lsr.l	#8,d0
	lsr.l	#2,d0
	jsr	FmtDec
.kb:	move.l	a0,a1
	lea	MsgKB(pc),a0
	jsr	StrCopy
	lea	g_StatusBuf(a4),a0
	bsr	GuiStatus
.x:	movem.l	(sp)+,d2
	rts

MsgRecv:	dc.b	"Received ",0
LogRecv:	dc.b	"recv",0
LogPageX:	dc.b	"pagex",0
LogPageY:	dc.b	"pagey",0
MsgOf:		dc.b	" of ",0
MsgKB:		dc.b	" KB",0
	even

;--------------------------------------------------------------------
; TypeAheadKey - the oldest event kept while loading, if it is a key
; Out: d0 = raw code, d1 = qualifier (g_PrevKeys set); Z set if none
;--------------------------------------------------------------------
TypeAheadKey:
	tst.l	g_TaCount(a4)
	beq.s	.no
	lea	g_TaKeys(a4),a0
	cmp.l	#IDCMP_RAWKEY,(a0)	; (only keys: other events end it)
	bne.s	.no
	moveq	#0,d0
	move.w	4(a0),d0
	moveq	#0,d1
	move.w	6(a0),d1
	move.l	16(a0),g_PrevKeys(a4)
	movem.l	d0-d1,-(sp)
	bsr	DropDeferred
	movem.l	(sp)+,d0-d1
	and.b	#$fb,ccr		; Z clear: a key
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; ImgNetHook - the network hook while an image loads: scrolling and the
; like are handled at once; anything else (following a link, a menu...)
; stops the image, which is fetched again later (BusyEvents)
; In: d0 = signals; Out: d0 = 1 to abort
;--------------------------------------------------------------------
ImgNetHook:
	btst	#SIGBREAKB_CTRL_C,d0
	bne.s	.abort
	moveq	#0,d0
	bra	BusyEvents
.abort:	moveq	#1,d0
	rts

;====================================================================
	section	data,data
;====================================================================
WinTags:
	dc.l	WA_Left,0
WinTagT:dc.l	WA_Top,0
WinTagW:dc.l	WA_Width,640
WinTagH:dc.l	WA_Height,400
WinTagScr:
	dc.l	WA_PubScreen,0
	dc.l	WA_Title,WinTitle
	dc.l	WA_ScreenTitle,WinTitle
	dc.l	WA_MinWidth,200
	dc.l	WA_MinHeight,100
	dc.l	WA_MaxWidth,-1
	dc.l	WA_MaxHeight,-1
	dc.l	WA_DragBar,1
	dc.l	WA_DepthGadget,1
	dc.l	WA_CloseGadget,1
	dc.l	WA_SizeGadget,1
	dc.l	WA_SizeBBottom,1
	dc.l	WA_SmartRefresh,1
	dc.l	WA_Activate,1
	dc.l	WA_ReportMouse,1
	dc.l	WA_NewLookMenus,1
	dc.l	WA_IDCMP,IDCMP_CLOSEWINDOW|IDCMP_NEWSIZE|IDCMP_REFRESHWINDOW|IDCMP_GADGETUP|IDCMP_GADGETDOWN|IDCMP_MOUSEMOVE|IDCMP_MOUSEBUTTONS|IDCMP_RAWKEY|IDCMP_INTUITICKS|IDCMP_MENUPICK
	dc.l	TAG_DONE

UrlTags:
	dc.l	GTST_MaxChars,URL_MAX-1
	dc.l	GTST_String,0
	dc.l	TAG_DONE
UrlSetTags:
	dc.l	GTST_String,0
	dc.l	TAG_DONE
ScrollTags:
	dc.l	PGA_Freedom,LORIENT_VERT
	dc.l	GTSC_Arrows,10
	dc.l	GTSC_Total,1
	dc.l	GTSC_Visible,1
	dc.l	GA_RelVerify,1
	dc.l	GA_Immediate,1
	dc.l	TAG_DONE
ScrTags:
ScrTagTop:	dc.l	GTSC_Top,0
ScrTagTotal:	dc.l	GTSC_Total,1
ScrTagVis:	dc.l	GTSC_Visible,1
	dc.l	TAG_DONE
BusyTags:
	dc.l	WA_BusyPointer,0
	dc.l	TAG_DONE

WinTitle:	dc.b	"Velox",0

NM	MACRO	; type, label, key, action
	dc.b	\1,0
	dc.l	\2,\3
	dc.w	0
	dc.l	0,\4
	ENDM
NewMenus:
	NM	NM_TITLE,MProject,0,0
	NM	NM_ITEM,MOpen,KeyL,MA_OPEN
	NM	NM_ITEM,MSave,KeyS,MA_SAVE
	NM	NM_ITEM,MFind,KeySlash,MA_FIND
	NM	NM_ITEM,MCopy,KeyC,MA_COPY
	NM	NM_ITEM,MSource,KeyU,MA_SOURCE
	NM	NM_ITEM,NM_BARLABEL,0,0
	NM	NM_ITEM,MAbout,KeyA,MA_ABOUT
	NM	NM_ITEM,NM_BARLABEL,0,0
	NM	NM_ITEM,MQuit,KeyQ,MA_QUIT
	NM	NM_TITLE,MNavigate,0,0
	NM	NM_ITEM,MBack,KeyB,MA_BACK
	NM	NM_ITEM,MFwd,KeyF,MA_FWD
	NM	NM_ITEM,MReload,KeyR,MA_RELOAD
	NM	NM_ITEM,MHome,KeyH,MA_HOME
	NM	NM_ITEM,NM_BARLABEL,0,0
	NM	NM_ITEM,MAddBm,KeyD,MA_ADDBM
	NM	NM_ITEM,MBookmarks,KeyK,MA_BOOKMARKS
	NM	NM_END,0,0,0

MProject:	dc.b	"Project",0
MOpen:		dc.b	"Open location",0
MSave:		dc.b	"Save file...",0
MAbout:		dc.b	"About...",0
MQuit:		dc.b	"Quit",0
MNavigate:	dc.b	"Navigate",0
MBack:		dc.b	"Back",0
MFwd:		dc.b	"Forward",0
MReload:	dc.b	"Reload",0
MHome:		dc.b	"Home",0
MAddBm:		dc.b	"Add bookmark",0
MFind:		dc.b	"Find in page",0
MCopy:		dc.b	"Copy address",0
MSource:	dc.b	"View source",0
MBookmarks:	dc.b	"Bookmarks",0
KeyL:		dc.b	"L",0
KeyS:		dc.b	"S",0
KeyA:		dc.b	"?",0
KeyQ:		dc.b	"Q",0
KeyB:		dc.b	"B",0
KeyF:		dc.b	"F",0
KeyR:		dc.b	"R",0
KeyH:		dc.b	"H",0
KeyD:		dc.b	"D",0
KeySlash:	dc.b	"/",0
KeyC:		dc.b	"C",0
KeyU:		dc.b	"U",0
KeyK:		dc.b	"K",0
AboutTitle:	dc.b	"About Velox",0
AboutText:	dc.b	"Velox "
		VERSION_STR
		dc.b	10,"A web browser for AmigaOS 3.x,",10
		dc.b	"written in 68k assembly.",10,10
		dc.b	"HTTPS needs AmiSSL 6 or a proxy",10
		dc.b	"(tools/velox-proxy.py).",0
AboutOk:	dc.b	"OK",0
	even
