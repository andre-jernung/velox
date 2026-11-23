;
; html.s - HTML tokenizer and tree builder
;
; A tolerant, simplified HTML5 parser.  It works on the page source in
; place: text nodes point into it (entities decoded and, outside <pre>,
; blanks collapsed); attribute values are copied into the page pool.
;
; Tree building handles the implied end tags that matter for real pages:
; <p> closed by blocks, <li>/<dt>/<dd>/<option>, table cells, rows and
; sections, nested <a> and headings.  End tags pop to the matching open
; element unless a scope boundary is in the way.
;
; Register use inside this module:
;   a2 = input cursor
;   a5 = element being created (start tags)
;   d6 = its tag id, d7 = its TF_xxx flags
;

	include	"velox.i"

	xdef	HtmlParse
	xref	PageAlloc,DomNewNode,DomAppend,DomAddAttr,DomGetAttr
	xref	TagLookup,TagFlagsOf,DecodeEntities,ToLower,StrIPrefix

	section	code,code

;--------------------------------------------------------------------
; HtmlParse - build the DOM
; In:  a0 = Latin-1 text, NUL terminated, writable
; Out: d0 = document node or 0 (g_Doc is set too)
;--------------------------------------------------------------------
HtmlParse:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2
	moveq	#DN_DOCUMENT,d0
	moveq	#0,d1
	bsr	DomNewNode
	move.l	d0,g_Doc(a4)
	beq	.x
	move.l	d0,g_OpenStack(a4)
	clr.l	g_Depth(a4)
	clr.l	g_PreDepth(a4)
	clr.l	g_Title(a4)
	clr.l	g_BaseHref(a4)

.loop:	move.b	(a2),d0
	beq	.done
	cmp.b	#'<',d0
	bne.s	.text
	move.b	1(a2),d0
	cmp.b	#'/',d0
	beq	.endtag
	cmp.b	#'!',d0
	beq	.markup
	cmp.b	#'?',d0
	beq	.bogus
	bsr	IsLetter
	bne	.starttag

.text:	move.l	a2,a3			; text runs up to a tag-like '<'
.tl:	addq.l	#1,a2
	move.b	(a2),d0
	beq.s	.tend
	cmp.b	#'<',d0
	bne.s	.tl
	move.b	1(a2),d0
	cmp.b	#'/',d0
	beq.s	.tend
	cmp.b	#'!',d0
	beq.s	.tend
	cmp.b	#'?',d0
	beq.s	.tend
	bsr	IsLetter
	beq.s	.tl
.tend:	move.l	a3,a0
	move.l	a2,d0
	sub.l	a3,d0
	bsr	AddText
	bra.s	.loop

.markup:
	cmp.b	#'-',2(a2)
	bne.s	.bogus
	cmp.b	#'-',3(a2)
	bne.s	.bogus
	addq.l	#4,a2			; comment: up to "-->"
.cm:	move.b	(a2)+,d0
	beq.s	.eof
	cmp.b	#'-',d0
	bne.s	.cm
	cmp.b	#'-',(a2)
	bne.s	.cm
	cmp.b	#'>',1(a2)
	bne.s	.cm
	addq.l	#2,a2
	bra	.loop
.bogus:	bsr	SkipToGt		; <!DOCTYPE ...>, <?...>
	bra	.loop
.eof:	subq.l	#1,a2
	bra	.loop

.endtag:
	move.b	2(a2),d0
	bsr	IsLetter
	beq.s	.bogus			; "</>" or "</ ..."
	addq.l	#2,a2
	bsr	ReadTagName
	bsr	SkipToGt
	lea	g_TagName(a4),a0
	bsr	TagLookup
	bsr	EndTag
	bra	.loop

.starttag:
	addq.l	#1,a2
	bsr	ReadTagName
	lea	g_TagName(a4),a0
	bsr	TagLookup
	move.l	d0,d6
	bsr	TagFlagsOf
	move.l	d0,d7
	moveq	#DN_ELEMENT,d0
	move.l	d6,d1
	bsr	DomNewNode
	tst.l	d0
	beq	.done
	move.l	d0,a5
	bsr	ParseAttrs		; d0 = 1 if "/>"
	move.l	d0,d5
	bsr	ImpliedClose
	bsr	CurrentNode
	move.l	a5,a1
	bsr	DomAppend

	cmp.w	#TAG_BASE,d6
	bne.s	.nobase
	tst.l	g_BaseHref(a4)
	bne.s	.nobase
	move.l	a5,a0
	lea	AnHref(pc),a1
	bsr	DomGetAttr
	move.l	d0,g_BaseHref(a4)
