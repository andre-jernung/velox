;
; style.s - computed styles: user agent defaults, presentational HTML
;           attributes, colour and length parsing
;
; A Style is computed from the parent's style each time layout visits
; an element; nothing is stored in the DOM.  CSS (css.s) is applied on
; top of what is computed here.
;

	include	"velox.i"

	xdef	StyleRoot,StyleCompute,ParseColor,ParseLength
	xref	UaStyle,DomGetAttr,ToLower,StrIPrefix,StrIFind,SkipSpace
	xref	BgFind

	section	code,code

;--------------------------------------------------------------------
; StyleRoot - the style of the document (root of inheritance)
; In: a0 = Style
;--------------------------------------------------------------------
StyleRoot:
	move.l	a0,a1
	moveq	#STYLE_SIZEOF/4-1,d0
.c:	clr.l	(a1)+
	dbf	d0,.c
	move.b	#DISP_BLOCK,st_Display(a0)
	move.b	#1,st_Font(a0)
	move.l	g_PageFg(a4),st_Color(a0)
	moveq	#-1,d0
	move.l	d0,st_Bg(a0)
	rts

;--------------------------------------------------------------------
; StyleCompute - compute the style of an element
; In: a0 = element, a1 = parent's style, a2 = output Style
;--------------------------------------------------------------------
StyleCompute:
	movem.l	d2-d4/a2-a3/a5,-(sp)
	move.l	a0,a5			; element
	move.l	a2,a3			; out
	moveq	#STYLE_SIZEOF/4-1,d0	; inherit everything ...
.cp:	move.l	(a1)+,(a2)+
	dbf	d0,.cp
	clr.b	st_Display(a3)		; ... then reset what is not inherited
	moveq	#-1,d0
	move.l	d0,st_Bg(a3)
	clr.l	st_BgImg(a3)
	move.b	#3,st_BgRep(a3)
	clr.l	st_MTop(a3)
	clr.l	st_MLeft(a3)
	clr.l	st_Width(a3)
	and.b	#~(SF_MAUTO|SF_FLOATL|SF_FLOATR),st_Flags(a3)

	; user agent defaults
	moveq	#0,d0
	move.w	n_Tag(a5),d0
	lea	UaStyle,a0
	add.w	d0,d0
	move.w	(a0,d0.w),d2		; d2 = UA word
	move.b	d2,d0
	and.b	#15,d0
	move.b	d0,st_Display(a3)
	move.w	d2,d0			; font operation
	lsr.w	#4,d0
	and.w	#15,d0
	beq.s	.nofont
	move.b	st_Font(a3),d1
	cmp.w	#FOP_MONO,d0
	bne.s	.notmono
	or.b	#FONT_MONO,d1
	bra.s	.setf
.notmono:
	cmp.w	#FOP_SMALLER,d0
	bne.s	.notsm
	move.b	d1,d3
	and.b	#7,d3
	beq.s	.setf
	subq.b	#1,d1
	bra.s	.setf
.notsm:	cmp.w	#FOP_LARGER,d0
	bne.s	.head
	move.b	d1,d3
	and.b	#7,d3
	cmp.b	#FONT_SIZES-1,d3
	bhs.s	.setf
	addq.b	#1,d1
	bra.s	.setf
.head:	; FOP_H1 (4) .. FOP_H6 (9) -> size 5 .. 0
	moveq	#FOP_H1+5,d1
	sub.b	d0,d1
.setf:	move.b	d1,st_Font(a3)
.nofont:
	move.w	d2,d0			; soft styles
	lsr.w	#8,d0
	and.b	#7,d0
	or.b	d0,st_Soft(a3)
	btst	#14,d2
	beq.s	.nocenter
	move.b	#ALIGN_CENTER,st_Align(a3)
.nocenter:
	tst.w	d2
	bpl.s	.nopre
	move.b	#WS_PRE,st_White(a3)
.nopre:
	; margins by class, in units of the normal font height (em)
	move.w	d2,d0
	moveq	#11,d1
	lsr.w	d1,d0
	and.w	#7,d0
	beq.s	.nomargin
	move.w	g_FontH+2(a4),d3	; em = height of size class 1
	cmp.w	#MC_PARA,d0
	bne.s	.m2
	move.w	d3,st_MTop(a3)
	move.w	d3,st_MBottom(a3)
	bra.s	.nomargin
