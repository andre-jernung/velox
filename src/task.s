;
; task.s - the loader: one coroutine in Velox's own process
;
; Loading (fetching a page, its style sheets and images, parsing and
; laying it out) runs on a stack of its own, as a coroutine of the
; event loop.  Where it would wait (for a socket in WaitSocket, for the
; image decoder process) it yields to the event loop instead, and while
; it computes it yields whenever a window message is waiting
; (TaskPoll).  So the window always comes first, and nothing needs
; locking: control changes hands only at those points, where the DOM,
; the runs and the view are consistent.
;
; The event loop resumes the loader when what it waits for is there.
; TaskAbort stops it: its waits return ERR_ABORT, and it unwinds through
; its normal error paths (closing connections, freeing buffers).
;
; Switching stacks: CoSwitch saves d2-d7/a2-a6 and calls exec's
; StackSwap, which keeps the task's stack bounds right and moves the
; return address to the other stack; the same call switches back.
;

	include	"velox.i"

	xdef	TaskInit,TaskExit,TaskStart,TaskResume,TaskAbort,TaskBusy
	xdef	TaskYield,TaskPoll,TaskWaitSock,TaskWaitSig,TaskLoopWait,TaskNow
	IFD	PROFILE
	xref	LogEvent
	ENDC

TASK_STACK	equ	65536		; (layout recurses over the DOM)

	section	code,code

;--------------------------------------------------------------------
; TaskInit - allocate the loader's stack
; Out: d0 = 0 if there is no memory for it (CCR set)
;--------------------------------------------------------------------
TaskInit:
	move.l	#TASK_STACK,d0
	moveq	#MEMF_ANY,d1
	EXEC	AllocMem
	move.l	d0,g_TkStack(a4)
	rts

;--------------------------------------------------------------------
; TaskExit - free the stack (the loader must be idle: TaskAbort)
;--------------------------------------------------------------------
TaskExit:
	move.l	g_TkStack(a4),d0
	beq.s	.x
	clr.l	g_TkStack(a4)
	move.l	d0,a1
	move.l	#TASK_STACK,d0
	EXEC	FreeMem
.x:	rts

;--------------------------------------------------------------------
; TaskStart - make a0 the loader's job; it starts when the event loop
; resumes it (the loader must be idle: TaskAbort)
; Out: d0 = 0 if there is no stack (CCR set)
;--------------------------------------------------------------------
TaskStart:
	move.l	a0,g_TkEntry(a4)
	move.l	g_TkStack(a4),d0
	beq.s	.x
	move.l	d0,g_TkSSS+stk_Lower(a4)
	add.l	#TASK_STACK,d0
	move.l	d0,g_TkSSS+stk_Upper(a4)
	move.l	d0,a0			; the first switch "returns" to
	move.l	#TkEntry,-(a0)		; TkEntry, with a4 = G
	lea	-11*4(a0),a0		; (d2-d7/a2-a6 as CoSwitch pops them)
	move.l	a4,8*4(a0)
	move.l	a0,g_TkSSS+stk_Pointer(a4)
	clr.l	g_TkAbort(a4)
	moveq	#LS_RUN,d0
	move.l	d0,g_TkState(a4)
.x:	rts

; TkEntry - the bottom of the loader's stack: run the job, then be idle
TkEntry:
	move.l	g_TkEntry(a4),a0
	jsr	(a0)
	clr.l	g_TkState(a4)		; LS_IDLE
.dead:	bsr.s	CoSwitch		; (never resumed: TaskStart begins
	bra.s	.dead			;  anew)

; CoSwitch - switch between the event loop's stack and the loader's
; (d0-d1/a0-a1 changed)
CoSwitch:
	movem.l	d2-d7/a2-a6,-(sp)
	lea	g_TkSSS(a4),a0
	move.l	4.w,a6
	jsr	_LVOStackSwap(a6)
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;--------------------------------------------------------------------
; TaskResume - (event loop) run the loader until it yields, if it is
; ready to run
;--------------------------------------------------------------------
TaskResume:
	cmp.l	#LS_RUN,g_TkState(a4)
	bne.s	.x
	IFD	PROFILE
	bsr	TaskNow			; (how long it runs: "gap" below)
	move.l	d0,g_TkT0(a4)
	ENDC
	moveq	#1,d0
	move.l	d0,g_TkIn(a4)
	bsr.s	CoSwitch
	clr.l	g_TkIn(a4)
	IFD	PROFILE
	bsr	TaskGap
	ENDC
