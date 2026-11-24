;
; cookies.s - HTTP cookies (RFC 6265 subset)
;
; A cookie is one allocation: the Cookie header followed by its strings.
; Cookies with Max-Age or Expires are persistent: they are kept in
; ENVARC:Velox/Cookies between runs (one per line: expiry, flags,
; domain, path, name, value, separated by tabs; times in seconds since
; 1978 as the Amiga clock counts).  The others last for the session.
;

	include	"velox.i"

	xdef	CookieSet,CookieHeader,CookieFreeAll,CookiesLoad,CookiesSave
	xref	Alloc,Free,ToLower,StrIPrefix,SkipSpace,ParseDec,BufAppendStr
	xref	BufAppendByte,BufAppend,FmtUDec,StrLen

MAX_COOKIES	equ	300
MAX_COOKIE	equ	4096
CKF_SECURE	equ	1
CKF_HOSTONLY	equ	2

	RSRESET
ck_Next		rs.l	1
ck_Domain	rs.l	1		; lower case, no leading dot
ck_Path		rs.l	1
ck_Name		rs.l	1
ck_Value	rs.l	1
ck_Expires	rs.l	1		; seconds since 1978, 0 = session
ck_Flags	rs.b	1
ck_pad		rs.b	3
CK_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; CookieSet - handle a Set-Cookie header for the request in g_Parts
; In: a0 = header value
;--------------------------------------------------------------------
MAX_SEGS	equ	16

CookieSet:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	lea	-MAX_SEGS*4(sp),sp	; segment pointers
	tst.b	g_Parts+up_Host(a4)
	beq	.x
	; copy and split at ';' into trimmed, NUL terminated segments
	lea	g_CookieBuf(a4),a1
	lea	g_CookieBuf+MAX_COOKIE-1(a4),a2
	move.l	sp,a3
	moveq	#0,d7			; segments
.seg:	move.l	a1,(a3)+
	addq.l	#1,d7
.cp:	move.b	(a0)+,d0
	beq.s	.cpe
	cmp.b	#';',d0
	beq.s	.semi
	cmp.l	a2,a1
	bhs.s	.cp
	move.b	d0,(a1)+
	bra.s	.cp
.semi:	clr.b	(a1)+
	cmp.l	#MAX_SEGS,d7
	blo.s	.seg
.skip:	tst.b	(a0)+			; too many attributes: ignore the rest
	bne.s	.skip
.cpe:	clr.b	(a1)
	moveq	#0,d1
.tr:	move.l	(sp,d1.l*4),a0
	bsr	Trim
	move.l	a0,(sp,d1.l*4)
	addq.l	#1,d1
	cmp.l	d7,d1
	blo.s	.tr
	; name=value
	move.l	(sp),a0
	move.l	a0,d2			; name
.n:	move.b	(a0),d0
	beq	.x			; no '='
	cmp.b	#'=',d0
	beq.s	.eq
	addq.l	#1,a0
	bra.s	.n
.eq:	clr.b	(a0)+
	move.l	a0,a1
	bsr	Trim			; (value)
	move.l	a0,d3
	move.l	d2,a0
	bsr	Trim
	move.l	a0,d2
	tst.b	(a0)
	beq	.x			; empty name
	; attributes
	moveq	#CKF_HOSTONLY,d4	; flags
	moveq	#0,d5			; domain
	moveq	#0,d6			; path
	suba.l	a5,a5			; 1 = delete
	clr.l	g_CookieExp(a4)		; Expires
	clr.l	g_CookieAge(a4)		; Max-Age (wins over Expires)
	moveq	#1,d1
.attr:	cmp.l	d7,d1
	bhs	.done
	move.l	d1,-(sp)
	move.l	4(sp,d1.l*4),a3		; (segments start at 4(sp) now)
	move.l	a3,a0
	lea	AtDomain(pc),a1
	jsr	StrIPrefix
	beq.s	.a2
	bsr	AttrValue
	cmp.b	#'.',(a0)
	bne.s	.dom
	addq.l	#1,a0
.dom:	tst.b	(a0)
	beq.s	.an
	move.l	a0,d5
	bsr	Lower
	bra.s	.an
.a2:	move.l	a3,a0
	lea	AtPath(pc),a1
	jsr	StrIPrefix
	beq.s	.a3
	bsr	AttrValue
	cmp.b	#'/',(a0)
	bne.s	.an
	move.l	a0,d6
	bra.s	.an
