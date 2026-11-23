;
; conn.s - buffered byte streams over TCP (bsdsocket.library), TLS
;          (later) or a DOS file (for offline tests)
;
; All waits on the network go through WaitSelect() together with
; g_AbortMask, so the user can interrupt a transfer.  When one of those
; signals arrives, g_NetSigHook (if set) decides whether to abort.
;

	include	"velox.i"

	xdef	NetExit,ConnOpen,ConnOpenFile,ConnClose,TlsExit
	xdef	ConnWrite,ConnRead,ConnGetByte,ConnReadLine
	xref	Alloc,Free

AmiSSL_SocketBase	equ	TAG_USER+$01
AmiSSL_ErrNoPtr		equ	TAG_USER+$0b
AmiSSL_UsesOpenSSLStructs equ	TAG_USER+$0c
AmiSSL_GetAmiSSLBase	equ	TAG_USER+$0d
AmiSSL_GetAmiSSLExtBase	equ	TAG_USER+$0e

AF_INET		equ	2
SOCK_STREAM	equ	1
INADDR_NONE	equ	-1

	section	code,code

;--------------------------------------------------------------------
; NetOpen - open bsdsocket.library if not yet open
; Out: d0 = 0 on failure (g_Error = ERR_NOTCP)
;--------------------------------------------------------------------
NetOpen:
	move.l	g_SocketBase(a4),d0
	bne.s	.x
	lea	SockName(pc),a1
	moveq	#4,d0
	EXEC	OpenLibrary
	move.l	d0,g_SocketBase(a4)
	bne.s	.x
	SETERR	ERR_NOTCP
	moveq	#0,d0
.x:	rts

SockName:	dc.b	"bsdsocket.library",0
	even

	section	data,data
TlsTags:
	dc.l	AmiSSL_UsesOpenSSLStructs,0
TlsTagBase:	dc.l	AmiSSL_GetAmiSSLBase,0
TlsTagSock:	dc.l	AmiSSL_SocketBase,0
TlsTagErrno:	dc.l	AmiSSL_ErrNoPtr,0
TlsTagExt:	dc.l	AmiSSL_GetAmiSSLExtBase,0
	dc.l	TAG_DONE
	section	code,code

;--------------------------------------------------------------------
; NetExit - close bsdsocket.library
;--------------------------------------------------------------------
NetExit:
	bsr	TlsExit			; AmiSSL uses the socket library
	move.l	g_SocketBase(a4),d0
	beq.s	.x
	clr.l	g_SocketBase(a4)
	move.l	d0,a1
	EXEC	CloseLibrary
.x:	rts

;--------------------------------------------------------------------
; ConnOpen - connect to host:port
; In:  a0 = host name or dotted IP, d0 = port, d1 = 1 for TLS
; Out: d0 = Conn or 0 (g_Error set)
;--------------------------------------------------------------------
ConnOpen:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	move.l	d1,-(sp)		; TLS wanted?
	bsr	NetOpen
	beq	.fail1
	tst.l	(sp)
	beq.s	.plain
	bsr	TlsInit			; AmiSSL needs the socket library
	beq	.fail1
.plain:

	; resolve: dotted quad first, then DNS
	move.l	a2,a0
	SOCK	inet_addr
	move.l	d0,d3
	cmp.l	#INADDR_NONE,d3
	bne.s	.addr
	move.l	a2,a0
	SOCK	gethostbyname
	tst.l	d0
	beq.s	.noresolve
	move.l	d0,a0
	move.l	16(a0),a0		; h_addr_list
	move.l	(a0),d0			; first address
	beq.s	.noresolve
	move.l	d0,a0
	move.l	(a0),d3
.addr:
	lea	g_SockAddr(a4),a0	; struct sockaddr_in
	clr.l	8(a0)
	clr.l	12(a0)
	move.b	#16,(a0)		; sin_len
	move.b	#AF_INET,1(a0)		; sin_family
	move.w	d2,2(a0)		; sin_port
	move.l	d3,4(a0)		; sin_addr

	move.l	#CONN_SIZEOF,d0
	bsr	Alloc
	beq	.fail1
	move.l	d0,a3
	moveq	#-1,d0
	move.l	d0,c_Sock(a3)

	moveq	#AF_INET,d0
	moveq	#SOCK_STREAM,d1
	moveq	#0,d2
	SOCK	socket
	move.l	d0,c_Sock(a3)
	bmi.s	.noconnect

	lea	g_SockAddr(a4),a0
	move.l	c_Sock(a3),d0
	moveq	#16,d1
	SOCK	connect
	tst.l	d0
	bmi.s	.noconnect
	tst.l	(sp)
	beq.s	.ok
	move.l	a2,g_TlsHost(a4)
	move.l	a3,a0
	bsr	TlsHandshake
	beq.s	.failclose
