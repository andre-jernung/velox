;
; gui.s - browser window: toolbar, page view, scroller, status line,
;         fonts, colours, painting and input
;

	include	"velox.i"
	include	"graphics/text.i"
	include	"graphics/gfx.i"
	include	"graphics/view.i"
	include	"devices/inputevent.i"
	include	"lvo/gadtools_lib.i"
	include	"lvo/layers_lib.i"
	include	"lvo/diskfont_lib.i"
	include	"lvo/asl_lib.i"

	xdef	GuiOpen,GuiClose,GuiEventLoop,GuiPaintAll,GuiStatus
	xdef	GuiSetUrl,GuiSetTitle,GuiScrollTo,GuiNetHook,GuiBusy
	xdef	GuiRelayout,GuiPageWidth,GuiAbout,DrawStatus
	xref	FindStart,FindKey,FindHighlight,KeyToChars
	xref	LayoutDocument,RunCount,RunPtr,StrLen,StrCopyN
	xref	NavGo,NavBack,NavForward,NavReload,NavHome,NavLink,UrlFixup
	xref	DomGetAttr,LogEvent,FormStateOf,FormIsControl,FormActivate
	xref	FormEditKey,FormLeave,SaveDownload,BookmarkAdd,BookmarksShow
	xref	ImagesPending,ImagesStep,ImagesFree,ImagePaint

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
	suba.l	a0,a0
	INTUI	LockPubScreen
	move.l	d0,g_Screen(a4)
	beq	.fail
	move.l	d0,a0
	move.l	sc_ViewPort+vp_ColorMap(a0),g_ColorMap(a4)
	suba.l	a1,a1
	move.l	a0,-(sp)
	GT	GetVisualInfoA
	movem.l	(sp)+,a0
	move.l	d0,g_VisualInfo(a4)
	beq	.fail
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
.nogl:	move.l	g_Window(a4),a0
	clr.l	g_Window(a4)
	INTUI	CloseWindow
.nowin:	move.l	g_Menu(a4),a0
	clr.l	g_Menu(a4)
	GT	FreeMenus
	move.l	g_GList(a4),a0
	clr.l	g_GList(a4)
	GT	FreeGadgets
	jsr	ImagesFree		; (before the screen goes)
	clr.l	g_PageFreeHook(a4)
	move.l	g_DataTypesBase(a4),d0
	beq.s	.nodt
	clr.l	g_DataTypesBase(a4)
	move.l	d0,a1
	EXEC	CloseLibrary
.nodt:	bsr	PensRelease
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
	move.l	g_ScrollY(a4),d0
	move.l	d0,d1
	add.l	g_PageH(a4),d1
	bsr	PaintRange
	bsr	DrawStatus
	bra	UpdateScroller

; PaintRange - repaint document lines [d0, d1) (clipped to the view)
PaintRange:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	g_Window(a4),d2
	beq	.x
	move.l	d0,d6			; doc top
	move.l	d1,d7			; doc bottom
	; window rectangle of the range
	move.l	d6,d0
	sub.l	g_ScrollY(a4),d0
	bpl.s	.t
	moveq	#0,d0
.t:	add.l	g_PageY(a4),d0
	move.l	d7,d1
	sub.l	g_ScrollY(a4),d1
	cmp.l	g_PageH(a4),d1
	ble.s	.b
	move.l	g_PageH(a4),d1
.b:	add.l	g_PageY(a4),d1
	subq.l	#1,d1
	cmp.l	d0,d1
	blt	.x
	lea	g_ClipRect(a4),a0
	move.w	g_PageX+2(a4),ra_MinX(a0)
	move.w	d0,ra_MinY(a0)
	move.l	g_PageX(a4),d2
	add.l	g_PageW(a4),d2
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
	GFX	RectFill
	moveq	#-1,d0			; font cache of the window RastPort
	move.l	d0,g_PaintFont(a4)
	move.l	d0,g_PaintFont+4(a4)
	; runs overlapping the range
	jsr	RunCount
	move.l	d0,d5
	moveq	#0,d4
