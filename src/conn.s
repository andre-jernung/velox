;
; conn.s - buffered byte streams over TCP (bsdsocket.library), TLS
;          (later) or a DOS file (for offline tests)
;
; All waits on the network go through WaitSelect() together with
; g_AbortMask, so the user can interrupt a transfer.  When one of those
; signals arrives, g_NetSigHook (if set) decides whether to abort.
;
; TLS: AmiSSL's crypto takes seconds on a 68020 (a handshake), half a
; second for a 16 KB record.  It runs in a process of its own (the TLS
; process, TlsChild), below the window's priority, one job at a time
; (TwRun): SSL_connect, SSL_read, SSL_write on SSLs whose BIOs are
; memory BIOs.  Velox's task carries the bytes between the sockets
; (which belong to it) and those BIOs (TlsDo), and serves the window
; while the process works.  A job of a page that was stopped goes on to
; its end; the connection closed meanwhile leaves its SSL to the
; process to free (ConnClose), and the next job waits for it.
;

	include	"velox.i"
	include	"dos/dostags.i"

	xdef	NetExit,ConnOpen,ConnOpenFile,ConnClose,TlsExit
	xdef	ConnWrite,ConnRead,ConnGetByte,ConnReadLine
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	Alloc,Free,HttpCloseKept,LogEvent,G,TaskWaitSig,GuiBusy,StrCopyN

AmiSSL_SocketBase	equ	TAG_USER+$01
AmiSSL_ErrNoPtr		equ	TAG_USER+$0b
AmiSSL_UsesOpenSSLStructs equ	TAG_USER+$0c
AmiSSL_GetAmiSSLBase	equ	TAG_USER+$0d
AmiSSL_GetAmiSSLExtBase	equ	TAG_USER+$0e

AF_INET		equ	2
SOCK_STREAM	equ	1
INADDR_NONE	equ	-1

TW_CONNECT	equ	1		; TLS process jobs (g_TwOp)
TW_READ		equ	2
TW_WRITE	equ	3
TW_QUIT		equ	4

SSL_ERROR_WANT_READ	equ	2
SSL_ERROR_WANT_WRITE	equ	3
SSL_ERROR_SYSCALL	equ	5
SSL_ERROR_ZERO_RETURN	equ	6
BIO_CTRL_PENDING	equ	10

FIONBIO		equ	$8004667e
SOL_SOCKET	equ	$ffff
SO_ERROR	equ	$1007

	xref	TaskWaitSock

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
TlsChildInit:	dc.l	AmiSSL_ErrNoPtr,0
	dc.l	TAG_DONE
TlsChildTags:	dc.l	NP_Entry,TlsChild
	dc.l	NP_Name,TlsChildName
	dc.l	NP_StackSize,65536
	dc.l	NP_Priority,-1
	dc.l	TAG_DONE
TlsChildName:	dc.b	"Velox TLS",0
	even
	section	code,code

;--------------------------------------------------------------------
; NetExit - close bsdsocket.library
;--------------------------------------------------------------------
NetExit:
	jsr	HttpCloseKept		; connections first,
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
	moveq	#0,d3			; (the port: TLS sessions are per host
	move.w	d0,d3			;  and port)
	move.l	d3,g_TlsPort(a4)
	move.l	d1,-(sp)		; TLS wanted?
	bsr	NetOpen
	beq	.fail1
	tst.l	(sp)
	bne.s	.tls
	tst.l	g_Window(a4)		; (the window: TLS ready by the time
	beq.s	.plain			;  it is used; not for a CLI fetch)
	bsr	TlsPrepare
	bra.s	.plain
.tls:	bsr	TlsInit			; AmiSSL needs the socket library
	beq	.fail1
.plain:

	; resolve: dotted quad first, then DNS
	move.l	a2,a0
	SOCK	inet_addr
	move.l	d0,d3
	cmp.l	#INADDR_NONE,d3
	bne.s	.addr
	move.l	a2,a0			; looked up before?
	bsr	DnsCached
	move.l	d0,d3
	bne.s	.addr
	moveq	#1,d0			; (this blocks: hence the cache; the
	jsr	GuiBusy			;  busy pointer meanwhile)
	move.l	a2,a0
	SOCK	gethostbyname
	move.l	d0,-(sp)
	moveq	#0,d0
	jsr	GuiBusy
	move.l	(sp)+,d0
	tst.l	d0
	beq.s	.noresolve
	move.l	d0,a0
	move.l	16(a0),a0		; h_addr_list
	move.l	(a0),d0			; first address
	beq.s	.noresolve
	move.l	d0,a0
	move.l	(a0),d3
	move.l	a2,a0
	move.l	d3,d0
	bsr	DnsKeep
.addr:
	lea	g_SockAddr(a4),a0	; struct sockaddr_in
	clr.l	8(a0)
	clr.l	12(a0)
	move.b	#16,(a0)		; sin_len
	move.b	#AF_INET,1(a0)		; sin_family
	move.w	d2,2(a0)		; sin_port
	move.l	d3,4(a0)		; sin_addr

	move.l	#CONN_SIZEOF,d0
	jsr	Alloc
	beq	.fail1
	move.l	d0,a3
	moveq	#-1,d0
	move.l	d0,c_Sock(a3)

	moveq	#AF_INET,d0
	moveq	#SOCK_STREAM,d1
	moveq	#0,d2
	SOCK	socket
	move.l	d0,c_Sock(a3)
	bmi	.noconnect
	; non-blocking: connecting, the TLS handshake and reading wait in
	; WaitSocket, where the window keeps being served
	moveq	#1,d1
	move.l	d1,-(sp)
	move.l	sp,a0
	move.l	#FIONBIO,d1
	SOCK	IoctlSocket
	addq.l	#4,sp
	lea	g_SockAddr(a4),a0
	move.l	c_Sock(a3),d0
	moveq	#16,d1
	SOCK	connect
	tst.l	d0
	bpl.s	.conn			; at once (EINPROGRESS otherwise)
	move.l	c_Sock(a3),d0		; writable: connected or failed
	moveq	#1,d1
	bsr	WaitSocket
	beq.s	.failclose		; (aborted, timed out)
	clr.l	-(sp)			; SO_ERROR says which
	pea	4.w
	move.l	c_Sock(a3),d0
	move.l	#SOL_SOCKET,d1
	move.l	#SO_ERROR,d2
	lea	4(sp),a0
	move.l	sp,a1
	SOCK	getsockopt
	addq.l	#4,sp
	move.l	(sp)+,d1
	tst.l	d0
	bmi.s	.noconnect
	tst.l	d1
	bne.s	.noconnect