.ok:	move.l	a3,d0
.x:	addq.l	#4,sp
	movem.l	(sp)+,d2-d3/a2-a3
	rts
.noresolve:
	SETERR	ERR_RESOLVE
	bra.s	.fail1
.noconnect:
	SETERR	ERR_CONNECT
.failclose:
	move.l	a3,a0
	bsr	ConnClose
.fail1:	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; TlsInit - open AmiSSL and create the SSL context (once)
; Out: d0 = 0 if TLS is not available (g_Error set)
;--------------------------------------------------------------------
TlsInit:
	move.l	g_SslState(a4),d0
	bgt.s	.ok
	bmi	.none
	movem.l	d2-d3/a2,-(sp)
	moveq	#-1,d0			; until proven otherwise
	move.l	d0,g_SslState(a4)
	lea	MasterName(pc),a1
	moveq	#5,d0
	EXEC	OpenLibrary
	move.l	d0,g_AmiSSLMasterBase(a4)
	beq.s	.fail
	lea	g_AmiSSLBase(a4),a0	; OpenAmiSSLTagList(API, tags)
	move.l	a0,TlsTagBase+4
	move.l	g_SocketBase(a4),TlsTagSock+4
	lea	g_Errno(a4),a0
	move.l	a0,TlsTagErrno+4
	lea	g_AmiSSLExtBase(a4),a0
	move.l	a0,TlsTagExt+4
	move.l	#AMISSL_API,d0
	lea	TlsTags,a0
	move.l	g_AmiSSLMasterBase(a4),a6
	jsr	_LVOOpenAmiSSLTagList(a6)
	tst.l	d0
	bne.s	.fail
	tst.l	g_AmiSSLBase(a4)
	beq.s	.fail
	SSL	TLS_client_method
	move.l	d0,a0
	SSL	SSL_CTX_new
	move.l	d0,g_SslCtx(a4)
	beq.s	.fail
	move.l	d0,a0
	SSL	SSL_CTX_set_default_verify_paths
	move.l	g_SslCtx(a4),a0		; verify the server's certificate
	moveq	#1,d0			; SSL_VERIFY_PEER
	tst.l	g_Insecure(a4)
	beq.s	.v
	moveq	#0,d0			; SSL_VERIFY_NONE (tests only)
.v:	suba.l	a1,a1
	SSL	SSL_CTX_set_verify
	move.l	g_SslCtx(a4),a0		; cheap key exchanges only: the
	moveq	#92,d0			; post-quantum hybrid default takes
	moveq	#0,d1			; far too long on a 68020
	lea	TlsGroups(pc),a1	; (SSL_CTRL_SET_GROUPS_LIST)
	SSL	SSL_CTX_ctrl
	moveq	#1,d0
	move.l	d0,g_SslState(a4)
	movem.l	(sp)+,d2-d3/a2
.ok:	moveq	#1,d0
	rts
.fail:	movem.l	(sp)+,d2-d3/a2
	bsr	TlsExit
	moveq	#-1,d0
	move.l	d0,g_SslState(a4)
.none:	SETERR	ERR_NOAMISSL
	moveq	#0,d0
	rts

AMISSL_API	equ	47		; AMISSL_V41x: AmiSSL 6
MasterName:	dc.b	"amisslmaster.library",0
TlsGroups:	dc.b	"X25519:P-256",0
DbgW:		dc.b	"SSL_write error ",0
	even

;--------------------------------------------------------------------
; TlsExit - free the context and close AmiSSL
;--------------------------------------------------------------------
TlsExit:
	move.l	g_SslCtx(a4),d0
	beq.s	.noctx
	clr.l	g_SslCtx(a4)
	move.l	d0,a0
	SSL	SSL_CTX_free
	SSL	OPENSSL_thread_stop	; per task OpenSSL state