.l:	cmp.l	d5,d4
	bhs.s	.done
	move.l	d4,d0
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
.done:	move.l	g_Window(a4),a0
	move.l	wd_WLayer(a0),a0
	move.l	(sp)+,a1
	LAYERS	InstallClipRegion
	move.l	a5,a0
	GFX	DisposeRegion
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

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
	tst.l	g_FindRun(a4)		; the find match
	beq.s	.nofind
	move.l	d3,-(sp)
	sub.w	ru_Base(a2),d3
	jsr	FindHighlight
	move.l	(sp)+,d3
.nofind:
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

; DrawStatus - draw g_StatusText in the status line
DrawStatus:
	movem.l	d2-d3/a2,-(sp)
	move.l	g_Window(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	wd_RPort(a0),a2
	move.l	a2,a1
	moveq	#0,d0
	GFX	SetAPen
	move.l	a2,-(sp)
	move.l	g_Window(a4),a2
	bsr	InnerBox
	movem.l	(sp)+,a2
	move.l	g_StatusY(a4),d1
	move.l	a2,a1
	GFX	RectFill
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
.x:	movem.l	(sp)+,d2-d3/a2
	rts

; GuiStatus - set and show the status line
; In: a0 = text
GuiStatus:
	lea	g_StatusText(a4),a1
	move.l	#STATUS_MAX-1,d0
	jsr	StrCopyN
	bra	DrawStatus

; UpdateScroller - give the scroller the document size and position
UpdateScroller:
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
	lea	LogScroll(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
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
GuiRelayout:
	bsr	GuiPageWidth
	jsr	LayoutDocument
	move.l	g_ScrollY(a4),d0
	clr.l	g_ScrollY(a4)
	bsr	ClampScroll
	move.l	d0,g_ScrollY(a4)
	bra	GuiPaintAll

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

; GuiSetUrl - show a URL in the URL gadget
; In: a0 = URL
GuiSetUrl:
	move.l	a0,UrlSetTags+4
	move.l	g_GadUrl(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	g_Window(a4),a1
	movem.l	a2-a3,-(sp)
	suba.l	a2,a2
	lea	UrlSetTags,a3
	GT	GT_SetGadgetAttrsA
	movem.l	(sp)+,a2-a3
.x:	rts

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

; GuiEventLoop - run until the window is closed or Ctrl-C
GuiEventLoop:
	movem.l	d2-d7/a2,-(sp)
.wait:	tst.l	g_Quit(a4)
	bne.s	.x
	jsr	ImagesPending		; images to load: no waiting, just
	beq.s	.idle			; look at the messages in between
	moveq	#0,d0
	move.l	#SIGBREAKF_CTRL_C,d1
	EXEC	SetSignal
	btst	#SIGBREAKB_CTRL_C,d0
	bne.s	.x
	bsr	HandleMessages
	tst.l	g_Quit(a4)
	bne.s	.x
	jsr	ImagesStep
	bra.s	.wait
.idle:	move.l	g_WinSigMask(a4),d0
	or.l	#SIGBREAKF_CTRL_C,d0
	EXEC	Wait
	btst	#SIGBREAKB_CTRL_C,d0
	bne.s	.x
	bsr	HandleMessages
	bra.s	.wait
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; HandleMessages - process all pending window messages
HandleMessages:
	movem.l	d2-d7/a2,-(sp)
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
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; HandleEvent - d2 = class, d3 = code, d4 = qualifier, a2 = IAddress,
; d5/d6 = mouse position
HandleEvent:
	cmp.l	#IDCMP_CLOSEWINDOW,d2
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
	bra	GuiScrollTo
.nm:	cmp.l	#IDCMP_GADGETDOWN,d2
	bne.s	.ngd
	cmp.l	g_GadScroll(a4),a2
	bne.s	.x
	move.l	d3,d0
	bra	GuiScrollTo
.ngd:	cmp.l	#IDCMP_MENUPICK,d2
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
	move.l	d3,d0
	bra	GuiScrollTo
.ns:	cmp.w	#GID_BACK,d0
	beq	ToNavBack
	cmp.w	#GID_FWD,d0
	beq	ToNavForward
	cmp.w	#GID_RELOAD,d0
	beq	ToNavReload
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
	move.w	d4,d0			; Ctrl / Amiga + key: commands
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
.plain:	cmp.w	#RAW_TAB,d3
	bne.s	.ntab
	moveq	#1,d0
	move.w	d4,d1
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d1
	beq	FocusNext
	moveq	#-1,d0
	bra	FocusNext
.ntab:	cmp.w	#RAW_RETURN,d3
	beq.s	.follow
	cmp.w	#RAW_ENTER,d3
	bne.s	.scroll
.follow:
	move.l	g_FocusLink(a4),d0
	beq.s	.x
	move.l	d0,a0
	bra	Activate
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
ToNavLink:	jmp	NavLink
ToFormActivate:	jmp	FormActivate

; ActivateUrl - empty the URL gadget and put the cursor into it
; ("open location"; clicking the gadget edits the current URL instead)
ActivateUrl:
	lea	EmptyStr(pc),a0
	bsr	GuiSetUrl
	move.l	g_GadUrl(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	g_Window(a4),a1
	move.l	a2,-(sp)
	suba.l	a2,a2
	INTUI	ActivateGadget
	move.l	(sp)+,a2
.x:	rts

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
	bsr	GuiScrollTo
.paint:	bsr	GuiPaintAll
	move.l	g_FocusLink(a4),a0
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
.none:	clr.l	g_FocusLink(a4)
	moveq	#-1,d0
	move.l	d0,g_FocusIdx(a4)
	bsr	GuiPaintAll
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
	bsr	LinkAt
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
MenuActions:
	dc.w	ActivateUrl-MenuActions,MenuSave-MenuActions
	dc.w	GuiAbout-MenuActions,MenuQuit-MenuActions
	dc.w	ToNavBack-MenuActions,ToNavForward-MenuActions
	dc.w	ToNavReload-MenuActions,ToNavHome-MenuActions
	dc.w	MenuAddBm-MenuActions,MenuBookmarks-MenuActions
	dc.w	MenuFind-MenuActions

MenuSave:	jmp	SaveDownload
MenuAddBm:	jmp	BookmarkAdd
MenuBookmarks:	jmp	BookmarksShow
MenuFind:	jmp	FindStart
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
	cmp.w	#IECODE_LBUTTON,d3
	bne.s	.up
	bsr	LinkAt
	move.l	d0,g_PressLink(a4)
	cmp.l	g_EditField(a4),d0	; clicking elsewhere ends editing
	beq.s	.x
	jmp	FormLeave
.up:	cmp.w	#IECODE_LBUTTON|IECODE_UP_PREFIX,d3
	bne.s	.x
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
	bra	GuiRelayout

;--------------------------------------------------------------------
; GuiNetHook - called by the network code when a window message or
; Ctrl-C arrives during a transfer
; In:  d0 = signals received
; Out: d0 = 1 to abort the transfer
;--------------------------------------------------------------------
GuiNetHook:
	movem.l	d2-d7/a2,-(sp)
	btst	#SIGBREAKB_CTRL_C,d0
	bne.s	.abort
	clr.l	g_AbortReq(a4)
.next:	move.l	g_Window(a4),a0
	move.l	wd_UserPort(a0),a0
	GT	GT_GetIMsg
	tst.l	d0
	beq.s	.done
	move.l	d0,a1
	move.l	im_Class(a1),d2
	move.w	im_Code(a1),d3
	move.l	im_IAddress(a1),a2
	GT	GT_ReplyIMsg
	cmp.l	#IDCMP_CLOSEWINDOW,d2
	bne.s	.nc
	moveq	#1,d0
	move.l	d0,g_Quit(a4)
	bra.s	.req
.nc:	cmp.l	#IDCMP_REFRESHWINDOW,d2
	bne.s	.nr
	move.l	g_Window(a4),a0
	GT	GT_BeginRefresh
	move.l	g_Window(a4),a0
	moveq	#-1,d0
	GT	GT_EndRefresh
	bra.s	.next
.nr:	cmp.l	#IDCMP_GADGETUP,d2
	bne.s	.next
	cmp.w	#GID_RELOAD,gg_GadgetID(a2)	; "Reload" stops a load
	bne.s	.next
.req:	moveq	#1,d0
	move.l	d0,g_AbortReq(a4)
	bra.s	.next
.done:	move.l	g_AbortReq(a4),d0
	bra.s	.x
.abort:	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d7/a2
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
