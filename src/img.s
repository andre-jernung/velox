;
; img.s - images through datatypes.library
;
; After a page is shown, its <img> elements are queued.  The event loop
; loads one at a time (ImagesStep), so the window stays usable.  An
; image is fetched, written to T:, decoded by a picture datatype
; (remapped to the screen), then copied or scaled into a bitmap of our
; own; the datatype object is disposed of at once.  The ImageInfo hangs
; in the <img> element's aux slot (n_Data2).
;

	include	"velox.i"
	include	"graphics/scale.i"

; from datatypes/datatypesclass.i, datatypes.i and pictureclass.i (the
; first uses C-style 0x numbers that vasm does not take)
DTA_Dummy		equ	TAG_USER+$1000
DTA_GroupID		equ	DTA_Dummy+31
PDTA_BitMapHeader	equ	DTA_Dummy+201
PDTA_BitMap		equ	DTA_Dummy+202
PDTA_Remap		equ	DTA_Dummy+211
PDTA_Screen		equ	DTA_Dummy+212
PDTA_DestBitMap		equ	DTA_Dummy+215
PDTA_DestMode		equ	DTA_Dummy+251
PMODE_V43		equ	1
GID_PICTURE		equ	'pict'
DTM_PROCLAYOUT		equ	$0602
bmh_Width		equ	0
bmh_Height		equ	2
	include	"lvo/datatypes_lib.i"

	xdef	ImagesStart,ImagesStep,ImagesPending,ImagesFree,ImagePaint
	xref	PageAlloc,DomGetAttr,UrlResolve,HttpGetCached,ParseDec,BufFree
	xref	BufAppend,BufClear,GuiStatus,GuiRelayout,GuiPaintAll,GuiPageWidth
	xref	FmtDec,StrCopy,LogEvent,GuiNetHook

MAX_IMAGES	equ	64
MAX_IMAGE	equ	2*1024*1024	; bytes of an image file
CHIP_RESERVE	equ	200*1024	; keep this much chip memory free
RELAYOUT_EVERY	equ	4
MY_BMF_CLEAR	equ	1

	section	code,code

;--------------------------------------------------------------------
; ImagesStart - queue the images of the page (after it is shown)
;--------------------------------------------------------------------
ImagesStart:
	movem.l	d2/a2-a3/a5,-(sp)
	clr.l	g_ImgCount(a4)
	clr.l	g_ImgNext(a4)
	clr.l	g_ImgLoaded(a4)
	clr.l	g_ImgRelayout(a4)
	tst.l	g_NoImages(a4)
	bne	.x
	move.l	g_Doc(a4),d0
	beq	.x
	move.l	#MAX_IMAGES*4,d0
	jsr	PageAlloc
	move.l	d0,g_ImgQueue(a4)
	beq	.x
	move.l	g_Doc(a4),a5
	move.l	n_First(a5),a3