.noctx:	move.l	g_AmiSSLMasterBase(a4),d0
	beq.s	.x
	tst.l	g_AmiSSLBase(a4)
	beq.s	.nobase
	clr.l	g_AmiSSLBase(a4)
	move.l	d0,a6
	jsr	_LVOCloseAmiSSL(a6)
.nobase:
	move.l	g_AmiSSLMasterBase(a4),a1
	clr.l	g_AmiSSLMasterBase(a4)
	EXEC	CloseLibrary
.x:	clr.l	g_SslState(a4)
	rts

;--------------------------------------------------------------------
; TlsHandshake - start TLS on a connected socket
; In:  a0 = Conn, g_TlsHost = server name
; Out: d0 = 0 on failure (g_Error = ERR_TLS or ERR_CERT)
;--------------------------------------------------------------------
TlsHandshake:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	g_SslCtx(a4),a0
	SSL	SSL_new
	move.l	d0,c_SSL(a2)
	beq.s	.fail
	move.l	d0,a0
	move.l	c_Sock(a2),d0
	SSL	SSL_set_fd
	move.l	c_SSL(a2),a0		; SNI: SSL_set_tlsext_host_name
	moveq	#55,d0			; SSL_CTRL_SET_TLSEXT_HOSTNAME
	moveq	#0,d1			; TLSEXT_NAMETYPE_host_name
	move.l	g_TlsHost(a4),a1
	SSL	SSL_ctrl
	move.l	c_SSL(a2),a0		; the certificate must name the host
	SSL	SSL_get0_param		; (or its IP address)
	move.l	d0,a0
	move.l	g_TlsHost(a4),a1
	bsr	IsDottedQuad
	bne.s	.ip
	moveq	#0,d0			; length 0: NUL terminated
	SSL	X509_VERIFY_PARAM_set1_host
	bra.s	.conn
.ip:	SSL	X509_VERIFY_PARAM_set1_ip_asc
.conn:
	move.l	c_SSL(a2),a0
	SSL	SSL_connect
	cmp.l	#1,d0
	beq.s	.ok
	move.l	c_SSL(a2),a0		; failed: was it the certificate?
	SSL	SSL_get_verify_result
	tst.l	d0
	beq.s	.fail
	SETERR	ERR_CERT
	bra.s	.x0
.fail:	SETERR	ERR_TLS
.x0:	moveq	#0,d0
	bra.s	.x
.ok:	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a2
	rts

; IsDottedQuad - is a1 a numeric IPv4 address?
; Out: Z clear if yes (a0/a1 kept)
IsDottedQuad:
	move.l	a1,-(sp)
	moveq	#0,d1			; dots
.l:	move.b	(a1)+,d0
	beq.s	.end
	cmp.b	#'.',d0
	bne.s	.d
	addq.l	#1,d1
	bra.s	.l
.d:	sub.b	#'0',d0
	cmp.b	#9,d0
	bls.s	.l
	moveq	#0,d1			; a letter: a name
	bra.s	.x
.end:	cmp.l	#3,d1
	seq	d1
	ext.w	d1
	ext.l	d1
.x:	move.l	(sp)+,a1
	tst.l	d1
	rts

;--------------------------------------------------------------------
; ConnOpenFile - open a DOS file as a Conn (tests)
; In:  a0 = file name
; Out: d0 = Conn or 0 (g_Error set)
;--------------------------------------------------------------------
ConnOpenFile:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	move.l	#CONN_SIZEOF,d0
	bsr	Alloc
	beq.s	.x
	move.l	d0,a3
	moveq	#-1,d0
	move.l	d0,c_Sock(a3)
	move.l	a2,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,c_File(a3)
	bne.s	.ok
	SETERR	ERR_FILE
	move.l	a3,a0
	bsr.s	ConnClose
	moveq	#0,d0
	bra.s	.x
.ok:	move.l	a3,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

;--------------------------------------------------------------------
; ConnClose - close and free a Conn
; In: a0 = Conn or 0
;--------------------------------------------------------------------
ConnClose:
	move.l	a2,-(sp)
	move.l	a0,d0
	beq.s	.x
	move.l	a0,a2
	move.l	c_SSL(a2),d0
	beq.s	.nossl
	move.l	d0,a0
	SSL	SSL_free
.nossl:	move.l	c_Sock(a2),d0
	bmi.s	.nosock
	SOCK	CloseSocket