.m2:	cmp.w	#MC_LIST,d0
	bne.s	.m3
	move.w	d3,d1
	add.w	d1,d1
	move.w	d1,st_MLeft(a3)
	btst	#0,st_Flags(a3)		; nested lists: no vertical margin
	bne.s	.nomargin
	move.w	d3,st_MTop(a3)
	move.w	d3,st_MBottom(a3)
	bra.s	.nomargin
.m3:	cmp.w	#MC_INDENT,d0
	bne.s	.m4
	move.w	d3,d1
	add.w	d1,d1
	move.w	d1,st_MLeft(a3)
	bra.s	.nomargin
.m4:	cmp.w	#MC_QUOTE,d0
	bne.s	.m5
	move.w	d3,st_MTop(a3)
	move.w	d3,st_MBottom(a3)
	move.w	d3,d1
	add.w	d1,d1
	move.w	d1,st_MLeft(a3)
	move.w	d1,st_MRight(a3)
	bra.s	.nomargin
.m5:	; heading: 2/3 of its own font height
	moveq	#0,d0
	move.b	st_Font(a3),d0
	and.w	#15,d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	move.w	(a0,d0.w),d1
	mulu.w	#2,d1
	divu.w	#3,d1
	move.w	d1,st_MTop(a3)
	move.w	d1,st_MBottom(a3)
.nomargin:

	; tag specific rules
	move.w	n_Tag(a5),d0
	cmp.w	#TAG_UL,d0
	beq.s	.ul
	cmp.w	#TAG_MENU,d0
	beq.s	.ul
	cmp.w	#TAG_DIR,d0
	beq.s	.ul
	cmp.w	#TAG_OL,d0
	beq.s	.ol
	cmp.w	#TAG_A,d0
	beq	.a
	cmp.w	#TAG_FONT,d0
	beq	.font
	bra	.attrs
.ul:	moveq	#LIST_DISC,d1
	btst	#0,st_Flags(a3)
	beq.s	.setl
	moveq	#LIST_CIRCLE,d1
	bra.s	.setl
.ol:	moveq	#LIST_DECIMAL,d1
.setl:	move.b	d1,st_List(a3)
	bset	#0,st_Flags(a3)		; SF_INLIST
	bra	.attrs
.a:	move.l	a5,a0
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.attrs
	move.l	a5,st_Link(a3)
	move.l	g_LinkColor(a4),st_Color(a3)
	or.b	#SOFT_UNDERLINE,st_Soft(a3)
	bra	.attrs
