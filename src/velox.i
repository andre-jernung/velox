;
; velox.i - common include for every Velox module
;
; Pulls in the NDK definitions we use, the global data layout and the
; library-call macros.  Every .s file includes this first.
;
; Register conventions (see CLAUDE.md):
;   a4        = pointer to the global data block G, never changed
;   d0-d1/a0-a1/a6 = scratch, may be destroyed by any routine
;   d2-d7/a2-a3/a5 = preserved by every routine
;   Results come back in d0; the CCR reflects d0 unless documented otherwise.
;

	IFND	VELOX_I
VELOX_I	SET	1

	include	"exec/types.i"
	include	"exec/ports.i"
	include	"dos/dos.i"
	include	"dos/dosextens.i"
	include	"intuition/intuition.i"
	include	"graphics/rastport.i"
	include	"workbench/startup.i"
	include	"utility/tagitem.i"

	include	"lvo/exec_lib.i"
	include	"lvo/dos_lib.i"
	include	"lvo/intuition_lib.i"
	include	"lvo/graphics_lib.i"

;--------------------------------------------------------------------
; Global data block, addressed as xxx(a4)
;--------------------------------------------------------------------
	RSRESET
g_SysBase	rs.l	1
g_DOSBase	rs.l	1
g_IntuitionBase	rs.l	1
g_GfxBase	rs.l	1
g_WBMsg		rs.l	1	; WBStartup message, 0 when run from CLI
g_Window	rs.l	1	; main window
g_WinSigMask	rs.l	1	; signal mask of the window's UserPort
g_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Library call macros.  They load a6 themselves, so a6 is always scratch.
;--------------------------------------------------------------------
EXEC	MACRO
	move.l	g_SysBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

DOS	MACRO
	move.l	g_DOSBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

INTUI	MACRO
	move.l	g_IntuitionBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

GFX	MACRO
	move.l	g_GfxBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

RC_OK		equ	0
RC_FAIL		equ	20

	ENDC	; VELOX_I