.nobase:
	btst	#0,d7			; TF_VOID
	bne	.loop
	move.l	d7,d0
	and.w	#TF_RAW|TF_RCDATA,d0
	beq.s	.notraw
	bsr	RawText
	bra	.loop
.notraw:
	tst.l	d5			; "<foo/>" on unknown elements
	beq.s	.push
	tst.w	d6
	beq	.loop
.push:	move.l	a5,a0
	bsr	Push
	bra	.loop

.done:	move.l	g_Doc(a4),d0
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

;--------------------------------------------------------------------
; Open element stack
;--------------------------------------------------------------------

; CurrentNode - Out: a0 = innermost open element (or the document)
CurrentNode:
	move.l	g_Depth(a4),d0
	lea	g_OpenStack(a4),a0
	move.l	(a0,d0.l*4),a0
	rts

; Push - In: a0 = element
Push:
	move.l	g_Depth(a4),d0
	cmp.l	#MAX_DEPTH-1,d0
	bhs.s	.full
	addq.l	#1,d0
	move.l	d0,g_Depth(a4)
	lea	g_OpenStack(a4),a1
	move.l	a0,(a1,d0.l*4)
	move.w	n_Tag(a0),d0
	bsr	TagFlagsOf
	tst.b	d0			; TF_PRE is bit 7
	bpl.s	.full
	addq.l	#1,g_PreDepth(a4)
.full:	rts

; PopTo - pop elements until the one at index d0 is gone
; In: d0 = stack index (>= 1)
PopTo:
	move.l	d2,-(sp)
	move.l	d0,d2
.l:	move.l	g_Depth(a4),d0
	cmp.l	d2,d0
	blo.s	.x
	lea	g_OpenStack(a4),a0
	move.l	(a0,d0.l*4),a0
	move.w	n_Tag(a0),d0
	bsr	TagFlagsOf
	tst.b	d0
	bpl.s	.np
	subq.l	#1,g_PreDepth(a4)
.np:	subq.l	#1,g_Depth(a4)
	bra.s	.l
.x:	movem.l	(sp)+,d2
	rts

; FindOpen - innermost open element with tag d0 or d1, searching down
; the stack until an element with one of the flags in d2 is met (that
; element itself can still match).
; In:  d0, d1 = tag ids, d2 = stop flags
; Out: d0 = stack index or 0 when not found
FindOpen:
	movem.l	d3-d5,-(sp)
	move.l	d0,d4
	move.l	d1,d5
	move.l	g_Depth(a4),d3
.l:	tst.l	d3
	beq.s	.nf
	lea	g_OpenStack(a4),a0
	move.l	(a0,d3.l*4),a0
	move.w	n_Tag(a0),d0
	cmp.w	d4,d0
	beq.s	.found
	cmp.w	d5,d0
	beq.s	.found
	bsr	TagFlagsOf
	and.w	d2,d0
	bne.s	.nf
	subq.l	#1,d3
	bra.s	.l
.found:	move.l	d3,d0
	bra.s	.x
.nf:	moveq	#0,d0
.x:	movem.l	(sp)+,d3-d5
	rts

; CloseOpen - FindOpen, then pop to it if found.  Same input.
CloseOpen:
	bsr.s	FindOpen
	tst.l	d0
	beq.s	.x
	bsr.s	PopTo
.x:	rts

; ClosePair - close the innermost of two tags, macro-like helper
CLOSE	MACRO	; tagA, tagB, stopflags
	move.l	#\1,d0
	move.l	#\2,d1
	move.l	#\3,d2
	bsr	CloseOpen
	ENDM

;--------------------------------------------------------------------
; ImpliedClose - close elements that the new start tag ends
; In: d6 = tag id, d7 = flags (a5 = new element)
;--------------------------------------------------------------------
ImpliedClose:
	movem.l	d2,-(sp)
	btst	#1,d7			; TF_CLOSEP
	beq.s	.nop
	CLOSE	TAG_P,TAG_P,TF_SCOPE
