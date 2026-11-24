;
; url.s - URL parsing and resolution (RFC 3986 subset)
;

	include	"velox.i"

	xdef	UrlParse,UrlResolve,UrlFixup
	xref	ToLower,ParseDec,StrCopy,StrCopyN,StrIPrefix

	section	code,code

;--------------------------------------------------------------------
; UrlParse - split an absolute http(s) URL
; In:  a0 = URL, a1 = UrlParts
; Out: d0 = 1 if ok, 0 if malformed (g_Error = ERR_URL).
;      up_Scheme is SCHEME_OTHER for schemes we cannot fetch (d0 = 1).
;--------------------------------------------------------------------
UrlParse:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2			; a2 = cursor
	move.l	a1,a3
	move.l	#SCHEME_OTHER,up_Scheme(a3)
	clr.l	up_Port(a3)
	clr.b	up_Host(a3)
	clr.l	up_PathLen(a3)
	move.l	a2,up_Path(a3)

	move.l	a2,a0
	lea	SchHttps(pc),a1
	jsr	StrIPrefix
	beq.s	.nothttps
	move.l	#SCHEME_HTTPS,up_Scheme(a3)
	move.l	#443,up_Port(a3)
	bra.s	.auth
.nothttps:
	lea	SchHttp(pc),a1
	jsr	StrIPrefix
	beq.s	.other
	move.l	#SCHEME_HTTP,up_Scheme(a3)
	moveq	#80,d0
	move.l	d0,up_Port(a3)
.auth:
	; a0 = start of authority.  Skip userinfo ("user:pw@").
	move.l	a0,a2
	move.l	a0,a1
	move.l	a0,up_User(a3)
	clr.l	up_UserLen(a3)
.ui:	move.b	(a1)+,d0
	beq.s	.host
	cmp.b	#'/',d0
	beq.s	.host
	cmp.b	#'?',d0
	beq.s	.host
	cmp.b	#'#',d0
	beq.s	.host
	cmp.b	#'@',d0
	bne.s	.ui
	move.l	a1,a2			; host starts after the '@'
	move.l	a1,d0
	sub.l	up_User(a3),d0
	subq.l	#1,d0
	move.l	d0,up_UserLen(a3)
	bra.s	.ui
.host:
	lea	up_Host(a3),a1
	move.w	#HOST_MAX-2,d2
.hl:	move.b	(a2),d0
	beq.s	.hend
	cmp.b	#':',d0
	beq.s	.hend
	cmp.b	#'/',d0
	beq.s	.hend
	cmp.b	#'?',d0
	beq.s	.hend
	cmp.b	#'#',d0
	beq.s	.hend
	jsr	ToLower
	move.b	d0,(a1)+
	addq.l	#1,a2
	dbf	d2,.hl
	bra.s	.bad			; host name too long
.hend:
	clr.b	(a1)
	tst.b	up_Host(a3)
	beq.s	.bad
	cmp.b	#':',(a2)
	bne.s	.path
	addq.l	#1,a2
	move.l	a2,a0
	jsr	ParseDec
	move.l	a0,a2
	tst.l	d1			; "host:" means default port
	beq.s	.path
	tst.l	d0
	beq.s	.bad
	cmp.l	#65535,d0
	bhi.s	.bad
	move.l	d0,up_Port(a3)
.path:
	move.l	a2,up_Path(a3)
	move.l	a2,a0
.pl:	move.b	(a0)+,d0
	beq.s	.pend
	cmp.b	#'#',d0
	bne.s	.pl
.pend:	subq.l	#1,a0
	sub.l	a2,a0
	move.l	a0,up_PathLen(a3)
	move.b	(a2),d0			; path must start with / or ? or end
	beq.s	.ok
	cmp.b	#'#',d0
	beq.s	.ok
	cmp.b	#'/',d0
	beq.s	.ok
	cmp.b	#'?',d0
	bne.s	.bad
.ok:
.other:
	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts
.bad:
	SETERR	ERR_URL
	moveq	#0,d0
	bra.s	.x

SchHttps:	dc.b	"https://",0
SchHttp:	dc.b	"http://",0
	even

;--------------------------------------------------------------------
; HasScheme - does a string start with "scheme:"?
; In:  a0 = string
; Out: d0 = 1 if yes
;--------------------------------------------------------------------
HasScheme:
	move.l	a0,a1
	move.b	(a1)+,d0
	bsr	IsAlpha
	beq.s	.no
.l:	move.b	(a1)+,d0
	cmp.b	#':',d0
	beq.s	.yes
	bsr	IsAlpha
	bne.s	.l
	cmp.b	#'0',d0
	blo.s	.sym
	cmp.b	#'9',d0
	bls.s	.l
.sym:	cmp.b	#'+',d0
	beq.s	.l
	cmp.b	#'-',d0
	beq.s	.l
	cmp.b	#'.',d0
	beq.s	.l
.no:	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

; IsAlpha - In: d0.b; Out: Z clear if ASCII letter.  d0 preserved.
IsAlpha:
	move.b	d0,d1
	or.b	#$20,d1
	cmp.b	#'a',d1
	blo.s	.no
	cmp.b	#'z',d1
	bhi.s	.no
	moveq	#1,d1
	rts
.no:	moveq	#0,d1
	rts

;--------------------------------------------------------------------
; AuthorityEnd - find where the path starts in an absolute URL
; In:  a0 = URL with "scheme://"
; Out: a0 = first char of the path ('/', '?', '#' or NUL)
;--------------------------------------------------------------------
AuthorityEnd:
.s:	move.b	(a0)+,d0		; skip scheme and ':'
	beq.s	.back
	cmp.b	#':',d0
	bne.s	.s
	cmp.b	#'/',(a0)
	bne.s	.a
	cmp.b	#'/',1(a0)
	bne.s	.a
	addq.l	#2,a0
.a:	move.b	(a0)+,d0
	beq.s	.back
	cmp.b	#'/',d0
	beq.s	.back
	cmp.b	#'?',d0
	beq.s	.back
	cmp.b	#'#',d0
	bne.s	.a
.back:	subq.l	#1,a0
	rts

;--------------------------------------------------------------------
; UrlResolve - resolve a (possibly relative) reference against a base
; In:  a0 = base URL (absolute), a1 = reference, a2 = output buffer
;      (URL_MAX bytes)
; Out: d0 = 1 if ok, 0 if the result does not fit (g_Error = ERR_URL)
;      Leading/trailing blanks and embedded tab/CR/LF in the reference
;      are dropped.  Dot segments in the result path are removed.
;--------------------------------------------------------------------
UrlResolve:
	movem.l	d2-d3/a2-a3/a5,-(sp)
	move.l	a0,a3			; a3 = base
	move.l	a2,a5			; a5 = output start

	; clean the reference into g_UrlTmp
	move.l	a1,a0
.lead:	move.b	(a0),d0
	beq.s	.cl
	cmp.b	#' ',d0
	bhi.s	.cl
	addq.l	#1,a0
	bra.s	.lead
.cl:	lea	g_UrlTmp(a4),a1
	move.l	a1,d3			; last non-blank position + 1
	move.w	#URL_MAX-2,d2
.cll:	move.b	(a0)+,d0
	beq.s	.cle
	cmp.b	#9,d0
	beq.s	.cll
	cmp.b	#10,d0
	beq.s	.cll
	cmp.b	#13,d0
	beq.s	.cll
	move.b	d0,(a1)+
	cmp.b	#' ',d0
	bls.s	.notlast
	move.l	a1,d3
.notlast:
	dbf	d2,.cll
	bra	.toolong
.cle:	move.l	d3,a1
	clr.b	(a1)			; trailing blanks cut

	lea	g_UrlTmp(a4),a0		; a0 = reference
	bsr	HasScheme
	beq.s	.noscheme
	; absolute reference: copy it
	move.l	a5,a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bra	.dots

