;
; http.s - HTTP/1.1 client: request building, response parsing,
;          chunked transfer coding, redirects
;
; Results go to g_Resp.  One request per connection ("Connection:
; close") keeps the state machine simple.
;

	include	"velox.i"

	xdef	HttpGet,HttpReadResponse,HttpCloseKept
	xref	CacheStore
	xref	UrlParse,UrlResolve
	xref	ConnOpen,ConnClose,ConnWrite,ConnRead,ConnReadLine
	xref	BufAppend,BufAppendByte,BufAppendStr,BufClear,BufReserve
	xref	StrCopyN,StrIPrefix,StrIFind,SkipSpace,ParseDec,ParseHex,FmtDec
	xref	CookieSet,CookieHeader

	section	code,code

;--------------------------------------------------------------------
; HttpGet - fetch a URL, following redirects
; In:  a0 = absolute URL
; Out: d0 = HTTP status, or 0 on failure (g_Error set)
;      g_Resp holds the response; r_Url is the final URL.
;--------------------------------------------------------------------
HttpGet:
	movem.l	d2-d3/a2-a3,-(sp)
	lea	g_Resp(a4),a3
	lea	r_Url(a3),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	moveq	#0,d3			; redirects followed
.again:
	lea	r_Url(a3),a0
	lea	g_Parts(a4),a1
	jsr	UrlParse
	beq	.fail
	move.l	g_Parts+up_Scheme(a4),d1
	bmi	.badscheme
	bsr	Exchange		; d0 = status or 0
	move.l	d0,d2
	beq	.fail

	; redirect?
	tst.b	r_Location(a3)
	beq.s	.done
	cmp.l	#301,d2
	blo.s	.done
	cmp.l	#303,d2
	bls.s	.redir
	cmp.l	#307,d2
	blo.s	.done
	cmp.l	#308,d2
	bhi.s	.done
.redir:	cmp.l	#307,d2			; 301-303: the next request is a GET
	bhs.s	.keep
	clr.l	g_PostData(a4)
.keep:	addq.l	#1,d3
	cmp.l	#MAX_REDIRECTS,d3
	bhi.s	.toomany
	lea	r_Url(a3),a0
	lea	r_Location(a3),a1
	lea	g_UrlTmp2(a4),a2
	jsr	UrlResolve
	beq.s	.fail
	lea	g_UrlTmp2(a4),a0
	lea	r_Url(a3),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bra	.again

.done:	cmp.l	#200,d2			; keep GET responses for later
	bne.s	.nost
	tst.l	g_PostData(a4)
	bne.s	.nost
	jsr	CacheStore
.nost:	move.l	d2,d0
.x:	clr.l	g_PostData(a4)		; a POST body is used once
	tst.l	d0			; (the clr changed the flags)
	movem.l	(sp)+,d2-d3/a2-a3
	rts
.badscheme:
	SETERR	ERR_URL
	bra.s	.fail
.toomany:
	SETERR	ERR_REDIRECTS
	bra.s	.fail
.fail:	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; Exchange - send the request for g_Parts and read the response, on a
; kept-alive connection to the same server if there is one.  A kept
; connection the server has closed in the meantime is retried once on
; a new connection.
; Out: d0 = HTTP status or 0 (g_Error set)
;--------------------------------------------------------------------
Exchange:
	movem.l	d2-d6/a2,-(sp)
	moveq	#0,d4			; attempt
.try:	; the server we talk to: the proxy, or the URL's host
	move.l	g_ProxyPort(a4),d5
	beq.s	.direct
	lea	g_ProxyHost(a4),a0
	moveq	#0,d6			; (plain HTTP to the proxy)
	bra.s	.tgt
.direct:
	lea	g_Parts+up_Host(a4),a0
	move.l	g_Parts+up_Port(a4),d5
	move.l	g_Parts+up_Scheme(a4),d6
.tgt:	; the kept connection, if it goes there
	moveq	#0,d3			; reused?
	move.l	g_KeepConn(a4),d0
	beq.s	.new
	clr.l	g_KeepConn(a4)
	move.l	d0,a2
	tst.l	d4
	bne.s	.drop
	cmp.l	g_KeepPort(a4),d5
	bne.s	.drop
	cmp.l	g_KeepTls(a4),d6
	bne.s	.drop
	move.l	a0,-(sp)
	lea	g_KeepHost(a4),a1
.hc:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.hne
	tst.b	d0
	bne.s	.hc
	move.l	(sp)+,a0
	moveq	#1,d3
	bra.s	.send
.hne:	move.l	(sp)+,a0
.drop:	move.l	a0,-(sp)		; another server: close it
	move.l	a2,a0
	jsr	ConnClose
	move.l	(sp)+,a0
.new:	move.l	a0,-(sp)		; remember the target for keeping
	lea	g_KeepHost(a4),a1
	move.l	#HOST_MAX-1,d0
	jsr	StrCopyN
	move.l	(sp)+,a0
	move.l	d5,d0
	move.l	d6,d1
	jsr	ConnOpen
	beq	.fail
	move.l	d0,a2
.send:	bsr	BuildRequest
	beq.s	.failclose
	move.l	a2,a0
	move.l	g_ReqBuf+buf_Data(a4),a1
	move.l	g_ReqBuf+buf_Len(a4),d0
	jsr	ConnWrite
	beq.s	.retry
	move.l	a2,a0
	bsr	HttpReadResponse
	move.l	d0,d2
	beq.s	.retry
	tst.l	g_Resp+r_Reuse(a4)	; keep it for the next request?
	beq.s	.close
	move.l	a2,g_KeepConn(a4)
	move.l	d5,g_KeepPort(a4)
	move.l	d6,g_KeepTls(a4)
	bra.s	.ok
.close:	move.l	a2,a0
	jsr	ConnClose
.ok:	move.l	d2,d0
.x:	movem.l	(sp)+,d2-d6/a2
	rts
.retry:	; a reused connection that failed: once more on a new one
	move.l	a2,a0
	jsr	ConnClose
	tst.l	d3
	beq.s	.fail
	cmp.l	#ERR_ABORT,g_Error(a4)
	beq.s	.fail
	moveq	#1,d4
	bra	.try
.failclose:
	move.l	a2,a0
	jsr	ConnClose
.fail:	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; HttpCloseKept - close the kept-alive connection (before the socket
; library goes)
;--------------------------------------------------------------------
HttpCloseKept:
	move.l	g_KeepConn(a4),d0
	beq.s	.x
	clr.l	g_KeepConn(a4)
	move.l	d0,a0
	jmp	ConnClose
.x:	rts

;--------------------------------------------------------------------
; BuildRequest - build the GET request for g_Parts in g_ReqBuf
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
REQSTR	MACRO
	lea	g_ReqBuf(a4),a0
	lea	\1(pc),a1
	jsr	BufAppendStr
	beq	ReqNoMem
	ENDM

BuildRequest:
	movem.l	d2-d3/a2,-(sp)
	lea	g_ReqBuf(a4),a0
	jsr	BufClear
	tst.l	g_PostData(a4)
	beq.s	.get
	REQSTR	RqPost
	bra.s	.meth
.get:	REQSTR	RqGet
.meth:	tst.l	g_ProxyPort(a4)		; proxies get the absolute URL
	beq.s	.origin
	lea	SchHttpP(pc),a1
	tst.l	g_Parts+up_Scheme(a4)
	beq.s	.sch
	lea	SchHttpsP(pc),a1
.sch:	lea	g_ReqBuf(a4),a0
	jsr	BufAppendStr
	beq	ReqNoMem
	bsr	AppendHostPort
	beq	ReqNoMem
.origin:
	; path: escape blanks, controls and 8-bit characters
	move.l	g_Parts+up_Path(a4),a2
	move.l	g_Parts+up_PathLen(a4),d2
	beq.s	.slash
	cmp.b	#'?',(a2)
	bne.s	.path
.slash:	lea	g_ReqBuf(a4),a0
	moveq	#'/',d0
	jsr	BufAppendByte
	beq	ReqNoMem
.path:	subq.l	#1,d2
	bmi.s	.pathend
	moveq	#0,d3
	move.b	(a2)+,d3
	cmp.b	#' ',d3
	bls.s	.esc
	cmp.b	#127,d3
	bhs.s	.esc
	lea	g_ReqBuf(a4),a0
	move.l	d3,d0
	jsr	BufAppendByte
	beq	ReqNoMem
	bra.s	.path
.esc:	lea	-4(sp),sp
	move.l	sp,a1
	move.b	#'%',(a1)
	lea	HexDigits(pc),a0
	move.l	d3,d0
	lsr.b	#4,d0
	move.b	(a0,d0.w),1(a1)
	and.w	#15,d3
	move.b	(a0,d3.w),2(a1)
	lea	g_ReqBuf(a4),a0
	moveq	#3,d0
	jsr	BufAppend
	lea	4(sp),sp
	tst.l	d0
	beq	ReqNoMem
	bra.s	.path
.pathend:
	REQSTR	RqHost
	bsr	AppendHostPort
	beq	ReqNoMem
	lea	g_ReqBuf(a4),a0
	jsr	CookieHeader
	beq	ReqNoMem
	tst.l	g_PostData(a4)
	beq.s	.nopost
	REQSTR	RqPostHdr
	lea	-16(sp),sp
	move.l	g_PostLen(a4),d0
	move.l	sp,a0
	jsr	FmtDec
	lea	g_ReqBuf(a4),a0
	move.l	sp,a1
	jsr	BufAppendStr
	lea	16(sp),sp
	tst.l	d0
	beq	ReqNoMem
.nopost:
	REQSTR	RqTail
	move.l	g_PostData(a4),d0	; the body follows the headers
	beq.s	.done
	lea	g_ReqBuf(a4),a0
	move.l	d0,a1
	move.l	g_PostLen(a4),d0
	jsr	BufAppend
	beq	ReqNoMem
.done:	moveq	#1,d0
	movem.l	(sp)+,d2-d3/a2
	rts
ReqNoMem:
	SETERR	ERR_NOMEM
	moveq	#0,d0
	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; AppendHostPort - append "host" or "host:port" (when not the default
; port of the scheme) of g_Parts to the request
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
AppendHostPort:
	lea	g_ReqBuf(a4),a0
	lea	g_Parts+up_Host(a4),a1
	jsr	BufAppendStr
	beq.s	.x
	move.l	g_Parts+up_Port(a4),d0
	moveq	#80,d1
	tst.l	g_Parts+up_Scheme(a4)
	beq.s	.def
	move.l	#443,d1
.def:	cmp.l	d1,d0
	beq.s	.ok
	lea	-16(sp),sp
	move.l	sp,a0
	move.b	#':',(a0)+
	jsr	FmtDec
	lea	g_ReqBuf(a4),a0
	move.l	sp,a1
	jsr	BufAppendStr
	lea	16(sp),sp
	tst.l	d0
	rts
.ok:	moveq	#1,d0
.x:	rts

SchHttpP:	dc.b	"http://",0
SchHttpsP:	dc.b	"https://",0
HexDigits:	dc.b	"0123456789ABCDEF"
RqGet:		dc.b	"GET ",0
RqPost:		dc.b	"POST ",0
RqPostHdr:	dc.b	13,10,"Content-Type: application/x-www-form-urlencoded"
		dc.b	13,10,"Content-Length: ",0
RqHost:		dc.b	" HTTP/1.1",13,10,"Host: ",0
RqTail:		dc.b	13,10
		dc.b	"User-Agent: Velox/"
		VERSION_STR
		dc.b	" (AmigaOS; 68k)",13,10
		dc.b	"Accept: text/html,text/plain;q=0.9,*/*;q=0.5",13,10
		dc.b	"Accept-Encoding: identity",13,10
		dc.b	"Connection: keep-alive",13,10,13,10,0
	even

;--------------------------------------------------------------------
; HttpReadResponse - read status line, headers and body into g_Resp
; In:  a0 = Conn
; Out: d0 = HTTP status, or 0 on failure (g_Error set)
;--------------------------------------------------------------------
HttpReadResponse:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	lea	g_Resp(a4),a3
	lea	r_Body(a3),a0
	jsr	BufClear
.status:
	clr.l	r_Status(a3)
	clr.l	r_Reuse(a3)
	clr.l	r_ConnHdr(a3)
	moveq	#-1,d0
	move.l	d0,r_Length(a3)
	clr.l	r_Chunked(a3)
	clr.b	r_CType(a3)
	clr.b	r_Location(a3)
.sl:	bsr	ReadHdrLine
	bmi	.proto
	beq.s	.sl			; tolerate blank lines before it
	lea	g_Line(a4),a0
	lea	HHttp(pc),a1
	jsr	StrIPrefix
	beq	.proto
	moveq	#1,d0			; HTTP/1.1 keeps the connection by
	cmp.b	#'1',(a0)		; default, HTTP/1.0 does not
	bne.s	.v10
	cmp.b	#'0',2(a0)
	bne.s	.v11
.v10:	moveq	#-1,d0
.v11:	move.l	d0,r_ConnHdr(a3)
.ver:	move.b	(a0)+,d0
	beq	.proto
	cmp.b	#' ',d0
	bne.s	.ver
	jsr	SkipSpace
	jsr	ParseDec
	cmp.l	#3,d1
	bne	.proto
	move.l	d0,r_Status(a3)

.hdr:	bsr	ReadHdrLine
	bmi	.proto
	beq.s	.endhdr
	lea	g_Line(a4),a0
	lea	HContentLength(pc),a1
	jsr	StrIPrefix
	beq.s	.h2
	jsr	SkipSpace
	jsr	ParseDec
	tst.l	d1
	beq.s	.hdr
	move.l	d0,r_Length(a3)
	bra.s	.hdr
.h2:	lea	HTransferEncoding(pc),a1
	jsr	StrIPrefix
	beq.s	.h3
	lea	HChunked(pc),a1
	jsr	StrIFind
	beq.s	.hdr
	moveq	#1,d0
	move.l	d0,r_Chunked(a3)
	bra.s	.hdr
.h3:	lea	HLocation(pc),a1
	jsr	StrIPrefix
	beq.s	.h4
	jsr	SkipSpace
	lea	r_Location(a3),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bra.s	.hdr
.h4:	lea	HContentType(pc),a1
	jsr	StrIPrefix
	beq.s	.h5
	jsr	SkipSpace
	lea	r_CType(a3),a1
	moveq	#63,d0
	jsr	StrCopyN
	bra	.hdr
.h5:	lea	HSetCookie(pc),a1
	jsr	StrIPrefix
	beq	.h6
	jsr	CookieSet
	bra	.hdr
.h6:	lea	HConnection(pc),a1	; Connection: close / keep-alive
	jsr	StrIPrefix
	beq	.hdr
	move.l	a0,-(sp)
	lea	HClose(pc),a1
	jsr	StrIFind
	movem.l	(sp)+,a0
	tst.l	d0
	beq.s	.nclose
	moveq	#-1,d0
	move.l	d0,r_ConnHdr(a3)
	bra	.hdr
.nclose:
	lea	HKeepAlive(pc),a1
	jsr	StrIFind
	beq	.hdr
	moveq	#1,d0
	move.l	d0,r_ConnHdr(a3)
	bra	.hdr

.endhdr:
	move.l	r_Status(a3),d0
	cmp.l	#200,d0
	blo	.status			; 1xx: another status line follows
	cmp.l	#204,d0
	beq.s	.done
	cmp.l	#304,d0
	beq.s	.done
	tst.l	r_Chunked(a3)
	bne.s	.chunked
	move.l	r_Length(a3),d0
	bmi.s	.toeof
	bsr	ReadBody
	bmi.s	.fail
	bra.s	.done
.toeof:	move.l	#$7fffffff,d0
	bsr	ReadBody
	bmi.s	.fail
	move.l	#-1,r_ConnHdr(a3)	; ended by closing: not reusable
	bra.s	.done

.chunked:
	bsr	ReadHdrLine		; chunk size line
	bmi.s	.done			; truncated: keep what we have
	beq.s	.chunked		; CRLF after previous chunk
	lea	g_Line(a4),a0
	jsr	ParseHex
	tst.l	d1
	beq.s	.proto
	tst.l	d0
	beq.s	.trailer
	bsr	ReadBody
	bmi.s	.fail
	bra.s	.chunked
.trailer:
	bsr	ReadHdrLine
	bgt.s	.trailer

.done:	tst.l	r_ConnHdr(a3)		; reusable when not closing
	bmi.s	.noreuse
	moveq	#1,d0
	move.l	d0,r_Reuse(a3)
.noreuse:
	move.l	r_Status(a3),d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts
.proto:	SETERR	ERR_PROTOCOL
.fail:	moveq	#0,d0
	bra.s	.x

; ReadHdrLine - (a2 = Conn) read a line into g_Line, trailing blanks
; removed
; Out: d0 = length or -1, CCR set
ReadHdrLine:
	move.l	a2,a0
	lea	g_Line(a4),a1
	move.l	#LINE_MAX,d0
	jsr	ConnReadLine
	tst.l	d0
	ble.s	.x
	lea	g_Line(a4),a0
	add.l	d0,a0
.trim:	move.b	-(a0),d1
	cmp.b	#' ',d1
	beq.s	.cut
	cmp.b	#9,d1
	bne.s	.done
.cut:	clr.b	(a0)
	subq.l	#1,d0
	bne.s	.trim
.done:	tst.l	d0
.x:	rts

; ReadBody - (a2 = Conn, a3 = Resp) append up to d0 bytes to the body,
; stopping early at end of stream.
; Out: d0 = 0 ok, -1 on error (CCR set)
ReadBody:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2			; bytes left
.l:	tst.l	d2
	beq.s	.ok
	move.l	#16384,d3
	cmp.l	d2,d3
	bls.s	.n
	move.l	d2,d3
.n:	lea	r_Body(a3),a0
	move.l	d3,d0
	jsr	BufReserve
	beq.s	.err
	move.l	a2,a0
	move.l	r_Body+buf_Data(a3),a1
	add.l	r_Body+buf_Len(a3),a1
	move.l	d3,d0
	jsr	ConnRead
	tst.l	d0
	bmi.s	.err
	beq.s	.ok			; end of stream
	add.l	d0,r_Body+buf_Len(a3)
	sub.l	d0,d2
	move.l	r_Body+buf_Data(a3),a0
	add.l	r_Body+buf_Len(a3),a0
	clr.b	(a0)
	move.l	g_ProgressHook(a4),d0	; progress (status line)
	beq.s	.l
	move.l	d0,a0
	move.l	r_Body+buf_Len(a3),d0
	move.l	r_Length(a3),d1
	jsr	(a0)
	bra.s	.l
.ok:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3
	rts
.err:	moveq	#-1,d0
	bra.s	.x

HHttp:			dc.b	"http/",0
HContentLength:		dc.b	"content-length:",0
HTransferEncoding:	dc.b	"transfer-encoding:",0
HChunked:		dc.b	"chunked",0
HLocation:		dc.b	"location:",0
HContentType:		dc.b	"content-type:",0
HSetCookie:		dc.b	"set-cookie:",0
HConnection:		dc.b	"connection:",0
HClose:			dc.b	"close",0
HKeepAlive:		dc.b	"keep-alive",0
	even