.font:	move.l	a5,a0
	lea	AnColor(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.fsize
	move.l	d0,a0
	bsr	ParseColor
	tst.l	d0
	bmi.s	.fsize
	move.l	d0,st_Color(a3)
.fsize:	move.l	a5,a0
	lea	AnSize(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.fface
	move.l	d0,a0
	jsr	SkipSpace
	moveq	#0,d3			; relative: +n / -n from 3
	move.b	(a0),d0
	cmp.b	#'+',d0
	beq.s	.rel
	cmp.b	#'-',d0
	bne.s	.abs
.rel:	move.b	d0,d3
	addq.l	#1,a0
.abs:	bsr	ParseDecLocal
	tst.l	d1
	beq.s	.fface
	tst.b	d3
	beq.s	.sz
	cmp.b	#'-',d3
	bne.s	.plus
	neg.l	d0
.plus:	addq.l	#3,d0
.sz:	; HTML size 1..7 -> size class 0 0 1 2 3 4 5
	subq.l	#2,d0
	bpl.s	.s1
	moveq	#0,d0
.s1:	cmp.l	#FONT_SIZES-1,d0
	bls.s	.s2
	moveq	#FONT_SIZES-1,d0
.s2:	move.b	st_Font(a3),d1
	and.b	#FONT_MONO,d1
	or.b	d0,d1
	move.b	d1,st_Font(a3)
.fface:	move.l	a5,a0
	lea	AnFace(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.attrs
	move.l	d0,d4
	move.l	d0,a0
	lea	SCourier(pc),a1
	jsr	StrIFind
	bne.s	.mono
	move.l	d4,a0
	lea	SMono(pc),a1
	jsr	StrIFind
	beq.s	.attrs
.mono:	or.b	#FONT_MONO,st_Font(a3)

.attrs:	; presentational attributes common to many elements
	move.l	a5,a0
	lea	AnHidden(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.nohid
	move.b	#DISP_NONE,st_Display(a3)
	bra	.x
.nohid:	move.l	a5,a0
	lea	AnAlign(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.noalign
	cmp.w	#TAG_IMG,n_Tag(a5)	; <img align=left|right>: floats
	bne.s	.notimg
	move.l	d0,a0
	move.b	(a0),d0
	or.b	#$20,d0
	cmp.b	#'l',d0
	bne.s	.ir
	bset	#2,st_Flags(a3)		; SF_FLOATL
.ir:	cmp.b	#'r',d0
	bne.s	.noalign
	bset	#3,st_Flags(a3)		; SF_FLOATR
	bra.s	.noalign
.notimg:
	cmp.b	#DISP_IBLOCK,st_Display(a3)	; (other replaced elements and
	beq.s	.noalign			;  tables align themselves)
	cmp.w	#TAG_TABLE,n_Tag(a5)
	beq.s	.noalign
	move.l	d0,a0
	lea	SCenter(pc),a1		; (StrIPrefix uses d1)
	jsr	StrIPrefix
	beq.s	.al2
	moveq	#ALIGN_CENTER,d1
	bra.s	.setal
.al2:	lea	SRight(pc),a1
	jsr	StrIPrefix
	moveq	#ALIGN_RIGHT,d1
	tst.l	d0
	bne.s	.setal
	moveq	#ALIGN_LEFT,d1		; left, justify, ...
.setal:	move.b	d1,st_Align(a3)
.noalign:
	move.l	a5,a0
	lea	AnBgcolor(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.nobg
	move.l	d0,a0
	bsr	ParseColor
	move.l	d0,st_Bg(a3)
.nobg:	move.l	a5,a0			; background="image" (repeated)
	lea	AnBackground(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.nobi
	move.l	d0,a0
	suba.l	a1,a1
	jsr	BgFind
	move.l	d0,st_BgImg(a3)
.nobi:	move.l	a5,a0
	lea	AnText(pc),a1		; <body text=...>
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.notext
	cmp.w	#TAG_BODY,n_Tag(a5)
	bne.s	.notext
	move.l	d0,a0
	bsr	ParseColor
	tst.l	d0
	bmi.s	.notext
	move.l	d0,st_Color(a3)
.notext:
	move.l	a5,a0
	lea	AnNowrap(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.nonowrap
	move.b	#WS_NOWRAP,st_White(a3)
.nonowrap:
	move.l	a5,a0
	lea	AnWidth(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.now
	move.l	d0,a0
	move.w	g_FontH+2(a4),d0
	bsr	ParseLength
	tst.l	d1
	beq.s	.wpx
	neg.l	d0			; percent: negative
.wpx:	move.w	d0,st_Width(a3)
.now:	move.l	a5,a0
	lea	AnHeight(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	move.w	g_FontH+2(a4),d0
	bsr	ParseLength
	tst.l	d1
	bne.s	.x			; percent heights are ignored
	move.w	d0,st_Height(a3)
.x:	movem.l	(sp)+,d2-d4/a2-a3/a5
	rts

AnHref:		dc.b	"href",0
AnColor:	dc.b	"color",0
AnSize:		dc.b	"size",0
AnFace:		dc.b	"face",0
AnHidden:	dc.b	"hidden",0
AnAlign:	dc.b	"align",0
AnBgcolor:	dc.b	"bgcolor",0
AnBackground:	dc.b	"background",0
AnText:		dc.b	"text",0
AnNowrap:	dc.b	"nowrap",0
AnWidth:	dc.b	"width",0
AnHeight:	dc.b	"height",0
SCourier:	dc.b	"courier",0
SMono:		dc.b	"mono",0
SCenter:	dc.b	"center",0
SRight:		dc.b	"right",0
	even

; ParseDecLocal - In: a0; Out: d0 value, d1 digits, a0 advanced
ParseDecLocal:
	move.l	d2,-(sp)
	moveq	#0,d0
	moveq	#0,d1
.l:	moveq	#0,d2
	move.b	(a0),d2
	sub.b	#'0',d2
	cmp.b	#9,d2
	bhi.s	.x
	mulu.l	#10,d0
	add.l	d2,d0
	addq.l	#1,a0
	addq.l	#1,d1
	bra.s	.l
.x:	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; ParseColor - parse an HTML/CSS colour
; In:  a0 = text ("#rgb", "#rrggbb", "rrggbb", "rgb(r,g,b)", name)
; Out: d0 = $RRGGBB, or -1 if not understood
;--------------------------------------------------------------------
ParseColor:
	movem.l	d2-d4/a2,-(sp)
	jsr	SkipSpace
	move.l	a0,a2
	cmp.b	#'#',(a2)
	bne.s	.nohash
	addq.l	#1,a2
	bsr	HexRun			; d0 = value, d1 = digits
	cmp.w	#6,d1
	beq.s	.ok
	cmp.w	#3,d1
	bne.s	.bad
	; #rgb -> #rrggbb
	move.l	d0,d2
	moveq	#0,d0
	moveq	#2,d3
.ex:	rol.l	#8,d0
	move.l	d2,d1
	lsr.l	#8,d1			; take the top nibble of three
	and.l	#$f,d1
	move.l	d1,d4
	lsl.l	#4,d4
	or.l	d4,d1
	or.l	d1,d0
	lsl.l	#4,d2
	dbf	d3,.ex
	bra.s	.ok
.nohash:
	move.l	a2,a0
	lea	SRgb(pc),a1
	jsr	StrIPrefix
	bne.s	.rgb
	; a bare 6 digit hex value (legacy bgcolor="ffffff")
	bsr	HexRun
	cmp.w	#6,d1
	bne.s	.named
	move.b	(a2,d1.w),d2
	beq.s	.ok
	cmp.b	#' ',d2
	bls.s	.ok
.named:	lea	ColorNames(pc),a1
.nl:	move.l	(a1)+,d2		; colour, -1 = end
	bmi.s	.bad
	move.l	a2,a0
.nc:	move.b	(a1)+,d1
	beq.s	.nend
	move.b	(a0)+,d0
	jsr	ToLower
	cmp.b	d0,d1
	beq.s	.nc
.nskip:	tst.b	(a1)+			; skip the rest of the name
	bne.s	.nskip
	move.l	a1,d0			; names are padded to even length
	addq.l	#1,d0
	and.b	#$fe,d0
	move.l	d0,a1
	bra.s	.nl
.nend:	move.b	(a0),d0			; whole word must match
	jsr	ToLower
	cmp.b	#'a',d0
	blo.s	.nm
	cmp.b	#'z',d0
	bls.s	.nskip1
.nm:	move.l	d2,d0
	bra.s	.ok
.nskip1:
	subq.l	#1,a1			; back on the NUL
	bra.s	.nskip
.rgb:	; rgb(r, g, b) with 0-255 or percentages
	moveq	#0,d2
	moveq	#2,d3
.rl:	jsr	SkipSpace
	bsr	ParseDecLocal
	tst.l	d1
	beq.s	.bad
	cmp.b	#'%',(a0)
	bne.s	.rn
	addq.l	#1,a0
	mulu.w	#255,d0
	divu.w	#100,d0
	and.l	#$ffff,d0
.rn:	cmp.l	#255,d0
	bls.s	.rc
	move.l	#255,d0
.rc:	lsl.l	#8,d2
	or.l	d0,d2
	jsr	SkipSpace
	cmp.b	#',',(a0)
	bne.s	.rs
	addq.l	#1,a0
.rs:	dbf	d3,.rl
	move.l	d2,d0
	bra.s	.ok
.bad:	moveq	#-1,d0
.ok:	movem.l	(sp)+,d2-d4/a2
	rts

; HexRun - In: a2 = text; Out: d0 = value of up to 8 hex digits,
;          d1 = number of digits
HexRun:
	moveq	#0,d0
	moveq	#0,d1
.l:	move.b	(a2,d1.w),d2
	sub.b	#'0',d2
	cmp.b	#9,d2
	bls.s	.d
	move.b	(a2,d1.w),d2
	or.b	#$20,d2
	sub.b	#'a',d2
	cmp.b	#5,d2
	bhi.s	.x
	add.b	#10,d2
.d:	lsl.l	#4,d0
	and.l	#15,d2
	or.l	d2,d0
	addq.w	#1,d1
	cmp.w	#8,d1
	blo.s	.l
.x:	rts

SRgb:	dc.b	"rgb",0
	even

CN	MACRO
	dc.l	\1
	dc.b	\2,0
	even
	ENDM
ColorNames:
	CN	$000000,"black"
	CN	$ffffff,"white"
	CN	$ff0000,"red"
	CN	$008000,"green"
	CN	$0000ff,"blue"
	CN	$ffff00,"yellow"
	CN	$808080,"gray"
	CN	$808080,"grey"
	CN	$c0c0c0,"silver"
	CN	$800000,"maroon"
	CN	$000080,"navy"
	CN	$800080,"purple"
	CN	$008080,"teal"
	CN	$808000,"olive"
	CN	$00ff00,"lime"
	CN	$00ffff,"aqua"
	CN	$00ffff,"cyan"
	CN	$ff00ff,"fuchsia"
	CN	$ff00ff,"magenta"
	CN	$ffa500,"orange"
	CN	$a52a2a,"brown"
	CN	$ffc0cb,"pink"
	CN	$d3d3d3,"lightgray"
	CN	$d3d3d3,"lightgrey"
	CN	$a9a9a9,"darkgray"
	CN	$a9a9a9,"darkgrey"
	CN	$00008b,"darkblue"
	CN	$006400,"darkgreen"
	CN	$8b0000,"darkred"
	CN	$add8e6,"lightblue"
	CN	$90ee90,"lightgreen"
	CN	$ffffe0,"lightyellow"
	CN	$f5f5f5,"whitesmoke"
	CN	$f0f0f0,"gainsboro"
	CN	$4682b4,"steelblue"
	CN	$4169e1,"royalblue"
	CN	$1e90ff,"dodgerblue"
	CN	$87ceeb,"skyblue"
	CN	$ff4500,"orangered"
	CN	$ffd700,"gold"
	CN	$4b0082,"indigo"
	CN	$ee82ee,"violet"
	CN	$f5f5dc,"beige"
	CN	$fffff0,"ivory"
	CN	$f0e68c,"khaki"
	CN	$fa8072,"salmon"
	CN	$ff7f50,"coral"
	CN	$ff6347,"tomato"
	CN	$2f4f4f,"darkslategray"
	CN	$708090,"slategray"
	CN	$dc143c,"crimson"
	CN	$ffffff,"transparent"	; best effort: treated as white
	dc.l	-1

;--------------------------------------------------------------------
; ParseLength - parse a length
; In:  a0 = text, d0.w = em in pixels
; Out: d0 = pixels (or percent), d1 = 1 if percent, 0 otherwise.
;      Units: px (default), em, rem, ex, pt, %.  Up to two decimals.
;--------------------------------------------------------------------
ParseLength:
	movem.l	d2-d4,-(sp)
	moveq	#0,d4
	move.w	d0,d4			; em
	jsr	SkipSpace
	moveq	#0,d3			; sign
	cmp.b	#'-',(a0)
	bne.s	.pos
	moveq	#1,d3
	addq.l	#1,a0
.pos:	bsr	ParseDecLocal		; integer part
	move.l	d0,d2
	mulu.l	#100,d2			; value * 100
	cmp.b	#'.',(a0)
	bne.s	.unit
	addq.l	#1,a0
	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.unit
	mulu.w	#10,d0
	add.l	d0,d2
	addq.l	#1,a0
	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.unit
	add.l	d0,d2
.skipd:	addq.l	#1,a0			; ignore further decimals
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bls.s	.skipd
.unit:	moveq	#0,d1
	move.b	(a0),d0
	cmp.b	#'%',d0
	beq.s	.pct
	jsr	ToLower
	cmp.b	#'e',d0
	beq.s	.em
	cmp.b	#'r',d0
	beq.s	.em			; rem
	cmp.b	#'p',d0
	bne.s	.px
	move.b	1(a0),d0
	jsr	ToLower
	cmp.b	#'t',d0
	bne.s	.px
	mulu.l	#4,d2			; pt = 4/3 px
	divu.l	#3,d2
	bra.s	.px
.em:	move.b	1(a0),d0
	jsr	ToLower
	mulu.l	d4,d2
	cmp.b	#'x',d0
	bne.s	.px
	lsr.l	#1,d2			; ex = em / 2
	bra.s	.px
.pct:	moveq	#1,d1
.px:	move.l	d2,d0
	add.l	#50,d0			; round
	divu.l	#100,d0
	tst.l	d3
	beq.s	.x
	neg.l	d0
.x:	movem.l	(sp)+,d2-d4
	rts