.nop:	btst	#10,d7			; TF_HEADING: no heading in a heading
	beq.s	.noh
	bsr	CurrentNode
	move.w	n_Tag(a0),d0
	bsr	TagFlagsOf
	btst	#10,d0
	beq.s	.noh
	move.l	g_Depth(a4),d0
	bsr	PopTo
.noh:	move.w	d6,d0
	cmp.w	#TAG_LI,d0
	beq.s	.li
	cmp.w	#TAG_DT,d0
	beq.s	.dtdd
	cmp.w	#TAG_DD,d0
	beq.s	.dtdd
	cmp.w	#TAG_A,d0
	beq.s	.a
	cmp.w	#TAG_TD,d0
	beq.s	.cell
	cmp.w	#TAG_TH,d0
	beq.s	.cell
	cmp.w	#TAG_TR,d0
	beq.s	.tr
	cmp.w	#TAG_OPTION,d0
	beq.s	.option
	cmp.w	#TAG_OPTGROUP,d0
	beq.s	.optgroup
	btst	#11,d7			; TF_TBODY
	bne.s	.tbody
.x:	movem.l	(sp)+,d2
	rts
.li:	CLOSE	TAG_LI,TAG_LI,TF_LIST|TF_SCOPE
	bra.s	.x
.dtdd:	CLOSE	TAG_DT,TAG_DD,TF_LIST|TF_SCOPE
	bra.s	.x
.a:	CLOSE	TAG_A,TAG_A,TF_SCOPE
	bra.s	.x
.cell:	CLOSE	TAG_TD,TAG_TH,TF_ROW|TF_TABLE
	bra.s	.x
.tr:	CLOSE	TAG_TD,TAG_TH,TF_ROW|TF_TABLE
	CLOSE	TAG_TR,TAG_TR,TF_TABLE|TF_TBODY
	bra.s	.x
.tbody:	CLOSE	TAG_TD,TAG_TH,TF_TABLE
	CLOSE	TAG_TR,TAG_TR,TF_TABLE
	CLOSE	TAG_THEAD,TAG_TBODY,TF_TABLE
	CLOSE	TAG_TFOOT,TAG_TFOOT,TF_TABLE
	bra.s	.x
.optgroup:
	bsr	CurrentNode
	cmp.w	#TAG_OPTION,n_Tag(a0)
	bne.s	.og
	move.l	g_Depth(a4),d0
	bsr	PopTo
.og:	bsr	CurrentNode
	cmp.w	#TAG_OPTGROUP,n_Tag(a0)
	bne.s	.x
	move.l	g_Depth(a4),d0
	bsr	PopTo
	bra.s	.x
.option:
	bsr	CurrentNode
	cmp.w	#TAG_OPTION,n_Tag(a0)
	bne.s	.x
	move.l	g_Depth(a4),d0
	bsr	PopTo
	bra.s	.x

;--------------------------------------------------------------------
; EndTag - handle an end tag
; In: d0 = tag id
;--------------------------------------------------------------------
EndTag:
	movem.l	d2-d3,-(sp)
	move.l	d0,d3
	beq.s	.x			; unknown elements: ignored
	cmp.w	#TAG_BR,d3		; "</br>" acts like "<br>"
	bne.s	.notbr
	moveq	#DN_ELEMENT,d0
	moveq	#TAG_BR,d1
	bsr	DomNewNode
	tst.l	d0
	beq.s	.x
	move.l	d0,-(sp)
	bsr	CurrentNode
	move.l	(sp)+,a1
	bsr	DomAppend
	bra.s	.x
.notbr:	move.l	d3,d0
	bsr	TagFlagsOf
	moveq	#TF_SCOPE,d2		; normal: stop at scope boundaries
	move.w	d0,d1
	and.w	#TF_SCOPE,d1
	beq.s	.find
	moveq	#0,d2			; </td>, </table>...: search everything
.find:	move.w	d0,d1
	and.w	#TF_ROW|TF_TBODY,d1
	beq.s	.go
	move.l	#TF_TABLE,d2		; </tr>, </tbody>: stop at the table
.go:	move.l	d3,d0
	move.l	d3,d1
	bsr	CloseOpen
.x:	movem.l	(sp)+,d2-d3
	rts

