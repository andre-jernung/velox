;
; maps.s - image maps
;
; Client side: an <img usemap="#name"> is its own link in its run
; (layout.s); the point under the mouse picks the first <area> of
; <map name="name"> whose shape holds it (rect, circle, poly, default):
; that is the link (LinkAt), followed as any (NavLink: its href and
; target).  An area without href holds the point but is no link.  The
; keys step through a map's areas one after the other (FocusNext).
;
; Server side: an <img ismap> in a link notes where it was clicked
; (g_IsMapA, g_IsMapX/Y): NavLink adds "?x,y" to the link's URL.
;

	include	"velox.i"

	xdef	MapHit,MapOf,MapStep,MapIsArea
	xref	DomGetAttr

MAP_COORDS	equ	64		; numbers in coords, at most

	section	code,code

;--------------------------------------------------------------------
; MapHit - (LinkAt) image run a0 at document point d2/d3 (x, y): the
; link there: its map's area (client side), or its link (an ismap image
; inside one: the point noted for NavLink)
; Out: d0 = the link or 0 (CCR set)
;--------------------------------------------------------------------
MapHit:
	movem.l	d2-d3/a2,-(sp)
	move.l	a0,a2			; a2 = the run
	clr.l	g_IsMapA(a4)
	move.w	ru_X(a2),d0		; the point in the image
	ext.l	d0
	sub.l	d0,d2
	sub.l	ru_Y(a2),d3
	move.l	ru_Text(a2),a0		; the <img>
	cmp.l	ru_Link(a2),a0
	bne.s	.ism
	bsr	MapOf			; a map: the area there
	beq.s	.x
	move.l	d0,a0
	move.l	d2,d0
	move.l	d3,d1
	bsr	MapArea
	bra.s	.x
.ism:	lea	SIsmap(pc),a1		; in a link: an ismap image notes the
	jsr	DomGetAttr		; point
	tst.l	d0
	beq.s	.lk
	move.l	ru_Link(a2),g_IsMapA(a4)
	move.l	d2,g_IsMapX(a4)
	move.l	d3,g_IsMapY(a4)
.lk:	move.l	ru_Link(a2),d0
.x:	movem.l	(sp)+,d2-d3/a2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; MapOf - the <map> of <img> a0 (usemap="#name": the map of that name
; or id), or 0 (CCR set)
;--------------------------------------------------------------------
MapOf:
	movem.l	a2-a3,-(sp)
	cmp.l	g_MapImg(a4),a0		; (the last one asked for)
	bne.s	.find
	move.l	g_MapNode(a4),d0
	bra.s	.x
