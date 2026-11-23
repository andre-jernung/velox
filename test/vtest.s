;
; vtest.s - headless test driver for the Velox core modules (runs under
; vamos).  Reads a script; each line is "command arg..." and the result
; is printed after the echoed line.  Lines that are empty or start
; with '#' are echoed unchanged.  An argument written as "" is empty.
;
;   parse URL            UrlParse
;   resolve BASE REF     UrlResolve
;   fixup TEXT           UrlFixup
;   http FILE            HttpReadResponse on a canned response file
;   httpinfo FILE        same, but print body length and checksum only
;

	include	"velox.i"

	xdef	G
	xref	MemInit,MemExit,UrlParse,UrlResolve,UrlFixup
	xref	ConnOpenFile,ConnClose,ConnReadLine,HttpReadResponse
	xref	PutStr,PutBuf,PutNum,PutNL,PutChar,FlushOut,ErrorText

T_LINEMAX	equ	2048
T_MAXWORDS	equ	4

	section	code,code

Start:
	movem.l	d2-d7/a2-a6,-(sp)
	lea	G,a4
	move.l	4.w,a6
	move.l	a6,g_SysBase(a4)
	moveq	#RC_FAIL,d7
	lea	DosName(pc),a1
	moveq	#39,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,g_DOSBase(a4)
	beq	.x
	bsr	MemInit
	beq	.closedos
	DOS	Output
	move.l	d0,g_StdOut(a4)
	lea	Template(pc),a0
	move.l	a0,d1
	lea	g_ArgArray(a4),a0
	move.l	a0,d2
	moveq	#0,d3
	DOS	ReadArgs
	move.l	d0,g_RDArgs(a4)
	beq.s	.argerr
	move.l	g_ArgArray(a4),a0
	bsr	ConnOpenFile
	move.l	d0,T_Conn
	beq.s	.fileerr
.line:	move.l	T_Conn,a0
	lea	T_Line,a1
	move.l	#T_LINEMAX,d0
	bsr	ConnReadLine
	tst.l	d0
	bmi.s	.eof
	bsr	DoLine
	bra.s	.line
.eof:	move.l	T_Conn,a0
	bsr	ConnClose
	moveq	#RC_OK,d7
	bra.s	.freeargs
.fileerr:
	lea	MsgNoFile(pc),a0
	bsr	PutStr
.freeargs:
	move.l	g_RDArgs(a4),d1
	DOS	FreeArgs
	bra.s	.mem
.argerr:
	DOS	IoErr
	move.l	d0,d1
	moveq	#0,d2
	DOS	PrintFault
.mem:	bsr	FlushOut
	bsr	MemExit
.closedos:
	move.l	g_DOSBase(a4),a1
	EXEC	CloseLibrary
.x:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

DosName:	dc.b	"dos.library",0
Template:	dc.b	"FILE/A",0
MsgNoFile:	dc.b	"vtest: cannot open script",10,0
	even

;--------------------------------------------------------------------
; DoLine - run one script line from T_Line
;--------------------------------------------------------------------
DoLine:
	movem.l	d2/a2-a3,-(sp)
	lea	T_Line,a0
	bsr	PutStr
	lea	T_Line,a0
	move.b	(a0),d0
	beq	.nl
	cmp.b	#'#',d0
	beq	.nl

	; split into words
	lea	T_Words,a1
	moveq	#T_MAXWORDS-1,d0
	lea	Empty(pc),a2
.cw:	move.l	a2,(a1)+
	dbf	d0,.cw
	lea	T_Line,a0
	lea	T_Words,a1
	moveq	#T_MAXWORDS-1,d2
.w:	cmp.b	#' ',(a0)
	bne.s	.ws
	addq.l	#1,a0
	bra.s	.w
.ws:	tst.b	(a0)
	beq.s	.split
	move.l	a0,(a1)+
	cmp.b	#'"',(a0)
	bne.s	.we
	cmp.b	#'"',1(a0)
	bne.s	.we
	move.l	a2,-4(a1)		; "" = empty argument
.we:	move.b	(a0),d0
	beq.s	.split
	cmp.b	#' ',d0
	beq.s	.wend
	addq.l	#1,a0
	bra.s	.we
.wend:	clr.b	(a0)+
	dbf	d2,.w
.split:
	lea	ResultSep(pc),a0
	bsr	PutStr
	lea	Commands(pc),a2
.cmd:	tst.w	(a2)
	beq.s	.unknown
	lea	Commands(pc),a0
	add.w	(a2),a0
	move.l	T_Words,a1
	bsr	StrEq
	bne.s	.found
	addq.l	#4,a2
	bra.s	.cmd
.found:	lea	Commands(pc),a0
	add.w	2(a2),a0
	jsr	(a0)
	bra.s	.nl
.unknown:
	lea	MsgUnknown(pc),a0
	bsr	PutStr
.nl:	bsr	PutNL
	movem.l	(sp)+,d2/a2-a3
	rts

Commands:
	dc.w	CnParse-Commands,CmdParse-Commands
	dc.w	CnResolve-Commands,CmdResolve-Commands
	dc.w	CnFixup-Commands,CmdFixup-Commands
	dc.w	CnHttp-Commands,CmdHttp-Commands
	dc.w	CnHttpInfo-Commands,CmdHttpInfo-Commands
	dc.w	0

CnParse:	dc.b	"parse",0
CnResolve:	dc.b	"resolve",0
CnFixup:	dc.b	"fixup",0
CnHttp:		dc.b	"http",0
CnHttpInfo:	dc.b	"httpinfo",0
Empty:		dc.b	0
ResultSep:	dc.b	" => ",0
MsgUnknown:	dc.b	"unknown command",0
	even