;--------------------------------------------------------------------
; AddText - add a text node to the current element
; In: a0 = text start, d0 = length (decoded and collapsed in place)
;--------------------------------------------------------------------
AddText:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	tst.l	d0
	beq	.x
	move.l	a2,a1
	moveq	#0,d1
	bsr	DecodeEntities
	move.l	d0,d2			; length
	tst.l	g_PreDepth(a4)
	bne.s	.pre
	move.l	a2,a0
	move.l	d2,d0
	bsr	Collapse
	move.l	d0,d2
	bra.s	.check
.pre:	; a newline right after <pre>/<textarea> is dropped
	bsr	CurrentNode
	tst.l	n_First(a0)
	bne.s	.check
	cmp.b	#13,(a2)
	bne.s	.nocr
	addq.l	#1,a2
	subq.l	#1,d2
	beq.s	.x
.nocr:	cmp.b	#10,(a2)
	bne.s	.check
	addq.l	#1,a2
	subq.l	#1,d2
.check:	tst.l	d2
	beq.s	.x
	bsr	CurrentNode
	move.l	a0,a3
	cmp.l	#1,d2			; just a blank?
	bne.s	.add
	cmp.b	#' ',(a2)
	bne.s	.add
	cmp.b	#DN_DOCUMENT,n_Type(a3)
	beq.s	.x
	move.w	n_Tag(a3),d0
	bsr	TagFlagsOf
	btst	#6,d0			; TF_NOWS
	bne.s	.x
.add:	moveq	#DN_TEXT,d0
	moveq	#0,d1
	bsr	DomNewNode
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.l	a2,n_Data(a1)
	move.l	d2,n_Data2(a1)
	move.l	a3,a0
	bsr	DomAppend
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; Collapse - turn every run of blanks (space, tab, CR, LF, FF) into a
; single space, in place
; In:  a0 = text, d0 = length
; Out: d0 = new length
;--------------------------------------------------------------------
Collapse:
	movem.l	d2/a2,-(sp)
	move.l	a0,a1			; write position
	move.l	a0,a2			; start
	moveq	#0,d2			; previous character was a blank
.l:	subq.l	#1,d0
	bmi.s	.end
	move.b	(a0)+,d1
	cmp.b	#' ',d1
	beq.s	.bl
	cmp.b	#9,d1
	blo.s	.ch
	cmp.b	#13,d1
	bls.s	.bl			; tab, LF, VT, FF, CR
.ch:	move.b	d1,(a1)+
	moveq	#0,d2
	bra.s	.l
.bl:	tst.b	d2
	bne.s	.l
	move.b	#' ',(a1)+
	moveq	#1,d2
	bra.s	.l
.end:	move.l	a1,d0
	sub.l	a2,d0
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; ReadTagName - copy a tag name at a2 into g_TagName (lower case, max
; 31 characters), advancing a2 past it
;--------------------------------------------------------------------
ReadTagName:
	lea	g_TagName(a4),a1
	moveq	#30,d1
.l:	move.b	(a2),d0
	beq.s	.x
	cmp.b	#' ',d0
	bls.s	.x
	cmp.b	#'/',d0
	beq.s	.x
	cmp.b	#'>',d0
	beq.s	.x
	addq.l	#1,a2
	tst.w	d1
	bmi.s	.l			; too long: skip the rest
	bsr	ToLower
	move.b	d0,(a1)+
	subq.w	#1,d1
	bra.s	.l
.x:	clr.b	(a1)
	rts

; SkipToGt - advance a2 past the next '>' (or to the end)
SkipToGt:
.l:	move.b	(a2)+,d0
	beq.s	.end
	cmp.b	#'>',d0
	bne.s	.l
	rts
.end:	subq.l	#1,a2
	rts

; SkipBlanks - advance a2 over blanks
SkipBlanks:
.l:	move.b	(a2),d0
	cmp.b	#' ',d0
	beq.s	.n
	cmp.b	#9,d0
	blo.s	.x
	cmp.b	#13,d0
	bhi.s	.x
.n:	addq.l	#1,a2
	bra.s	.l
.x:	rts

; IsLetter - In: d0.b; Out: Z clear if ASCII letter (d0 kept)
IsLetter:
	move.b	d0,d1
	or.b	#$20,d1
	sub.b	#'a',d1
	cmp.b	#25,d1
	bls.s	.yes
	moveq	#0,d1
	rts
.yes:	moveq	#1,d1
	rts

;--------------------------------------------------------------------
; ParseAttrs - read attributes up to and including '>'
; In:  a2 = after the tag name, a5 = element
; Out: d0 = 1 if the tag ended with "/>"
;--------------------------------------------------------------------
ParseAttrs:
	movem.l	d2-d4/a3,-(sp)
.l:	bsr.s	SkipBlanks
	move.b	(a2),d0
	beq	.eof
	cmp.b	#'>',d0
	beq	.gt
	cmp.b	#'/',d0
	bne.s	.name
	addq.l	#1,a2
	cmp.b	#'>',(a2)
	bne.s	.l
	addq.l	#1,a2
	moveq	#1,d0
	bra	.x
.name:	; name: up to a blank, '/', '>' or '=' (a leading '=' belongs to it)
	lea	g_AttrName(a4),a1
	moveq	#30,d1
	bra.s	.nc
.nl:	move.b	(a2),d0
	beq.s	.ne
	cmp.b	#' ',d0
	bls.s	.ne
	cmp.b	#'/',d0
	beq.s	.ne
	cmp.b	#'>',d0
	beq.s	.ne
	cmp.b	#'=',d0
	beq.s	.ne
.nc:	move.b	(a2)+,d0
	tst.w	d1
	bmi.s	.nl
	bsr	ToLower
	move.b	d0,(a1)+
	subq.w	#1,d1
	bra.s	.nl
.ne:	clr.b	(a1)
	bsr	SkipBlanks
	lea	Empty(pc),a3		; value start
	moveq	#0,d3			; value length
	cmp.b	#'=',(a2)
	bne.s	.add
	addq.l	#1,a2
	bsr	SkipBlanks
	move.b	(a2),d2
	cmp.b	#'"',d2
	beq.s	.quoted
	cmp.b	#39,d2
	beq.s	.quoted
	move.l	a2,a3			; unquoted
.ul:	move.b	(a2),d0
	beq.s	.ue
	cmp.b	#'>',d0
	beq.s	.ue
	cmp.b	#' ',d0
	bls.s	.ue
	addq.l	#1,a2
	bra.s	.ul
.ue:	move.l	a2,d3
	sub.l	a3,d3
	bra.s	.add
.quoted:
	addq.l	#1,a2
	move.l	a2,a3
.ql:	move.b	(a2),d0
	beq.s	.qe
	cmp.b	d2,d0
	beq.s	.qe
	addq.l	#1,a2
	bra.s	.ql
.qe:	move.l	a2,d3
	sub.l	a3,d3
	tst.b	(a2)
	beq.s	.add
	addq.l	#1,a2			; closing quote
.add:	bsr.s	AddAttr
	tst.l	d0
	bne	.l
.eof:	moveq	#0,d0
	bra.s	.x
.gt:	addq.l	#1,a2
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4/a3
	rts

; AddAttr - add g_AttrName = (a3, d3) to element a5
; Out: d0 = 0 when out of memory
AddAttr:
	movem.l	d2/a2,-(sp)
	tst.b	g_AttrName(a4)
	beq.s	.skip			; empty name ("<a =x>")
	move.l	d3,d0			; copy and decode the value
	addq.l	#1,d0
	bsr	PageAlloc
	beq.s	.x
	move.l	d0,a2
	move.l	a3,a0
	move.l	d3,d0
	move.l	a2,a1
	moveq	#1,d1
	bsr	DecodeEntities
	clr.b	(a2,d0.l)
	bsr	AttrName		; a0 = name to store
	beq.s	.x
	move.l	a0,a1
	move.l	a5,a0
	move.l	a2,d0
	bsr	DomAddAttr
.x:	movem.l	(sp)+,d2/a2
	rts
.skip:	moveq	#1,d0
	bra.s	.x

; AttrName - pointer to a static copy of g_AttrName if it is a known
; name, else a copy in the page pool.
; Out: a0 = name, d0 = 0 when out of memory
AttrName:
	movem.l	a2-a3,-(sp)
	lea	AttrNames(pc),a2
.l:	tst.b	(a2)
	beq.s	.copy
	move.l	a2,a0
	lea	g_AttrName(a4),a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.next
	tst.b	d0
	bne.s	.c
	move.l	a2,a0
	moveq	#1,d0
	bra.s	.x
.next:	tst.b	(a2)+
	bne.s	.next
	bra.s	.l
.copy:	moveq	#32,d0
	bsr	PageAlloc
	beq.s	.x
	move.l	d0,a3
	lea	g_AttrName(a4),a0
	move.l	a3,a1
.cp:	move.b	(a0)+,(a1)+
	bne.s	.cp
	move.l	a3,a0
	moveq	#1,d0
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; RawText - read the content of a raw text / RCDATA element (a5, flags
; in d7) up to its end tag and add it as a text node
;--------------------------------------------------------------------
RawText:
	movem.l	d2-d3/a3,-(sp)
	move.l	a2,a3			; content start
.l:	move.b	(a2),d0
	beq.s	.end
	cmp.b	#'<',d0
	bne.s	.n
	cmp.b	#'/',1(a2)
	bne.s	.n
	lea	2(a2),a0
	lea	g_TagName(a4),a1
	bsr	StrIPrefix
	beq.s	.n
	move.b	(a0),d0			; "</title" must end the name
	cmp.b	#'>',d0
	beq.s	.end
	cmp.b	#'/',d0
	beq.s	.end
	cmp.b	#' ',d0
	bls.s	.end
.n:	addq.l	#1,a2
	bra.s	.l
.end:	move.l	a2,d2
	sub.l	a3,d2			; content length
	beq.s	.close
	move.l	a3,a0
	move.l	d2,d0
	btst	#3,d7			; TF_RCDATA: entities
	beq.s	.raw
	move.l	a3,a1
	moveq	#0,d1
	bsr	DecodeEntities
	move.l	d0,d2
	btst	#7,d7			; TF_PRE (textarea) keeps blanks
	bne.s	.raw
	move.l	a3,a0
	move.l	d2,d0
	bsr	Collapse
	move.l	d0,d2
.raw:	tst.l	d2
	beq.s	.close
	cmp.w	#TAG_TEXTAREA,d6	; drop the first newline
	bne.s	.node
	cmp.b	#10,(a3)
	bne.s	.node
	addq.l	#1,a3
	subq.l	#1,d2
	beq.s	.close
.node:	moveq	#DN_TEXT,d0
	moveq	#0,d1
	bsr	DomNewNode
	tst.l	d0
	beq.s	.close
	move.l	d0,a1
	move.l	a3,n_Data(a1)
	move.l	d2,n_Data2(a1)
	move.l	a5,a0
	bsr	DomAppend
	cmp.w	#TAG_TITLE,d6
	bne.s	.close
	tst.l	g_Title(a4)
	bne.s	.close
	move.l	n_Last(a5),g_Title(a4)
.close:	bsr	SkipToGt		; the end tag
	movem.l	(sp)+,d2-d3/a3
	rts

Empty:		dc.b	0
AnHref:		dc.b	"href",0

; known attribute names (stored once, not per element)
AttrNames:
	dc.b	"href",0,"src",0,"alt",0,"title",0,"name",0,"value",0
	dc.b	"type",0,"id",0,"class",0,"style",0,"width",0,"height",0
	dc.b	"action",0,"method",0,"colspan",0,"rowspan",0,"align",0
	dc.b	"valign",0,"checked",0,"selected",0,"disabled",0,"size",0
	dc.b	"maxlength",0,"rows",0,"cols",0,"color",0,"bgcolor",0
	dc.b	"face",0,"border",0,"target",0,"rel",0,"content",0
	dc.b	"http-equiv",0,"charset",0,"lang",0,"start",0,"for",0
	dc.b	"placeholder",0,"multiple",0,"readonly",0,"label",0
	dc.b	"hidden",0,"cellpadding",0,"cellspacing",0,"text",0
	dc.b	"link",0,"vlink",0,"background",0,"nowrap",0,"role",0
	dc.b	"tabindex",0,"onclick",0,"onload",0,"onsubmit",0
	dc.b	"aria-label",0,"aria-hidden",0,"data-src",0,"srcset",0
	dc.b	"loading",0,"enctype",0,"accept-charset",0,"autocomplete",0
	dc.b	0
	even
