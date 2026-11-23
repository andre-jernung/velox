;
; wbrun.s - start a program the way Workbench does, for tests
;
;   wbrun PROG
;
; Loads PROG, starts it as a new process without a CLI and sends it a
; WBStartup message whose argument is PROG (lock on its drawer + name),
; so the program finds its icon and tool types.  Returns when the
; program has ended (the message came back).
;

	include	"exec/types.i"
	include	"exec/memory.i"
	include	"exec/ports.i"
	include	"exec/nodes.i"
	include	"dos/dos.i"
	include	"dos/dosextens.i"
	include	"dos/dostags.i"
	include	"workbench/startup.i"
	include	"lvo/exec_lib.i"
	include	"lvo/dos_lib.i"

MSGSIZE	equ	sm_SIZEOF+wa_SIZEOF

CALLDOS	MACRO
	move.l	a5,a6
	jsr	_LVO\1(a6)
	ENDM
CALLEXEC MACRO
	move.l	4.w,a6
	jsr	_LVO\1(a6)
	ENDM

	section	code,code

; d7 = return code, a5 = DOSBase (always), d6 = RDArgs, d5 = drawer lock,
; d4 = name, d3 = seglist, a3 = reply port, a2 = message
Start:
	movem.l	d2-d7/a2-a6,-(sp)
	moveq	#RETURN_FAIL,d7
	moveq	#0,d6
	moveq	#0,d5
	moveq	#0,d3
	sub.l	a3,a3
	sub.l	a2,a2
	move.l	4.w,a6
	lea	DosName(pc),a1
	moveq	#37,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,a5
	tst.l	d0
	beq	.x
	clr.l	-(sp)			; argument array
	lea	Template(pc),a0
	move.l	a0,d1
	move.l	sp,d2
	moveq	#0,d3
	CALLDOS	ReadArgs
	move.l	(sp)+,a0		; PROG
	move.l	d0,d6
	beq	.fail
	move.l	a0,d4
	move.l	d4,d1			; the drawer: parent of PROG
	moveq	#ACCESS_READ,d2
	CALLDOS	Lock
	move.l	d0,d1
	beq	.fail
	move.l	d0,d2
	CALLDOS	ParentDir
	move.l	d0,d5
	move.l	d2,d1
	CALLDOS	UnLock
	tst.l	d5
	beq	.fail
	move.l	d4,d1
	CALLDOS	LoadSeg
	move.l	d0,d3
	beq	.fail
	move.l	d4,d1			; d4 = name part
	CALLDOS	FilePart
	move.l	d0,d4
	CALLEXEC	CreateMsgPort
	move.l	d0,a3
	tst.l	d0
	beq	.fail
	move.l	#MSGSIZE,d0
	move.l	#MEMF_PUBLIC|MEMF_CLEAR,d1
	CALLEXEC	AllocVec
	move.l	d0,a2
	tst.l	d0
	beq	.fail
	move.l	d5,d1
	CALLDOS	DupLock
	move.l	d0,d2			; the process's current dir
	clr.l	-(sp)			; TAG_DONE
	move.l	d2,-(sp)
	move.l	#NP_CurrentDir,-(sp)
	move.l	#16384,-(sp)
	move.l	#NP_StackSize,-(sp)
	move.l	d4,-(sp)
	move.l	#NP_Name,-(sp)
	clr.l	-(sp)
	move.l	#NP_FreeSeglist,-(sp)
	move.l	d3,-(sp)
	move.l	#NP_Seglist,-(sp)
	move.l	sp,d1
	CALLDOS	CreateNewProc
	lea	44(sp),sp
	tst.l	d0
	bne.s	.started
	move.l	d2,d1
	CALLDOS	UnLock
	bra.s	.fail
.started:
	move.l	d0,a0
	lea	pr_MsgPort(a0),a0
	move.b	#NT_MESSAGE,LN_TYPE(a2)
	move.l	a3,MN_REPLYPORT(a2)
	move.w	#MSGSIZE,MN_LENGTH(a2)
	move.l	a0,sm_Process(a2)
	move.l	d3,sm_Segment(a2)
	moveq	#1,d0
	move.l	d0,sm_NumArgs(a2)
	lea	sm_SIZEOF(a2),a1
	move.l	a1,sm_ArgList(a2)
	move.l	d5,wa_Lock(a1)
	move.l	d4,wa_Name(a1)
	move.l	a2,a1
	CALLEXEC	PutMsg
	move.l	a3,a0
	CALLEXEC	WaitPort
	move.l	a3,a0
	CALLEXEC	GetMsg
	moveq	#RETURN_OK,d7
.fail:	move.l	a2,d0
	beq.s	.c1
	move.l	a2,a1
	CALLEXEC	FreeVec
.c1:	move.l	a3,d0
	beq.s	.c2
	move.l	a3,a0
	CALLEXEC	DeleteMsgPort
.c2:	move.l	d3,d1
	beq.s	.c3
	CALLDOS	UnLoadSeg
.c3:	move.l	d5,d1
	beq.s	.c4
	CALLDOS	UnLock
.c4:	move.l	d6,d1
	beq.s	.c5
	CALLDOS	FreeArgs
.c5:	move.l	a5,a1
	move.l	4.w,a6
	jsr	_LVOCloseLibrary(a6)
.x:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

DosName:	dc.b	"dos.library",0
Template:	dc.b	"PROG/A",0