.a3:	move.l	a3,a0
	lea	AtSecure(pc),a1
	jsr	StrIPrefix
	beq.s	.a4
	tst.b	(a0)
	bne.s	.an
	bset	#0,d4			; CKF_SECURE
	bra.s	.an
.a4:	move.l	a3,a0
	lea	AtMaxAge(pc),a1
	jsr	StrIPrefix
	beq.s	.a5
	bsr	AttrValue
	cmp.b	#'-',(a0)
	beq.s	.del
	jsr	ParseDec
	tst.l	d0
	beq.s	.del
	move.l	d0,g_CookieAge(a4)
	bra.s	.an
.del:	move.w	#1,a5
	bra.s	.an
.a5:	move.l	a3,a0
	lea	AtExpires(pc),a1
	jsr	StrIPrefix
	beq.s	.an
	bsr	AttrValue
	bsr	ParseDate
	move.l	d0,g_CookieExp(a4)
.an:	move.l	(sp)+,d1
	addq.l	#1,d1
	bra	.attr
.done:	; expiry: Max-Age, else Expires; in the past: a delete
	bsr	Now
	move.l	d0,d7
	move.l	g_CookieAge(a4),d1
	beq.s	.exp
	add.l	d1,d7			; now + Max-Age
	bcc.s	.ttl
	moveq	#-1,d7
	bra.s	.ttl
.exp:	move.l	g_CookieExp(a4),d1
	beq.s	.sess
	cmp.l	d0,d1
	bls.s	.gone
	move.l	d1,d7
	bra.s	.ttl
.gone:	move.w	#1,a5
.sess:	moveq	#0,d7
.ttl:
	; the domain must match the request host
	lea	g_Parts+up_Host(a4),a1
	tst.l	d5
	beq.s	.host
	move.l	d5,a0
	bsr	DomainMatch
	beq	.x			; a cookie for someone else
	bclr	#1,d4			; not host-only
	bra.s	.path
.host:	move.l	a1,d5
.path:	tst.l	d6
	bne.s	.haspath
	; default path: the directory of the request path
	lea	g_CookiePath(a4),a0
	move.l	a0,d6
	move.b	#'/',(a0)
	clr.b	1(a0)
	move.l	g_Parts+up_Path(a4),a1
	move.l	g_Parts+up_PathLen(a4),d1
	beq.s	.haspath
	cmp.b	#'/',(a1)
	bne.s	.haspath
	move.l	a0,a3			; last '/' written
	lea	g_CookiePath+HOST_MAX-1(a4),a2
.pl:	subq.l	#1,d1
	bmi.s	.pd
	move.b	(a1)+,d0
	cmp.b	#'?',d0
	beq.s	.pd
	cmp.l	a2,a0
	bhs.s	.pd
	move.b	d0,(a0)
	cmp.b	#'/',d0
	bne.s	.pn
	move.l	a0,a3
.pn:	addq.l	#1,a0
	bra.s	.pl
.pd:	cmp.l	d6,a3			; only the leading '/': keep "/"
	bne.s	.cut
	addq.l	#1,a3
.cut:	clr.b	(a3)
.haspath:
	move.l	a5,d0
	beq.s	.keep
	move.l	d5,a0			; a delete
	move.l	d6,a1
	move.l	d2,d0
	bsr	CookieRemove
	bra.s	.x
