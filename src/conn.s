;
; conn.s - buffered byte streams over TCP (bsdsocket.library), TLS
;          (later) or a DOS file (for offline tests)
;
; All waits on the network go through WaitSelect() together with
; g_AbortMask, so the user can interrupt a transfer.  When one of those
; signals arrives, g_NetSigHook (if set) decides whether to abort.
;

	include	"velox.i"
	include	"dos/dostags.i"

	xdef	NetExit,ConnOpen,ConnOpenFile,ConnClose,TlsExit
	xdef	ConnWrite,ConnRead,ConnGetByte,ConnReadLine
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	Alloc,Free,HttpCloseKept,LogEvent,G,TaskWaitSig

AmiSSL_SocketBase	equ	TAG_USER+$01
AmiSSL_ErrNoPtr		equ	TAG_USER+$0b
AmiSSL_UsesOpenSSLStructs equ	TAG_USER+$0c
AmiSSL_GetAmiSSLBase	equ	TAG_USER+$0d
AmiSSL_GetAmiSSLExtBase	equ	TAG_USER+$0e

AF_INET		equ	2
SOCK_STREAM	equ	1
INADDR_NONE	equ	-1

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
TlsChildName:	dc.b	"Velox TLS setup",0
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
	move.l	a2,a0			; (this blocks: hence the cache)
	SOCK	gethostbyname
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
; TlsPrepare - (the network is used) open AmiSSL and have the SSL
; context made by a process of its own below the window's priority
; (TlsChild): SSL_CTX_new takes 6.6 s on a stock A1200, and nothing
; waits for it unless a TLS connection needs it first (TlsInit)
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
	move.l	g_TlsSigBit(a4),d0	; no process: made here
	EXEC	FreeSignal
.here:	moveq	#-1,d0
	move.l	d0,g_TlsSigBit(a4)
	bsr	TlsCtx
	bsr	TlsMade
	bra.s	.xx
.fail:	bsr	TlsExit
	moveq	#-1,d0
	move.l	d0,g_SslState(a4)
.xx:	movem.l	(sp)+,d2/a2
.x:	rts

; TlsChild - the process that makes the context (shares Velox's AmiSSL)
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
	suba.l	a0,a0
	move.l	g_AmiSSLBase(a4),a6
	jsr	_LVOCleanupAmiSSLA(a6)
.done:	EXEC	Forbid			; (gone before Velox goes on)
	move.l	g_TlsMain(a4),a1
	move.l	g_TlsSig(a4),d0
	EXEC	Signal
	moveq	#0,d0
	rts

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

; TlsChildDone - the child signalled: its signal freed, the result
TlsChildDone:
	move.l	g_TlsSigBit(a4),d0
	bmi.s	.n
	EXEC	FreeSignal
	moveq	#-1,d0
	move.l	d0,g_TlsSigBit(a4)
.n:	bra.s	TlsMade

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
	lea	VarCiphers(pc),a0	; Velox/TlsCiphers: TLS 1.3 suites
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
	move.l	g_TlsSigBit(a4),d0
	bmi.s	.nc
	move.l	g_TlsSig(a4),d0
	EXEC	Wait
	move.l	g_TlsSigBit(a4),d0
	EXEC	FreeSignal
	moveq	#-1,d0
	move.l	d0,g_TlsSigBit(a4)
	clr.l	g_SslState(a4)
.nc:	move.l	g_SslCtx(a4),d0
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
	bra.s	.conn0
.ip:	SSL	X509_VERIFY_PARAM_set1_ip_asc
.conn0:	bsr	TlsSessFor		; a session of this host and port:
	move.l	d0,c_Sess(a2)		; resumed (no certificate to check)
	beq.s	.conn
	move.l	d0,a0
	move.l	ts_Gen(a0),c_SessGen(a2)
	move.l	ts_Sess(a0),d0
	beq.s	.conn
	move.l	d0,a1
	move.l	c_SSL(a2),a0
	SSL	SSL_set_session
	lea	LogSessUse(pc),a0	; (for tests)
	move.l	g_TlsHost(a4),a1
	jsr	LogEvent
.conn:
	move.l	c_SSL(a2),a0
	SSL	SSL_connect
	cmp.l	#1,d0
	beq.s	.ok
	bsr	TlsWait			; waiting for the server?
	bgt.s	.conn
	beq.s	.x0			; (aborted, timed out)
	move.l	c_SSL(a2),a0		; failed: was it the certificate?
	SSL	SSL_get_verify_result
	tst.l	d0
	beq.s	.fail
	SETERR	ERR_CERT
	bra.s	.x0
.fail:	SETERR	ERR_TLS
.x0:	moveq	#0,d0
	bra.s	.x
.ok:	move.l	c_SSL(a2),a0		; (for tests: "tls host 1" when the
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
	even

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
; TlsWait - after an AmiSSL call on Conn a2 returned d0 (<= 0): if it
; only has to wait for the socket (non-blocking), wait for it
; Out: d0 = 1 to try again, 0 if the wait failed (g_Error set), -1 on
;      any other error (CCR set)
;--------------------------------------------------------------------
TlsWait:
	move.l	c_SSL(a2),a0
	SSL	SSL_get_error
	moveq	#0,d1			; readable
	cmp.l	#2,d0			; SSL_ERROR_WANT_READ
	beq.s	.w
	moveq	#1,d1			; writable
	cmp.l	#3,d0			; SSL_ERROR_WANT_WRITE
	beq.s	.w
	moveq	#-1,d0
	rts
.w:	move.l	c_Sock(a2),d0
	bra	WaitSocket

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
	move.l	c_SSL(a2),d0
	beq.s	.plain
	move.l	d0,a0			; TLS
	move.l	a3,a1
	move.l	d3,d0
	SSL	SSL_write
	tst.l	d0
	bgt.s	.sent
	bsr	TlsWait			; (the same again when it can go)
	bgt.s	.l
	beq.s	.fail
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
	ble.s	.tno
	tst.l	c_Sess(a2)		; the first data: the session tickets
	beq.s	.got			; came before it; keep the session now
	move.l	d0,-(sp)		; (closed without close_notify, as many
	bsr	TlsKeepSession		;  servers do, it cannot be resumed)
	clr.l	c_Sess(a2)
	move.l	(sp)+,d0
	bra.s	.got
.tno:
	move.l	d0,-(sp)		; why not?  closed = end of stream
	move.l	c_SSL(a2),a0
	SSL	SSL_get_error
	cmp.l	#6,d0			; SSL_ERROR_ZERO_RETURN
	beq.s	.eos1
	cmp.l	#5,d0			; SSL_ERROR_SYSCALL (closed without
	beq.s	.eos1			;   close_notify, as many servers do)
	movem.l	(sp)+,d0
	bsr	TlsWait			; a record not complete yet: wait
	bgt.s	.tls
	beq.s	.fail
	bra.s	.err
.eos1:	addq.l	#4,sp
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