.nosock:
	move.l	c_File(a2),d1
	beq.s	.nofile
	DOS	Close
.nofile:
	move.l	a2,a1
	bsr	Free
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; WaitSocket - wait until a socket is readable (d1=0) or writable (d1=1)
; In:  d0 = socket, d1 = direction
; Out: d0 = 1 ready, 0 on timeout/abort/error (g_Error set)
;--------------------------------------------------------------------
WaitSocket:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	d0,d2			; socket
	move.l	d1,d4
.again:
	lea	g_FdSet(a4),a0
	moveq	#7,d0
.clr:	clr.l	(a0)+
	dbf	d0,.clr
	lea	g_FdSet(a4),a0
	move.l	d2,d0
	lsr.l	#5,d0			; long index
	lsl.l	#2,d0
	add.l	d0,a0
	move.l	(a0),d1
	bset	d2,d1			; bit = socket & 31
	move.l	d1,(a0)
	lea	g_Timeval(a4),a3
	move.l	#NET_TIMEOUT,(a3)
	clr.l	4(a3)
	move.l	g_AbortMask(a4),-(sp)	; in: signals to wait for
	move.l	sp,d1			; out: signals received
	move.l	d2,d0
	addq.l	#1,d0			; nfds
	lea	g_FdSet(a4),a0		; read set ...
	suba.l	a1,a1
	tst.l	d4
	beq.s	.rd
	move.l	a0,a1			; ... or write set
	suba.l	a0,a0
.rd:	suba.l	a2,a2
	SOCK	WaitSelect
	move.l	(sp)+,d3		; signals received
	tst.l	d0
	bgt.s	.ready
	bmi.s	.err
	; 0: timeout or signal
	tst.l	d3
	beq.s	.timeout
	move.l	g_NetSigHook(a4),d1
	beq.s	.abort
	move.l	d1,a0
	move.l	d3,d0
	jsr	(a0)
	tst.l	d0
	beq.s	.again			; hook handled it, keep waiting
.abort:	SETERR	ERR_ABORT
	bra.s	.fail
.timeout:
	SETERR	ERR_TIMEOUT
	bra.s	.fail
.err:	SETERR	ERR_RECV
.fail:	moveq	#0,d0
	bra.s	.x
.ready:	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

;--------------------------------------------------------------------
; ConnWrite - send all bytes
; In:  a0 = Conn, a1 = data, d0 = length
; Out: d0 = 0 on failure (g_Error set)
;--------------------------------------------------------------------
ConnWrite:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	move.l	d0,d3
.l:	tst.l	d3
	beq.s	.ok
	move.l	c_SSL(a2),d0
	beq.s	.plain
	move.l	d0,a0			; TLS: AmiSSL writes it all
	move.l	a3,a1
	move.l	d3,d0
	SSL	SSL_write
	tst.l	d0
	bgt.s	.sent
	bra.s	.err			; (EPIPE here: the server gave up
					;  waiting for a slow handshake)
.plain:	move.l	c_Sock(a2),d0
	bmi.s	.err
	moveq	#1,d1
	bsr	WaitSocket
	beq.s	.fail
	move.l	c_Sock(a2),d0
	move.l	a3,a0
	move.l	d3,d1
	moveq	#0,d2
	SOCK	send
	tst.l	d0
	ble.s	.err
.sent:	add.l	d0,a3
	sub.l	d0,d3
	bra.s	.l
.ok:	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts
.err:	SETERR	ERR_SEND
.fail:	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; ConnFill - refill the read buffer
; In:  a0 = Conn
; Out: d0 = bytes now available, 0 at end of stream, -1 on error
;--------------------------------------------------------------------
ConnFill:
	movem.l	d2-d3/a2,-(sp)
	move.l	a0,a2
	clr.l	c_Pos(a2)
	clr.l	c_End(a2)
	move.l	c_File(a2),d1
	beq.s	.sock
	lea	c_Buf(a2),a0
	move.l	a0,d2
	move.l	#CONN_BUFSIZE,d3
	DOS	Read
	bra.s	.got
.sock:	move.l	c_Sock(a2),d0
	bmi.s	.err
	tst.l	c_SSL(a2)		; TLS with data already decrypted:
	beq.s	.wait			; no need to wait for the socket
	move.l	c_SSL(a2),a0
	SSL	SSL_pending
	tst.l	d0
	bgt.s	.tls