; StrEq - In: a0, a1 strings; Out: d0 = 1 if equal
StrEq:
.l:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.no
	tst.b	d0
	bne.s	.l
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; PutError - print "ERROR <message>"
PutError:
	lea	MsgError(pc),a0
	bsr	PutStr
	move.l	g_Error(a4),d0
	bsr	ErrorText
	bra	PutStr

MsgError:	dc.b	"ERROR ",0
	even

;--------------------------------------------------------------------
CmdParse:
	move.l	T_Words+4,a0
	lea	g_Parts(a4),a1
	bsr	UrlParse
	beq.s	PutError
	lea	MsgScheme(pc),a0
	bsr	PutStr
	move.l	g_Parts+up_Scheme(a4),d0
	bsr	PutNum
	lea	MsgPort(pc),a0
	bsr	PutStr
	move.l	g_Parts+up_Port(a4),d0
	bsr	PutNum
	lea	MsgHost(pc),a0
	bsr	PutStr
	lea	g_Parts+up_Host(a4),a0
	bsr	PutStr
	lea	MsgPath(pc),a0
	bsr	PutStr
	move.l	g_Parts+up_Path(a4),a0
	move.l	g_Parts+up_PathLen(a4),d0
	bsr	PutBuf
	moveq	#']',d0
	bra	PutChar

MsgScheme:	dc.b	"scheme=",0
MsgPort:	dc.b	" port=",0
MsgHost:	dc.b	" host=",0
MsgPath:	dc.b	" path=[",0
	even

CmdResolve:
	move.l	a2,-(sp)
	move.l	T_Words+4,a0
	move.l	T_Words+8,a1
	lea	g_UrlTmp2(a4),a2
	bsr	UrlResolve
	move.l	(sp)+,a2
	tst.l	d0
	beq.s	PutError
	lea	g_UrlTmp2(a4),a0
	bra	PutStr

CmdFixup:
	move.l	T_Words+4,a0
	lea	g_UrlTmp2(a4),a1
	bsr	UrlFixup
	lea	g_UrlTmp2(a4),a0
	bra	PutStr

CmdHttpInfo:
	st	T_NoBody
	bsr.s	CmdHttp
	sf	T_NoBody
	rts

CmdHttp:
	movem.l	d2-d3/a2,-(sp)
	move.l	T_Words+4,a0
	bsr	ConnOpenFile
	move.l	d0,a2
	tst.l	d0
	beq.s	.err
	move.l	a2,a0
	bsr	HttpReadResponse
	move.l	d0,-(sp)
	move.l	a2,a0
	bsr	ConnClose
	move.l	(sp)+,d0
	beq.s	.err
	lea	g_Resp(a4),a2
	lea	MsgStatus(pc),a0
	bsr	PutStr
	move.l	r_Status(a2),d0
	bsr	PutNum
	lea	MsgLength(pc),a0
	bsr	PutStr
	move.l	r_Length(a2),d0
	bsr	PutNum
	lea	MsgChunked(pc),a0
	bsr	PutStr
	move.l	r_Chunked(a2),d0
	bsr	PutNum
	lea	MsgType(pc),a0
	bsr	PutStr
	lea	r_CType(a2),a0
	bsr	PutStr
	lea	MsgLoc(pc),a0
	bsr	PutStr
	lea	r_Location(a2),a0
	bsr	PutStr
	lea	MsgBody(pc),a0
	bsr	PutStr
	move.l	r_Body+buf_Len(a2),d0
	bsr	PutNum
	tst.b	T_NoBody
	beq.s	.withbody
	lea	MsgSum(pc),a0		; checksum: sum of bytes * position
	bsr	PutStr
	move.l	r_Body+buf_Data(a2),a0
	move.l	r_Body+buf_Len(a2),d1
	moveq	#0,d0
	moveq	#0,d2
.sum:	subq.l	#1,d1
	bmi.s	.sumd
	moveq	#0,d3
	move.b	(a0)+,d3
	addq.l	#1,d2
	mulu.l	d2,d3
	add.l	d3,d0
	bra.s	.sum
.sumd:	bsr	PutNum
	movem.l	(sp)+,d2-d3/a2
	rts
.withbody:
	lea	MsgBodyOpen(pc),a0
	bsr	PutStr
	move.l	r_Body+buf_Data(a2),d0
	beq.s	.nobody
	move.l	d0,a0
	move.l	r_Body+buf_Len(a2),d0
	bsr	PutBuf
.nobody:
	lea	MsgBodyClose(pc),a0
	bsr	PutStr
	movem.l	(sp)+,d2-d3/a2
	rts
.err:	movem.l	(sp)+,d2-d3/a2
	bra	PutError

MsgStatus:	dc.b	"status=",0
MsgLength:	dc.b	" length=",0
MsgChunked:	dc.b	" chunked=",0
MsgType:	dc.b	" type=[",0
MsgLoc:		dc.b	"] location=[",0
MsgBody:	dc.b	"] body=",0
MsgBodyOpen:	dc.b	10,"<<<",0
MsgBodyClose:	dc.b	">>>",0
MsgSum:		dc.b	" sum=",0
	even

;====================================================================
	section	bss,bss
;====================================================================
G:		ds.b	g_SIZEOF
T_Conn:		ds.l	1
T_NoBody:	ds.b	2
T_Words:	ds.l	T_MAXWORDS
T_Line:		ds.b	T_LINEMAX
