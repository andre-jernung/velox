;
; http.s - HTTP/1.1 client: request building, response parsing,
;          chunked transfer coding, redirects
;
; Results go to g_Resp.  One request per connection ("Connection:
; close") keeps the state machine simple.
;

	include	"velox.i"

	xdef	HttpGet,HttpReadResponse
	xref	UrlParse,UrlResolve
	xref	ConnOpen,ConnClose,ConnWrite,ConnRead,ConnReadLine
	xref	BufAppend,BufAppendByte,BufAppendStr,BufClear,BufReserve
	xref	StrCopyN,StrIPrefix,StrIFind,SkipSpace,ParseDec,ParseHex,FmtDec

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
	bsr	StrCopyN
	moveq	#0,d3			; redirects followed
.again:
	lea	r_Url(a3),a0
	lea	g_Parts(a4),a1
	bsr	UrlParse
	beq	.fail
	move.l	g_Parts+up_Scheme(a4),d1
	bmi	.badscheme
	lea	g_Parts+up_Host(a4),a0
	move.l	g_Parts+up_Port(a4),d0
	bsr	ConnOpen
	beq	.fail
	move.l	d0,a2
	bsr	BuildRequest
	beq.s	.failclose
	move.l	a2,a0
	move.l	g_ReqBuf+buf_Data(a4),a1
	move.l	g_ReqBuf+buf_Len(a4),d0
	bsr	ConnWrite
	beq.s	.failclose
	move.l	a2,a0
	bsr	HttpReadResponse
	move.l	d0,d2
	move.l	a2,a0
	bsr	ConnClose
	tst.l	d2
	beq.s	.fail

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
	bsr	UrlResolve
	beq.s	.fail
	lea	g_UrlTmp2(a4),a0
	lea	r_Url(a3),a1
	move.l	#URL_MAX-1,d0
	bsr	StrCopyN
	bra	.again

.done:	move.l	d2,d0
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
.failclose:
	move.l	a2,a0
	bsr	ConnClose
.fail:	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; BuildRequest - build the GET request for g_Parts in g_ReqBuf
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
REQSTR	MACRO
	lea	g_ReqBuf(a4),a0
	lea	\1(pc),a1
	bsr	BufAppendStr
	beq	ReqNoMem
	ENDM

BuildRequest:
	movem.l	d2-d3/a2,-(sp)
	lea	g_ReqBuf(a4),a0
	bsr	BufClear
	tst.l	g_PostData(a4)
	beq.s	.get
	REQSTR	RqPost
	bra.s	.meth
.get:	REQSTR	RqGet
.meth:

	; path: escape blanks, controls and 8-bit characters
	move.l	g_Parts+up_Path(a4),a2
	move.l	g_Parts+up_PathLen(a4),d2
	beq.s	.slash
	cmp.b	#'?',(a2)
	bne.s	.path
.slash:	lea	g_ReqBuf(a4),a0
	moveq	#'/',d0
	bsr	BufAppendByte
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
	bsr	BufAppendByte
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
	bsr	BufAppend
	lea	4(sp),sp
	tst.l	d0
	beq	ReqNoMem
	bra.s	.path
.pathend:
	REQSTR	RqHost
	lea	g_ReqBuf(a4),a0
	lea	g_Parts+up_Host(a4),a1
	bsr	BufAppendStr
	beq	ReqNoMem
	; ":port" unless it is the scheme's default
	move.l	g_Parts+up_Port(a4),d0
	moveq	#80,d1
	tst.l	g_Parts+up_Scheme(a4)
	beq.s	.def
	move.l	#443,d1
.def:	cmp.l	d1,d0
	beq.s	.noport
	lea	-16(sp),sp
	move.l	sp,a0
	move.b	#':',(a0)+
	bsr	FmtDec
	lea	g_ReqBuf(a4),a0
	move.l	sp,a1
	bsr	BufAppendStr
	lea	16(sp),sp
	tst.l	d0
	beq.s	ReqNoMem
.noport:
	tst.l	g_PostData(a4)
	beq.s	.nopost
	REQSTR	RqPostHdr
	lea	-16(sp),sp
	move.l	g_PostLen(a4),d0
	move.l	sp,a0
	bsr	FmtDec
	lea	g_ReqBuf(a4),a0
	move.l	sp,a1
	bsr	BufAppendStr
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
	bsr	BufAppend
	beq	ReqNoMem
.done:	moveq	#1,d0
	movem.l	(sp)+,d2-d3/a2
	rts
ReqNoMem:
	SETERR	ERR_NOMEM
	moveq	#0,d0
	movem.l	(sp)+,d2-d3/a2
	rts

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
		dc.b	"Connection: close",13,10,13,10,0
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
	bsr	BufClear
.status:
	clr.l	r_Status(a3)
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
	bsr	StrIPrefix
	beq	.proto
.ver:	move.b	(a0)+,d0
	beq	.proto
	cmp.b	#' ',d0
	bne.s	.ver
	bsr	SkipSpace
	bsr	ParseDec
	cmp.l	#3,d1
	bne	.proto
	move.l	d0,r_Status(a3)

.hdr:	bsr	ReadHdrLine
	bmi	.proto
	beq.s	.endhdr
	lea	g_Line(a4),a0
	lea	HContentLength(pc),a1
	bsr	StrIPrefix
	beq.s	.h2
	bsr	SkipSpace
	bsr	ParseDec
	tst.l	d1
	beq.s	.hdr
	move.l	d0,r_Length(a3)
	bra.s	.hdr
.h2:	lea	HTransferEncoding(pc),a1
	bsr	StrIPrefix
	beq.s	.h3
	lea	HChunked(pc),a1
	bsr	StrIFind
	beq.s	.hdr
	moveq	#1,d0
	move.l	d0,r_Chunked(a3)
	bra.s	.hdr
.h3:	lea	HLocation(pc),a1
	bsr	StrIPrefix
	beq.s	.h4
	bsr	SkipSpace
	lea	r_Location(a3),a1
	move.l	#URL_MAX-1,d0
	bsr	StrCopyN
	bra.s	.hdr
.h4:	lea	HContentType(pc),a1
	bsr	StrIPrefix
	beq.s	.hdr
	bsr	SkipSpace
	lea	r_CType(a3),a1
	moveq	#63,d0
	bsr	StrCopyN
	bra.s	.hdr

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
	bra.s	.done

.chunked:
	bsr	ReadHdrLine		; chunk size line
	bmi.s	.done			; truncated: keep what we have
	beq.s	.chunked		; CRLF after previous chunk
	lea	g_Line(a4),a0
	bsr	ParseHex
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

.done:	move.l	r_Status(a3),d0
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
	bsr	ConnReadLine
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
	bsr	BufReserve
	beq.s	.err
	move.l	a2,a0
	move.l	r_Body+buf_Data(a3),a1
	add.l	r_Body+buf_Len(a3),a1
	move.l	d3,d0
	bsr	ConnRead
	tst.l	d0
	bmi.s	.err
	beq.s	.ok			; end of stream
	add.l	d0,r_Body+buf_Len(a3)
	sub.l	d0,d2
	move.l	r_Body+buf_Data(a3),a0
	add.l	r_Body+buf_Len(a3),a0
	clr.b	(a0)
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
	even