.noscheme:
	cmp.b	#'/',(a0)
	bne.s	.notnet
	cmp.b	#'/',1(a0)
	bne.s	.notnet
	; network-path reference "//host/path": base scheme + ':' + ref
	move.l	a3,a0
	move.l	a5,a1
.sc:	move.b	(a0)+,d0
	move.b	d0,(a1)+
	cmp.b	#':',d0
	bne.s	.sc
	lea	g_UrlTmp(a4),a0
	bra	.append

.notnet:
	; copy base up to the start of its path
	move.l	a3,a0
	bsr	AuthorityEnd
	move.l	a0,d2			; d2 = base path start
	move.l	a3,a0
	move.l	a5,a1
.cb:	cmp.l	d2,a0
	beq.s	.cbe
	move.b	(a0)+,(a1)+
	bra.s	.cb
.cbe:
	; a1 = output position, d2 = base path start
	lea	g_UrlTmp(a4),a2		; a2 = reference
	move.b	(a2),d0
	beq.s	.empty
	cmp.b	#'#',d0
	beq.s	.frag
	cmp.b	#'?',d0
	beq.s	.query
	cmp.b	#'/',d0
	beq.s	.abspath

	; relative path: base path up to its last '/', then the reference
	; (in file: URLs also up to a ':', "file:///Work:page.html")
	move.l	(a3),d1
	or.l	#$20202020,d1
	cmp.l	#'file',d1
	bne.s	.nfile
	cmp.b	#':',4(a3)
.nfile:	seq	d1			; d1.b = file: URL
	move.l	d2,a0
	move.l	a0,d3			; d3 = after last '/' (none yet)
.rp:	move.b	(a0)+,d0
	beq.s	.rpe
	cmp.b	#'?',d0
	beq.s	.rpe
	cmp.b	#'#',d0
	beq.s	.rpe
	cmp.b	#':',d0
	bne.s	.rps
	tst.b	d1
	bne.s	.rpm
.rps:	cmp.b	#'/',d0
	bne.s	.rp
.rpm:	move.l	a0,d3
	bra.s	.rp
.rpe:	move.l	d2,a0
	cmp.l	d3,a0
	bne.s	.rpc
	move.b	#'/',(a1)+		; base had no path: use "/"
	bra.s	.rpd
.rpc:	cmp.l	d3,a0
	beq.s	.rpd
	move.b	(a0)+,(a1)+
	bra.s	.rpc
.rpd:	move.l	a2,a0
	bra.s	.append

.abspath:
	move.l	a2,a0
	bra.s	.append

.query:	; base path without query, then the reference
	move.l	d2,a0
.q:	move.b	(a0),d0
	beq.s	.qe
	cmp.b	#'?',d0
	beq.s	.qe
	cmp.b	#'#',d0
	beq.s	.qe
	move.b	d0,(a1)+
	addq.l	#1,a0
	bra.s	.q
.qe:	move.l	a2,a0
	bra.s	.append

.frag:	; base without fragment, then the reference
	move.l	d2,a0
.f:	move.b	(a0),d0
	beq.s	.fe
	cmp.b	#'#',d0
	beq.s	.fe
	move.b	d0,(a1)+
	addq.l	#1,a0
	bra.s	.f
.fe:	move.l	a2,a0
	bra.s	.append

.empty:	; base without fragment
	move.l	d2,a0
	lea	g_UrlTmp(a4),a2
	bra.s	.f

.append:
	; append string a0 at a1, checking the length
	move.l	a1,d0
	sub.l	a5,d0			; used so far
	move.l	#URL_MAX-1,d1
	sub.l	d0,d1			; room left
	bmi.s	.toolong
.ap:	move.b	(a0)+,(a1)+
	beq.s	.dots
	subq.l	#1,d1
	bpl.s	.ap
	bra.s	.toolong