.conn:	tst.l	(sp)
	beq.s	.ok
	move.l	a2,g_TlsHost(a4)
	clr.l	g_TlsAgain(a4)
	move.l	a3,a0
	bsr	TlsHandshake
	bne.s	.ok
	tst.l	g_TlsAgain(a4)		; TLS 1.3 only: connect again
	beq.s	.failclose
	clr.l	g_TlsAgain(a4)
	move.l	a3,a0
	bsr	ConnClose
	move.l	g_TlsPort(a4),d2
	bra	.addr
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
; TlsPrepare - (the network is used) open AmiSSL and start the TLS
; process (TlsChild), which first makes the SSL context: SSL_CTX_new
; takes 6.6 s on a stock A1200, and nothing waits for it unless a TLS
; connection needs it first (TlsInit)
; g_SslState: 0 not yet, 2 being made, 1 ready, -1 no AmiSSL
;--------------------------------------------------------------------
TlsPrepare:
	tst.l	g_SslState(a4)
	bne	.x			; (done or under way)
	movem.l	d2/a2,-(sp)
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
	moveq	#2,d0			; the context: being made
	move.l	d0,g_SslState(a4)
	moveq	#-1,d0
	EXEC	AllocSignal
	move.l	d0,g_TlsSigBit(a4)
	bmi.s	.here
	moveq	#0,d1
	bset	d0,d1
	move.l	d1,g_TlsSig(a4)
	suba.l	a1,a1
	EXEC	FindTask
	move.l	d0,g_TlsMain(a4)
	move.l	#TlsChildTags,d1
	DOS	CreateNewProc
	tst.l	d0
	bne.s	.xx
	bsr	TlsSigFree		; no process: made here (and the
.here:	bsr	TlsCtx			; jobs done here)
	bsr	TlsMade
	bra.s	.xx
.fail:	bsr	TlsExit
	moveq	#-1,d0
	move.l	d0,g_SslState(a4)
.xx:	movem.l	(sp)+,d2/a2
.x:	rts

