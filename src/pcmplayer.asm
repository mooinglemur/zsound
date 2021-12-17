.include "x16.inc"
.include "macros.inc"

EXPORT_TAGGED "init_pcm"
EXPORT_TAGGED "start_digi"
EXPORT_TAGGED "play_pcm"
EXPORT_TAGGED "stop_pcm"

; bare minimum info needed in a data file: VERA_CTRL, RATE, length
; digi parameter table also needs to store the location of the data
.struct DIGITAB
	addr		.addr
	bank		.byte
	size		.word	; 24bit digi size
	sizehi		.byte	; ...
	cfg			.byte	; VERA_audio_ctrl value
	rate		.byte	; VERA_audio_rate
.endstruct
DIGITAB_LAST		= DIGITAB::rate

.struct PCMSTATE
	state		.byte
	digi		.tag	DIGITAB
	byterate_f	.byte	; 16.8 fixedpoint "bytes per frame" rate 
	byterate	.word	; (computed whenever playback rate is set)
	fracbytes	.byte	; fractional bytes transferred counter
.endstruct


; TODO: these ZP addresses aren't permanent storage. Convert to using
; other temporary space in ZP and not hogging bytes just for this player.
.segment "ZEROPAGE"
pcm_pages:		.res 1	; Hi byte of transfer size. (.X holds low byte)
zp_tmp:			.res 2

.segment "BSS"
digi:			.tag PCMSTATE

active_digi		:= digi + PCMSTATE::state
frac_bytes		:= digi + PCMSTATE::fracbytes


;---------------------------------------------------------------
.segment "CODE"
.proc init_pcm: near
	jmp stop_pcm
	; TODO: at some point I plan to have hooks in ZSM player
	; for using PCM, and this routine should setup the hooks
	; appropriately, as I'm thinking "jump table" to be the
	; way to do that without directly referencing symbols in this
	; module, forcing it to be assembled in whether or not it's
	; desired.
	rts
.endproc

;---------------------------------------------------------------
; .A = RAM bank
; .X/.Y = pointer to a digi's parameter table
; (TODO: implement HiRAM support for integration with zsound)
;---------------------------------------------------------------
; notes: This is probably going to be a higher-level API call for
; supporting tables of digi clips. There should probably be lower-level
; calls such as "pcm_setpointer, pcm_setparams, pcm_start, pcm_stop, etc.
;

.segment "CODE"
.proc start_digi: near

	stx	zp_tmp
	sty zp_tmp+1
	tax
	jsr stop_pcm
	; bank in the RAM with the digi index table.
	lda RAM_BANK
	sta BANK_SAVE
	stx RAM_BANK

	; copy the digi table data into the PCM engine's state table.
	ldy #DIGITAB_LAST
loop:
	lda (zp_tmp),y
	sta digi + PCMSTATE::digi,y
	dey
	bpl loop
	
	lda digi + PCMSTATE::digi + DIGITAB::cfg
	ora #$80	; clear the FIFO when setting the PCM parameters.
		; TODO: Make the playback engine work in a way that doesn't require
		; clearing the buffer, yet is able to change parameters at the correct
		; time when the previous sound finishes draining. Challenge accepted!
	sta VERA_audio_ctrl
	; pre-load the FIFO
	ldx digi + PCMSTATE::digi + DIGITAB::rate
	jsr set_byte_rate
	dec active_digi
	stz frac_bytes
	jsr play_pcm	; prime the FIFO with at least 1 frame's worth of data.
	; enable VERA PCM playback
	ldx digi + PCMSTATE::digi + DIGITAB::rate
	stx VERA_audio_rate
exit:
	lda #$FF
	BANK_SAVE := (*-1)
	sta RAM_BANK
	rts
.endproc

;---------------------------------------------------------------
; .A = VERA_audio_ctrl
; .X = VERA_audio_rate setting
.segment "CODE"
.proc set_byte_rate: near
	dex
	bmi bad_rate
	ldy pcmrate_fr,x
	sty digi + PCMSTATE::byterate
	ldy pcmrate_lo,x
	sty digi + PCMSTATE::byterate
	ldy pcmrate_hi,x
	sty digi + PCMSTATE::byterate+1
	inx
check_16bit:
	bit #$10 ; check the 16bit format flag
	beq check_stereo
	asl digi+PCMSTATE::byterate_f
	rol digi+PCMSTATE::byterate
	rol digi+PCMSTATE::byterate+1
check_stereo:
	bit #$20 ; check stereo flag
	beq done
	asl digi+PCMSTATE::byterate_f
	rol digi+PCMSTATE::byterate
	rol digi+PCMSTATE::byterate+1
done:
	clc
	rts
bad_rate:
	jmp stop_pcm
.endproc


;---------------------------------------------------------------
.segment "CODE"
.proc play_pcm: near

	totalbytes		= digi + PCMSTATE::digi + DIGITAB::size
	bytesperframe 	= digi + PCMSTATE::byterate
	fracframe		= digi + PCMSTATE::byterate_f

	lda	active_digi		; quick check whether digi player is active
	
	beq noop
	bmi :+
	dec active_digi
noop:
	rts

	; precalculate the fractional frame accumulation, store in pcm_pages as tmp.
:	clc
	stz pcm_pages
	lda frac_bytes
	adc fracframe
	sta frac_bytes
	bcc :+
	inc pcm_pages
:
	; totalbytes -= bytesperframe + pcm_pages
	sec
	lda totalbytes
	sbc pcm_pages
	sbc bytesperframe
	tax
	lda totalbytes+1
	sbc bytesperframe+1
	tay
	lda totalbytes+2
	sbc #0
	bmi	last_frame
	; load pcm_pages with hi byte of totalbytes + fractional frame and
	; store the low byte in .X for jmp into load_fifo
	sta totalbytes+2
	sty totalbytes+1
	stx totalbytes
	clc
	lda pcm_pages
	adc bytesperframe
	tax
	lda bytesperframe+1
	adc #0
	sta pcm_pages	; none of the frame rates in the table will overflow this.
	jmp load_fifo
last_frame:
	ldx totalbytes
	lda totalbytes+1
	sta pcm_pages
	stz totalbytes
	stz totalbytes+1
	stz frac_bytes
	stz active_digi
	jmp load_fifo
.endproc


;---------------------------------------------------------------
; load_fifo: 
; assumes pcm_ptr:pcm_bank point at the current byte of the sample stream
; and that the current bank is not necessarily the one with the data.
; assumes FIFO overflow is impossible, as this implementation attempts to
; keep just 1 frame's worth of samples in the FIFO, max.
;
; .X = low byte of transfer amount
;---------------------------------------------------------------
.segment "CODE"
.proc load_fifo: near

	pcm_ptr  = digi + PCMSTATE::digi + DIGITAB::addr
	pcm_bank = digi + PCMSTATE::digi + DIGITAB::bank

	ldy pcm_ptr+1		; (formerly) ZP
	sty data_page
	ldy pcm_ptr			; (formerly) ZP
	; swap in the current RAM bank of the sample stream
	lda RAM_BANK
	sta BANK_SAVE
	lda pcm_bank		; (formerly) ZP
	sta RAM_BANK
	jmp copy_byte

loop_bankwrap:
	lda #$a0
	inc RAM_BANK
	inc pcm_bank		; (formerly) ZP
loop:
	sta data_page
check_done:
	cpx #0
	bne dec1
	lda pcm_pages		; ZP
	bne dec2
finished:
	;update the data pointer. (does this even need to be ZP anymore?)
	sty pcm_ptr			; (formerly) ZP
	ldy data_page		; self-mod
	sty pcm_ptr+1		; (formerly) ZP
	lda #$FF
	BANK_SAVE = (*-1)
	sta RAM_BANK
	rts