.keep:	bsr	CkStore
.x:	lea	MAX_SEGS*4(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

;--------------------------------------------------------------------
; CkStore - add a cookie, replacing one with the same domain, path and
; name.  In: d2 = name, d3 = value, d4 = flags, d5 = domain, d6 = path,
; d7 = expiry (0 = session)
;--------------------------------------------------------------------
CkStore:
	movem.l	d1-d7/a2-a3,-(sp)
	move.l	d5,a0
	move.l	d6,a1
	move.l	d2,d0
	bsr	CookieRemove
	tst.l	d7
	beq.s	.nd
	st	g_CookiesDirty(a4)	; the file changes
.nd:	; one allocation for the cookie and its strings
	move.l	d5,a0
	bsr	Len
	move.l	d0,d1
	move.l	d6,a0
	bsr	Len
	add.l	d0,d1
	move.l	d2,a0
	bsr	Len
	add.l	d0,d1
	move.l	d3,a0
	bsr	Len
	add.l	d0,d1
	cmp.l	#MAX_COOKIE,d1
	bhi	.x
	move.l	d1,d0
	add.l	#CK_SIZEOF,d0
	jsr	Alloc
	beq	.x
	move.l	d0,a3
	lea	CK_SIZEOF(a3),a1
	move.l	a1,ck_Domain(a3)
	move.l	d5,a0
	bsr	Cpy
	move.l	a1,ck_Path(a3)
	move.l	d6,a0
	bsr	Cpy
	move.l	a1,ck_Name(a3)
	move.l	d2,a0
	bsr	Cpy
	move.l	a1,ck_Value(a3)
	move.l	d3,a0
	bsr	Cpy
	move.b	d4,ck_Flags(a3)
	move.l	d7,ck_Expires(a3)
	cmp.l	#MAX_COOKIES,g_CookieCount(a4)
	blo.s	.add
	bsr	DropOldest
.add:	lea	g_Cookies(a4),a0	; append: oldest first
.ap:	move.l	(a0),d0
	beq.s	.ape
	move.l	d0,a0
	bra.s	.ap
.ape:	move.l	a3,(a0)			; (ck_Next is at offset 0)
	addq.l	#1,g_CookieCount(a4)
.x:	movem.l	(sp)+,d1-d7/a2-a3
	rts

; Trim - In: a0 = NUL terminated string (writable)
; Out: a0 = first non-blank; trailing blanks cut (d1 kept)
Trim:
.l:	move.b	(a0),d0
	beq.s	.e
	cmp.b	#' ',d0
	bhi.s	.e
	addq.l	#1,a0
	bra.s	.l
.e:	move.l	a0,a1
.f:	tst.b	(a1)+
	bne.s	.f
	subq.l	#1,a1
.t:	cmp.l	a0,a1
	bls.s	.x
	cmp.b	#' ',-1(a1)
	bhi.s	.x
	clr.b	-(a1)
	bra.s	.t
.x:	rts

; Lower - lower case a string in place
Lower:
.l:	move.b	(a0),d0
	beq.s	.x
	jsr	ToLower
	move.b	d0,(a0)+
	bra.s	.l
.x:	rts

AtDomain:	dc.b	"domain",0
AtPath:		dc.b	"path",0
AtSecure:	dc.b	"secure",0
AtMaxAge:	dc.b	"max-age",0
AtExpires:	dc.b	"expires",0
	even

; AttrValue - a0 after the attribute name: skip "=" and blanks
AttrValue:
.l:	move.b	(a0),d0
	beq.s	.x
	cmp.b	#'=',d0
	beq.s	.eq
	cmp.b	#' ',d0
	bhi.s	.x
	addq.l	#1,a0
	bra.s	.l
.eq:	addq.l	#1,a0
.b:	cmp.b	#' ',(a0)
	bne.s	.x
	addq.l	#1,a0
	bra.s	.b
.x:	rts

; Len - In: a0 = string; Out: d0 = length + 1
Len:
	move.l	a0,d0
.l:	tst.b	(a0)+
	bne.s	.l
	sub.l	d0,a0
	move.l	a0,d0
	rts

; Cpy - copy a0 to a1 including the NUL; a1 after it
Cpy:
.l:	move.b	(a0)+,(a1)+
	bne.s	.l
	rts

; DomainMatch - does host a1 match cookie domain a0?
; host == domain, or host ends with "." domain.  Out: Z clear if yes
DomainMatch:
	movem.l	a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	move.l	a3,a0
	bsr	Len
	move.l	d0,d1			; host length + 1
	move.l	a2,a0
	bsr	Len			; domain length + 1
	sub.l	d0,d1			; how much longer the host is
	bmi.s	.no
	beq.s	.cmp
	move.l	a3,a0
	add.l	d1,a0
	cmp.b	#'.',-1(a0)		; must be a whole label
	bne.s	.no
	move.l	a0,a3
.cmp:	move.l	a2,a0
	move.l	a3,a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.no
	tst.b	d0
	bne.s	.c
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2-a3
	rts

; StrEq - Out: Z clear if a0 = a1
StrEq:
.l:	move.b	(a0)+,d1
	cmp.b	(a1)+,d1
	bne.s	.no
	tst.b	d1
	bne.s	.l
	moveq	#1,d1
	rts
.no:	moveq	#0,d1
	rts

; CookieRemove - remove the cookie (domain a0, path a1, name d0)
CookieRemove:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	a0,d2
	move.l	a1,d3
	move.l	d0,d4
	lea	g_Cookies(a4),a3	; a3 = the link that points to a2
.l:	move.l	(a3),d0
	beq.s	.x
	move.l	d0,a2
	move.l	ck_Domain(a2),a0
	move.l	d2,a1
	bsr	StrEq
	beq.s	.n
	move.l	ck_Path(a2),a0
	move.l	d3,a1
	bsr	StrEq
	beq.s	.n
	move.l	ck_Name(a2),a0
	move.l	d4,a1
	bsr	StrEq
	beq.s	.n
	tst.l	ck_Expires(a2)
	beq.s	.ns
	st	g_CookiesDirty(a4)
.ns:	move.l	ck_Next(a2),(a3)	; unlink and free
	subq.l	#1,g_CookieCount(a4)
	move.l	a2,a1
	jsr	Free
	bra.s	.x
.n:	move.l	a2,a3
	bra.s	.l
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

; DropOldest - free the first cookie
DropOldest:
	move.l	g_Cookies(a4),d0
	beq.s	.x
	move.l	d0,a1
	move.l	ck_Next(a1),g_Cookies(a4)
	subq.l	#1,g_CookieCount(a4)
	jmp	Free
.x:	rts

;--------------------------------------------------------------------
; CookieHeader - append "\r\nCookie: a=b; c=d" for the request in
; g_Parts to a Buf (nothing if no cookie applies)
; In:  a0 = Buf
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
CookieHeader:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	a0,a3
	bsr	Now
	move.l	d0,d4			; d4 = now
	moveq	#0,d3			; cookies written
	move.l	g_Cookies(a4),a2
.l:	move.l	a2,d0
	beq	.done
	move.l	ck_Expires(a2),d0	; expired?
	beq.s	.live
	cmp.l	d4,d0
	bls	.n
.live:
	; secure cookies only over https
	btst	#0,ck_Flags(a2)
	beq.s	.s
	cmp.l	#SCHEME_HTTPS,g_Parts+up_Scheme(a4)
	bne	.n
.s:	; domain
	lea	g_Parts+up_Host(a4),a1
	move.l	ck_Domain(a2),a0
	btst	#1,ck_Flags(a2)
	beq.s	.dm
	bsr	StrEq			; host-only: exactly the host
	beq	.n
	bra.s	.p
.dm:	bsr	DomainMatch
	beq	.n
.p:	; path: the request path starts with the cookie path, at a '/'
	move.l	ck_Path(a2),a0
	move.l	g_Parts+up_Path(a4),a1
	move.l	g_Parts+up_PathLen(a4),d2
	tst.l	d2			; an empty path is "/"
	beq.s	.root
	cmp.b	#'?',(a1)
	beq.s	.root
.pc:	move.b	(a0)+,d0
	beq.s	.pend
	subq.l	#1,d2
	bmi.s	.n
	cmp.b	(a1)+,d0
	bne.s	.n
	bra.s	.pc
.root:	cmp.b	#'/',(a0)+
	bne.s	.n
	tst.b	(a0)
	bne.s	.n
	bra.s	.ok
.pend:	cmp.b	#'/',-2(a0)		; cookie path ended with '/'
	beq.s	.ok
	tst.l	d2			; or the request path continues
	beq.s	.ok			; with '/', '?' or ends
	move.b	(a1),d0
	cmp.b	#'/',d0
	beq.s	.ok
	cmp.b	#'?',d0
	bne.s	.n
.ok:	lea	SSep(pc),a1
	tst.l	d3
	bne.s	.sep
	lea	SCookie(pc),a1
.sep:	move.l	a3,a0
	jsr	BufAppendStr
	beq.s	.fail
	move.l	a3,a0
	move.l	ck_Name(a2),a1
	jsr	BufAppendStr
	beq.s	.fail
	move.l	a3,a0
	moveq	#'=',d0
	jsr	BufAppendByte
	beq.s	.fail
	move.l	a3,a0
	move.l	ck_Value(a2),a1
	jsr	BufAppendStr
	beq.s	.fail
	addq.l	#1,d3
.n:	move.l	ck_Next(a2),a2
	bra	.l
.done:	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

SCookie:	dc.b	13,10,"Cookie: ",0
SSep:		dc.b	"; ",0
	even

;--------------------------------------------------------------------
; CookieFreeAll - forget all cookies
;--------------------------------------------------------------------
CookieFreeAll:
.l:	tst.l	g_Cookies(a4)
	beq.s	.x
	bsr	DropOldest
	bra.s	.l
.x:	rts

;--------------------------------------------------------------------
; Now - the time in seconds since 1978 (g_TestNow if set, for tests)
;--------------------------------------------------------------------
Now:
	move.l	g_TestNow(a4),d0
	bne.s	.x
	lea	-12(sp),sp
	move.l	sp,d1
	DOS	DateStamp
	move.l	(sp),d0			; days
	mulu.l	#86400,d0
	move.l	4(sp),d1		; minutes
	mulu.w	#60,d1
	add.l	d1,d0
	move.l	8(sp),d1		; ticks
	divu.w	#50,d1
	and.l	#$ffff,d1
	add.l	d1,d0
	lea	12(sp),sp
.x:	rts

;--------------------------------------------------------------------
; ParseDate - an HTTP date ("Wed, 21 Oct 2026 07:28:00 GMT", also
; with dashes or a 2 digit year) to seconds since 1978
; In:  a0 = text; Out: d0 = seconds, or 0 if there is no year
;--------------------------------------------------------------------
ParseDate:
	movem.l	d2-d6,-(sp)
	moveq	#1,d2			; day
	moveq	#0,d3			; month 0-11
	moveq	#0,d4			; year
	moveq	#0,d5			; seconds of the day
.tok:	move.b	(a0),d0
	beq	.calc
	sub.b	#'0',d0
	cmp.b	#9,d0
	bls.s	.num
	move.b	(a0),d0			; a month name?
	jsr	ToLower
	move.b	d0,d1
	lsl.w	#8,d1
	move.b	1(a0),d0
	jsr	ToLower
	move.b	d0,d1
	swap	d1
	move.b	2(a0),d0
	jsr	ToLower
	lsl.w	#8,d0
	move.w	d0,d1
	lea	Months(pc),a1
	moveq	#0,d6
.m:	move.l	(a1)+,d0
	beq.s	.skip
	and.l	#$ffffff00,d1
	cmp.l	d0,d1
	beq.s	.mon
	addq.l	#1,d6
	bra.s	.m
.mon:	move.l	d6,d3
.skip:	addq.l	#1,a0
	bra.s	.tok
.num:	jsr	ParseDec		; d0 = value, d1 = digits
	cmp.b	#':',(a0)
	bne.s	.notime
	mulu.l	#3600,d0		; hh:mm:ss
	move.l	d0,d5
	addq.l	#1,a0
	jsr	ParseDec
	mulu.w	#60,d0
	add.l	d0,d5
	cmp.b	#':',(a0)
	bne.s	.tok
	addq.l	#1,a0
	jsr	ParseDec
	add.l	d0,d5
	bra.s	.tok
.notime:
	cmp.l	#2,d1
	bhi.s	.year
	tst.l	d4			; 2 digits: the day, then the year
	bne.s	.yy
	cmp.l	#1,d2
	bne.s	.yy
	move.l	d0,d2
	bra.s	.tok
.yy:	add.l	#1900,d0		; 70-99: 19xx, else 20xx
	cmp.l	#1970,d0
	bhs.s	.year
	add.l	#100,d0
.year:	move.l	d0,d4
	bra	.tok
.calc:	moveq	#0,d0
	cmp.l	#1978,d4		; before the Amiga's epoch: long gone
	blo.s	.old
	cmp.l	#2099,d4		; the far future: 2099
	bls.s	.y
	move.l	#2099,d4
.y:	move.l	d4,d0			; days: years, leap days, months, day
	sub.l	#1978,d0
	mulu.l	#365,d0
	move.l	d4,d1
	subq.l	#1,d1
	lsr.l	#2,d1
	sub.l	#1977/4,d1		; leap years since 1978
	add.l	d1,d0
	lea	MonthDays(pc),a1
	add.w	(a1,d3.l*2),d0
	cmp.l	#2,d3			; past February in a leap year
	blo.s	.nl
	moveq	#3,d1
	and.l	d4,d1
	bne.s	.nl
	addq.l	#1,d0
.nl:	add.l	d2,d0
	subq.l	#1,d0
	mulu.l	#86400,d0
	add.l	d5,d0
	bne.s	.x
.old:	moveq	#1,d0			; (0 means "no date")
.x:	movem.l	(sp)+,d2-d6
	rts

Months:		dc.b	"jan",0,"feb",0,"mar",0,"apr",0,"may",0,"jun",0
		dc.b	"jul",0,"aug",0,"sep",0,"oct",0,"nov",0,"dec",0
		dc.l	0
MonthDays:	dc.w	0,31,59,90,120,151,181,212,243,273,304,334

;--------------------------------------------------------------------
; CookiesSave - write the persistent cookies (if they changed)
;--------------------------------------------------------------------
CookiesSave:
	movem.l	d2-d5/a2,-(sp)
	tst.b	g_CookiesDirty(a4)
	beq	.x
	lea	CkDir(pc),a0		; ENVARC:Velox may not exist yet
	move.l	a0,d1
	DOS	CreateDir
	move.l	d0,d1
	beq.s	.nodir
	DOS	UnLock
.nodir:	lea	CkFile(pc),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	beq	.x
	bsr	Now
	move.l	d0,d5
	move.l	g_Cookies(a4),a2
.l:	move.l	a2,d0
	beq.s	.done
	move.l	ck_Expires(a2),d0	; persistent and not expired
	beq.s	.n
	cmp.l	d5,d0
	bls.s	.n
	lea	-16(sp),sp
	move.l	sp,a0
	jsr	FmtUDec
	move.l	sp,a0
	bsr	.put
	lea	16(sp),sp
	moveq	#'0',d2
	add.b	ck_Flags(a2),d2
	bsr	.tab
	move.l	d4,d1
	DOS	FPutC
	move.l	ck_Domain(a2),a0
	bsr	.field
	move.l	ck_Path(a2),a0
	bsr	.field
	move.l	ck_Name(a2),a0
	bsr	.field
	move.l	ck_Value(a2),a0
	bsr	.field
	moveq	#10,d2
	move.l	d4,d1
	DOS	FPutC
.n:	move.l	ck_Next(a2),a2
	bra.s	.l
.done:	move.l	d4,d1
	DOS	Close
	clr.b	g_CookiesDirty(a4)
.x:	movem.l	(sp)+,d2-d5/a2
	rts
.field:	move.l	a0,-(sp)		; tab, then the string
	move.l	d2,-(sp)
	bsr.s	.tab
	move.l	(sp)+,d2
	move.l	(sp)+,a0
.put:	move.l	a0,d2
	move.l	d4,d1
	DOS	FPuts
	rts
.tab:	move.l	d2,-(sp)
	moveq	#9,d2
	move.l	d4,d1
	DOS	FPutC
	move.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; CookiesLoad - read the persistent cookies of earlier runs
;--------------------------------------------------------------------
CookiesLoad:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	lea	CkFile(pc),a0
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d7
	beq	.x
	move.l	#MAX_FILE,d0
	jsr	Alloc
	move.l	d0,a5
	tst.l	d0
	beq	.close
	move.l	d7,d1
	move.l	a5,d2
	move.l	#MAX_FILE-1,d3
	DOS	Read
	tst.l	d0
	bpl.s	.rd
	moveq	#0,d0
.rd:	clr.b	(a5,d0.l)
	move.l	d7,d1
	DOS	Close
	bsr	Now
	move.l	d0,g_CookieExp(a4)	; (now)
	move.l	a5,a3			; a3 = the next line
.line:	tst.b	(a3)
	beq.s	.free
	move.l	a3,a0			; the end of the line
.eol:	move.b	(a0),d0
	beq.s	.eole
	addq.l	#1,a0
	cmp.b	#10,d0
	bne.s	.eol
	clr.b	-1(a0)
.eole:	move.l	a0,-(sp)		; the next line
	lea	-24(sp),sp		; six fields, split at tabs
	move.l	sp,a2
	moveq	#5,d0
.f:	move.l	a3,(a2)+
.fc:	move.b	(a3)+,d1
	beq.s	.fe
	cmp.b	#9,d1
	bne.s	.fc
	clr.b	-1(a3)
	dbf	d0,.f
	bra.s	.bad			; too many fields
.fe:	tst.w	d0			; exactly six?
	bne.s	.bad
	move.l	(sp),a0
	jsr	ParseDec
	move.l	d0,d7			; expiry
	cmp.l	g_CookieExp(a4),d7
	bls.s	.bad			; expired
	move.l	4(sp),a0
	jsr	ParseDec
	move.l	d0,d4			; flags
	move.l	8(sp),d5		; domain
	move.l	12(sp),d6		; path
	move.l	16(sp),d2		; name
	move.l	20(sp),d3		; value
	bsr	CkStore
.bad:	lea	24(sp),sp
	move.l	(sp)+,a3
	bra.s	.line
.free:	move.l	a5,a1
	jsr	Free
	clr.b	g_CookiesDirty(a4)	; as on disk
	bra.s	.x
.close:	move.l	d7,d1
	DOS	Close
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

MAX_FILE	equ	64*1024
CkDir:		dc.b	"ENVARC:Velox",0
CkFile:		dc.b	"ENVARC:Velox/Cookies",0
	even