.wait:	move.l	c_Sock(a2),d0
	moveq	#0,d1
	bsr	WaitSocket
	beq.s	.fail
	tst.l	c_SSL(a2)
	beq.s	.recv
.tls:	move.l	c_SSL(a2),a0
	lea	c_Buf(a2),a1
	move.l	#CONN_BUFSIZE,d0
	SSL	SSL_read
	tst.l	d0
	bgt.s	.got
	move.l	d0,d1			; why not?  closed = end of stream
	move.l	c_SSL(a2),a0
	SSL	SSL_get_error
	cmp.l	#6,d0			; SSL_ERROR_ZERO_RETURN
	beq.s	.eos
	cmp.l	#5,d0			; SSL_ERROR_SYSCALL (closed without
	beq.s	.eos			;   close_notify, as many servers do)
	cmp.l	#2,d0			; SSL_ERROR_WANT_READ: try again
	beq.s	.wait
	bra.s	.err
.eos:	moveq	#0,d0
	bra.s	.got
.recv:	move.l	c_Sock(a2),d0
	lea	c_Buf(a2),a0
	move.l	#CONN_BUFSIZE,d1
	moveq	#0,d2
	SOCK	recv
.got:	tst.l	d0
	bmi.s	.err
	move.l	d0,c_End(a2)
.x:	movem.l	(sp)+,d2-d3/a2
	rts
.err:	SETERR	ERR_RECV
.fail:	moveq	#-1,d0
	bra.s	.x

;--------------------------------------------------------------------
; ConnGetByte - read one byte
; In:  a0 = Conn
; Out: d0 = byte (0-255), -1 at end of stream or on error
;      a0 preserved
;--------------------------------------------------------------------
ConnGetByte:
	move.l	c_Pos(a0),d0
	cmp.l	c_End(a0),d0
	blo.s	.have
	move.l	a0,-(sp)
	bsr.s	ConnFill
	move.l	(sp)+,a0
	tst.l	d0
	ble.s	.eof
	moveq	#0,d0
.have:	moveq	#0,d1
	move.b	c_Buf(a0,d0.l),d1
	addq.l	#1,d0
	move.l	d0,c_Pos(a0)
	move.l	d1,d0
	rts
.eof:	moveq	#-1,d0
	rts

;--------------------------------------------------------------------
; ConnRead - read up to d0 bytes
; In:  a0 = Conn, a1 = destination, d0 = max bytes
; Out: d0 = bytes read, 0 at end of stream, -1 on error
;--------------------------------------------------------------------
ConnRead:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	move.l	d0,d2
	move.l	c_End(a2),d0
	sub.l	c_Pos(a2),d0
	bne.s	.have
	move.l	a2,a0
	bsr	ConnFill
	tst.l	d0
	ble.s	.x
.have:	cmp.l	d2,d0
	bls.s	.n
	move.l	d2,d0
.n:	move.l	d0,d2
	lea	c_Buf(a2),a0
	add.l	c_Pos(a2),a0
	move.l	a3,a1
	EXEC	CopyMem
	add.l	d2,c_Pos(a2)
	move.l	d2,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

;--------------------------------------------------------------------
; ConnReadLine - read a line, strip CR/LF.  Excess characters of
; over-long lines are dropped.
; In:  a0 = Conn, a1 = destination, d0 = buffer size
; Out: d0 = line length, -1 at end of stream with nothing read
;--------------------------------------------------------------------
ConnReadLine:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a1,a3
	move.l	a1,a2			; write position
	move.l	d0,d3
	subq.l	#1,d3			; room for the NUL
	moveq	#0,d2			; bytes read in total
.l:	bsr	ConnGetByte
	tst.l	d0
	bmi.s	.eof
	addq.l	#1,d2
	cmp.b	#10,d0
	beq.s	.end
	cmp.b	#13,d0
	beq.s	.l
	tst.l	d3
	beq.s	.l			; buffer full: drop
	move.b	d0,(a2)+
	subq.l	#1,d3
	bra.s	.l
.eof:	tst.l	d2
	bne.s	.end
	clr.b	(a2)
	moveq	#-1,d0
	bra.s	.x
.end:	clr.b	(a2)
	move.l	a2,d0
	sub.l	a3,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts
