;
; css.s - author style sheets (CSS subset)
;
; Placeholder until the CSS engine exists: no author styles.
;

	include	"velox.i"

	xdef	CssApply

	section	code,code

;--------------------------------------------------------------------
; CssApply - apply author styles to a computed style
; In: a0 = element, a1 = style (modified)
;--------------------------------------------------------------------
CssApply:
	rts