.find:	move.l	a0,g_MapImg(a4)
	clr.l	g_MapNode(a4)
	lea	SUsemap(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a3			; a3 = its name
	cmp.b	#'#',(a3)
	bne.s	.nh
	addq.l	#1,a3
.nh:	move.l	g_Doc(a4),d0		; the <map> of that name
	beq.s	.x
	move.l	d0,a1			; (a1 = root)
	move.l	d0,a2
.walk:	move.l	n_First(a2),d0
	bne.s	.go
.up:	cmp.l	a1,a2
	beq.s	.none
	move.l	n_Next(a2),d0
	bne.s	.go
	move.l	n_Parent(a2),a2
	bra.s	.up
.go:	move.l	d0,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.walk
	cmp.w	#TAG_MAP,n_Tag(a2)
	bne.s	.walk
	move.l	a1,-(sp)
	move.l	a2,a0
	lea	SName(pc),a1
	bsr	AttrIs
	bne.s	.got
	move.l	a2,a0
	lea	SId(pc),a1
	bsr	AttrIs
.got:	move.l	(sp)+,a1
	tst.l	d0
	beq.s	.walk
	move.l	a2,g_MapNode(a4)
	move.l	a2,d0
	bra.s	.x
.none:	moveq	#0,d0
.x:	movem.l	(sp)+,a2-a3
	tst.l	d0
	rts

; AttrIs - (MapOf) is attribute a1 of element a0 the string a3
; (case as it is)?  Out: d0 = 1 if so (CCR set)
AttrIs:
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	move.l	a3,a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.no
	tst.b	d0
	bne.s	.c
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
.x:	rts

;--------------------------------------------------------------------
; MapArea - the first <area> of map a0 whose shape holds point d0/d1:
; it if it has an href, else 0 (CCR set)
;--------------------------------------------------------------------
MapArea:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	d0,d2			; d2/d3 = the point
	move.l	d1,d3
	move.l	a0,a3			; a3 = the map
	move.l	a0,a2
.walk:	move.l	n_First(a2),d0
	bne.s	.go
.up:	cmp.l	a3,a2
	beq.s	.none
	move.l	n_Next(a2),d0
	bne.s	.go
	move.l	n_Parent(a2),a2
	bra.s	.up
.go:	move.l	d0,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.walk
	cmp.w	#TAG_AREA,n_Tag(a2)
	bne.s	.walk
	move.l	a2,a0
	move.l	d2,d0
	move.l	d3,d1
	bsr	AreaHolds
	beq.s	.walk
	move.l	a2,a0			; (no href: it holds the point, but is
	lea	SHref(pc),a1		;  no link)
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	a2,d0
	bra.s	.x
.none:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	tst.l	d0
	rts

;--------------------------------------------------------------------
; AreaHolds - does the shape of <area> a0 hold point d0/d1?
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
AreaHolds:
	movem.l	d2-d7/a2,-(sp)
	lea	-MAP_COORDS*4(sp),sp	; the coords
	move.l	d0,d6			; d6/d7 = the point
	move.l	d1,d7
	move.l	a0,a2
	lea	SShape(pc),a1		; the shape: its first letter
	jsr	DomGetAttr
	moveq	#'r',d5			; (none: a rectangle)
	tst.l	d0
	beq.s	.sh
	move.l	d0,a0
	move.b	(a0),d5
	or.b	#$20,d5
.sh:	cmp.b	#'d',d5			; default: everywhere
	beq	.yes
	move.l	a2,a0			; the coords
	lea	SCoords(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.no
	move.l	d0,a0
	move.l	sp,a1
	bsr	ParseCoords
	move.l	d0,d4			; d4 = how many
	cmp.b	#'c',d5
	beq.s	.circ
	cmp.b	#'p',d5
	beq	.poly
	cmp.l	#4,d4			; a rectangle: x1,y1,x2,y2
	blo	.no
	movem.l	(sp),d0-d3
	cmp.l	d0,d2			; (in either order)
	bge.s	.r1
	exg	d0,d2
.r1:	cmp.l	d1,d3
	bge.s	.r2
	exg	d1,d3
.r2:	cmp.l	d0,d6
	blt	.no
	cmp.l	d2,d6
	bge	.no
	cmp.l	d1,d7
	blt	.no
	cmp.l	d3,d7
	bge	.no
	bra	.yes
.circ:	cmp.l	#3,d4			; a circle: x, y, r
	blo	.no
	movem.l	(sp),d0-d2
	sub.l	d6,d0			; (x - cx)^2 + (y - cy)^2 <= r^2
	muls.l	d0,d0
	sub.l	d7,d1
	muls.l	d1,d1
	add.l	d1,d0
	muls.l	d2,d2
	cmp.l	d2,d0
	bgt	.no
	bra	.yes
.poly:	lsr.l	#1,d4			; a polygon: x1,y1,x2,y2...: a ray to
	cmp.l	#3,d4			; the right crosses its edges an odd
	blo	.no			; number of times
	moveq	#0,d5			; d5 = crossings
	move.l	d4,d3			; d3 = j (the vertex before i)
	subq.l	#1,d3
	moveq	#0,d2			; d2 = i
.pl:	cmp.l	d4,d2
	bhs.s	.pe
	move.l	4(sp,d2.l*8),d0		; yi
	move.l	4(sp,d3.l*8),d1		; yj
	cmp.l	d7,d0			; (yi > y) != (yj > y)?
	sgt	d0
	cmp.l	d7,d1
	sgt	d1
	cmp.b	d0,d1
	beq.s	.pn
	; x < (xj - xi) * (y - yi) / (yj - yi) + xi
	move.l	(sp,d3.l*8),d0		; xj - xi
	sub.l	(sp,d2.l*8),d0
	move.l	d7,d1			; y - yi
	sub.l	4(sp,d2.l*8),d1
	muls.l	d1,d0
	move.l	4(sp,d3.l*8),d1		; yj - yi
	sub.l	4(sp,d2.l*8),d1
	beq.s	.pn
	divs.l	d1,d0
	add.l	(sp,d2.l*8),d0
	cmp.l	d0,d6
	bge.s	.pn
	addq.l	#1,d5
.pn:	move.l	d2,d3
	addq.l	#1,d2
	bra.s	.pl
.pe:	btst	#0,d5
	bne.s	.yes
.no:	moveq	#0,d0
	bra.s	.x
.yes:	moveq	#1,d0
.x:	lea	MAP_COORDS*4(sp),sp
	movem.l	(sp)+,d2-d7/a2
	tst.l	d0
	rts

; ParseCoords - the numbers of list a0 ("10,20, 30 40") into a1 (longs,
; MAP_COORDS at most); Out: d0 = how many
ParseCoords:
	movem.l	d2-d3,-(sp)
	moveq	#0,d2			; d2 = how many
.n:	cmp.l	#MAP_COORDS,d2
	bhs.s	.x
.sk:	move.b	(a0),d0			; to a digit or '-'
	beq.s	.x
	cmp.b	#'-',d0
	beq.s	.num
	sub.b	#'0',d0
	cmp.b	#9,d0
	bls.s	.num
	addq.l	#1,a0
	bra.s	.sk
.num:	moveq	#0,d1			; d1 = the number
	moveq	#0,d3			; d3 = negative
	cmp.b	#'-',(a0)
	bne.s	.d
	moveq	#1,d3
	addq.l	#1,a0
.d:	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.e
	mulu.l	#10,d1
	add.l	d0,d1
	addq.l	#1,a0
	bra.s	.d
.e:	tst.l	d3
	beq.s	.p
	neg.l	d1
.p:	move.l	d1,(a1)+
	addq.l	#1,d2
	cmp.b	#'.',(a0)		; ("10.5": the fraction skipped)
	bne.s	.n
.fr:	addq.l	#1,a0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bls.s	.fr
	bra.s	.n
.x:	move.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

;--------------------------------------------------------------------
; MapIsArea - is element a0 an <area>?  Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
MapIsArea:
	moveq	#0,d0
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.x
	cmp.w	#TAG_AREA,n_Tag(a0)
	bne.s	.x
	moveq	#1,d0
.x:	rts

;--------------------------------------------------------------------
; MapStep - (FocusNext) the keys on image run a0's map: the area after
; (d0 = 1) or before (-1) area a1 (0: the first or the last) that has an
; href
; Out: d0 = it or 0 (none more) (CCR set)
;--------------------------------------------------------------------
MapStep:
	movem.l	d2/a2-a3,-(sp)
	move.l	d0,d2			; d2 = which way
	move.l	a1,a3			; a3 = from
	move.l	ru_Text(a0),a0
	bsr	MapOf
	beq.s	.x
	move.l	d0,a2			; a2 = the map
	move.l	a2,a0			; the areas with an href, in order:
	move.l	a3,a1			; the next after a3 (or before)
	move.l	d2,d0
	bsr	AreaNext
.x:	movem.l	(sp)+,d2/a2-a3
	tst.l	d0
	rts

; AreaNext - (MapStep) map a0: the area with an href after (d0 = 1) or
; before (-1) area a1 (0: from the start or the end)
; Out: d0 = it or 0
AreaNext:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	d0,d2			; d2 = which way
	move.l	a1,d3			; d3 = from (0: none)
	moveq	#0,d4			; d4 = the one before (backwards)
	move.l	a0,a3			; a3 = root
	move.l	a0,a2
	tst.l	d3			; (forwards from none: the first)
	seq	d1
	ext.w	d1
	ext.l	d1
	move.l	d1,-(sp)		; (sp) = past "from" (forwards)
.walk:	move.l	n_First(a2),d0
	bne.s	.go
.up:	cmp.l	a3,a2
	beq.s	.end
	move.l	n_Next(a2),d0
	bne.s	.go
	move.l	n_Parent(a2),a2
	bra.s	.up
.go:	move.l	d0,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.walk
	cmp.w	#TAG_AREA,n_Tag(a2)
	bne.s	.walk
	cmp.l	d3,a2			; "from" itself
	bne.s	.oth
	tst.l	d2
	bmi.s	.back
	st	3(sp)			; forwards: the next one
	bra.s	.walk
.back:	move.l	d4,d0			; backwards: the one before it
	bra.s	.x
.oth:	move.l	a2,a0			; (an href: one to stop at)
	lea	SHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.walk
	tst.l	d2
	bmi.s	.bk
	tst.l	(sp)
	beq.s	.walk
	move.l	a2,d0			; forwards: this one
	bra.s	.x
.bk:	move.l	a2,d4			; backwards: remember it
	bra.s	.walk
.end:	moveq	#0,d0			; the end: backwards from none, the
	tst.l	d2			; last one
	bpl.s	.x
	tst.l	d3
	bne.s	.x
	move.l	d4,d0
.x:	addq.l	#4,sp
	movem.l	(sp)+,d2-d4/a2-a3
	tst.l	d0
	rts

SIsmap:		dc.b	"ismap",0
SUsemap:	dc.b	"usemap",0
SName:		dc.b	"name",0
SId:		dc.b	"id",0
SHref:		dc.b	"href",0
SShape:		dc.b	"shape",0
SCoords:	dc.b	"coords",0
	even