; TlsChild - the TLS process (shares Velox's AmiSSL): makes the
; context, signals (g_TlsSig), then does the jobs Velox gives it
; (TwRun), signalling the end of each, until TW_QUIT (TwQuit).  It
; ends at once if there is no context, and after making it if it has
; no signal for jobs (g_TwTask 0: Velox does them itself)
TlsChild:
	lea	G,a4
	clr.l	g_TlsOk(a4)
	lea	TlsChildInit,a0		; (its own errno)
	lea	g_TlsErrno(a4),a1
	move.l	a1,4(a0)
	move.l	g_AmiSSLBase(a4),a6
	jsr	_LVOInitAmiSSLA(a6)
	tst.l	d0
	bne.s	.done
	bsr	TlsCtx
	move.l	d0,g_TlsOk(a4)
	beq.s	.stop
	moveq	#-1,d0
	EXEC	AllocSignal
	move.l	d0,g_TwSigBit(a4)
	bmi.s	.stop
	moveq	#0,d1
	bset	d0,d1
	move.l	d1,g_TwSig(a4)
	suba.l	a1,a1
	EXEC	FindTask
	move.l	d0,g_TwTask(a4)
	move.l	g_TlsMain(a4),a1	; ready
	move.l	g_TlsSig(a4),d0
	EXEC	Signal
.wait:	move.l	g_TwSig(a4),d0
	EXEC	Wait
	cmp.l	#TW_QUIT,g_TwOp(a4)
	beq.s	.quit
	tst.l	g_TwBusy(a4)
	beq.s	.wait
	bsr	TwExec
	EXEC	Forbid
	clr.l	g_TwBusy(a4)		; (with the signal: TwRun checks
	move.l	g_TlsMain(a4),a1	;  g_TwBusy before it waits)
	move.l	g_TlsSig(a4),d0
	EXEC	Signal
	EXEC	Permit
	bra.s	.wait
.quit:	move.l	g_TwSigBit(a4),d0
	EXEC	FreeSignal
	clr.l	g_TwSig(a4)
.stop:	SSL	OPENSSL_thread_stop	; (its per task OpenSSL state: else a
	suba.l	a0,a0			;  later task at the same address gets
	move.l	g_AmiSSLBase(a4),a6	;  it, and AmiSSL fails there)
	jsr	_LVOCleanupAmiSSLA(a6)
.done:	EXEC	Forbid			; (gone before Velox goes on)
	clr.l	g_TwTask(a4)
	move.l	g_TlsMain(a4),a1
	move.l	g_TlsSig(a4),d0
	EXEC	Signal
	moveq	#0,d0
	rts

; TwExec - do the job g_TwOp on g_TwSSL (in the TLS process, or in
; Velox if there is none): g_TwRet, g_TwErr
TwExec:
	move.l	g_TwSSL(a4),a0
	move.l	g_TwOp(a4),d0
	cmp.l	#TW_CONNECT,d0
	bne.s	.rw
	move.l	g_TwDelay(a4),d1	; (tests)
	ble.s	.c
	DOS	Delay
.c:	move.l	g_TwSSL(a4),a0
	SSL	SSL_connect
	bra.s	.r
.rw:	lea	g_TwBuf(a4),a1
	cmp.l	#TW_READ,d0
	bne.s	.wr
	move.l	g_TwLen(a4),d0
	SSL	SSL_read
	bra.s	.r
.wr:	move.l	g_TwLen(a4),d0
	SSL	SSL_write
.r:	move.l	d0,g_TwRet(a4)
	clr.l	g_TwErr(a4)
	tst.l	d0
	bgt.s	.x
	move.l	g_TwSSL(a4),a0		; (in this task: its error queue)
	SSL	SSL_get_error
	move.l	d0,g_TwErr(a4)
.x:	rts

; TlsMade - the context was made (g_TlsOk / g_SslCtx): ready, or no
; AmiSSL after all
TlsMade:
	tst.l	g_SslCtx(a4)
	beq.s	.no
	moveq	#1,d0
	move.l	d0,g_SslState(a4)
	rts
.no:	bsr	TlsExit
	moveq	#-1,d0
	move.l	d0,g_SslState(a4)
	rts

; TlsChildDone - the TLS process signalled: the context made, the
; process waiting for jobs (or gone: its signal freed)
TlsChildDone:
	tst.l	g_TwTask(a4)
	bne.s	TlsMade
	bsr	TlsSigFree
	bra.s	TlsMade

; TlsSigFree - free g_TlsSig (if allocated)
TlsSigFree:
	tst.l	g_TlsSig(a4)
	beq.s	.x
	clr.l	g_TlsSig(a4)
	move.l	g_TlsSigBit(a4),d0
	EXEC	FreeSignal
.x:	rts

; TwQuit - end the TLS process (its job first, if one still runs)
TwQuit:
	tst.l	g_TwTask(a4)
	beq.s	TlsSigFree
.b:	tst.l	g_TwBusy(a4)
	beq.s	.q
	move.l	g_TlsSig(a4),d0
	EXEC	Wait
	bra.s	.b
.q:	bsr	TwOrphan
	moveq	#TW_QUIT,d0
	move.l	d0,g_TwOp(a4)
	move.l	g_TwTask(a4),a1
	move.l	g_TwSig(a4),d0
	EXEC	Signal
.w:	tst.l	g_TwTask(a4)
	beq.s	.gone
	move.l	g_TlsSig(a4),d0
	EXEC	Wait
	bra.s	.w
.gone:	move.l	d2,-(sp)		; and until it is gone from the system
	moveq	#50,d2			; (its memory back: 1 s at most)
.g:	EXEC	Forbid
	lea	TlsChildName,a1
	EXEC	FindTask
	move.l	d0,-(sp)
	EXEC	Permit
	tst.l	(sp)+
	beq.s	.gd
	moveq	#1,d1
	DOS	Delay
	subq.l	#1,d2
	bne.s	.g
.gd:	move.l	(sp)+,d2
	bra	TlsSigFree

;--------------------------------------------------------------------
; TlsInit - AmiSSL and the SSL context, for a TLS connection: made now
; if not yet (TlsPrepare), waited for if being made (in the loader the
; window is served meanwhile)
; Out: d0 = 0 if there is no AmiSSL or it was stopped (g_Error)
;--------------------------------------------------------------------
TlsInit:
	bsr	TlsPrepare
	move.l	g_SslState(a4),d0
	cmp.l	#2,d0
	bne.s	.st
	PROFB	22
	move.l	g_TlsSig(a4),d0
	tst.l	g_TkIn(a4)
	beq.s	.own
	jsr	TaskWaitSig
	tst.l	d0
	bne.s	.got
	PROFE	22
	moveq	#0,d0			; (stopped: g_Error is set)
	rts
.own:	EXEC	Wait
.got:	bsr	TlsChildDone
	PROFE	22
	move.l	g_SslState(a4),d0
.st:	tst.l	d0
	bgt.s	.ok
	SETERR	ERR_NOAMISSL
	moveq	#0,d0
	rts
.ok:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; TlsCtx - make the SSL context (g_SslCtx; 0 if it cannot be)
; Out: d0 = 1 if made (CCR set)
;--------------------------------------------------------------------
TlsCtx:
	movem.l	d2-d4,-(sp)
	SSL	TLS_client_method
	move.l	d0,a0
	SSL	SSL_CTX_new
	move.l	d0,g_SslCtx(a4)
	beq	.x
	move.l	d0,a0
	SSL	SSL_CTX_set_default_verify_paths
	move.l	g_SslCtx(a4),a0		; verify the server's certificate
	moveq	#1,d0			; SSL_VERIFY_PEER
	tst.l	g_Insecure(a4)
	beq.s	.v
	moveq	#0,d0			; SSL_VERIFY_NONE (tests only)
.v:	suba.l	a1,a1
	SSL	SSL_CTX_set_verify
	move.l	g_SslCtx(a4),a0		; a certificate checked before: not
	lea	TlsVerify(pc),a1	; again (TlsVerify)
	move.l	a2,-(sp)
	suba.l	a2,a2
	SSL	SSL_CTX_set_cert_verify_callback
	move.l	(sp)+,a2
	move.l	g_SslCtx(a4),a0		; cheap key exchanges only: the
	moveq	#92,d0			; post-quantum hybrid default takes
	moveq	#0,d1			; far too long on a 68020
	lea	TlsGroups(pc),a1	; (SSL_CTRL_SET_GROUPS_LIST)
	SSL	SSL_CTX_ctrl
	; the ciphers fastest on a 68k first: ChaCha20-Poly1305 (twice as
	; fast as AES-GCM without AES instructions), then AES-128 (fewer
	; rounds, SHA-256 instead of SHA-384)
	move.l	g_SslCtx(a4),a0
	lea	TlsSuites(pc),a1
	SSL	SSL_CTX_set_ciphersuites
	move.l	g_SslCtx(a4),a0
	lea	TlsCiphers(pc),a1
	SSL	SSL_CTX_set_cipher_list
	move.l	g_SslCtx(a4),a0		; RSA signatures first: far cheaper
	moveq	#98,d0			; to verify than ECDSA (a server with
	moveq	#0,d1			; both kinds of certificate uses RSA)
	lea	TlsSigalgs(pc),a1	; (SSL_CTRL_SET_SIGALGS_LIST)
	SSL	SSL_CTX_ctrl
	lea	VarTls13(pc),a0	; Velox/Tls13: no TLS 1.2 (tests)
	move.l	a0,d1
	lea	g_TlsVar(a4),a0
	move.l	a0,d2
	moveq	#127,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	sgt	d0
	and.l	#1,d0
	move.l	d0,g_Tls13(a4)
	lea	VarDelay(pc),a0		; Velox/TlsDelay: ticks each handshake
	move.l	a0,d1			; job waits in the TLS process (tests:
	lea	g_TlsVar(a4),a0		; a slow handshake)
	move.l	a0,d2
	moveq	#127,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	ble.s	.nd
	lea	g_TlsVar(a4),a0
	move.l	a0,d1
	lea	g_TwDelay(a4),a0
	move.l	a0,d2
	DOS	StrToLong
.nd:	lea	VarCiphers(pc),a0	; Velox/TlsCiphers: TLS 1.3 suites
	move.l	a0,d1			; (tests, or a server that wants
	lea	g_TlsVar(a4),a0		;  others)
	move.l	a0,d2
	moveq	#127,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	ble.s	.ok
	move.l	g_SslCtx(a4),a0
	lea	g_TlsVar(a4),a1
	SSL	SSL_CTX_set_ciphersuites
.ok:	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d4
	rts

AMISSL_API	equ	47		; AMISSL_V41x: AmiSSL 6
MasterName:	dc.b	"amisslmaster.library",0
TlsGroups:	dc.b	"X25519:P-256",0
VarCiphers:	dc.b	"Velox/TlsCiphers",0
VarTls13:	dc.b	"Velox/Tls13",0
VarDelay:	dc.b	"Velox/TlsDelay",0
TlsSuites:	dc.b	"TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:"
		dc.b	"TLS_AES_256_GCM_SHA384",0
TlsCiphers:	dc.b	"ECDHE+CHACHA20:ECDHE+AESGCM+AES128:ECDHE+AES128:"
		dc.b	"DEFAULT",0
TlsSigalgs:	dc.b	"rsa_pss_rsae_sha256:rsa_pkcs1_sha256:"
		dc.b	"rsa_pss_rsae_sha384:rsa_pkcs1_sha384:"
		dc.b	"rsa_pss_rsae_sha512:rsa_pkcs1_sha512:ed25519:"
		dc.b	"ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:"
		dc.b	"ecdsa_secp521r1_sha512:rsa_pkcs1_sha1:ecdsa_sha1",0
DbgW:		dc.b	"SSL_write error ",0
	even

;--------------------------------------------------------------------
; TlsExit - free the context and close AmiSSL
;--------------------------------------------------------------------
TlsExit:
	cmp.l	#2,g_SslState(a4)	; the context still being made: wait
	bne.s	.nc
	tst.l	g_TlsSig(a4)
	beq.s	.nc
	move.l	g_TlsSig(a4),d0
	EXEC	Wait
	clr.l	g_SslState(a4)
.nc:	bsr	TwQuit			; the TLS process gone
	move.l	g_SslCtx(a4),d0
	beq.s	.noctx
	move.l	d2,-(sp)		; the sessions kept
	moveq	#TLS_SESS-1,d2
.s:	move.l	d2,d0
	mulu.w	#TS_SIZEOF,d0
	lea	g_TlsSess(a4),a0
	add.l	d0,a0
	clr.l	ts_Gen(a0)
	move.l	ts_Sess(a0),d0
	beq.s	.sn
	clr.l	ts_Sess(a0)
	move.l	d0,a0
	SSL	SSL_SESSION_free
.sn:	dbf	d2,.s
	move.l	(sp)+,d2
	move.l	g_SslCtx(a4),d0
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
	PROFB	20
	move.l	a0,a2
	move.l	g_SslCtx(a4),a0
	SSL	SSL_new
	move.l	d0,c_SSL(a2)
	beq	.fail
	bsr	TlsBios			; (the bytes go through Velox)
	beq	.fail
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
	bra.s	.conn0
.ip:	SSL	X509_VERIFY_PARAM_set1_ip_asc
.conn0:	bsr	TlsSessFor		; a session of this host and port:
	move.l	d0,c_Sess(a2)		; resumed (no certificate to check)
	beq.s	.conn
	bsr	TlsCap
	move.l	c_Sess(a2),a0
	move.l	ts_Gen(a0),c_SessGen(a2)
	move.l	ts_Sess(a0),d0
	beq.s	.conn
	move.l	d0,a1
	move.l	c_SSL(a2),a0
	SSL	SSL_set_session
	lea	LogSessUse(pc),a0	; (for tests)
	move.l	g_TlsHost(a4),a1
	jsr	LogEvent
.conn:	clr.l	g_TwCertKnown(a4)
	move.l	a2,a0			; (in the TLS process: seconds of
	moveq	#TW_CONNECT,d0		;  crypto on a 68020)
	move.l	g_TlsHost(a4),a1
	bsr	TlsDo
	bgt.s	.ok
	cmp.l	#ERR_TLS,g_Error(a4)	; (stopped, timed out: no more)
	bne.s	.x0
	move.l	c_SSL(a2),a0		; failed: was it the certificate?
	SSL	SSL_get_verify_result
	tst.l	d0
	beq.s	.tlsf
	SETERR	ERR_CERT
	bra.s	.x0
.tlsf:	move.l	c_Sess(a2),d0		; TLS 1.2 at most: once more without
	beq.s	.fail			; (a server that speaks only 1.3;
	move.l	d0,a0			;  ConnOpen connects again)
	tst.l	ts_Tls13(a0)
	bne.s	.fail
	tst.l	g_Tls13(a4)
	bne.s	.fail
	moveq	#1,d0
	move.l	d0,ts_Tls13(a0)
	move.l	d0,g_TlsAgain(a4)
	lea	LogTls13(pc),a0		; (for tests)
	move.l	g_TlsHost(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
.fail:	SETERR	ERR_TLS
.x0:	moveq	#0,d0
	bra.s	.x
.ok:	move.l	g_TwCertKnown(a4),d0	; (for tests: a job left by a
	cmp.l	c_SSL(a2),d0		;  page stopped sets its own SSL)
	bne.s	.ok1
	lea	LogCertOk(pc),a0
	move.l	g_TlsHost(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
.ok1:	move.l	c_SSL(a2),a0		; (for tests: "tls host 1" when the
	SSL	SSL_session_reused	;  session was resumed)
	lea	LogTls(pc),a0
	move.l	g_TlsHost(a4),a1
	jsr	LogEvent
	move.l	c_SSL(a2),a0		; (and the cipher)
	SSL	SSL_get_current_cipher
	move.l	d0,a0
	SSL	SSL_CIPHER_get_name
	move.l	d0,a1
	lea	LogCipher(pc),a0
	move.l	#$80000000,d0
	jsr	LogEvent
	moveq	#1,d0
.x:	PROFE	20
	movem.l	(sp)+,d2/a2
	tst.l	d0
	rts

LogTls:	dc.b	"tls",0
LogCipher:	dc.b	"cipher",0
LogSessKept:	dc.b	"tlssession",0
LogSessUse:	dc.b	"tlsresume",0
LogTls13:	dc.b	"tls13",0
	even

;--------------------------------------------------------------------
; TlsVerify - (AmiSSL calls it in SSL_connect instead of checking the
; certificate chain; C calling convention: the X509_STORE_CTX at 4(sp))
; the server's certificate, if checked before for this host and not
; expired, is taken as it is: checking a chain of ECDSA P-384
; signatures takes 25 s on a stock A1200.  Else the chain is checked
; (and the certificate noted if it is good).  The proof that the server
; has its key (its signature over the handshake) is checked as always.
; The host name must be the same, character for character (a hash
; could be matched by a domain made for it).  It runs in the TLS
; process: the host is g_TwHost, set with the job (TwRun).
; Out: d0 = 1 good, 0 not
;--------------------------------------------------------------------
TlsVerify:
	movem.l	d2-d7/a2-a6,-(sp)
	lea	G,a4
	move.l	11*4+4(sp),a5		; a5 = the X509_STORE_CTX
	clr.l	g_CertMdOk(a4)
	bsr	CertLoad
	move.l	a5,a0
	SSL	X509_STORE_CTX_get0_cert
	move.l	d0,d7			; d7 = the server's certificate
	beq.s	.full
	SSL	EVP_sha256
	move.l	d0,a1
	move.l	d7,a0
	lea	g_CertMd(a4),a2
	lea	g_CertMdLen(a4),a3
	SSL	X509_digest
	tst.l	d0
	beq.s	.full
	cmp.l	#32,g_CertMdLen(a4)
	bne.s	.full
	move.l	d7,a0			; not expired? (from now to its end)
	SSL	X509_get0_notAfter
	move.l	d0,a3
	suba.l	a2,a2
	lea	g_CertDay(a4),a0
	lea	g_CertSec(a4),a1
	SSL	ASN1_TIME_diff
	tst.l	d0
	beq.s	.full
	tst.l	g_CertDay(a4)
	bmi.s	.full
	tst.l	g_CertSec(a4)
	bmi.s	.full
	moveq	#1,d0
	move.l	d0,g_CertMdOk(a4)
	bsr	CertFind
	beq.s	.full
	move.l	g_TwSSL(a4),g_TwCertKnown(a4)	; (TlsHandshake logs it)
	moveq	#1,d0
	bra.s	.x
.full:	move.l	a5,a0
	SSL	X509_verify_cert
	cmp.l	#1,d0
	bne.s	.no
	tst.l	g_CertMdOk(a4)
	beq.s	.ok
	bsr	CertAdd
.ok:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a6
	rts

CO_SIZEOF	equ	32+HOST_MAX	; an entry: SHA-256, host name

; CertFind - is g_CertMd noted for g_TwHost?  Out: d0 = 1 if so (CCR)
CertFind:
	movem.l	d2/a2,-(sp)
	lea	g_CertOk(a4),a2
	moveq	#CERT_OK-1,d2
.l:	tst.b	32(a2)
	beq.s	.n
	move.l	a2,a0
	lea	g_CertMd(a4),a1
	moveq	#8-1,d0
.c:	cmpm.l	(a0)+,(a1)+
	dbne	d0,.c
	bne.s	.n
	lea	32(a2),a0
	lea	g_TwHost(a4),a1
.h:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.n
	tst.b	d0
	bne.s	.h
	moveq	#1,d0
	bra.s	.x
.n:	lea	CO_SIZEOF(a2),a2
	dbf	d2,.l
	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2
	rts

; CertAdd - note g_CertMd for g_TwHost (instead of the oldest), and
; keep the list in the disk cache's directory
CertAdd:
	move.l	a2,-(sp)
	move.l	g_CertNext(a4),d0
	addq.l	#1,d0
	cmp.l	#CERT_OK,d0
	blo.s	.n
	moveq	#0,d0
.n:	move.l	d0,g_CertNext(a4)
	mulu.l	#CO_SIZEOF,d0
	lea	g_CertOk(a4),a2
	add.l	d0,a2
	lea	g_CertMd(a4),a0
	move.l	a2,a1
	moveq	#8-1,d0
.c:	move.l	(a0)+,(a1)+
	dbf	d0,.c
	lea	g_TwHost(a4),a0
	move.l	#HOST_MAX-1,d0
	jsr	StrCopyN
	move.l	(sp)+,a2
	move.l	#MODE_NEWFILE,d0
	bra.s	CertFile

; CertLoad - the first time: g_CertOk from the disk cache's directory
CertLoad:
	tst.l	g_CertLoaded(a4)
	bne.s	.x
	moveq	#1,d0
	move.l	d0,g_CertLoaded(a4)
	move.l	#MODE_OLDFILE,d0
	bra.s	CertFile
.x:	rts

; CertFile - read (d0 = MODE_OLDFILE) or write (MODE_NEWFILE) g_CertOk
; as the file "tlscerts" in the disk cache's directory
CertFile:
	movem.l	d2-d5,-(sp)
	move.l	d0,d5
	tst.l	g_DcOn(a4)
	beq.s	.x0
	lea	g_DcDir(a4),a0
	lea	g_CertPath(a4),a1
	move.l	#DCPATH_MAX-1,d0
	jsr	StrCopyN
	lea	g_CertPath(a4),a0
	move.l	a0,d1
	lea	CertName(pc),a0
	move.l	a0,d2
	move.l	#DCPATH_MAX,d3
	DOS	AddPart
	lea	g_CertPath(a4),a0
	move.l	a0,d1
	move.l	d5,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.x0
	move.l	d4,d1
	lea	g_CertOk(a4),a0
	move.l	a0,d2
	move.l	#CERT_OK*CO_SIZEOF,d3
	cmp.l	#MODE_OLDFILE,d5
	bne.s	.w
	DOS	Read
	cmp.l	#CERT_OK*CO_SIZEOF,d0	; (anything else: none)
	beq.s	.c
	lea	g_CertOk(a4),a0
	move.l	#CERT_OK*CO_SIZEOF/4-1,d0
.z:	clr.l	(a0)+
	dbf	d0,.z
	bra.s	.c
.w:	DOS	Write
.c:	move.l	d4,d1
	DOS	Close
.x0:	movem.l	(sp)+,d2-d5
	rts

CertName:	dc.b	"tlscerts",0
LogCertOk:	dc.b	"certknown",0
	even

;--------------------------------------------------------------------
; TlsCap - (a2 = Conn, c_Sess its entry) TLS 1.2 at most, unless the
; server speaks only 1.3 (or Velox/Tls13 is set): a 1.2 session is
; resumed without a key exchange (a tenth of a second on a 68020),
; a 1.3 session with one (X25519: three seconds)
;--------------------------------------------------------------------
TlsCap:
	move.l	c_Sess(a2),a0
	tst.l	ts_Tls13(a0)
	bne.s	.x
	tst.l	g_Tls13(a4)
	bne.s	.x
	move.l	c_SSL(a2),a0
	moveq	#124,d0			; SSL_CTRL_SET_MAX_PROTO_VERSION
	move.l	#$303,d1		; TLS1_2_VERSION
	suba.l	a1,a1
	SSL	SSL_ctrl
.x:	rts

;--------------------------------------------------------------------
; TlsSessFor - the g_TlsSess entry of g_TlsHost, port g_TlsPort; made
; (instead of the oldest) if there is none
; Out: d0 = it
;--------------------------------------------------------------------
TlsSessFor:
	movem.l	d2-d3/a2-a3,-(sp)
	lea	g_TlsSess(a4),a2
	suba.l	a3,a3			; a3 = the oldest
	moveq	#-1,d3			; (its ts_Gen)
	moveq	#TLS_SESS-1,d2
.l:	move.l	ts_Gen(a2),d0
	beq.s	.old			; (free: the oldest of all)
	move.l	ts_Port(a2),d0
	cmp.l	g_TlsPort(a4),d0
	bne.s	.n
	lea	ts_Host(a2),a0
	move.l	g_TlsHost(a4),a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.n
	tst.b	d0
	bne.s	.c
	move.l	a2,d0			; found
	bra.s	.x
.n:	move.l	ts_Gen(a2),d0
.old:	cmp.l	d3,d0
	bhs.s	.nx
	move.l	d0,d3
	move.l	a2,a3
.nx:	lea	TS_SIZEOF(a2),a2
	dbf	d2,.l
	move.l	ts_Sess(a3),d0		; the oldest becomes this host's
	beq.s	.ns
	clr.l	ts_Sess(a3)
	move.l	d0,a0
	SSL	SSL_SESSION_free
.ns:	addq.l	#1,g_TlsGen(a4)
	move.l	g_TlsGen(a4),ts_Gen(a3)
	move.l	g_TlsPort(a4),ts_Port(a3)
	clr.l	ts_Tls13(a3)
	move.l	g_TlsHost(a4),a0
	lea	ts_Host(a3),a1
	move.l	#HOST_MAX-2,d0
.cp:	move.b	(a0)+,(a1)+
	dbeq	d0,.cp
	clr.b	(a1)
	move.l	a3,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; TlsKeepSession - (ConnClose) keep the session of TLS connection a2
; for its host, if it can be resumed
;--------------------------------------------------------------------
TlsKeepSession:
	movem.l	d2/a3,-(sp)
	move.l	c_Sess(a2),d0
	beq.s	.x
	move.l	d0,a3
	move.l	ts_Gen(a3),d0		; (the entry still this host's?)
	cmp.l	c_SessGen(a2),d0
	bne.s	.x
	move.l	c_SSL(a2),a0
	SSL	SSL_get1_session
	move.l	d0,d2
	beq.s	.x
	move.l	d2,a0			; a copy: the connection's own is
	SSL	SSL_SESSION_dup		; marked not resumable when the
	move.l	d0,-(sp)		; server closes without close_notify
	move.l	d2,a0			; (as many do)
	SSL	SSL_SESSION_free
	move.l	(sp)+,d2
	beq	.x
	move.l	d2,a0
	SSL	SSL_SESSION_is_resumable
	move.l	d0,-(sp)		; (for tests)
	lea	LogSessKept(pc),a0
	lea	ts_Host(a3),a1
	jsr	LogEvent
	move.l	(sp)+,d0
	tst.l	d0
	beq.s	.no
	move.l	ts_Sess(a3),d0		; the newest replaces it
	move.l	d2,ts_Sess(a3)
	move.l	d0,d2
	beq.s	.x
.no:	move.l	d2,a0
	SSL	SSL_SESSION_free
.x:	movem.l	(sp)+,d2/a3
	rts

;--------------------------------------------------------------------
; TlsBios - (a2 = Conn with its SSL) give the SSL memory BIOs: what it
; reads and writes goes through Velox (TlsDo), not the socket
; Out: d0 = 0 if out of memory (CCR set)
;--------------------------------------------------------------------
TlsBios:
	SSL	BIO_s_mem
	move.l	d0,a0
	SSL	BIO_new
	move.l	d0,c_RBio(a2)
	beq.s	.x
	SSL	BIO_s_mem
	move.l	d0,a0
	SSL	BIO_new
	move.l	d0,c_WBio(a2)
	bne.s	.set
	move.l	c_RBio(a2),a0
	SSL	BIO_free
	moveq	#0,d0
	rts
.set:	move.l	a2,-(sp)		; (the SSL's now)
	move.l	c_SSL(a2),a0
	move.l	c_RBio(a2),a1
	move.l	d0,a2
	SSL	SSL_set_bio
	move.l	(sp)+,a2
	moveq	#1,d0
.x:	rts

;--------------------------------------------------------------------
; TlsDo - job d0 on TLS connection a0, done by the TLS process:
; TW_CONNECT (a1 = host name), TW_READ (into c_Buf), TW_WRITE (d1 <=
; CONN_BUFSIZE bytes from a1).  What the SSL writes goes to the socket,
; what the socket brings to the SSL, until the job is done; the window
; is served meanwhile.
; Out: d0 > 0 done (SSL_xxx's result), 0 at end of stream (TW_READ),
;      -1 failed (g_Error set: ERR_TLS if the handshake failed) (CCR)
;--------------------------------------------------------------------
TlsDo:
	movem.l	d2-d5/a2-a3,-(sp)
	move.l	a0,a2
	move.l	d0,d4			; d4 = the job
	move.l	d1,d5			; d5 = bytes
	move.l	a1,a3
	cmp.l	#TW_READ,d4
	bne.s	.run
	move.l	#CONN_BUFSIZE,d5
.run:	move.l	d4,d0
	move.l	c_SSL(a2),a0
	move.l	d5,d1
	move.l	a3,a1
	bsr	TwRun
	beq	.fail
	bsr	TlsFlush		; what it wrote: to the server
	beq	.fail
	move.l	g_TwRet(a4),d0
	bgt.s	.done
	move.l	g_TwErr(a4),d0
	cmp.l	#SSL_ERROR_WANT_READ,d0
	beq.s	.recv
	cmp.l	#SSL_ERROR_WANT_WRITE,d0
	beq.s	.run
	cmp.l	#TW_READ,d4		; (closed without close_notify, as
	bne.s	.err			;  many servers do: the end too)
	cmp.l	#SSL_ERROR_ZERO_RETURN,d0
	beq.s	.eos
	cmp.l	#SSL_ERROR_SYSCALL,d0
	beq.s	.eos
.err:	moveq	#ERR_TLS,d0
	cmp.l	#TW_READ,d4
	bne.s	.e1
	moveq	#ERR_RECV,d0
.e1:	cmp.l	#TW_WRITE,d4
	bne.s	.e2
	moveq	#ERR_SEND,d0
.e2:	move.l	d0,g_Error(a4)
	bra.s	.fail
.recv:	move.l	c_Sock(a2),d0		; more from the server
	moveq	#0,d1
	bsr	WaitSocket
	beq.s	.fail
	move.l	c_Sock(a2),d0
	lea	g_TwNet(a4),a0
	move.l	#TW_NET,d1
	moveq	#0,d2
	SOCK	recv
	tst.l	d0
	bmi.s	.rerr
	beq.s	.closed
	move.l	c_RBio(a2),a0
	lea	g_TwNet(a4),a1
	SSL	BIO_write
	bra	.run
.closed:
	cmp.l	#TW_READ,d4
	bne.s	.err
.eos:	moveq	#0,d0
	bra.s	.x
.rerr:	SETERR	ERR_RECV
	bra.s	.fail
.done:	cmp.l	#TW_READ,d4
	bne.s	.x
	move.l	d0,d2
	lea	g_TwBuf(a4),a0
	lea	c_Buf(a2),a1
	EXEC	CopyMem
	move.l	d2,d0
	bra.s	.x
.fail:	moveq	#-1,d0
.x:	movem.l	(sp)+,d2-d5/a2-a3
	tst.l	d0
	rts

; TlsFlush - (a2 = Conn) send what its SSL wrote to its memory BIO
; Out: d0 = 0 if sending failed (g_Error set) (CCR)
TlsFlush:
	movem.l	d2-d3/a3,-(sp)
.l:	move.l	c_WBio(a2),a0
	moveq	#BIO_CTRL_PENDING,d0
	moveq	#0,d1
	suba.l	a1,a1
	SSL	BIO_ctrl
	tst.l	d0
	ble.s	.ok
	cmp.l	#TW_NET,d0
	bls.s	.n
	move.l	#TW_NET,d0
.n:	move.l	c_WBio(a2),a0
	lea	g_TwNet(a4),a1
	SSL	BIO_read
	move.l	d0,d3
	ble.s	.ok
	lea	g_TwNet(a4),a3
.s:	move.l	c_Sock(a2),d0
	moveq	#1,d1
	bsr	WaitSocket
	beq.s	.x
	move.l	c_Sock(a2),d0
	move.l	a3,a0
	move.l	d3,d1
	moveq	#0,d2
	SOCK	send
	tst.l	d0
	ble.s	.err
	add.l	d0,a3
	sub.l	d0,d3
	bgt.s	.s
	bra.s	.l
.err:	SETERR	ERR_SEND
	moveq	#0,d0
	bra.s	.x
.ok:	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d3/a3
	rts

;--------------------------------------------------------------------
; TwRun - have the TLS process do job d0 on SSL a0 (TW_CONNECT: a1 =
; host name; TW_WRITE: d1 bytes from a1; TW_READ: up to d1 bytes into
; g_TwBuf) and wait for it; the window is served meanwhile.  Without
; the process the job is done here.
; Out: d0 = 1 done (g_TwRet, g_TwErr), 0 if the loader was stopped
;      (g_Error = ERR_ABORT; the job goes on: ConnClose leaves its SSL
;      to the process) (CCR)
;--------------------------------------------------------------------
TwRun:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	d0,d2
	move.l	a0,a2
	move.l	d1,d3
	move.l	a1,a3
.idle:	tst.l	g_TwBusy(a4)		; a job of a page stopped: its end
	beq.s	.go			; first
	bsr	TwWait
	bne.s	.idle
	bra.s	.x
.go:	bsr	TwOrphan
	move.l	d2,g_TwOp(a4)
	move.l	a2,g_TwSSL(a4)
	move.l	d3,g_TwLen(a4)
	cmp.l	#TW_WRITE,d2
	bne.s	.nw
	move.l	a3,a0
	lea	g_TwBuf(a4),a1
	move.l	d3,d0
	EXEC	CopyMem
.nw:	cmp.l	#TW_CONNECT,d2		; (the host for TlsVerify: set only
	bne.s	.nc			;  now, the job before may have
	move.l	a3,a0			;  used it)
	lea	g_TwHost(a4),a1
	move.l	#HOST_MAX-1,d0
	jsr	StrCopyN
.nc:	tst.l	g_TwTask(a4)
	bne.s	.task
	bsr	TwExec			; (no process: here)
	bra.s	.ok
.task:	moveq	#0,d0			; (a signal left from a job of a
	move.l	g_TlsSig(a4),d1		;  page stopped: gone)
	EXEC	SetSignal
	moveq	#1,d0
	move.l	d0,g_TwBusy(a4)
	move.l	g_TwTask(a4),a1
	move.l	g_TwSig(a4),d0
	EXEC	Signal
.w:	tst.l	g_TwBusy(a4)
	beq.s	.ok
	bsr	TwWait
	bne.s	.w
	bra.s	.x
.ok:	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; TwOrphan - (the TLS process idle) free the SSL of a connection
; closed while its job ran (ConnClose)
TwOrphan:
	move.l	g_TwOrphan(a4),d0
	beq.s	.x
	clr.l	g_TwOrphan(a4)
	move.l	d0,a0
	SSL	SSL_free
.x:	rts

; TwWait - wait for the TLS process's signal (in the loader the window
; is served meanwhile)
; Out: d0 = 0 if the loader was stopped (g_Error = ERR_ABORT) (CCR)
TwWait:
	move.l	g_TlsSig(a4),d0
	tst.l	g_TkIn(a4)
	beq.s	.own
	jsr	TaskWaitSig
	tst.l	d0
	bne.s	.x
	SETERR	ERR_ABORT
	moveq	#0,d0
.x:	rts
.own:	EXEC	Wait
	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; DnsCached - the address of host name a0 if it was looked up before
; Out: d0 = address or 0
;--------------------------------------------------------------------
DnsCached:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a3
	lea	g_DnsCache(a4),a2
	moveq	#DNS_ENTRIES-1,d2
.e:	tst.l	(a2)
	beq.s	.n
	move.l	a3,a0
	lea	4(a2),a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.n
	tst.b	d0
	bne.s	.c
	move.l	(a2),d0
	bra.s	.x
.n:	lea	DNS_SIZEOF(a2),a2
	dbf	d2,.e
	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

; DnsKeep - remember address d0 for host name a0 (oldest entry goes)
DnsKeep:
	move.l	g_DnsNext(a4),d1
	addq.l	#1,g_DnsNext(a4)
	and.l	#DNS_ENTRIES-1,d1
	mulu.w	#DNS_SIZEOF,d1
	lea	g_DnsCache(a4),a1
	add.l	d1,a1
	clr.l	(a1)
	move.l	a0,-(sp)		; (names too long are not kept)
	moveq	#-1,d1
.l:	addq.l	#1,d1
	tst.b	(a0)+
	bne.s	.l
	move.l	(sp)+,a0
	cmp.l	#DNS_NAME-1,d1
	bhi.s	.x
	move.l	d0,(a1)+
.c:	move.b	(a0)+,(a1)+
	bne.s	.c
.x:	rts

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
	jsr	Alloc
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
	EXEC	Forbid
	tst.l	g_TwBusy(a4)		; its job still under way (the page
	beq.s	.own			; was stopped): freed once that ends
	move.l	c_SSL(a2),d0		; (TwOrphan; here: AmiSSL frees in the
	cmp.l	g_TwSSL(a4),d0		;  task that allocated)
	bne.s	.own
	move.l	d0,g_TwOrphan(a4)
	EXEC	Permit
	bra.s	.nossl
.own:	EXEC	Permit
	bsr	TlsKeepSession		; (resumed next time)
	move.l	c_SSL(a2),a0
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
	jsr	Free
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; WaitSocket - wait until a socket is readable (d1=0) or writable (d1=1)
; In:  d0 = socket, d1 = direction
; Out: d0 = 1 ready, 0 on timeout/abort/error (g_Error set)
;--------------------------------------------------------------------
WaitSocket:
	movem.l	d2-d4/a2-a3,-(sp)
	tst.l	g_TkIn(a4)		; in the loader: the event loop waits
	beq.s	.own			; for it (and serves the window)
	jsr	TaskWaitSock
	tst.l	d0
	bgt	.ready
	bmi	.err
	tst.l	g_TkAbort(a4)
	bne	.abort
	bra	.timeout
.own:	move.l	d0,d2			; socket
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
	tst.l	c_SSL(a2)
	beq.s	.plain
	move.l	d3,d1			; TLS: a buffer at a time (EPIPE
	cmp.l	#CONN_BUFSIZE,d1	; here: the server gave up waiting
	bls.s	.t			; for a slow handshake)
	move.l	#CONN_BUFSIZE,d1
.t:	move.l	a2,a0
	move.l	a3,a1
	moveq	#TW_WRITE,d0
	bsr	TlsDo
	bgt.s	.sent
	bra.s	.fail
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
	tst.l	c_SSL(a2)
	beq.s	.wait
	move.l	c_SSL(a2),a0		; TLS: data decrypted already is
	SSL	SSL_pending		; only copied (here); else the TLS
	tst.l	d0			; process decrypts the next record
	ble.s	.tjob
	move.l	c_SSL(a2),a0
	lea	c_Buf(a2),a1
	move.l	#CONN_BUFSIZE,d0
	SSL	SSL_read
	tst.l	d0
	bgt.s	.tgot
.tjob:	move.l	a2,a0
	moveq	#TW_READ,d0
	bsr	TlsDo
	bmi.s	.fail
	beq.s	.got
.tgot:	tst.l	c_Sess(a2)		; the first data: the session tickets
	beq.s	.got			; came before it; keep the session now
	move.l	d0,-(sp)		; (closed without close_notify, as many
	bsr	TlsKeepSession		;  servers do, it cannot be resumed)
	clr.l	c_Sess(a2)
	move.l	(sp)+,d0
	bra.s	.got
.wait:	move.l	c_Sock(a2),d0
	moveq	#0,d1
	bsr	WaitSocket
	beq.s	.fail
	move.l	c_Sock(a2),d0
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
