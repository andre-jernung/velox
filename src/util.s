;
; util.s - string helpers, number parsing/formatting, CLI output,
;          error messages
;

	include	"velox.i"

	xdef	StrLen,StrCopy,StrCopyN,ToLower,StrIPrefix,StrIFind
	xdef	ParseDec,ParseHex,FmtDec,FmtUDec,SkipSpace
	xdef	PutStr,PutBuf,PutChar,PutNum,PutNL,FlushOut
	xdef	ErrorText,LogEvent

	section	code,code

;--------------------------------------------------------------------
; StrLen
; In:  a0 = string
; Out: d0 = length; a0 preserved
;--------------------------------------------------------------------
StrLen:
	move.l	a0,a1
.l:	tst.b	(a1)+
	bne.s	.l
	move.l	a1,d0
	sub.l	a0,d0
	subq.l	#1,d0
	rts

;--------------------------------------------------------------------
; StrCopy - copy a NUL terminated string
; In:  a0 = source, a1 = destination
; Out: a1 = points at the NUL written to the destination
;--------------------------------------------------------------------
StrCopy:
.l:	move.b	(a0)+,(a1)+
	bne.s	.l
	subq.l	#1,a1
	rts

;--------------------------------------------------------------------
; StrCopyN - copy at most d0 bytes, always NUL terminate.  The
; destination must hold d0+1 bytes.
; In:  a0 = source, a1 = destination, d0 = max length
; Out: a1 = points at the NUL written
;--------------------------------------------------------------------
StrCopyN:
	bra.s	.go
.l:	move.b	(a0)+,(a1)+
	beq.s	.end
.go:	subq.l	#1,d0
	bpl.s	.l
	clr.b	(a1)
	rts
.end:	subq.l	#1,a1
	rts

;--------------------------------------------------------------------
; ToLower - ASCII and Latin-1 lower case
; In:  d0.b = char
; Out: d0.b = lower case char (upper bytes unchanged)
;--------------------------------------------------------------------
ToLower:
	cmp.b	#'A',d0
	blo.s	.x
	cmp.b	#'Z',d0
	bls.s	.cv
	cmp.b	#$c0,d0
	blo.s	.x
	cmp.b	#$de,d0
	bhi.s	.x
	cmp.b	#$d7,d0			; multiplication sign
	beq.s	.x
.cv:	add.b	#32,d0
.x:	rts

;--------------------------------------------------------------------
; StrIPrefix - does a string start with a (lower case) prefix?
; In:  a0 = string, a1 = lower case prefix (NUL terminated)
; Out: d0 = 1 and a0 = after the prefix if it matches,
;      d0 = 0 and a0 unchanged otherwise
;--------------------------------------------------------------------
StrIPrefix:
	move.l	a0,-(sp)
.l:	move.b	(a1)+,d1
	beq.s	.yes
	move.b	(a0)+,d0
	bsr.s	ToLower
	cmp.b	d0,d1
	beq.s	.l
	move.l	(sp)+,a0
	moveq	#0,d0
	rts
.yes:	addq.l	#4,sp
	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; StrIFind - search a lower case needle in a string, ignoring case
; In:  a0 = string, a1 = needle
; Out: d0 = 1 if found (a0 = after the match), else 0
;--------------------------------------------------------------------
StrIFind:
	movem.l	a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
.l:	tst.b	(a2)
	beq.s	.no
	move.l	a2,a0
	move.l	a3,a1
	bsr.s	StrIPrefix
	bne.s	.x
	addq.l	#1,a2
	bra.s	.l
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; SkipSpace - skip blanks, tabs, CR, LF
; In:  a0 = string
; Out: a0 = first non-space char
;--------------------------------------------------------------------
SkipSpace:
.l:	move.b	(a0)+,d0
	cmp.b	#' ',d0
	beq.s	.l
	cmp.b	#9,d0
	beq.s	.l
	cmp.b	#10,d0
	beq.s	.l
	cmp.b	#13,d0
	beq.s	.l
	subq.l	#1,a0
	rts

;--------------------------------------------------------------------
; ParseDec - parse an unsigned decimal number
; In:  a0 = string
; Out: d0 = value, d1 = number of digits, a0 = after the digits
;--------------------------------------------------------------------
ParseDec:
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
; ParseHex - parse an unsigned hexadecimal number
; In:  a0 = string
; Out: d0 = value, d1 = number of digits, a0 = after the digits
;--------------------------------------------------------------------
ParseHex:
	move.l	d2,-(sp)
	moveq	#0,d0
	moveq	#0,d1
.l:	moveq	#0,d2
	move.b	(a0),d2
	sub.b	#'0',d2
	cmp.b	#9,d2
	bls.s	.dig
	move.b	(a0),d2
	or.b	#$20,d2			; lower case
	sub.b	#'a',d2
	cmp.b	#5,d2
	bhi.s	.x
	add.b	#10,d2
.dig:	lsl.l	#4,d0
	add.l	d2,d0
	addq.l	#1,a0
	addq.l	#1,d1
	bra.s	.l
.x:	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; FmtDec - format a signed decimal number
; In:  d0 = value, a0 = buffer (12 bytes)
; Out: a0 = points at the NUL written
;--------------------------------------------------------------------
FmtDec:
	tst.l	d0
	bpl.s	FmtUDec
	move.b	#'-',(a0)+
	neg.l	d0
; FmtUDec - the same for an unsigned number
FmtUDec:
	move.l	d2,-(sp)
	lea	-12(sp),sp		; digits are produced in reverse
	move.l	sp,a1
.l:	divul.l	#10,d1:d0		; d0 = quotient, d1 = remainder
	add.b	#'0',d1
	move.b	d1,(a1)+
	tst.l	d0
	bne.s	.l
.c:	move.b	-(a1),(a0)+
	cmp.l	sp,a1
	bne.s	.c
	clr.b	(a0)
	lea	12(sp),sp
	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; CLI output (buffered through dos.library).  No-ops without g_StdOut.
;--------------------------------------------------------------------

; PutStr - In: a0 = string
PutStr:
	move.l	d2,-(sp)
	move.l	a0,d2
	move.l	g_StdOut(a4),d1
	beq.s	.x
	DOS	FPuts
.x:	movem.l	(sp)+,d2
	rts

; PutBuf - In: a0 = data, d0 = length
PutBuf:
	movem.l	d2-d4,-(sp)
	move.l	d0,d4			; number of blocks
	beq.s	.x
	move.l	a0,d2
	moveq	#1,d3			; block length
	move.l	g_StdOut(a4),d1
	beq.s	.x
	DOS	FWrite
.x:	movem.l	(sp)+,d2-d4
	rts

; PutChar - In: d0.b = char
PutChar:
	move.l	d2,-(sp)
	moveq	#0,d2
	move.b	d0,d2
	move.l	g_StdOut(a4),d1
	beq.s	.x
	DOS	FPutC
.x:	movem.l	(sp)+,d2
	rts

; PutNL - write a line feed
PutNL:
	moveq	#10,d0
	bra.s	PutChar

; PutNum - In: d0 = signed number
PutNum:
	lea	-16(sp),sp
	move.l	sp,a0
	bsr	FmtDec
	move.l	sp,a0
	bsr.s	PutStr
	lea	16(sp),sp
	rts

; FlushOut - flush buffered output
FlushOut:
	move.l	g_StdOut(a4),d1
	beq.s	.x
	DOS	Flush
.x:	rts

;--------------------------------------------------------------------
; LogEvent - write "text1[ text2][ number]" as a line to the log file
; (LOG=file argument), if there is one
; In: a0 = text1, a1 = text2 or 0, d0 = number or $80000000 for none
;--------------------------------------------------------------------
LogEvent:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	g_LogFH(a4),d4
	beq.s	.x
	move.l	a1,a3
	move.l	d0,d3
	move.l	d4,d1
	move.l	a0,d2
	DOS	FPuts
	move.l	a3,d0
	beq.s	.nt2
	move.l	d4,d1
	moveq	#' ',d2
	DOS	FPutC
	move.l	d4,d1
	move.l	a3,d2
	DOS	FPuts
.nt2:	cmp.l	#$80000000,d3
	beq.s	.nl
	move.l	d4,d1
	moveq	#' ',d2
	DOS	FPutC
	lea	-16(sp),sp
	move.l	d3,d0
	move.l	sp,a0
	bsr	FmtDec
	move.l	d4,d1
	move.l	sp,d2
	DOS	FPuts
	lea	16(sp),sp
.nl:	move.l	d4,d1
	moveq	#10,d2
	DOS	FPutC
	move.l	d4,d1
	DOS	Flush
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

;--------------------------------------------------------------------
; ErrorText - message for an error code
; In:  d0 = ERR_xxx
; Out: a0 = message
;--------------------------------------------------------------------
ErrorText:
	cmp.l	#ERR_COUNT,d0
	blo.s	.ok
	moveq	#0,d0
.ok:	lea	ErrTab(pc),a0
	add.w	d0,d0
	add.w	(a0,d0.w),a0
	rts

ErrTab:
	dc.w	e0-ErrTab,e1-ErrTab,e2-ErrTab,e3-ErrTab,e4-ErrTab
	dc.w	e5-ErrTab,e6-ErrTab,e7-ErrTab,e8-ErrTab,e9-ErrTab
	dc.w	e10-ErrTab,e11-ErrTab,e12-ErrTab,e13-ErrTab,e14-ErrTab
	dc.w	e15-ErrTab
e0:	dc.b	"No error",0
e1:	dc.b	"Out of memory",0
e2:	dc.b	"Invalid or unsupported URL",0
e3:	dc.b	"No TCP/IP stack (bsdsocket.library v4)",0
e4:	dc.b	"Host not found",0
e5:	dc.b	"Connection failed",0
e6:	dc.b	"Send failed",0
e7:	dc.b	"Receive failed",0
e8:	dc.b	"Connection timed out",0
e9:	dc.b	"Aborted",0
e10:	dc.b	"Invalid HTTP response",0
e11:	dc.b	"Too many redirects",0
e12:	dc.b	"Secure connection (TLS) failed",0
e13:	dc.b	"File error",0
e14:	dc.b	"HTTPS needs AmiSSL 6 or a proxy (PROXY=)",0
e15:	dc.b	"The site's certificate could not be verified",0
	even
