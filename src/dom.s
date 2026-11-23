;
; dom.s - DOM nodes, attributes and tag lookup
;
; The DOM is the persistent model of the page (see docs/DESIGN.md,
; "Keeping the door open for JavaScript").  Nodes live in the page pool.
;

	include	"velox.i"

	xdef	DomNewNode,DomAppend,DomGetAttr,DomAddAttr
	xdef	TagLookup,TagFlagsOf,TagNameOf
	xref	PageAlloc,TagFlags,TagNames

	section	code,code

;--------------------------------------------------------------------
; DomNewNode - allocate a node
; In:  d0 = DN_xxx type, d1 = tag id
; Out: d0 = node or 0
;--------------------------------------------------------------------
DomNewNode:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	move.l	d1,d3
	moveq	#NODE_SIZEOF,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a0
	move.b	d2,n_Type(a0)
	move.w	d3,n_Tag(a0)
	tst.l	d0			; (the CCR follows d0)
.x:	movem.l	(sp)+,d2-d3
	rts

;--------------------------------------------------------------------
; DomAppend - append a child node
; In: a0 = parent, a1 = child
;--------------------------------------------------------------------
DomAppend:
	move.l	a0,n_Parent(a1)
	clr.l	n_Next(a1)
	move.l	n_Last(a0),d0
	beq.s	.first
	move.l	d0,a0
	move.l	a1,n_Next(a0)
	move.l	n_Parent(a1),a0
	move.l	a1,n_Last(a0)
	rts
.first:	move.l	a1,n_First(a0)
	move.l	a1,n_Last(a0)
	rts

;--------------------------------------------------------------------
; DomGetAttr - value of an attribute
; In:  a0 = element, a1 = lower case name
; Out: d0 = value (NUL terminated) or 0
;--------------------------------------------------------------------
DomGetAttr:
	movem.l	a2-a3,-(sp)
	move.l	n_Data(a0),a2
.l:	move.l	a2,d0
	beq.s	.x
	move.l	at_Name(a2),a0
	move.l	a1,a3
.c:	move.b	(a0)+,d0
	cmp.b	(a3)+,d0
	bne.s	.next
	tst.b	d0
	bne.s	.c
	move.l	at_Value(a2),d0
	bra.s	.x
.next:	move.l	at_Next(a2),a2
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; DomAddAttr - append an attribute (no copies are made)
; In:  a0 = element, a1 = name, d0 = value
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
DomAddAttr:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	move.l	d0,d2
	moveq	#ATTR_SIZEOF,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a0
	move.l	a3,at_Name(a0)
	move.l	d2,at_Value(a0)
	lea	n_Data-at_Next(a2),a1	; walk to the last at_Next field
.l:	move.l	at_Next(a1),d1
	beq.s	.end
	move.l	d1,a1
	bra.s	.l
.end:	move.l	a0,at_Next(a1)
	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

;--------------------------------------------------------------------
; TagLookup - tag id for a lower case tag name (binary search)
; In:  a0 = name
; Out: d0 = TAG_xxx or TAG_UNKNOWN
;--------------------------------------------------------------------
TagLookup:
	movem.l	d2-d4/a2-a3,-(sp)
	lea	TagNames,a2
	moveq	#1,d2			; low
	move.l	#TAG_COUNT-1,d3		; high
.l:	cmp.l	d3,d2
	bgt.s	.nf
	move.l	d2,d4
	add.l	d3,d4
	lsr.l	#1,d4			; mid
	move.w	d4,d0
	add.w	d0,d0
	move.l	a2,a1
	add.w	(a2,d0.w),a1		; name of tag mid
	move.l	a0,a3
.c:	move.b	(a3)+,d0
	move.b	(a1)+,d1
	cmp.b	d1,d0
	bne.s	.ne
	tst.b	d0
	bne.s	.c
	move.l	d4,d0
	bra.s	.x
.ne:	bhi.s	.right			; name > tag (unsigned)
	move.l	d4,d3
	subq.l	#1,d3
	bra.s	.l
.right:	move.l	d4,d2
	addq.l	#1,d2
	bra.s	.l
.nf:	moveq	#TAG_UNKNOWN,d0
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

;--------------------------------------------------------------------
; TagFlagsOf - In: d0 = tag id; Out: d0 = TF_xxx flags
;--------------------------------------------------------------------
TagFlagsOf:
	lea	TagFlags,a0
	and.l	#$ffff,d0
	add.w	d0,d0
	move.w	(a0,d0.w),d0
	rts

;--------------------------------------------------------------------
; TagNameOf - In: d0 = tag id; Out: a0 = name
;--------------------------------------------------------------------
TagNameOf:
	lea	TagNames,a0
	and.l	#$ffff,d0
	add.w	d0,d0
	add.w	(a0,d0.w),a0
	rts