.x:	rts

	IFD	PROFILE
; TaskGap - (profiling) the loader ran 0.14 s or more without yielding:
; log "gap TICKS" and "gapat ADDRESS" (where it yielded; "codebase" is
; TaskResume's address, to find it in a link map)
TaskGap:
	bsr	TaskNow
	sub.l	g_TkT0(a4),d0
	cmp.l	#7,d0
	blt.s	.x
	lea	LogGap(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	lea	LogGapAt(pc),a0
	suba.l	a1,a1
	move.l	g_TkWhere(a4),d0
	jsr	LogEvent
	lea	LogBase(pc),a0
	suba.l	a1,a1
	lea	TaskResume(pc),a1
	move.l	a1,d0
	suba.l	a1,a1
	jsr	LogEvent
.x:	rts
LogGap:		dc.b	"gap",0
LogGapAt:	dc.b	"gapat",0
LogBase:	dc.b	"codebase",0
	even
	ENDC

;--------------------------------------------------------------------
; TaskAbort - (event loop) stop the loader: resume it with its waits
; failing (ERR_ABORT) until its job has returned
;--------------------------------------------------------------------
TaskAbort:
	tst.l	g_TkIn(a4)		; (not from inside the loader)
	bne.s	.x
	tst.l	g_TkState(a4)
	beq.s	.x
	moveq	#1,d0
	move.l	d0,g_TkAbort(a4)
.l:	tst.l	g_TkState(a4)
	beq.s	.done
	moveq	#LS_RUN,d0
	move.l	d0,g_TkState(a4)
	bsr.s	TaskResume
	bra.s	.l
.done:	clr.l	g_TkAbort(a4)
.x:	rts

;--------------------------------------------------------------------
; TaskBusy - Out: d0 = 1 if the loader has a job (CCR set)
;--------------------------------------------------------------------
TaskBusy:
	tst.l	g_TkState(a4)
	sne	d0
	and.l	#1,d0
	rts

;--------------------------------------------------------------------
; TaskYield - (loader) let the event loop run, then go on
; Out: d0 = 1 if the loader is to stop (CCR set)
;--------------------------------------------------------------------
TaskYield:
	IFD	PROFILE
	move.l	(sp),g_TkWhere(a4)
	ENDC
	moveq	#LS_RUN,d0
	move.l	d0,g_TkState(a4)
	bsr.s	CoSwitch
	move.l	g_TkAbort(a4),d0
	rts

;--------------------------------------------------------------------
; TaskPoll - (loader, while computing) yield if a window message is
; waiting: the user comes first.  Cheap enough to call often.
; Out: d0 = 1 if the loader is to stop (CCR set)
;--------------------------------------------------------------------
TaskPoll:
	tst.l	g_TkIn(a4)
	beq.s	.no
	move.l	g_Window(a4),d0
	beq.s	.no
	move.l	d0,a0
	move.l	wd_UserPort(a0),a0
	lea	MP_MSGLIST(a0),a0
	cmp.l	LH_TAILPRED(a0),a0	; an empty list points to itself
	bne.s	TaskYield
.no:	move.l	g_TkAbort(a4),d0
	rts

;--------------------------------------------------------------------
; TaskWaitSock - (loader) wait until socket d0 is readable (d1 = 0) or
; writable (d1 = 1), for NET_TIMEOUT seconds; the event loop runs
; meanwhile
; Out: d0 = 1 ready, 0 timed out or stopped (g_TkAbort), -1 error
;--------------------------------------------------------------------
TaskWaitSock:
	IFD	PROFILE
	move.l	(sp),g_TkWhere(a4)
	ENDC
	tst.l	g_TkAbort(a4)
	bne.s	.stop
	move.l	d0,g_TkSock(a4)
	move.l	d1,g_TkDir(a4)
	bsr	TaskNow
	move.l	d0,g_TkSince(a4)
	moveq	#LS_SOCK,d0
	move.l	d0,g_TkState(a4)
	bsr.s	CoSwitch
	tst.l	g_TkAbort(a4)
	bne.s	.stop
	move.l	g_TkResult(a4),d0
	rts
.stop:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; TaskWaitSig - (loader) wait for one of the signals d0; the event loop
; runs meanwhile
; Out: d0 = the signals received, 0 if stopped (CCR set)
;--------------------------------------------------------------------
TaskWaitSig:
	IFD	PROFILE
	move.l	(sp),g_TkWhere(a4)
	ENDC
	tst.l	g_TkAbort(a4)
	bne.s	.stop
	move.l	d0,g_TkSigs(a4)
	moveq	#LS_SIG,d0
	move.l	d0,g_TkState(a4)
	bsr	CoSwitch
	tst.l	g_TkAbort(a4)
	bne.s	.stop
	move.l	g_TkGot(a4),d0
	rts
.stop:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; TaskLoopWait - (event loop) sleep until a window message, Ctrl-C,
; signals d0 (more of the event loop's), or what the loader waits for;
; that makes the loader ready to run
; Out: d0 = the signals received
;--------------------------------------------------------------------
TaskLoopWait:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	d0,d2
	or.l	g_WinSigMask(a4),d2
	or.l	#SIGBREAKF_CTRL_C,d2	; d2 = the signals
	move.l	g_TkState(a4),d0
	cmp.l	#LS_SOCK,d0
	beq.s	.sock
	cmp.l	#LS_SIG,d0
	bne.s	.plain
	or.l	g_TkSigs(a4),d2
.plain:	move.l	d2,d0
	EXEC	Wait
	move.l	d0,d3
	cmp.l	#LS_SIG,g_TkState(a4)
	bne.s	.x
	and.l	g_TkSigs(a4),d0
	beq.s	.x
	move.l	d0,g_TkGot(a4)
	bra.s	.run
.sock:	bsr	TaskNow			; time left: NET_TIMEOUT from the
	sub.l	g_TkSince(a4),d0	; start of the wait
	bpl.s	.pos
	add.l	#24*60*3000,d0		; (past midnight)
.pos:	divu.l	#50,d0
	moveq	#NET_TIMEOUT,d1
	sub.l	d0,d1
	bgt.s	.left
	moveq	#0,d3			; timed out
	clr.l	g_TkResult(a4)
	bra.s	.run
.left:	lea	g_Timeval(a4),a3
	move.l	d1,(a3)
	clr.l	4(a3)
	lea	g_FdSet(a4),a0
	moveq	#7,d0
.clr:	clr.l	(a0)+
	dbf	d0,.clr
	move.l	g_TkSock(a4),d4
	lea	g_FdSet(a4),a0
	move.l	d4,d0
	lsr.l	#5,d0
	lsl.l	#2,d0
	add.l	d0,a0
	move.l	(a0),d1
	bset	d4,d1
	move.l	d1,(a0)
	move.l	d2,-(sp)		; in: signals; out: received
	move.l	sp,d1
	move.l	d4,d0
	addq.l	#1,d0			; nfds
	lea	g_FdSet(a4),a0		; read set ...
	suba.l	a1,a1
	tst.l	g_TkDir(a4)
	beq.s	.rd
	move.l	a0,a1			; ... or write set
	suba.l	a0,a0
.rd:	suba.l	a2,a2
	SOCK	WaitSelect
	move.l	(sp)+,d3		; signals received
	tst.l	d0
	bgt.s	.ready
	bmi.s	.err
	tst.l	d3			; neither: timed out
	bne.s	.x
	clr.l	g_TkResult(a4)
	bra.s	.run
.err:	moveq	#-1,d0
	move.l	d0,g_TkResult(a4)
	bra.s	.run
.ready:	moveq	#1,d0
	move.l	d0,g_TkResult(a4)
.run:	moveq	#LS_RUN,d0
	move.l	d0,g_TkState(a4)
.x:	move.l	d3,d0
	movem.l	(sp)+,d2-d4/a2-a3
	rts

; TaskNow - Out: d0 = the time of day in ticks (1/50 s)
TaskNow:
	lea	-12(sp),sp
	move.l	sp,d1
	DOS	DateStamp
	move.l	4(sp),d0		; minutes * 3000 + ticks
	mulu.l	#3000,d0
	add.l	8(sp),d0
	lea	12(sp),sp
	rts
