;
; mouse.s - move the mouse pointer and use the left button, for tests
;
;   mouse X Y            pointer to X/Y on the default public screen
;   mouse X Y DOWN       ... then press the left button
;   mouse X Y DRAG       pointer to X/Y with the button held
;   mouse X Y UP         pointer to X/Y, then release the button
;
; The events go through input.device, as if the mouse had done it.
;

	include	"exec/types.i"
	include	"exec/io.i"
	include	"devices/input.i"
	include	"devices/inputevent.i"
	include	"intuition/screens.i"
	include	"lvo/exec_lib.i"
	include	"lvo/dos_lib.i"
	include	"lvo/intuition_lib.i"

ARG_X		equ	0
ARG_Y		equ	4
ARG_DOWN	equ	8
ARG_DRAG	equ	12
ARG_UP		equ	16

	section	code,code

; a5 = DOSBase, a3 = IntuitionBase, d6 = RDArgs, d5 = screen,
; d4 = port, a2 = request, d7 = return code
Start:
	movem.l	d2-d7/a2-a6,-(sp)
	moveq	#20,d7
	moveq	#0,d6
	moveq	#0,d5
	moveq	#0,d4
	sub.l	a2,a2
	sub.l	a3,a3
	move.l	4.w,a6
	lea	DosName(pc),a1
	moveq	#37,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,a5
	tst.l	d0
	beq	.x
	lea	IntName(pc),a1
	moveq	#37,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,a3
	tst.l	d0
	beq	.fail
	lea	-20(sp),sp		; arguments
	move.l	sp,a0
	moveq	#4,d0
.cl:	clr.l	(a0)+
	dbf	d0,.cl
	lea	Template(pc),a0
	move.l	a0,d1
	move.l	sp,d2
	moveq	#0,d3
	move.l	a5,a6
	jsr	_LVOReadArgs(a6)
	move.l	d0,d6
	beq	.noargs
	suba.l	a0,a0
	move.l	a3,a6
	jsr	_LVOLockPubScreen(a6)
	move.l	d0,d5
	beq	.noargs
	move.l	4.w,a6
	jsr	_LVOCreateMsgPort(a6)
	move.l	d0,d4
	beq	.noargs
	move.l	d4,a0
	moveq	#IOSTD_SIZE,d0
	jsr	_LVOCreateIORequest(a6)
	move.l	d0,a2
	tst.l	d0
	beq	.noargs
	lea	InputName(pc),a0
	moveq	#0,d0
	move.l	a2,a1
	moveq	#0,d1
	jsr	_LVOOpenDevice(a6)
	tst.l	d0
	bne	.noargs
	; the pointer position
	lea	Pixel,a0
	move.l	d5,(a0)+
	move.l	ARG_X(sp),a1
	move.w	2(a1),(a0)+
	move.l	ARG_Y(sp),a1
	move.w	2(a1),(a0)
	lea	Event,a0
	move.b	#IECLASS_NEWPOINTERPOS,ie_Class(a0)
	move.b	#IESUBCLASS_PIXEL,ie_SubClass(a0)
	clr.w	ie_Code(a0)
	clr.w	ie_Qualifier(a0)
	tst.l	ARG_DRAG(sp)
	bne.s	.held
	tst.l	ARG_UP(sp)
	beq.s	.mv
.held:	move.w	#IEQUALIFIER_LEFTBUTTON,ie_Qualifier(a0)
.mv:	lea	Pixel,a1
	move.l	a1,ie_EventAddress(a0)
	bsr	.send
	; the button
	moveq	#0,d0
	tst.l	ARG_DOWN(sp)
	beq.s	.nd
	move.w	#IECODE_LBUTTON,d0
.nd:	tst.l	ARG_UP(sp)
	beq.s	.nu
	move.w	#IECODE_LBUTTON|IECODE_UP_PREFIX,d0
.nu:	tst.w	d0
	beq.s	.done
	lea	Event,a0
	move.b	#IECLASS_RAWMOUSE,ie_Class(a0)
	clr.b	ie_SubClass(a0)
	move.w	d0,ie_Code(a0)
	move.w	#IEQUALIFIER_RELATIVEMOUSE,d1
	cmp.w	#IECODE_LBUTTON,d0
	bne.s	.q
	or.w	#IEQUALIFIER_LEFTBUTTON,d1
.q:	move.w	d1,ie_Qualifier(a0)
	clr.l	ie_EventAddress(a0)	; (ie_X = ie_Y = 0)
	bsr	.send
.done:	moveq	#0,d7
	move.l	a2,a1
	move.l	4.w,a6
	jsr	_LVOCloseDevice(a6)
.noargs:
	lea	20(sp),sp
	move.l	4.w,a6
	move.l	a2,d0
	beq.s	.nr
	move.l	a2,a0
	jsr	_LVODeleteIORequest(a6)
.nr:	tst.l	d4
	beq.s	.np
	move.l	d4,a0
	jsr	_LVODeleteMsgPort(a6)
.np:	tst.l	d5
	beq.s	.ns
	suba.l	a0,a0
	move.l	d5,a1
	move.l	a3,a6
	jsr	_LVOUnlockPubScreen(a6)
.ns:	tst.l	d6
	beq.s	.na
	move.l	d6,d1
	move.l	a5,a6
	jsr	_LVOFreeArgs(a6)
.na:
.fail:	move.l	4.w,a6
	move.l	a3,d0
	beq.s	.ni
	move.l	a3,a1
	jsr	_LVOCloseLibrary(a6)
.ni:	move.l	a5,a1
	jsr	_LVOCloseLibrary(a6)
.x:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts
.send:	move.w	#IND_WRITEEVENT,IO_COMMAND(a2)
	lea	Event,a0
	move.l	a0,IO_DATA(a2)
	move.l	#ie_SIZEOF,IO_LENGTH(a2)
	move.l	a2,a1
	move.l	4.w,a6
	jmp	_LVODoIO(a6)

DosName:	dc.b	"dos.library",0
IntName:	dc.b	"intuition.library",0
InputName:	dc.b	"input.device",0
Template:	dc.b	"X/N/A,Y/N/A,DOWN/S,DRAG/S,UP/S",0
	even

	section	bss,bss
Event:		ds.b	ie_SIZEOF
Pixel:		ds.b	IEPointerPixel_SIZEOF