.dots:
	; remove dot segments from the path of the result (in a5)
	move.l	a5,a0
	bsr	HasScheme
	beq.s	.ok
	move.l	a5,a0
	bsr	AuthorityEnd
	cmp.b	#'/',(a0)
	bne.s	.ok
	bsr	RemoveDots
.ok:	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3/a5
	rts
.toolong:
	clr.b	(a5)
	SETERR	ERR_URL
	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; RemoveDots - remove "." and ".." segments from a path, in place
; In:  a0 = path, starting with '/'; ends at '?', '#' or NUL.
;      The rest of the string (query, fragment) is kept.
;--------------------------------------------------------------------
RemoveDots:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a1			; a1 = write position
	move.l	a0,a2			; a2 = start (for popping)
.seg:	; a0 is at a '/'
	lea	1(a0),a3		; a3 = segment start
	move.l	a3,a0
.se:	move.b	(a0),d0
	beq.s	.send
	cmp.b	#'/',d0
	beq.s	.send
	cmp.b	#'?',d0
	beq.s	.send
	cmp.b	#'#',d0
	beq.s	.send
	addq.l	#1,a0
	bra.s	.se
.send:	; a0 = segment end, d0 = char there
	move.l	a0,d2
	sub.l	a3,d2			; d2 = segment length
	cmp.l	#1,d2
	bne.s	.not1
	cmp.b	#'.',(a3)
	bne.s	.copy
	bra.s	.slashifend
.not1:	cmp.l	#2,d2
	bne.s	.copy
	cmp.b	#'.',(a3)
	bne.s	.copy
	cmp.b	#'.',1(a3)
	bne.s	.copy
	; ".." - drop the last output segment
.pop:	cmp.l	a2,a1
	beq.s	.slashifend
	cmp.b	#'/',-(a1)
	bne.s	.pop
.slashifend:
	cmp.b	#'/',d0
	beq.s	.next
	move.b	#'/',(a1)+		; "." or ".." at the end keeps a '/'
	bra.s	.rest
.copy:	move.b	#'/',(a1)+
.cp:	cmp.l	a0,a3
	beq.s	.next
	move.b	(a3)+,(a1)+
	bra.s	.cp
.next:	cmp.b	#'/',(a0)
	beq.s	.seg
.rest:	; copy query/fragment and the NUL
.r:	move.b	(a0)+,(a1)+
	bne.s	.r
	movem.l	(sp)+,d2/a2-a3
	rts

;--------------------------------------------------------------------
; UrlFixup - turn user input into a URL: trims blanks and adds
; "http://" when no scheme is given.
; In:  a0 = input, a1 = output buffer (URL_MAX)
;--------------------------------------------------------------------
UrlFixup:
	movem.l	a2-a3,-(sp)
	move.l	a1,a3
.lead:	move.b	(a0),d0
	beq.s	.go
	cmp.b	#' ',d0
	bhi.s	.go
	addq.l	#1,a0
	bra.s	.lead
.go:	move.l	a0,a2
	bsr	HasScheme
	beq.s	.add
	; "host:port/..." looks like a scheme; treat digits after ':' as port
	move.l	a2,a0
.c:	cmp.b	#':',(a0)+
	bne.s	.c
	move.b	(a0),d0
	cmp.b	#'0',d0
	blo.s	.copy
	cmp.b	#'9',d0
	bhi.s	.copy
.add:	lea	SchHttp(pc),a0
	move.l	a3,a1
	jsr	StrCopy
	move.l	a2,a0
	move.l	#URL_MAX-8,d0
	jsr	StrCopyN
	bra.s	.trim
.copy:	move.l	a2,a0
	move.l	a3,a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
.trim:	; cut trailing blanks
.t:	cmp.l	a3,a1
	beq.s	.x
	cmp.b	#' ',-1(a1)
	bhi.s	.x
	clr.b	-(a1)
	bra.s	.t
.x:	movem.l	(sp)+,a2-a3
	rts
