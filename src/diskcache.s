;
; diskcache.s - the disk cache
;
; Pages and style sheets are kept as they came (body and validators:
; ETag, Last-Modified, max-age), so that a page can be shown at once
; and then checked with a conditional request.  Images are kept as they
; are shown: scaled and dithered for this screen, ready for the bitmap,
; so a page's images come back without fetching or decoding.
;
; One file per entry in the cache directory (Velox/CacheDir, default
; PROGDIR:Cache), named after a hash of its key (the URL; for an image
; also the size and the screen's colours).  The file has a header, the
; key and the validators, then the data; a key that differs (a hash
; collision) is a miss.  When the files take more than Velox/CacheSize
; KB (default 4096; 0: no cache), the oldest go.
;

	include	"velox.i"

	xdef	DcInit,DcLoad,DcStore,DcFresh,DcLoadImg,DcStoreImg,DcImgFree,DcCond,DcHash
	xref	StrCopyN,StrLen,StrIPrefix,BufClear,BufReserve,ParseDec

DC_MAGIC	equ	'VXC1'
DC_DEFKB	equ	4096

; then: the key, the content type, the ETag, Last-Modified (each NUL
; terminated), then the data

	section	code,code

;--------------------------------------------------------------------
; DcInit - the cache directory (made if missing) and the bytes in it
;--------------------------------------------------------------------
DcInit:
	movem.l	d2-d4,-(sp)
	clr.l	g_DcOn(a4)
	lea	VarCacheSize(pc),a0	; Velox/CacheSize: KB, 0 for none
	bsr	DcGetVar
	move.l	#DC_DEFKB,d0
	tst.l	d1
	ble.s	.def
	lea	g_VarBuf(a4),a0
	jsr	ParseDec
.def:	lsl.l	#8,d0
	lsl.l	#2,d0
	move.l	d0,g_DcMax(a4)
	beq.s	.x
	lea	VarCacheDir(pc),a0	; Velox/CacheDir
	bsr	DcGetVar
	lea	g_VarBuf(a4),a0
	tst.l	d1
	bgt.s	.dir
	lea	DefDir(pc),a0
.dir:	lea	g_DcDir(a4),a1
	move.l	#DCPATH_MAX-1,d0
	jsr	StrCopyN
	lea	g_DcDir(a4),a0		; there, or made
	move.l	a0,d1
	moveq	#ACCESS_READ,d2
	DOS	Lock
	tst.l	d0
	bne.s	.have
	lea	g_DcDir(a4),a0
	move.l	a0,d1
	DOS	CreateDir
	tst.l	d0
	beq.s	.x
.have:	move.l	d0,d1
	DOS	UnLock
	moveq	#1,d0
	move.l	d0,g_DcOn(a4)
	bsr	DcScanDir			; the bytes kept
	move.l	d0,g_DcUsed(a4)
.x:	movem.l	(sp)+,d2-d4
	rts

; DcGetVar - environment variable a0 into g_VarBuf
; Out: d1 = its length, -1 if there is none
DcGetVar:
	movem.l	d2-d4,-(sp)
	move.l	a0,d1
	lea	g_VarBuf(a4),a0
	move.l	a0,d2
	move.l	#255,d3
	moveq	#0,d4
	DOS	GetVar
	move.l	d0,d1
	movem.l	(sp)+,d2-d4
	rts

;--------------------------------------------------------------------
; DcScanDir - go through the cache directory: the bytes of all files, and
; the oldest (g_DcOld = its name, g_DcOldSize)
; Out: d0 = the bytes, 0 if the directory cannot be read
;--------------------------------------------------------------------
DcScanDir:
	movem.l	d2-d6/a2,-(sp)
	moveq	#0,d5			; bytes
	clr.b	g_DcOld(a4)
	moveq	#-1,d6			; the oldest date (days) so far
	move.l	d6,g_DcOldMin(a4)
	moveq	#DOS_FIB,d1
	moveq	#0,d2
	DOS	AllocDosObject
	move.l	d0,a2
	tst.l	d0
	beq.s	.x
	lea	g_DcDir(a4),a0
	move.l	a0,d1
	moveq	#ACCESS_READ,d2
	DOS	Lock
	move.l	d0,d4
	beq.s	.free
	move.l	d4,d1
	move.l	a2,d2
	DOS	Examine
	tst.l	d0
	beq.s	.unl
.n:	move.l	d4,d1
	move.l	a2,d2
	DOS	ExNext
	tst.l	d0
	beq.s	.unl
	tst.l	fib_DirEntryType(a2)	; files only
	bpl.s	.n
	add.l	fib_Size(a2),d5
	move.l	fib_DateStamp+ds_Days(a2),d0	; older than the oldest?
	cmp.l	d6,d0
	bhi.s	.n
	blo.s	.old
	move.l	fib_DateStamp+ds_Minute(a2),d0
	cmp.l	g_DcOldMin(a4),d0
	bhs.s	.n
.old:	move.l	fib_DateStamp+ds_Days(a2),d6
	move.l	fib_DateStamp+ds_Minute(a2),g_DcOldMin(a4)
	move.l	fib_Size(a2),g_DcOldSize(a4)
	lea	fib_FileName(a2),a0
	lea	g_DcOld(a4),a1
	moveq	#31,d0
	jsr	StrCopyN
	bra.s	.n
.unl:	move.l	d4,d1
	DOS	UnLock
.free:	moveq	#DOS_FIB,d1
	move.l	a2,d2
	DOS	FreeDosObject
.x:	move.l	d5,d0
	movem.l	(sp)+,d2-d6/a2
	rts

;--------------------------------------------------------------------
; DcTrimOld - the oldest files go until the cache takes 3/4 of its size
;--------------------------------------------------------------------
DcTrimOld:
	movem.l	d2,-(sp)
.l:	move.l	g_DcMax(a4),d0
	lsr.l	#2,d0
	move.l	g_DcMax(a4),d1
	sub.l	d0,d1
	cmp.l	g_DcUsed(a4),d1
	bhs.s	.x
	bsr	DcScanDir
	move.l	d0,g_DcUsed(a4)
	tst.b	g_DcOld(a4)
	beq.s	.x
	lea	g_DcDir(a4),a0		; the oldest goes
	lea	g_DcPath(a4),a1
	move.l	#DCPATH_MAX-1,d0
	jsr	StrCopyN
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	lea	g_DcOld(a4),a0
	move.l	a0,d2
	move.l	#DCPATH_MAX,d3
	DOS	AddPart
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	DOS	DeleteFile
	tst.l	d0
	beq.s	.x			; (cannot: stop trying)
	move.l	g_DcOldSize(a4),d0
	sub.l	d0,g_DcUsed(a4)
	bra.s	.l
.x:	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; DcPathOf - g_DcPath = the file of key a0: the cache directory and the
; key's hash (FNV-1a) in hex, ".i" after it for images (d0 = 1)
;--------------------------------------------------------------------
DcPathOf:
	movem.l	d2-d4,-(sp)
	move.l	d0,d4
	move.l	#$811c9dc5,d2		; FNV-1a
	moveq	#0,d1
.h:	move.b	(a0)+,d1
	beq.s	.hd
	eor.l	d1,d2
	mulu.l	#$01000193,d2
	bra.s	.h
.hd:	lea	g_DcName(a4),a1
	moveq	#8-1,d3
.hx:	rol.l	#4,d2
	moveq	#15,d0
	and.l	d2,d0
	move.b	Hex(pc,d0.l),(a1)+
	dbf	d3,.hx
	tst.l	d4
	beq.s	.nx
	move.b	#'.',(a1)+
	move.b	#'i',(a1)+
.nx:	clr.b	(a1)
	lea	g_DcDir(a4),a0
	lea	g_DcPath(a4),a1
	move.l	#DCPATH_MAX-1,d0
	jsr	StrCopyN
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	lea	g_DcName(a4),a0
	move.l	a0,d2
	move.l	#DCPATH_MAX,d3
	DOS	AddPart
	movem.l	(sp)+,d2-d4
	rts

Hex:	dc.b	"0123456789ABCDEF"

;--------------------------------------------------------------------
; DcNow - Out: d0 = the time in seconds (since 1978)
;--------------------------------------------------------------------
DcNow:
	lea	-12(sp),sp
	move.l	sp,d1
	DOS	DateStamp
	move.l	(sp),d0			; days * 86400 + minutes * 60 +
	mulu.l	#86400,d0		; ticks / 50
	move.l	4(sp),d1
	mulu.w	#60,d1
	add.l	d1,d0
	move.l	8(sp),d1
	divu.w	#50,d1
	ext.l	d1
	add.l	d1,d0
	lea	12(sp),sp
	rts

;--------------------------------------------------------------------
; DcFresh - is the entry last loaded (DcLoad, DcLoadImg) still fresh
; (max-age), so that it need not be checked?
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
DcFresh:
	move.l	g_DcHdr+dh_MaxAge(a4),d1
	ble.s	.no
	bsr.s	DcNow
	sub.l	g_DcHdr+dh_Time(a4),d0
	bmi.s	.no
	cmp.l	g_DcHdr+dh_MaxAge(a4),d0
	bhs.s	.no
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; DcOpenEntry - open the entry of key a0 (d0 = 1: an image) and read its
; header and strings (g_DcHdr, g_DcStr: key, type, ETag, Last-Modified;
; g_DcETag/g_DcLM get the validators)
; Out: d0 = the file handle, 0 if there is no such entry (CCR set)
;--------------------------------------------------------------------
DcOpenEntry:
	movem.l	d2-d4/a2,-(sp)
	move.l	a0,a2
	tst.l	g_DcOn(a4)
	beq	.no
	bsr	DcPathOf
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq	.no
	move.l	d4,d1			; the header
	lea	g_DcHdr(a4),a0
	move.l	a0,d2
	moveq	#DH_SIZEOF,d3
	DOS	Read
	cmp.l	#DH_SIZEOF,d0
	bne.s	.bad
	cmp.l	#DC_MAGIC,g_DcHdr+dh_Magic(a4)
	bne.s	.bad
	move.l	g_DcHdr+dh_StrLen(a4),d3	; the strings
	cmp.l	#DCSTR_MAX,d3
	bhi.s	.bad
	move.l	d4,d1
	lea	g_DcStr(a4),a0
	move.l	a0,d2
	DOS	Read
	cmp.l	g_DcHdr+dh_StrLen(a4),d0
	bne.s	.bad
	clr.b	g_DcStr+DCSTR_MAX-1(a4)
	lea	g_DcStr(a4),a0		; the key must be ours
	move.l	a2,a1
.k:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.bad
	tst.b	d0
	bne.s	.k
	jsr	StrLen			; (a0 = the type: skip it)
	lea	1(a0,d0.l),a0
	move.l	a0,-(sp)
	lea	g_DcETag(a4),a1
	moveq	#ETAG_MAX-1,d0
	jsr	StrCopyN
	move.l	(sp)+,a0
	jsr	StrLen
	lea	1(a0,d0.l),a0
	lea	g_DcLM(a4),a1
	moveq	#LASTMOD_MAX-1,d0
	jsr	StrCopyN
	move.l	d4,d0
	bra.s	.x
.bad:	move.l	d4,d1
	DOS	Close
.no:	clr.b	g_DcETag(a4)
	clr.b	g_DcLM(a4)
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4/a2
	rts

;--------------------------------------------------------------------
; DcLoad - a page or style sheet from the cache, as if it had just
; come: g_Resp (status 200, URL, type, body); DcFresh says if it must
; be checked, DcCond makes the next request check it
; In:  a0 = URL
; Out: d0 = 1 if it was there (CCR set)
;--------------------------------------------------------------------
DcLoad:
	movem.l	d2-d4/a2,-(sp)
	move.l	a0,a2
	moveq	#0,d0
	bsr	DcOpenEntry
	move.l	d0,d4
	beq.s	.x
	lea	g_Resp+r_Body(a4),a0	; the body
	jsr	BufClear
	lea	g_Resp+r_Body(a4),a0
	move.l	g_DcHdr+dh_Len(a4),d0
	addq.l	#1,d0
	jsr	BufReserve
	beq.s	.bad
	move.l	d4,d1
	move.l	g_Resp+r_Body+buf_Data(a4),d2
	move.l	g_DcHdr+dh_Len(a4),d3
	DOS	Read
	cmp.l	g_DcHdr+dh_Len(a4),d0
	bne.s	.bad
	move.l	d0,g_Resp+r_Body+buf_Len(a4)
	move.l	g_Resp+r_Body+buf_Data(a4),a0
	clr.b	(a0,d0.l)
	move.l	a2,a0			; as a response
	lea	g_Resp+r_Url(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	lea	g_DcStr(a4),a0
	jsr	StrLen
	lea	1(a0,d0.l),a0
	lea	g_Resp+r_CType(a4),a1
	moveq	#63,d0
	jsr	StrCopyN
	clr.b	g_Resp+r_Location(a4)
	move.l	#200,g_Resp+r_Status(a4)
	move.l	d4,d1
	DOS	Close
	moveq	#1,d0
	bra.s	.x
.bad:	move.l	d4,d1
	DOS	Close
	lea	g_Resp+r_Body(a4),a0
	jsr	BufClear
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4/a2
	rts

;--------------------------------------------------------------------
; DcStore - keep the response in g_Resp (a 200 to a GET): text only
; (pages, style sheets; images are kept as shown, DcStoreImg), not
; with no-store, not if it is a quarter of the cache or more
;--------------------------------------------------------------------
DcStore:
	movem.l	d2-d3/a2,-(sp)
	tst.l	g_DcOn(a4)
	beq.s	.x
	tst.l	g_Resp+r_NoStore(a4)
	bne.s	.x
	lea	g_Resp+r_CType(a4),a0
	tst.b	(a0)
	beq.s	.ok
	lea	CtText(pc),a1
	jsr	StrIPrefix
	beq.s	.x
.ok:	move.l	g_Resp+r_Body+buf_Len(a4),d2
	move.l	g_DcMax(a4),d0
	lsr.l	#2,d0
	cmp.l	d0,d2
	bhs.s	.x
	clr.l	g_DcHdr+dh_W(a4)
	clr.l	g_DcHdr+dh_H(a4)
	clr.l	g_DcHdr+dh_Mode(a4)
	clr.l	g_DcHdr+dh_Mask(a4)
	clr.l	g_DcHdr+dh_Hash(a4)
	lea	g_Resp+r_Url(a4),a0
	moveq	#0,d0
	move.l	g_Resp+r_Body+buf_Data(a4),a1
	move.l	d2,d1
	suba.l	a2,a2
	bsr	DcWrite
.x:	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; DcWrite - an entry: key a0 (d0 = 1: an image), d1 bytes of data a1,
; then g_DcHdr+dh_Mask bytes of mask a2; the type, validators and
; max-age from g_Resp; dh_W/H/Mode/Mask set by the caller
;--------------------------------------------------------------------
DcWrite:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	a0,a3			; a3 = key
	move.l	a1,d6			; d6/d7 = data
	move.l	d1,d7
	bsr	DcPathOf
	move.l	#DC_MAGIC,g_DcHdr+dh_Magic(a4)
	bsr	DcNow
	move.l	d0,g_DcHdr+dh_Time(a4)
	move.l	g_Resp+r_MaxAge(a4),g_DcHdr+dh_MaxAge(a4)
	move.l	d7,g_DcHdr+dh_Len(a4)
	move.l	a2,-(sp)		; (the mask)
	lea	g_DcStr(a4),a1		; the strings
	move.l	a3,a0
	bsr.s	DcStrA1
	lea	g_Resp+r_CType(a4),a0
	bsr.s	DcStrA1
	lea	g_Resp+r_ETag(a4),a0
	bsr.s	DcStrA1
	lea	g_Resp+r_LastMod(a4),a0
	bsr.s	DcStrA1
	move.l	a1,d0
	lea	g_DcStr(a4),a0
	sub.l	a0,d0
	move.l	d0,g_DcHdr+dh_StrLen(a4)
	move.l	(sp)+,a2
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.x
	move.l	d4,d1
	lea	g_DcHdr(a4),a0
	move.l	a0,d2
	moveq	#DH_SIZEOF,d3
	DOS	Write
	move.l	d4,d1
	lea	g_DcStr(a4),a0
	move.l	a0,d2
	move.l	g_DcHdr+dh_StrLen(a4),d3
	DOS	Write
	move.l	d4,d1
	move.l	d6,d2
	move.l	d7,d3
	DOS	Write
	move.l	d0,d5
	move.l	g_DcHdr+dh_Mask(a4),d3
	beq.s	.nm
	move.l	d4,d1
	move.l	a2,d2
	DOS	Write
.nm:	move.l	d4,d1
	DOS	Close
	cmp.l	d7,d5			; (not all written: the disk is full)
	beq.s	.ok
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	DOS	DeleteFile
	bra.s	.x
.ok:	moveq	#DH_SIZEOF,d0
	add.l	g_DcHdr+dh_StrLen(a4),d0
	add.l	d7,d0
	add.l	g_DcHdr+dh_Mask(a4),d0
	add.l	d0,g_DcUsed(a4)
	move.l	g_DcUsed(a4),d0
	cmp.l	g_DcMax(a4),d0
	bls.s	.x
	bsr	DcTrimOld
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; DcStrA1 - copy string a0 with its NUL to g_DcStr at a1, room permitting
; Out: a1 = after it (a2 changed)
DcStrA1:
	lea	g_DcStr+DCSTR_MAX-1(a4),a2
.sc:	cmp.l	a2,a1
	bhs.s	.se
	move.b	(a0)+,(a1)+
	bne.s	.sc
	rts
.se:	clr.b	(a1)+
	rts

;--------------------------------------------------------------------
; DcLoadImg - an image as it was shown: key a0 (URL and size, see
; img.s), with the pixels (g_DcImg: the bytes of dh_Len, then the
; mask, dh_Mask bytes) in g_DcHdr's size and mode
; Out: d0 = 1 if it was there (CCR set); DcImgFree frees it
;--------------------------------------------------------------------
DcLoadImg:
	movem.l	d2-d4,-(sp)
	bsr	DcImgFree
	moveq	#1,d0
	bsr	DcOpenEntry
	move.l	d0,d4
	beq.s	.x
	move.l	g_DcHdr+dh_Len(a4),d0
	add.l	g_DcHdr+dh_Mask(a4),d0
	beq.s	.bad
	move.l	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,g_DcImg(a4)
	beq.s	.bad
	move.l	d4,d1
	move.l	d0,d2
	move.l	g_DcHdr+dh_Len(a4),d3
	add.l	g_DcHdr+dh_Mask(a4),d3
	DOS	Read
	cmp.l	d3,d0
	bne.s	.bad
	move.l	d4,d1
	DOS	Close
	moveq	#1,d0
	bra.s	.x
.bad:	move.l	d4,d1
	DOS	Close
	bsr	DcImgFree
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4
	rts

; DcCond - the next request (only that one: HttpGet clears them) asks
; for the entry last loaded only if it changed: If-None-Match,
; If-Modified-Since
;--------------------------------------------------------------------
DcCond:
	lea	g_DcETag(a4),a0
	lea	g_CondETag(a4),a1
	moveq	#ETAG_MAX-1,d0
	jsr	StrCopyN
	lea	g_DcLM(a4),a0
	lea	g_CondLM(a4),a1
	moveq	#LASTMOD_MAX-1,d0
	jmp	StrCopyN

; DcHash - In: a0 = data, d0 = length; Out: d0 = a hash of it (the
; same file again: no need to decode it again)
;--------------------------------------------------------------------
DcHash:
	move.l	d2,-(sp)
	move.l	d0,d1
	moveq	#0,d0
	moveq	#0,d2
	bra.s	.e
.l:	rol.l	#5,d0
	move.b	(a0)+,d2
	add.l	d2,d0
	eor.l	d1,d0
.e:	subq.l	#1,d1
	bpl.s	.l
	move.l	(sp)+,d2
	rts

; DcImgFree - free the pixels DcLoadImg read
DcImgFree:
	move.l	g_DcImg(a4),d0
	beq.s	.x
	clr.l	g_DcImg(a4)
	move.l	d0,a1
	EXEC	FreeVec
.x:	rts

;--------------------------------------------------------------------
; DcStoreImg - keep an image as shown: key a0, d1 bytes of pixels a1,
; mask a2 (g_DcHdr dh_W, dh_H, dh_Mode, dh_Mask set); the validators
; from g_Resp
;--------------------------------------------------------------------
DcStoreImg:
	tst.l	g_DcOn(a4)
	beq.s	.x
	tst.l	g_Resp+r_NoStore(a4)
	bne.s	.x
	moveq	#1,d0
	bra	DcWrite
.x:	rts

VarCacheSize:	dc.b	"Velox/CacheSize",0
VarCacheDir:	dc.b	"Velox/CacheDir",0
DefDir:		dc.b	"PROGDIR:Cache",0
CtText:		dc.b	"text/",0
	even