dec2:
	dec
	sta pcm_pages		; ZP
dec1:
	dex
copy_byte:
	lda $FF00,y
	data_page = (*-1)
	sta VERA_audio_data
	iny
	bne check_done
	; advance pointer to the next page. Do bank wrap if necessary
	lda data_page
	inc
	cmp #$c0
	bne loop
	bra loop_bankwrap
.endproc



;---------------------------------------------------------------
.segment "CODE"
.proc stop_pcm: near
	stz VERA_audio_rate
	lda #$80
	sta VERA_audio_ctrl
	stz active_digi
	rts
.endproc

; LUT for bytes-per-frame at all possible play rates 1..128
; (loader does dex once before using as index, since 0 = not playing)
;
; Consider moving this into Bank RAM.... but zsound doesn't have
; the "workbank" implemented at this time, so here it stays for now. :)
;
; hmmm, that would have to be generated at run-time....

.segment "RODATA"
pcmrate_fr: ; fraction per frame
	.byte $5C,$B7,$13,$6E,$CA,$26,$81,$DD,$38,$94,$F0,$4B,$A7,$02,$5E
	.byte $BA,$15,$71,$CC,$28,$84,$DF,$3B,$97,$F2,$4E,$A9,$05,$61,$BC
	.byte $18,$73,$CF,$2B,$86,$E2,$3D,$99,$F5,$50,$AC,$07,$63,$BF,$1A
	.byte $76,$D1,$2D,$89,$E4,$40,$9B,$F7,$53,$AE,$0A,$65,$C1,$1D,$78
	.byte $D4,$2F,$8B,$E7,$42,$9E,$F9,$55,$B1,$0C,$68,$C4,$1F,$7B,$D6
	.byte $32,$8E,$E9,$45,$A0,$FC,$58,$B3,$0F,$6A,$C6,$22,$7D,$D9,$34
	.byte $90,$EC,$47,$A3,$FE,$5A,$B6,$11,$6D,$C8,$24,$80,$DB,$37,$92
	.byte $EE,$4A,$A5,$01,$5C,$B8,$14,$6F,$CB,$26,$82,$DE,$39,$95,$F1
	.byte $4C,$A8,$03,$5F,$BB,$16,$72,$CD

pcmrate_lo:
	.byte $06,$0C,$13,$19,$1F,$26,$2C,$32,$39,$3F,$45,$4C,$52,$59,$5F
	.byte $65,$6C,$72,$78,$7F,$85,$8B,$92,$98,$9E,$A5,$AB,$B2,$B8,$BE
	.byte $C5,$CB,$D1,$D8,$DE,$E4,$EB,$F1,$F7,$FE,$04,$0B,$11,$17,$1E
	.byte $24,$2A,$31,$37,$3D,$44,$4A,$50,$57,$5D,$64,$6A,$70,$77,$7D
	.byte $83,$8A,$90,$96,$9D,$A3,$A9,$B0,$B6,$BD,$C3,$C9,$D0,$D6,$DC
	.byte $E3,$E9,$EF,$F6,$FC,$02,$09,$0F,$16,$1C,$22,$29,$2F,$35,$3C
	.byte $42,$48,$4F,$55,$5B,$62,$68,$6F,$75,$7B,$82,$88,$8E,$95,$9B
	.byte $A1,$A8,$AE,$B5,$BB,$C1,$C8,$CE,$D4,$DB,$E1,$E7,$EE,$F4,$FA
	.byte $01,$07,$0E,$14,$1A,$21,$27,$2D

pcmrate_hi:
	.byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	.byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	.byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$01,$01,$01,$01,$01
	.byte $01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01
	.byte $01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01
	.byte $01,$01,$01,$01,$01,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02
	.byte $02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02
	.byte $02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02
	.byte $03,$03,$03,$03,$03,$03,$03,$03

canary:
	.byte	"pcm player included"	; looking for this in the PRG for
									; simpleplayer when I re-build it
									; with this module in the library