.walk:	move.l	a3,d0
	beq	.x
	cmp.b	#DN_ELEMENT,n_Type(a3)
	bne.s	.next
	cmp.w	#TAG_IMG,n_Tag(a3)
	bne.s	.down
	move.l	a3,a0
	lea	AnSrc(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.next
	move.l	d0,a0			; data: URLs are not loaded
	cmp.b	#'d',(a0)
	bne.s	.q
	cmp.b	#'a',1(a0)
	bne.s	.q
	cmp.b	#':',4(a0)
	beq.s	.next
.q:	move.l	g_ImgCount(a4),d0
	cmp.l	#MAX_IMAGES,d0
	bhs.s	.x
	move.l	g_ImgQueue(a4),a0
	move.l	a3,(a0,d0.l*4)
	addq.l	#1,g_ImgCount(a4)
	bra.s	.next
.down:	move.l	n_First(a3),d0
	beq.s	.next
	move.l	d0,a3
	bra.s	.walk
.next:	move.l	n_Next(a3),d0
	bne.s	.go
	move.l	n_Parent(a3),a3
	cmp.l	a5,a3
	beq.s	.x
	move.l	a3,d0
	beq.s	.x
	bra.s	.next
.go:	move.l	d0,a3
	bra	.walk
.x:	movem.l	(sp)+,d2/a2-a3/a5
	rts

AnSrc:	dc.b	"src",0
AnWidth:	dc.b	"width",0
AnHeight:	dc.b	"height",0
	even

;--------------------------------------------------------------------
; ImagesPending - Out: d0 = 1 if images are still to be loaded
;--------------------------------------------------------------------
ImagesPending:
	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	blo.s	.yes
	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; ImagesStep - load the next queued image
;--------------------------------------------------------------------
ImagesStep:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	bhs	.x
	addq.l	#1,g_ImgNext(a4)
	move.l	g_ImgQueue(a4),a0
	move.l	(a0,d0.l*4),a5		; a5 = <img>
	; status "Image 3 of 12"
	lea	g_StatusBuf(a4),a1
	lea	MsgImage(pc),a0
	jsr	StrCopy
	move.l	a1,a0
	move.l	g_ImgNext(a4),d0
	jsr	FmtDec
	move.l	a0,a1
	lea	MsgOf(pc),a0
	jsr	StrCopy
	move.l	a1,a0
	move.l	g_ImgCount(a4),d0
	jsr	FmtDec
	lea	g_StatusBuf(a4),a0
	jsr	GuiStatus
	; enough chip memory left?
	move.l	#MEMF_CHIP|MEMF_LARGEST,d1
	EXEC	AvailMem
	cmp.l	#CHIP_RESERVE,d0
	blo	.done
	; the URL
	move.l	a5,a0
	lea	AnSrc(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.done
	move.l	d0,a1
	lea	g_PageUrl(a4),a0
	lea	g_LinkUrl(a4),a2
	jsr	UrlResolve
	tst.l	d0
	beq	.done
	; fetch (window events and Ctrl-C can stop it)
	move.l	g_WinSigMask(a4),d0
	or.l	#SIGBREAKF_CTRL_C,d0
	move.l	d0,g_AbortMask(a4)
	lea	GuiNetHook,a0
	move.l	a0,g_NetSigHook(a4)
	lea	g_LinkUrl(a4),a0
	jsr	HttpGetCached
	clr.l	g_NetSigHook(a4)
	cmp.l	#200,d0
	bne	.free
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	beq	.free
	cmp.l	#MAX_IMAGE,d0
	bhi	.free
	; to a temporary file for the datatype
	lea	TmpName(pc),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d7
	beq	.free
	move.l	d7,d1
	move.l	g_Resp+r_Body+buf_Data(a4),d2
	move.l	g_Resp+r_Body+buf_Len(a4),d3
	DOS	Write
	move.l	d0,d6
	move.l	d7,d1
	DOS	Close
	lea	g_Resp+r_Body(a4),a0	; the file has it now
	jsr	BufFree
	cmp.l	g_Resp+r_Body+buf_Len(a4),d6
	; (Write returns -1 on error; the length check is done by the DT)
	tst.l	d6
	bmi	.del
	bsr	Decode			; d0 = 1 if a5 got an image
	tst.l	d0
	beq.s	.del
	addq.l	#1,g_ImgLoaded(a4)
.del:	lea	TmpName(pc),a0
	move.l	a0,d1
	DOS	DeleteFile
	bra.s	.done
.free:	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
.done:	; lay out again now and then, and at the end
	tst.l	g_ImgRelayout(a4)
	beq.s	.paint
	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	beq.s	.relay
	divul.l	#RELAYOUT_EVERY,d1:d0
	tst.l	d1
	bne.s	.paint
.relay:	clr.l	g_ImgRelayout(a4)
	jsr	GuiRelayout
	bra.s	.end
.paint:	jsr	GuiPaintAll
.end:	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	blo.s	.x
	lea	LogImages(pc),a0	; all done
	suba.l	a1,a1
	move.l	g_ImgLoaded(a4),d0
	jsr	LogEvent
	lea	g_TitleText(a4),a0
	jsr	GuiStatus
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

TmpName:	dc.b	"T:velox-image",0
MsgImage:	dc.b	"Image ",0
MsgOf:		dc.b	" of ",0
LogImages:	dc.b	"images",0
	even

;--------------------------------------------------------------------
; Decode - make the image of <img> a5 from TmpName
; Out: d0 = 1 on success
;--------------------------------------------------------------------
Decode:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	g_DataTypesBase(a4),d0
	beq	.fail
	move.l	g_Screen(a4),DtTagScr+4
	move.l	d0,a6
	lea	TmpName(pc),a0		; NewDTObjectA(d0 = name, a0 = tags)
	move.l	a0,d0
	lea	DtTags,a0
	jsr	_LVONewDTObjectA(a6)
	move.l	d0,a3			; a3 = datatype object
	tst.l	d0
	beq	.fail
	lea	g_DtMsg(a4),a0		; DTM_PROCLAYOUT: remap to the screen
	move.l	#DTM_PROCLAYOUT,(a0)
	clr.l	4(a0)
	move.l	#1,8(a0)
	move.l	a3,a0
	suba.l	a1,a1
	suba.l	a2,a2
	move.l	a3,-(sp)
	lea	g_DtMsg(a4),a3
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVODoDTMethodA(a6)
	move.l	(sp)+,a3
	; the bitmap and its size
	clr.l	g_DtBmhd(a4)
	clr.l	g_DtBitMap(a4)
	clr.l	g_DtDestBM(a4)
	lea	g_DtBmhd(a4),a0		; where GetDTAttrs stores the values
	move.l	a0,DtGetTags+4
	lea	g_DtBitMap(a4),a0
	move.l	a0,DtGetTags+12
	lea	g_DtDestBM(a4),a0
	move.l	a0,DtGetTags+20
	move.l	a3,a0
	lea	DtGetTags,a2
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVOGetDTAttrsA(a6)
	move.l	g_DtDestBM(a4),d0	; v43: the remapped bitmap
	bne.s	.bm
	move.l	g_DtBitMap(a4),d0
	beq	.dispose
.bm:	move.l	d0,a2			; a2 = source bitmap
	move.l	g_DtBmhd(a4),d0
	beq	.dispose
	move.l	d0,a0
	moveq	#0,d2
	move.w	bmh_Width(a0),d2	; natural size
	moveq	#0,d3
	move.w	bmh_Height(a0),d3
	tst.l	d2
	beq	.dispose
	tst.l	d3
	beq	.dispose
	; wanted size: width=/height= (one of them keeps the aspect)
	move.l	d2,d4
	move.l	d3,d5
	moveq	#0,d6			; 1 if the size depends on the image
	move.l	a5,a0
	lea	AnWidth(pc),a1
	bsr	PxAttr
	move.l	d0,d7			; wanted width or 0
	move.l	a5,a0
	lea	AnHeight(pc),a1
	bsr	PxAttr			; d0 = wanted height or 0
	tst.l	d7
	beq.s	.now
	move.l	d7,d4
	tst.l	d0
	beq.s	.hfromw
	move.l	d0,d5
	bra.s	.fit
.hfromw:
	move.l	d3,d5			; h = h0 * w / w0
	mulu.l	d4,d5
	divu.l	d2,d5
	bra.s	.fit
.now:	moveq	#1,d6
	tst.l	d0
	beq.s	.fit
	move.l	d0,d5			; w = w0 * h / h0
	move.l	d2,d4
	mulu.l	d5,d4
	divu.l	d3,d4
.fit:	; never wider than the page
	jsr	GuiPageWidth
	sub.l	#16,d0
	cmp.l	d0,d4
	ble.s	.wok
	move.l	d5,d1			; h = h * maxw / w
	mulu.l	d0,d1
	divu.l	d4,d1
	move.l	d0,d4
	move.l	d1,d5
	moveq	#1,d6
.wok:	tst.l	d4
	ble	.dispose
	tst.l	d5
	ble	.dispose
	cmp.l	#4000,d5		; sanity
	bhi	.dispose
	; chip memory for the copy?
	move.l	#MEMF_CHIP|MEMF_LARGEST,d1
	EXEC	AvailMem
	move.l	d4,d1
	add.l	#15,d1
	lsr.l	#3,d1
	mulu.l	d5,d1
	lsl.l	#3,d1			; up to 8 planes
	add.l	#CHIP_RESERVE,d1
	cmp.l	d1,d0
	blo	.dispose
	; our bitmap, like the screen's
	move.l	g_Screen(a4),a0
	lea	sc_RastPort(a0),a0
	move.l	rp_BitMap(a0),a0
	moveq	#BMA_DEPTH,d1
	move.l	a0,-(sp)
	GFX	GetBitMapAttr
	move.l	(sp)+,a0		; friend
	move.l	d0,d1			; (depth)
	movem.l	d2-d3,-(sp)
	move.l	d1,d2
	move.l	d4,d0
	move.l	d5,d1
	moveq	#MY_BMF_CLEAR,d3
	GFX	AllocBitMap
	movem.l	(sp)+,d2-d3
	move.l	d0,d7			; d7 = our bitmap
	beq	.dispose
	cmp.l	d2,d4			; same size: copy, else scale
	bne.s	.scale
	cmp.l	d3,d5
	bne.s	.scale
	move.l	a2,a0
	moveq	#0,d0
	moveq	#0,d1
	move.l	d7,a1
	movem.l	d2-d7/a2,-(sp)
	moveq	#0,d2
	moveq	#0,d3
	move.l	d4,d4
	move.l	d5,d5
	move.l	#$c0,d6
	moveq	#-1,d7
	suba.l	a2,a2
	GFX	BltBitMap
	movem.l	(sp)+,d2-d7/a2
	bra.s	.made
.scale:	lea	g_Bsa(a4),a0
	moveq	#bsa_SIZEOF/2-1,d0
.cb:	clr.w	(a0)+
	dbf	d0,.cb
	lea	g_Bsa(a4),a0
	move.w	d2,bsa_SrcWidth(a0)
	move.w	d3,bsa_SrcHeight(a0)
	move.w	d2,bsa_XSrcFactor(a0)	; factors: dest / src, kept below
	move.w	d3,bsa_YSrcFactor(a0)	; 16384 by halving both
	move.w	d4,bsa_XDestFactor(a0)
	move.w	d5,bsa_YDestFactor(a0)
	move.l	a2,bsa_SrcBitMap(a0)
	move.l	d7,bsa_DestBitMap(a0)
	GFX	BitMapScale
.made:	GFX	WaitBlit
	; the ImageInfo
	moveq	#IMG_SIZEOF,d0
	jsr	PageAlloc
	beq.s	.nofo
	move.l	d0,a0
	move.l	d7,im_BitMap(a0)
	move.w	d4,im_W(a0)
	move.w	d5,im_H(a0)
	move.l	g_ImgList(a4),im_Next(a0)	; for ImagesFree
	move.l	a0,g_ImgList(a4)
	move.l	a0,n_Data2(a5)
	tst.l	d6
	beq.s	.ok
	moveq	#1,d0			; its size changes the layout
	move.l	d0,g_ImgRelayout(a4)
.ok:	move.l	a3,a0
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVODisposeDTObject(a6)
	moveq	#1,d0
	bra.s	.x
.nofo:	move.l	d7,a0
	GFX	FreeBitMap
.dispose:
	move.l	a3,a0
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVODisposeDTObject(a6)
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; PxAttr - a pixel attribute (width/height, not percent)
; In: a0 = element, a1 = name; Out: d0 = value or 0
PxAttr:
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	jsr	ParseDec
	tst.l	d1
	beq.s	.no
	cmp.b	#'%',(a0)
	beq.s	.no
	cmp.l	#4000,d0
	bls.s	.x
.no:	moveq	#0,d0
.x:	rts

;--------------------------------------------------------------------
; ImagesFree - free the bitmaps of the page's images (page change)
;--------------------------------------------------------------------
ImagesFree:
	move.l	a2,-(sp)
	clr.l	g_ImgCount(a4)
	clr.l	g_ImgNext(a4)
	move.l	g_ImgList(a4),a2
	clr.l	g_ImgList(a4)
	GFX	WaitBlit
.l:	move.l	a2,d0
	beq.s	.x
	move.l	im_BitMap(a2),a0
	GFX	FreeBitMap
	move.l	im_Next(a2),a2
	bra.s	.l
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; ImagePaint - draw the image of a run, if it is loaded
; In:  a0 = run, a1 = RastPort, d2/d3 = window x/y of the run,
;      d4 = first visible window line, d5 = last visible window line
; Out: d0 = 1 if drawn
;--------------------------------------------------------------------
ImagePaint:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	ru_Text(a0),a2		; <img>
	move.l	n_Data2(a2),d0
	beq.s	.no
	move.l	d0,a2			; ImageInfo
	move.l	a1,a3
	moveq	#0,d1			; source y: skip lines above the view
	move.l	d4,d0
	sub.l	d3,d0
	ble.s	.top
	move.l	d0,d1
	move.l	d4,d3
.top:	moveq	#0,d0
	move.w	im_H(a2),d0		; height to draw
	sub.l	d1,d0
	move.l	d3,d6
	add.l	d0,d6			; past the bottom of the view?
	subq.l	#1,d6
	cmp.l	d5,d6
	ble.s	.h
	move.l	d5,d6
.h:	sub.l	d3,d6
	addq.l	#1,d6			; d6 = lines
	ble.s	.no
	move.l	im_BitMap(a2),a0
	moveq	#0,d0			; source x
	move.l	a3,a1
	moveq	#0,d4
	move.w	im_W(a2),d4		; width
	move.l	d6,d5			; height
	move.l	#$c0,d6
	GFX	BltBitMapRastPort
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

	section	data,data
DtTags:
	dc.l	DTA_GroupID,GID_PICTURE
	dc.l	PDTA_Remap,1
DtTagScr:
	dc.l	PDTA_Screen,0
	dc.l	PDTA_DestMode,PMODE_V43
	dc.l	TAG_DONE
DtGetTags:
	dc.l	PDTA_BitMapHeader,0		; pointers filled in below
	dc.l	PDTA_BitMap,0
	dc.l	PDTA_DestBitMap,0
	dc.l	TAG_DONE
	section	code,code
