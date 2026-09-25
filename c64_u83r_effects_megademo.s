; ================================================================
; C64 U83R Effects Megademo v1.0.0
; Sixteen effects with a shared IRQ, SID routine, custom text charset, and two
; bitmap-bank finales. Runtime code starts at $4000; text uses screen $0400 and
; charset $2000. Bitmap effects use VIC bank 2 with screen $8400 and bitmap $a000.
; Build: acme --strict-segments -f cbm -o build/c64_u83r_effects_megademo.prg c64_u83r_effects_megademo.s
; Run:   x64sc build/c64_u83r_effects_megademo.prg
; ================================================================

!cpu 6502

; BASIC: 10 SYS 16384
* = $0801
        !byte $0c,$08,$0a,$00,$9e,$31,$36,$33,$38,$34,$00,$00,$00

; ---------------- Hardware constants ----------------
SCREEN      = $0400
COLOR       = $d800
CHARSET     = $2000
BORDER      = $d020
BGCOL       = $d021
CTRL1       = $d011
CTRL2       = $d016
MEMPTR      = $d018
RASTER      = $d012
VICIRQEN    = $d01a
VICIRQFLAG  = $d019
CIA1_ICR    = $dc0d
CIA2_ICR    = $dd0d
CIA2_PRA    = $dd00
CPU_PORT    = $01

; safe zero-page pointers
SrcLo       = $fb
SrcHi       = $fc
StrLo       = SrcLo              ; zp indirect title pointer
StrHi       = SrcHi
DstLo       = $fd
DstHi       = $fe
ColLo       = $f7
ColHi       = $f8
TmpA        = $f9
TmpB        = $fa

; screen-code constants in our custom charset
G_SPACE     = $20
G_DOT       = $61
G_BLOCK     = $62
G_HLINE     = $63
G_VLINE     = $64
G_SLASH     = $65
G_BSLASH    = $66
G_PLUS      = $67
G_SHADE1    = $68
G_SHADE2    = $69
G_SHADE3    = $6a
G_DIAMOND   = $6b

NUM_PARTS   = 16
RISKY_BITMAP_FIRST = 14
VICMODE_TEXT   = $00
VICMODE_BITMAP = $01
VICMODE_DIRTY  = $ff
BITMAP_SCREEN = $8400
BITMAP_BASE   = $a000

; ================================================================
; Runtime code/data safely outside VIC charset RAM
; ================================================================
* = $4000

Start:
        sei
        ldx #$ff
        txs
        lda #$37
        sta CPU_PORT
        lda #$7f
        sta CIA1_ICR
        sta CIA2_ICR
        lda CIA1_ICR
        lda CIA2_ICR
        lda #0
        sta VICIRQEN
        lda #VICMODE_DIRTY           ; force hard VIC restore at boot
        sta VICMode
        lda VICIRQFLAG
        sta VICIRQFLAG
        jsr VIC_Init
        jsr CopyCharROM
        jsr BuildDemoChars
        jsr ClearScreen
        jsr ClearColor
        jsr SID_Init
        jsr IRQ_Init
        lda #0
        sta Part
        jsr LoadPart
        cli
MainLoop:
        lda FrameReady
        beq MainLoop
        lda #0
        sta FrameReady
        jsr CheckSkipKey
        jsr C64SafeRuntimeWatchdog    ; clamp CPU port/part before VIC mode
        jsr ForceVICForCurrentPart     ; text or risky bitmap bank per effect
        jsr GuardPartState             ; recover safely if part/state is corrupted
        jsr MusicTick
        jsr VisualBeatPulse            ; tiny cracktro border/screen pulse
        jsr EffectPacerFX              ; safe text-part shimmer, skipped in bitmap mode
        jsr UpdateSequencer
        jmp MainLoop

VIC_Init:
        jsr ForceVICTextBank
        rts

TextEffectPreflight:
        ; called by every text-mode effect init/update.
        ; It prevents wrong char/VIC/bank on early effects and after risky modes.
        jsr ForceVICTextBank
        jsr BuildDemoChars
        rts

ForceVICTextBank:
        ; unconditional strict VIC text/charset/bank restore.
        ; Reason: if VICMode cache says TEXT while D018/CIA2/D011 was changed by
        ; risky bitmap/bank switching, the first text effects can show wrong
        ; chars/bank.  This routine is intentionally hard, not cached.
ForceVICTextBank_Hard:
        lda #$37
        sta CPU_PORT
        lda $dd02
        ora #%00000011
        sta $dd02
        lda CIA2_PRA
        and #%11111100
        ora #%00000011              ; VIC bank 0: $0000-$3fff
        sta CIA2_PRA
        lda #$1b                    ; text mode, bitmap off, 25 rows
        sta CTRL1
        lda #$08                    ; 40 col, multicolor off
        sta CTRL2
        lda #$18                    ; screen $0400, charset $2000
        sta MEMPTR
        lda #0
        sta $d015                   ; hard-disable all sprites after risky modes
        sta $d017
        sta $d01d
        sta $d01c
        sta BGCOL
        sta BORDER
        lda #VICMODE_TEXT
        sta VICMode
        rts
ForceVICTextBank_Fast:
        ; Compatibility label only.  Keep it hard too.
        jmp ForceVICTextBank_Hard

ForceVICForCurrentPart:
        ; allow dangerous bitmap/bank-switch effects only for the final risky parts.
        lda Part
        cmp #RISKY_BITMAP_FIRST
        bcs ForceVICBitmapBank2
        jmp ForceVICTextBank

ForceVICBitmapBank2:
        ; cached risky mode. VIC bank 2 ($8000-$bfff), hires bitmap at $a000, screen at $8400.
        lda VICMode
        cmp #VICMODE_BITMAP
        beq ForceVICBitmapBank2_Fast
ForceVICBitmapBank2_Hard:
        lda #$37
        sta CPU_PORT
        lda $dd02
        ora #%00000011
        sta $dd02
        lda CIA2_PRA
        and #%11111100
        ora #%00000001              ; VIC bank 2: $8000-$bfff
        sta CIA2_PRA
        lda #$3b                    ; bitmap mode on, 25 rows
        sta CTRL1
        lda #$08                    ; hires, 40 col, multicolor off
        sta CTRL2
        lda #$18                    ; bank-relative screen $0400, bitmap $2000
        sta MEMPTR
        lda #0
        sta BGCOL
        sta $d015                   ; risky bitmap parts never use sprites
        sta $d017
        sta $d01d
        sta $d01c
        lda #VICMODE_BITMAP
        sta VICMode
        rts
ForceVICBitmapBank2_Fast:
        lda #$37
        sta CPU_PORT
        rts

ExitRiskyModeClean:
        ; canonical escape from bitmap/bank switching with real IRQ ack.
        lda #$37
        sta CPU_PORT
        lda #$01
        sta VICIRQFLAG                ; D019 acknowledges only set bits, not zero
        lda #VICMODE_DIRTY            ; force hard text restore after risky bitmap mode
        sta VICMode
        jsr ForceVICTextBank
        lda #0
        sta BORDER
        sta BGCOL
        sta $d015                     ; no sprite residue
        sta $d017
        sta $d01d
        sta $d01c
        lda #$01
        sta VICIRQFLAG
        rts

ResetEffectLocalState:
        ; wipe all per-effect scratch that can leak between risky/text parts.
        lda #0
        sta LocalTick
        sta EffectIndex
        sta WGCol
        sta StarIndex
        sta GatePhase
        sta ClearRow
        sta BMByte
        sta BMColorTmp
        sta PlotX
        sta PlotY
        sta PlotChar
        sta PlotColor
        sta LineColor
        sta LineChar
        rts

CopyCharROM:
        lda CPU_PORT
        pha
        lda #$33                    ; char ROM visible at $d000
        sta CPU_PORT
        ldx #0
CopyCharROM_Loop:
        lda $d000,x
        sta CHARSET+$000,x
        lda $d100,x
        sta CHARSET+$100,x
        lda $d200,x
        sta CHARSET+$200,x
        lda $d300,x
        sta CHARSET+$300,x
        lda $d400,x
        sta CHARSET+$400,x
        lda $d500,x
        sta CHARSET+$500,x
        lda $d600,x
        sta CHARSET+$600,x
        lda $d700,x
        sta CHARSET+$700,x
        inx
        bne CopyCharROM_Loop
        pla
        sta CPU_PORT
        rts

BuildDemoChars:
        ; do not rely on whatever char code/bank the emulator currently shows.
        ; Force our core glyphs in charset $2000 every load.
        ldx #0
BuildSpaceGlyph_Loop:
        lda #0
        sta CHARSET+G_SPACE*8,x
        inx
        cpx #8
        bne BuildSpaceGlyph_Loop
        ldx #0
BuildDemoChars_Loop:
        lda DemoGfxCharData,x
        sta CHARSET+$61*8,x
        inx
        cpx #88
        bne BuildDemoChars_Loop
        rts

IRQ_Init:
        lda #$7f
        sta CIA1_ICR
        sta CIA2_ICR
        lda CIA1_ICR
        lda CIA2_ICR
        lda #<IRQ_Main
        sta $0314
        lda #>IRQ_Main
        sta $0315
        lda #$30
        sta RASTER
        lda CTRL1
        and #$7f
        sta CTRL1
        lda #$01
        sta VICIRQEN
        sta VICIRQFLAG
        rts

IRQ_Main:
        pha
        txa
        pha
        tya
        pha
        lda #$01
        sta VICIRQFLAG
        jsr ForceVICForCurrentPart     ; IRQ respects risky bitmap parts
        inc Frame
        lda #1
        sta FrameReady
        pla
        tay
        pla
        tax
        pla
        jmp $ea31

SID_Init:
        ldx #$18
        lda #0
SID_Clear:
        sta $d400,x
        dex
        bpl SID_Clear
        ; ATLANTIS GABBER: V1 brutal bass/kick hybrid.
        lda #$03                    ; fast attack/decay, hard pulse thump
        sta $d405
        lda #$f4                    ; high sustain, short release
        sta $d406
        ; V2 Atlantis saw/pulse lead, short rave pluck.
        lda #$12
        sta $d40c
        lda #$86
        sta $d40d
        ; V3 gabber click / ghost-kick / clap transient.
        lda #$00
        sta $d413
        lda #$08
        sta $d414
        lda #$00
        sta $d415
        lda #$20
        sta $d416
        lda #$f3                    ; high resonance, route V1+V2 through filter
        sta $d417
        lda #$1f                    ; low-pass + volume 15
        sta $d418
        rts

EffectPacerFX:
        ; lightweight per-frame polish. Text parts get top-row shimmer only; risky bitmap parts are untouched.
        lda Part
        cmp #RISKY_BITMAP_FIRST
        bcs EffectPacerFX_Done
        lda LocalTick
        and #$07
        bne EffectPacerFX_Done
        lda Part
        and #$0f
        tax
        lda LogoColors,x
        sta COLOR+0*40+1
        sta COLOR+0*40+38
EffectPacerFX_Done:
        rts

C64SafeRuntimeWatchdog:
        ; per-frame safety clamp + periodic hard VIC refresh.
        lda #$37
        sta CPU_PORT
        lda Part
        cmp #NUM_PARTS
        bcc C64SafeRuntimeWatchdog_PartOk
        lda #0
        sta Part
        lda #VICMODE_DIRTY
        sta VICMode
        jsr LoadPart
C64SafeRuntimeWatchdog_PartOk:
        inc VICRefreshCtr
        lda VICRefreshCtr
        and #$1f                    ; every 32 frames force a hard VIC reassert
        bne C64SafeRuntimeWatchdog_Ok
        lda #VICMODE_DIRTY
        sta VICMode
C64SafeRuntimeWatchdog_Ok:
        rts

GuardPartState:
        lda Part
        cmp #NUM_PARTS
        bcc GuardPartState_Ok
        lda #0
        sta Part
        jsr StopSIDGates
        jsr LoadPart
GuardPartState_Ok:
        rts

VisualBeatPulse:
        ; Subtle cracktro sync: black most of the time, flash on kick/clap steps.
        ldx MusicStep
        lda DrumPat,x
        beq VisualBeatPulse_Black
        cmp #1
        beq VisualBeatPulse_Kick
        cmp #3
        beq VisualBeatPulse_Clap
        lda #$0b                    ; hat / cyan-blue
        bne VisualBeatPulse_Set
VisualBeatPulse_Kick:
        lda #$06                    ; kick / blue
        bne VisualBeatPulse_Set
VisualBeatPulse_Clap:
        lda #$0f                    ; clap / light grey
VisualBeatPulse_Set:
        sta BORDER
        rts
VisualBeatPulse_Black:
        lda #0
        sta BORDER
        rts

MusicFrameFX:
        ; Runs every frame: adds live PWM/filter shimmer between grid retriggers.
        lda Frame
        clc
        adc MusicStep
        and #$3f
        tax
        lda LeadPwLo,x
        sta $d409
        lda LeadPwHi,x
        sta $d40a
        lda FilterCutHi,x
        sta $d416
        rts

CheckSkipKey:
        ; SPACE skips both the visual effect and the matching cracktro phrase.
        ; Debounced so holding space does not blast through every part.
        jsr $ffe4                    ; KERNAL GETIN, A=0 if no key
        cmp #$20
        bne CheckSkipKey_Release
        lda SkipLatch
        bne CheckSkipKey_Done
        lda #1
        sta SkipLatch
        jsr SkipNextPartAndMusic
        rts
CheckSkipKey_Release:
        lda #0
        sta SkipLatch
CheckSkipKey_Done:
        rts

UpdateSequencer:
        jsr DispatchUpdate
        ; robust 16-bit timer countdown with no wrap-underflow dependency.
        lda TimerLo
        ora TimerHi
        bne UpdateSequencer_Count
        jsr NextPart
        rts
UpdateSequencer_Count:
        lda TimerLo
        bne UpdateSequencer_DecLo
        dec TimerHi
        lda #$ff
        sta TimerLo
        rts
UpdateSequencer_DecLo:
        dec TimerLo
        rts

NextPart:
        inc Part
        lda Part
        cmp #NUM_PARTS
        bcc NextPart_Load
        lda #0
        sta Part
NextPart_Load:
        jsr LoadPart
        rts

SkipNextPartAndMusic:
        ; Explicit user skip: advance effect and jump music to matching section.
        inc Part
        lda Part
        cmp #NUM_PARTS
        bcc SkipNextPart_HavePart
        lda #0
        sta Part
SkipNextPart_HavePart:
        jsr StopSIDGates
        jsr LoadPart                  ; LoadPart already resets matching music phrase.
        rts

ResetMusicForPart:
        ldx Part
        lda MusicStart,x
        sta MusicStep
        lda #3                       ; next MusicTick immediately executes Music_Do
        sta MusicSub
        rts

StopSIDGates:
        ; complete SID gate/control cleanup before effect/music switches.
        lda #$40
        sta $d404
        sta $d40b
        lda #$80
        sta $d412
        lda #0
        sta $d418
        lda #$1f
        sta $d418
        rts

LoadPart:
        jsr StopSIDGates              ; no hanging note across timed changes
        jsr ExitRiskyModeClean        ; canonical restore from bitmap/bank switching
        jsr ResetEffectLocalState     ; no stale scratch state between effects
        jsr BuildDemoChars            ; reassert custom glyphs after every part switch
        jsr ClearScreen
        jsr ClearColor
        ldx Part
        lda DurLo,x
        sta TimerLo
        lda DurHi,x
        sta TimerHi
        jsr ResetMusicForPart       ; no stale music phrase/state after timed part change
        lda InitLo,x
        sta CallVec+1
        lda InitHi,x
        sta CallVec+2
CallVec:
        jsr $ffff
        rts

DispatchUpdate:
        ldx Part
        lda UpdLo,x
        sta UpdVec+1
        lda UpdHi,x
        sta UpdVec+2
UpdVec:
        jsr $ffff
        rts

; sequencer tables moved to data area after effect labels.

; ================================================================
; Common helpers
; ================================================================
ClearScreen:
        lda #G_SPACE
        ldx #0
ClearScreen_Loop:
        sta SCREEN,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$300,x
        inx
        bne ClearScreen_Loop
        rts

ClearColor:
        lda #$00
        ldx #0
ClearColor_Loop:
        sta COLOR,x
        sta COLOR+$100,x
        sta COLOR+$200,x
        sta COLOR+$300,x
        inx
        bne ClearColor_Loop
        rts

SetRowPtrs:
        tax
        lda RowLo,x
        sta DstLo
        lda RowHi,x
        sta DstHi
        lda CRowLo,x
        sta ColLo
        lda CRowHi,x
        sta ColHi
        rts

PutXY:
        lda PlotY
        jsr SetRowPtrs
        ldy PlotX
        lda PlotChar
        sta (DstLo),y
        lda PlotColor
        sta (ColLo),y
        rts

DrawHLine:
        lda LineY
        jsr SetRowPtrs
        ldy LineX1
DrawHLine_Loop:
        lda LineChar
        sta (DstLo),y
        lda LineColor
        sta (ColLo),y
        cpy LineX2
        beq DrawHLine_Done
        iny
        bne DrawHLine_Loop
DrawHLine_Done:
        rts

DrawVLine:
        lda LineY1
        sta TmpA
DrawVLine_Loop:
        lda TmpA
        jsr SetRowPtrs
        ldy LineX1
        lda LineChar
        sta (DstLo),y
        lda LineColor
        sta (ColLo),y
        lda TmpA
        cmp LineY2
        beq DrawVLine_Done
        inc TmpA
        jmp DrawVLine_Loop
DrawVLine_Done:
        rts

DrawDiagDownRight:
        lda LineX1
        sta TmpA
        lda LineY1
        sta TmpB
DrawDDR_Loop:
        lda TmpB
        jsr SetRowPtrs
        ldy TmpA
        lda G_BSLASH
        sta (DstLo),y
        lda LineColor
        sta (ColLo),y
        lda TmpA
        cmp LineX2
        beq DrawDDR_Done
        inc TmpA
        inc TmpB
        jmp DrawDDR_Loop
DrawDDR_Done:
        rts

DrawDiagUpRight:
        lda LineX1
        sta TmpA
        lda LineY1
        sta TmpB
DrawDUR_Loop:
        lda TmpB
        jsr SetRowPtrs
        ldy TmpA
        lda G_SLASH
        sta (DstLo),y
        lda LineColor
        sta (ColLo),y
        lda TmpA
        cmp LineX2
        beq DrawDUR_Done
        inc TmpA
        dec TmpB
        jmp DrawDUR_Loop
DrawDUR_Done:
        rts

CenterTitle:
        ; StrLo/StrHi points to !scr text, Count length, A=color, Y=row
        sta PlotColor
        sty PlotY
        lda #20
        sec
        sbc Count
        bcs CenterTitle_Pos
        lda #0
CenterTitle_Pos:
        lsr
        sta PlotX
        ldy #0
CenterTitle_Loop:
        lda (StrLo),y
        sta PlotChar
        jsr PutXY
        inc PlotX
        iny
        cpy Count
        bne CenterTitle_Loop
        rts

; ================================================================
; Effect 0: TunnelVoyager 4-way/inward charmode adaptation
; from uploaded TunnelVoyager-PAL v7.5 table ideas.
; ================================================================
TV_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        lda #0
        sta LocalTick
        lda #<TV_Title
        sta StrLo
        lda #>TV_Title
        sta StrHi
        lda #TV_TitleLen
        sta Count
        ldy #1
        lda #$0e
        jsr CenterTitle
        rts

TV_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        inc LocalTick
        jsr ClearStage
        ldx #2
TV_RowLoop:
        txa
        tay
        lda WidthTable,y
        clc
        adc LocalTick
        and #$03
        sta TmpA                    ; tiny breathing
        lda WidthTable,y
        clc
        adc TmpA
        sta TmpB                    ; half width
        lda #20
        sec
        sbc TmpB
        sta LineX1
        lda #20
        clc
        adc TmpB
        sta LineX2
        stx LineY
        lda TunnelRowColor,x
        sta LineColor
        lda G_HLINE
        sta LineChar
        jsr DrawHLine
        ldx LineY
        inx
        cpx #23
        beq TV_RowLoop_Done           ; branch-safe loop exit
        jmp TV_RowLoop
TV_RowLoop_Done:
        ; perspective rails
        lda #6
        sta LineColor
        lda #6
        sta LineX1
        lda #22
        sta LineY1
        lda #19
        sta LineX2
        lda #12
        sta LineY2
        jsr DrawDiagUpRight
        lda #34
        sta LineX1
        lda #22
        sta LineY1
        lda #21
        sta LineX2
        lda #12
        sta LineY2
        jsr DrawDiagUpLeftSafe
        jsr TV_ExtraTemplePulse
        rts

DrawDiagUpLeftSafe:
        lda LineX1
        sta TmpA
        lda LineY1
        sta TmpB
DrawDUL_Loop:
        lda TmpB
        jsr SetRowPtrs
        ldy TmpA
        lda G_BSLASH
        sta (DstLo),y
        lda LineColor
        sta (ColLo),y
        lda TmpA
        cmp LineX2
        beq DrawDUL_Done
        dec TmpA
        dec TmpB
        jmp DrawDUL_Loop
DrawDUL_Done:
        rts

DrawDiagDownLeftSafe:
        lda LineX1
        sta TmpA
        lda LineY1
        sta TmpB
DrawDDL_Loop:
        lda TmpB
        jsr SetRowPtrs
        ldy TmpA
        lda G_SLASH
        sta (DstLo),y
        lda LineColor
        sta (ColLo),y
        lda TmpA
        cmp LineX2
        beq DrawDDL_Done
        dec TmpA
        inc TmpB
        jmp DrawDDL_Loop
DrawDDL_Done:
        rts

; ================================================================
; per-effect polish helpers.  All are bounded charmode-only and
; use the already hardened TextEffectPreflight/VIC restore contract.
; ================================================================
TV_ExtraTemplePulse:
        lda LocalTick
        and #$0f
        tax
        lda LogoColors,x
        sta LineColor
        lda #20
        sta LineX1
        lda #5
        sta LineY1
        lda #22
        sta LineY2
        lda G_DOT
        sta LineChar
        jsr DrawVLine
        lda #10
        sta LineX1
        lda #30
        sta LineX2
        lda #12
        sta LineY
        lda G_DIAMOND
        sta LineChar
        jsr DrawHLine
        rts

CO_VanishExtras:
        lda #$06
        sta LineColor
        lda #4
        sta LineX1
        lda #4
        sta LineY1
        lda #20
        sta LineX2
        lda #12
        sta LineY2
        jsr DrawDiagDownRight
        lda #35
        sta LineX1
        lda #4
        sta LineY1
        lda #20
        sta LineX2
        lda #12
        sta LineY2
        jsr DrawDiagDownLeftSafe
        lda #4
        sta LineX1
        lda #22
        sta LineY1
        lda #20
        sta LineX2
        lda #12
        sta LineY2
        jsr DrawDiagUpRight
        lda #35
        sta LineX1
        lda #22
        sta LineY1
        lda #20
        sta LineX2
        lda #12
        sta LineY2
        jsr DrawDiagUpLeftSafe
        lda #20
        sta PlotX
        lda #12
        sta PlotY
        lda G_DIAMOND
        sta PlotChar
        lda #$01
        sta PlotColor
        jsr PutXY
        rts

BR_OrbitExtras:
        lda #0
        sta EffectIndex
BR_OrbitLoop:
        ldx EffectIndex
        lda BR_X1,x
        sta PlotX
        lda BR_Y2,x
        sta PlotY
        lda EffectIndex
        clc
        adc LocalTick
        and #$0f
        tax
        lda LogoColors,x
        sta PlotColor
        lda G_DIAMOND
        sta PlotChar
        jsr PutXY
        inc EffectIndex
        lda EffectIndex
        cmp #16
        bne BR_OrbitLoop
        rts

WG_CrossLines:
        lda LocalTick
        and #$0f
        tax
        lda LogoColors,x
        sta LineColor
        lda G_VLINE
        sta LineChar
        lda #8
        sta LineX1
        lda #4
        sta LineY1
        lda #22
        sta LineY2
        jsr DrawVLine
        lda #16
        sta LineX1
        jsr DrawVLine
        lda #24
        sta LineX1
        jsr DrawVLine
        lda #32
        sta LineX1
        jsr DrawVLine
        rts

GT_PlayerShip:
        lda GatePhase
        clc
        adc #12
        sta PlotX
        lda #18
        sta PlotY
        lda G_DIAMOND
        sta PlotChar
        lda #$01
        sta PlotColor
        jsr PutXY
        lda #19
        sta PlotY
        lda G_PLUS
        sta PlotChar
        lda #$0e
        sta PlotColor
        jsr PutXY
        rts

QS_TwinkleFrame:
        lda LocalTick
        and #$0f
        tax
        lda LogoColors,x
        sta LineColor
        lda G_DOT
        sta LineChar
        lda #2
        sta LineX1
        lda #37
        sta LineX2
        lda #3
        sta LineY
        jsr DrawHLine
        lda #23
        sta LineY
        jsr DrawHLine
        rts

PL_CenterRune:
        lda LocalTick
        and #$0f
        tax
        lda QuantumColors16,x
        sta PlotColor
        lda #20
        sta PlotX
        lda #12
        sta PlotY
        lda G_DIAMOND
        sta PlotChar
        jsr PutXY
        lda #19
        sta PlotX
        lda G_PLUS
        sta PlotChar
        jsr PutXY
        lda #21
        sta PlotX
        jsr PutXY
        lda #20
        sta PlotX
        lda #11
        sta PlotY
        jsr PutXY
        lda #13
        sta PlotY
        jsr PutXY
        rts

NE_DoubleBolt:
        lda #3
        sta EffectIndex
NE_DoubleLoop:
        lda EffectIndex
        tay
        lda LightningX,y
        eor #$1f
        clc
        adc LocalTick
        and #$1f
        clc
        adc #4
        sta PlotX
        lda EffectIndex
        sta PlotY
        lda G_BSLASH
        sta PlotChar
        lda #$0c
        sta PlotColor
        jsr PutXY
        inc EffectIndex
        lda EffectIndex
        cmp #23
        bne NE_DoubleLoop
        rts

HF_RadialBurst:
        lda #$0f
        sta LineColor
        lda G_HLINE
        sta LineChar
        lda #6
        sta LineX1
        lda #34
        sta LineX2
        lda #12
        sta LineY
        jsr DrawHLine
        lda G_VLINE
        sta LineChar
        lda #20
        sta LineX1
        lda #4
        sta LineY1
        lda #22
        sta LineY2
        jsr DrawVLine
        lda #8
        sta LineX1
        lda #20
        sta LineY1
        lda #20
        sta LineX2
        lda #8
        sta LineY2
        jsr DrawDiagUpRight
        lda #32
        sta LineX1
        lda #20
        sta LineY1
        lda #20
        sta LineX2
        lda #8
        sta LineY2
        jsr DrawDiagUpLeftSafe
        rts

FI_SplitCore:
        lda LocalTick
        and #$0f
        tax
        lda FireIceColors16,x
        sta LineColor
        lda G_BLOCK
        sta LineChar
        lda #3
        sta LineX1
        lda #36
        sta LineX2
        lda #13
        sta LineY
        jsr DrawHLine
        rts

; ================================================================
; Effect 1: Perspective corridor adapted from corridor.asm idea.
; ================================================================
CO_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        lda #0
        sta LocalTick
        lda #<CO_Title
        sta StrLo
        lda #>CO_Title
        sta StrHi
        lda #CO_TitleLen
        sta Count
        ldy #1
        lda #$0f
        jsr CenterTitle
        rts

CO_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        inc LocalTick
        jsr ClearStage
        lda #0
        sta EffectIndex             ; do not trust X across subroutine calls
CO_DepthLoop:
        ldx EffectIndex
        lda CorridorW,x
        sta TmpA
        lda #20
        sec
        sbc TmpA
        sta RectL
        lda #20
        clc
        adc TmpA
        sta RectR
        lda CorridorH,x
        sta TmpB
        lda #12
        sec
        sbc TmpB
        sta RectT
        lda #12
        clc
        adc TmpB
        sta RectB
        lda CorridorColor,x
        sta LineColor
        jsr DrawRect
        inc EffectIndex
        lda EffectIndex
        cmp #7
        beq CO_DepthDone              ; branch-safe loop exit
        jmp CO_DepthLoop
CO_DepthDone:
        jsr CO_VanishExtras
        rts

DrawRect:
        lda RectL
        sta LineX1
        lda RectR
        sta LineX2
        lda RectT
        sta LineY
        lda G_HLINE
        sta LineChar
        jsr DrawHLine
        lda RectB
        sta LineY
        jsr DrawHLine
        lda RectL
        sta LineX1
        lda RectT
        sta LineY1
        lda RectB
        sta LineY2
        lda G_VLINE
        sta LineChar
        jsr DrawVLine
        lda RectR
        sta LineX1
        jsr DrawVLine
        rts

; ================================================================
; Effect 2: Bresenham/XOR line lab adapted to charmode line pulse.
; ================================================================
BR_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        lda #0
        sta LocalTick
        lda #<BR_Title
        sta StrLo
        lda #>BR_Title
        sta StrHi
        lda #BR_TitleLen
        sta Count
        ldy #1
        lda #$0c
        jsr CenterTitle
        rts

BR_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        ; crash-safe third effect. Replaces diagonal-only lab with stable vector starburst.
        inc LocalTick
        jsr ClearStage
        lda LocalTick
        and #$0f
        sta EffectIndex

        ; rotating horizontal beam
        ldx EffectIndex
        lda BR_Y1,x
        sta LineY
        lda #4
        sta LineX1
        lda #35
        sta LineX2
        lda #$0f
        sta LineColor
        lda G_HLINE
        sta LineChar
        jsr DrawHLine

        ; rotating vertical beam
        ldx EffectIndex
        lda BR_X2,x
        sta LineX1
        lda #4
        sta LineY1
        lda #22
        sta LineY2
        lda #$03
        sta LineColor
        lda G_VLINE
        sta LineChar
        jsr DrawVLine

        ; safe star diagonals, bounded and deterministic
        lda #$0e
        sta LineColor
        lda #8
        sta LineX1
        lda #20
        sta LineY1
        lda #20
        sta LineX2
        lda #8
        sta LineY2
        jsr DrawDiagUpRight
        lda #32
        sta LineX1
        lda #20
        sta LineY1
        lda #20
        sta LineX2
        lda #8
        sta LineY2
        jsr DrawDiagUpLeftSafe
        jsr BR_OrbitExtras
        rts

DrawLineApprox:
        lda LineY2
        cmp LineY1
        bcs DrawLineDR
        jsr DrawDiagUpRight
        rts
DrawLineDR:
        jsr DrawDiagDownRight
        rts

; ================================================================
; Effect 3: Warp-grid from TunnelVoyager ColWarp table ideas.
; ================================================================
WG_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        lda #0
        sta LocalTick
        lda #<WG_Title
        sta StrLo
        lda #>WG_Title
        sta StrHi
        lda #WG_TitleLen
        sta Count
        ldy #1
        lda #$0b
        jsr CenterTitle
        rts

WG_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        ; index-safe warp grid. Old version used Y as loop counter across PutXY.
        inc LocalTick
        jsr ClearStage
        lda #0
        sta EffectIndex
WG_RowLoop:
        lda EffectIndex
        sta LineY
        and #$03
        tay
        lda WarpTableLo,y
        sta SrcLo
        lda WarpTableHi,y
        sta SrcHi
        lda #0
        sta WGCol
WG_ColLoop:
        ldy WGCol
        lda (SrcLo),y
        clc
        adc LocalTick
        and #$1f
        clc
        adc #4
        sta PlotX
        lda LineY
        clc
        adc #3
        sta PlotY
        lda G_DOT
        sta PlotChar
        lda WGCol
        and #$0f
        tax
        lda LogoColors,x
        sta PlotColor
        jsr PutXY
        inc WGCol
        lda WGCol
        cmp #40
        bne WG_ColLoop
        inc EffectIndex
        lda EffectIndex
        cmp #18
        beq WG_RowDone                ; branch-safe loop exit
        jmp WG_RowLoop
WG_RowDone:
        jsr WG_CrossLines
        rts

; ================================================================
; Effect 4: Gate runner / obstacle pass inspired by v7.7 fixed buffers.
; ================================================================
GT_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        lda #0
        sta LocalTick
        lda #<GT_Title
        sta StrLo
        lda #>GT_Title
        sta StrHi
        lda #GT_TitleLen
        sta Count
        ldy #1
        lda #$0d
        jsr CenterTitle
        rts

GT_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        ; index-safe gate runner.
        inc LocalTick
        jsr ClearStage
        lda LocalTick
        lsr
        and #$0f
        sta GatePhase
        lda #4
        sta EffectIndex
GT_RowLoop:
        lda EffectIndex
        sta PlotY
        and #$0f
        tay
        lda WidthTable,y
        sta TmpA
        lda #20
        sec
        sbc TmpA
        sta PlotX
        lda G_VLINE
        sta PlotChar
        lda #$0b
        sta PlotColor
        jsr PutXY
        lda #20
        clc
        adc TmpA
        sta PlotX
        jsr PutXY
        inc EffectIndex
        lda EffectIndex
        cmp #22
        bne GT_RowLoop
        ; moving gate
        lda GatePhase
        clc
        adc #12
        sta LineX1
        lda LineX1
        clc
        adc #10
        sta LineX2
        lda #12
        sta LineY
        lda #$0f
        sta LineColor
        lda G_BLOCK
        sta LineChar
        jsr DrawHLine
        jsr GT_PlayerShip
        rts

; ================================================================
; Effect 5: Quantum starfield/particles from DeepSeek quantum source ideas.
; ================================================================
QS_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        lda #0
        sta LocalTick
        jsr InitStars
        lda #<QS_Title
        sta StrLo
        lda #>QS_Title
        sta StrHi
        lda #QS_TitleLen
        sta Count
        ldy #1
        lda #$07
        jsr CenterTitle
        rts

QS_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        ; index-safe starfield. PutXY clobbers X/Y, so keep index in StarIndex.
        inc LocalTick
        jsr ClearStage
        lda #0
        sta StarIndex
QS_Loop:
        ldx StarIndex
        lda StarY,x
        sta PlotY
        lda StarX,x
        sta PlotX
        lda G_DOT
        sta PlotChar
        lda StarColor,x
        sta PlotColor
        jsr PutXY
        ldx StarIndex
        lda StarX,x
        clc
        adc StarSpeed,x
        cmp #38
        bcc QS_NoWrap
        lda #2
QS_NoWrap:
        ldx StarIndex
        sta StarX,x
        inc StarIndex
        lda StarIndex
        cmp #32
        bne QS_Loop
        jsr QS_TwinkleFrame
        rts

InitStars:
        ldx #0
InitStars_Loop:
        lda StarXInit,x
        sta StarX,x
        lda StarYInit,x
        sta StarY,x
        lda StarSpeedInit,x
        sta StarSpeed,x
        lda StarColorInit,x
        sta StarColor,x
        inx
        cpx #32
        bne InitStars_Loop
        rts

ClearStage:
        lda #3
        sta ClearRow
ClearStage_Row:
        lda ClearRow
        jsr SetRowPtrs
        ldy #39
ClearStage_Col:
        lda G_SPACE
        sta (DstLo),y
        lda #0
        sta (ColLo),y
        dey
        bpl ClearStage_Col
        inc ClearRow
        lda ClearRow
        cmp #24
        bne ClearStage_Row
        rts


; ================================================================
; Effect 6: Quantum plasma field from DeepSeek quantum palette ideas
; ================================================================
PL_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        jsr ForceVICTextBank          ; re-lock charset/bank before effect init
        lda #0
        sta LocalTick
        lda #<PL_Title
        sta StrLo
        lda #>PL_Title
        sta StrHi
        lda #PL_TitleLen
        sta Count
        ldy #1
        lda #$0f
        jsr CenterTitle
        rts

PL_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        inc LocalTick
        lda #3
        sta EffectIndex
PL_RowLoop:
        lda EffectIndex
        jsr SetRowPtrs
        lda #0
        sta WGCol
PL_ColLoop:
        ldy WGCol
        lda WGCol
        clc
        adc LocalTick
        eor EffectIndex              ; more plasma-like interference
        clc
        adc EffectIndex
        and #$0f
        tax
        lda PlasmaChars,x
        sta (DstLo),y
        lda QuantumColors16,x
        sta (ColLo),y
        inc WGCol
        lda WGCol
        cmp #40
        bne PL_ColLoop
        inc EffectIndex
        lda EffectIndex
        cmp #24
        beq PL_RowDone                ; branch-safe loop exit
        jmp PL_RowLoop
PL_RowDone:
        jsr PL_CenterRune
        rts

; ================================================================
; Effect 7: Neon lightning / moire source-material style charmode effect
; ================================================================
NE_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        jsr ForceVICTextBank          ; re-lock charset/bank before effect init
        lda #0
        sta LocalTick
        lda #<NE_Title
        sta StrLo
        lda #>NE_Title
        sta StrHi
        lda #NE_TitleLen
        sta Count
        ldy #1
        lda #$0d
        jsr CenterTitle
        rts

NE_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        inc LocalTick
        jsr ClearStage
        ; neon moire bars
        lda #4
        sta EffectIndex
NE_BarLoop:
        lda EffectIndex
        sta LineY
        lda #3
        sta LineX1
        lda #36
        sta LineX2
        lda EffectIndex
        clc
        adc LocalTick
        and #$0f
        tax
        lda NeonColors16,x
        sta LineColor
        lda G_SHADE2
        sta LineChar
        jsr DrawHLine
        lda EffectIndex
        clc
        adc #4
        sta EffectIndex
        cmp #24
        bcc NE_BarLoop
        ; lightning zig-zag down middle
        lda #3
        sta EffectIndex
NE_LightLoop:
        lda EffectIndex
        tay
        lda LightningX,y
        clc
        adc LocalTick
        and #$1f
        clc
        adc #4
        sta PlotX
        lda EffectIndex
        sta PlotY
        lda EffectIndex
        and #1
        beq NE_UseSlash
        lda G_BSLASH
        bne NE_HaveChar
NE_UseSlash:
        lda G_SLASH
NE_HaveChar:
        sta PlotChar
        lda #$0f
        sta PlotColor
        jsr PutXY
        inc EffectIndex
        lda EffectIndex
        cmp #23
        beq NE_LightDone              ; branch-safe loop exit
        jmp NE_LightLoop
NE_LightDone:
        jsr NE_DoubleBolt
        rts

; ================================================================
; Effect 8: Hyper warp field / quantum particles from source-material palettes
; ================================================================
HF_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        jsr ForceVICTextBank
        lda #0
        sta LocalTick
        lda #<HF_Title
        sta StrLo
        lda #>HF_Title
        sta StrHi
        lda #HF_TitleLen
        sta Count
        ldy #1
        lda #$0c
        jsr CenterTitle
        rts

HF_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        inc LocalTick
        jsr ClearStage
        lda #3
        sta EffectIndex
HF_RowLoop:
        lda EffectIndex
        sta PlotY
        lda EffectIndex
        clc
        adc LocalTick
        and #$0f
        tax
        lda NeonColors16,x
        sta PlotColor
        lda LocalTick
        clc
        adc EffectIndex
        and #$1f
        clc
        adc #4
        sta PlotX
        lda G_DIAMOND
        sta PlotChar
        jsr PutXY
        lda #39
        sec
        sbc PlotX
        sta PlotX
        lda G_PLUS
        sta PlotChar
        jsr PutXY
        lda EffectIndex
        and #$03
        bne HF_NoBeam
        lda #4
        sta LineX1
        lda #35
        sta LineX2
        lda EffectIndex
        sta LineY
        lda G_DOT
        sta LineChar
        lda PlotColor
        sta LineColor
        jsr DrawHLine
HF_NoBeam:
        inc EffectIndex
        lda EffectIndex
        cmp #24
        beq HF_RowDone                ; branch-safe loop exit
        jmp HF_RowLoop
HF_RowDone:
        jsr HF_RadialBurst
        rts

; ================================================================
; Effect 9: Fire/ice moire plasma adapted from quantum Fire/Ice palettes
; ================================================================
FI_Init:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank
        jsr ForceVICTextBank
        lda #0
        sta LocalTick
        lda #<FI_Title
        sta StrLo
        lda #>FI_Title
        sta StrHi
        lda #FI_TitleLen
        sta Count
        ldy #1
        lda #$07
        jsr CenterTitle
        rts

FI_Update:
        jsr TextEffectPreflight       ; lock text VIC/charset/bank every frame
        inc LocalTick
        lda #3
        sta EffectIndex
FI_RowLoop:
        lda EffectIndex
        jsr SetRowPtrs
        lda #0
        sta WGCol
FI_ColLoop:
        ldy WGCol
        lda WGCol
        clc
        adc LocalTick
        eor EffectIndex
        and #$0f
        tax
        lda FireIceChars16,x
        sta (DstLo),y
        lda FireIceColors16,x
        sta (ColLo),y
        inc WGCol
        lda WGCol
        cmp #40
        bne FI_ColLoop
        inc EffectIndex
        lda EffectIndex
        cmp #24
        bne FI_RowLoop
        jsr FI_SplitCore
        rts

; ================================================================
; Effect 10: Raster Temple Bars - text-mode raster illusion
; ================================================================
RT_Init:
        jsr TextEffectPreflight
        lda #0
        sta LocalTick
        lda #<RT_Title
        sta StrLo
        lda #>RT_Title
        sta StrHi
        lda #RT_TitleLen
        sta Count
        ldy #1
        lda #$0e
        jsr CenterTitle
        rts

RT_Update:
        jsr TextEffectPreflight
        inc LocalTick
        jsr ClearStage
        lda #3
        sta EffectIndex
RT_RowLoop:
        lda EffectIndex
        sta LineY
        lda EffectIndex
        clc
        adc LocalTick
        and #$0f
        tax
        lda LogoColors,x
        sta LineColor
        lda EffectIndex
        and #$03
        tax
        lda RT_CharTable,x
        sta LineChar
        lda #2
        sta LineX1
        lda #37
        sta LineX2
        jsr DrawHLine
        lda EffectIndex
        and #$03
        bne RT_NoPillars
        lda #6
        sta LineX1
        lda #34
        sta LineX2
        lda EffectIndex
        sta LineY
        lda G_PLUS
        sta LineChar
        lda #$01
        sta LineColor
        jsr DrawHLine
RT_NoPillars:
        inc EffectIndex
        lda EffectIndex
        cmp #24
        beq RT_Done
        jmp RT_RowLoop
RT_Done:
        ; sunken temple gate marker
        lda #17
        sta RectL
        lda #23
        sta RectR
        lda #8
        sta RectT
        lda #18
        sta RectB
        lda #$0f
        sta LineColor
        jsr DrawRect
        rts

; ================================================================
; Effect 11: Ocean Depth Sonar - expanding Atlantis depth rings
; ================================================================
OD_Init:
        jsr TextEffectPreflight
        lda #0
        sta LocalTick
        lda #<OD_Title
        sta StrLo
        lda #>OD_Title
        sta StrHi
        lda #OD_TitleLen
        sta Count
        ldy #1
        lda #$0b
        jsr CenterTitle
        rts

OD_Update:
        jsr TextEffectPreflight
        inc LocalTick
        jsr ClearStage
        lda LocalTick
        and #$03
        clc
        adc #2
        sta EffectIndex
OD_RingLoop:
        lda #20
        sec
        sbc EffectIndex
        sta RectL
        lda #20
        clc
        adc EffectIndex
        sta RectR
        lda #12
        sec
        sbc EffectIndex
        bcs OD_TopOk
        lda #2
OD_TopOk:
        sta RectT
        lda #12
        clc
        adc EffectIndex
        cmp #24
        bcc OD_BotOk
        lda #23
OD_BotOk:
        sta RectB
        lda EffectIndex
        clc
        adc LocalTick
        and #$0f
        tax
        lda QuantumColors16,x
        sta LineColor
        jsr DrawRect
        lda EffectIndex
        clc
        adc #4
        sta EffectIndex
        cmp #18
        bcc OD_RingLoop
        ; central sonar ping
        lda #20
        sta PlotX
        lda #12
        sta PlotY
        lda G_DIAMOND
        sta PlotChar
        lda #$01
        sta PlotColor
        jsr PutXY
        rts

; ================================================================
; Effect 12: Mirror Rune Tunnel - symmetric Phrygian temple glyphs
; ================================================================
MR_Init:
        jsr TextEffectPreflight
        lda #0
        sta LocalTick
        lda #<MR_Title
        sta StrLo
        lda #>MR_Title
        sta StrHi
        lda #MR_TitleLen
        sta Count
        ldy #1
        lda #$0d
        jsr CenterTitle
        rts

MR_Update:
        jsr TextEffectPreflight
        inc LocalTick
        jsr ClearStage
        lda #3
        sta EffectIndex
MR_RowLoop:
        lda EffectIndex
        sta PlotY
        lda EffectIndex
        clc
        adc LocalTick
        and #$0f
        tax
        lda NeonColors16,x
        sta PlotColor
        lda EffectIndex
        asl
        clc
        adc LocalTick
        and #$0f
        clc
        adc #4
        sta PlotX
        lda G_SLASH
        sta PlotChar
        jsr PutXY
        lda #39
        sec
        sbc PlotX
        sta PlotX
        lda G_BSLASH
        sta PlotChar
        jsr PutXY
        lda #20
        sta PlotX
        lda EffectIndex
        clc
        adc LocalTick
        and #$03
        tax
        lda RT_CharTable,x
        sta PlotChar
        jsr PutXY
        inc EffectIndex
        lda EffectIndex
        cmp #24
        beq MR_Done
        jmp MR_RowLoop
MR_Done:
        rts

; ================================================================
; Effect 13: Sine City Scanner - skyline scanner before risky bitmap
; ================================================================
SC_Init:
        jsr TextEffectPreflight
        lda #0
        sta LocalTick
        lda #<SC_Title
        sta StrLo
        lda #>SC_Title
        sta StrHi
        lda #SC_TitleLen
        sta Count
        ldy #1
        lda #$0c
        jsr CenterTitle
        rts

SC_Update:
        jsr TextEffectPreflight
        inc LocalTick
        jsr ClearStage
        lda #0
        sta WGCol
SC_ColLoop:
        lda WGCol
        clc
        adc LocalTick
        and #$0f
        tax
        lda SineCityHeight16,x
        sta TmpA
        lda #23
        sec
        sbc TmpA
        sta LineY1
        lda #23
        sta LineY2
        lda WGCol
        sta LineX1
        lda G_BLOCK
        sta LineChar
        lda WGCol
        clc
        adc LocalTick
        and #$0f
        tax
        lda FireIceColors16,x
        sta LineColor
        jsr DrawVLine
        inc WGCol
        lda WGCol
        cmp #40
        beq SC_Scanner
        jmp SC_ColLoop
SC_Scanner:
        lda LocalTick
        and #$1f
        clc
        adc #4
        cmp #40
        bcc SC_XOk
        sbc #36
SC_XOk:
        sta LineX1
        lda #3
        sta LineY1
        lda #23
        sta LineY2
        lda G_VLINE
        sta LineChar
        lda #$01
        sta LineColor
        jsr DrawVLine
        rts

; ================================================================
; Effect 14: RISKY real hires bitmap plasma in VIC bank 2
; ================================================================
BM_Init:
        lda #VICMODE_DIRTY
        sta VICMode
        lda #0
        sta LocalTick
        jsr ForceVICBitmapBank2
        jsr ClearBitmapBank2
        jsr SetupBitmapBank2Colors
        rts

BM_Update:
        inc LocalTick
        jsr ForceVICBitmapBank2
        jsr AnimateBitmapBank2Colors ; awesome hires color cycling
        lda LocalTick
        and #$10
        beq BM_Update_Plasma
        jsr DrawBitmapRingsBank2
        rts
BM_Update_Plasma:
        jsr DrawBitmapPlasmaBank2
        rts

; ================================================================
; Effect 15: RISKY live bank/mode switcher, bitmap <-> text strobe
; ================================================================
BS_Init:
        lda #VICMODE_DIRTY
        sta VICMode
        lda #0
        sta LocalTick
        jsr ForceVICTextBank
        jsr ClearScreen
        jsr ClearColor
        lda #<BS_Title
        sta StrLo
        lda #>BS_Title
        sta StrHi
        lda #BS_TitleLen
        sta Count
        ldy #1
        lda #$0f
        jsr CenterTitle
        jsr ForceVICBitmapBank2
        jsr ClearBitmapBank2
        jsr SetupBitmapBank2Colors
        rts

BS_Update:
        inc LocalTick
        lda LocalTick
        and #$08
        beq BS_ShowBitmap
BS_ShowText:
        ; intentionally dangerous mode switch: show restored text bank for a few frames.
        jsr ForceVICTextBank
        lda LocalTick
        and #$0f
        tax
        lda LogoColors,x
        sta BORDER
        ldx #0
BS_TextMarker_Loop:
        lda G_DIAMOND
        sta SCREEN+12*40+8,x
        lda LogoColors,x
        sta COLOR+12*40+8,x
        inx
        cpx #16
        bne BS_TextMarker_Loop
        rts
BS_ShowBitmap:
        jsr ForceVICBitmapBank2
        jsr AnimateBitmapBank2Colors ; color-cycle bitmap screen RAM
        jsr DrawBitmapRingsBank2
        rts

ClearBitmapBank2:
        lda #0
        ldx #0
ClearBitmapBank2_Loop:
        sta BITMAP_BASE+$0000,x
        sta BITMAP_BASE+$0100,x
        sta BITMAP_BASE+$0200,x
        sta BITMAP_BASE+$0300,x
        sta BITMAP_BASE+$0400,x
        sta BITMAP_BASE+$0500,x
        sta BITMAP_BASE+$0600,x
        sta BITMAP_BASE+$0700,x
        sta BITMAP_BASE+$0800,x
        sta BITMAP_BASE+$0900,x
        sta BITMAP_BASE+$0a00,x
        sta BITMAP_BASE+$0b00,x
        sta BITMAP_BASE+$0c00,x
        sta BITMAP_BASE+$0d00,x
        sta BITMAP_BASE+$0e00,x
        sta BITMAP_BASE+$0f00,x
        sta BITMAP_BASE+$1000,x
        sta BITMAP_BASE+$1100,x
        sta BITMAP_BASE+$1200,x
        sta BITMAP_BASE+$1300,x
        sta BITMAP_BASE+$1400,x
        sta BITMAP_BASE+$1500,x
        sta BITMAP_BASE+$1600,x
        sta BITMAP_BASE+$1700,x
        sta BITMAP_BASE+$1800,x
        sta BITMAP_BASE+$1900,x
        sta BITMAP_BASE+$1a00,x
        sta BITMAP_BASE+$1b00,x
        sta BITMAP_BASE+$1c00,x
        sta BITMAP_BASE+$1d00,x
        sta BITMAP_BASE+$1e00,x
        sta BITMAP_BASE+$1f00,x
        inx
        beq ClearBitmapBank2_Done     ; branch-safe 8KB clear loop
        jmp ClearBitmapBank2_Loop
ClearBitmapBank2_Done:
        rts

SetupBitmapBank2Colors:
        ; hires bitmap screen memory: high nybble foreground, low nybble background.
        ; $10 = white foreground over black background.
        lda #$10
        ldx #0
SetupBitmapScreen_Loop:
        sta BITMAP_SCREEN+$000,x
        sta BITMAP_SCREEN+$100,x
        sta BITMAP_SCREEN+$200,x
        sta BITMAP_SCREEN+$300,x
        lda #0
        sta COLOR+$000,x
        sta COLOR+$100,x
        sta COLOR+$200,x
        sta COLOR+$300,x
        lda #$10
        inx
        bne SetupBitmapScreen_Loop
        rts

AnimateBitmapBank2Colors:
        ; hyperoptimized color cycling. Update color RAM every other frame; bitmap still moves every frame.
        lda LocalTick
        and #$01
        bne AnimateBitmapColor_Done
        ldx #0
AnimateBitmapColor_Loop:
        txa
        clc
        adc LocalTick
        and #$0f
        tay
        lda BitmapColorNibbles,y
        sta BMColorTmp
        sta BITMAP_SCREEN+$000,x
        txa
        lsr
        clc
        adc LocalTick
        and #$0f
        tay
        lda BitmapColorNibbles,y
        eor BMColorTmp
        ora #$10
        sta BITMAP_SCREEN+$100,x
        lda BMColorTmp
        eor #$f0
        sta BITMAP_SCREEN+$200,x
        txa
        clc
        adc LocalTick
        adc #$08
        and #$0f
        tay
        lda BitmapColorNibbles,y
        sta BITMAP_SCREEN+$300,x
        inx
        beq AnimateBitmapColor_Done   ; branch-safe color cycle loop
        jmp AnimateBitmapColor_Loop
AnimateBitmapColor_Done:
        rts

DrawBitmapPlasmaBank2:
        ; 8 KB write. Heavy on purpose: real risky bitmap effect.
        ldx #0
DrawBitmapPlasma_Loop:
        txa
        clc
        adc LocalTick
        tay
        lda BitmapPattern,y
        sta BMByte
        sta BITMAP_BASE+$0000,x
        eor #$55
        sta BITMAP_BASE+$0100,x
        lda BMByte
        eor #$aa
        sta BITMAP_BASE+$0200,x
        lda BMByte
        eor LocalTick
        sta BITMAP_BASE+$0300,x
        lda BMByte
        ror
        sta BITMAP_BASE+$0400,x
        lda BMByte
        rol
        sta BITMAP_BASE+$0500,x
        lda BMByte
        eor #$ff
        sta BITMAP_BASE+$0600,x
        lda BMByte
        sta BITMAP_BASE+$0700,x
        lda BMByte
        eor #$11
        sta BITMAP_BASE+$0800,x
        lda BMByte
        eor #$22
        sta BITMAP_BASE+$0900,x
        lda BMByte
        eor #$44
        sta BITMAP_BASE+$0a00,x
        lda BMByte
        eor #$88
        sta BITMAP_BASE+$0b00,x
        lda BMByte
        sta BITMAP_BASE+$0c00,x
        lda BMByte
        eor #$33
        sta BITMAP_BASE+$0d00,x
        lda BMByte
        eor #$cc
        sta BITMAP_BASE+$0e00,x
        lda BMByte
        eor #$ff
        sta BITMAP_BASE+$0f00,x
        lda BMByte
        sta BITMAP_BASE+$1000,x
        lda BMByte
        eor #$55
        sta BITMAP_BASE+$1100,x
        lda BMByte
        eor #$aa
        sta BITMAP_BASE+$1200,x
        lda BMByte
        eor LocalTick
        sta BITMAP_BASE+$1300,x
        lda BMByte
        ror
        sta BITMAP_BASE+$1400,x
        lda BMByte
        rol
        sta BITMAP_BASE+$1500,x
        lda BMByte
        eor #$ff
        sta BITMAP_BASE+$1600,x
        lda BMByte
        sta BITMAP_BASE+$1700,x
        lda BMByte
        eor #$11
        sta BITMAP_BASE+$1800,x
        lda BMByte
        eor #$22
        sta BITMAP_BASE+$1900,x
        lda BMByte
        eor #$44
        sta BITMAP_BASE+$1a00,x
        lda BMByte
        eor #$88
        sta BITMAP_BASE+$1b00,x
        lda BMByte
        sta BITMAP_BASE+$1c00,x
        lda BMByte
        eor #$33
        sta BITMAP_BASE+$1d00,x
        lda BMByte
        eor #$cc
        sta BITMAP_BASE+$1e00,x
        lda BMByte
        eor #$ff
        sta BITMAP_BASE+$1f00,x
        inx
        beq DrawBitmapPlasma_Done ; long-loop branch over JMP
        jmp DrawBitmapPlasma_Loop
DrawBitmapPlasma_Done:
        rts

DrawBitmapRingsBank2:
        ; Different bitmap pattern for visible bank-switch part.
        ldx #0
DrawBitmapRings_Loop:
        txa
        eor LocalTick
        tay
        lda BitmapRingPattern,y
        sta BMByte
        sta BITMAP_BASE+$0000,x
        sta BITMAP_BASE+$0300,x
        sta BITMAP_BASE+$0600,x
        sta BITMAP_BASE+$0900,x
        sta BITMAP_BASE+$0c00,x
        sta BITMAP_BASE+$0f00,x
        eor #$ff
        sta BITMAP_BASE+$1200,x
        sta BITMAP_BASE+$1500,x
        sta BITMAP_BASE+$1800,x
        sta BITMAP_BASE+$1b00,x
        sta BITMAP_BASE+$1e00,x
        inx
        beq DrawBitmapRings_Done ; branch-safe loop ending
        jmp DrawBitmapRings_Loop
DrawBitmapRings_Done:
        rts

; ================================================================
; Hyperoptimized true cracktro SID tick
; ================================================================
MusicTick:
        ; ATLANTIS GABBER: 50 Hz driver.
        ; 4 frames/row on PAL ~= 187.5 BPM 16th-note tracker grid.
        jsr MusicFrameFX
        inc MusicSub
        lda MusicSub
        and #$03                    ; 12.5 rows/sec ~= 187.5 BPM
        beq Music_Do
        rts
Music_Do:
        ldx MusicStep

        ; Voice 1: gated pulse bass.  Explicit gate-off before retrigger.
        lda #$40
        sta $d404
        lda BassLo,x
        cmp #$ff
        beq Music_NoBass
        sta $d400
        lda BassHi,x
        sta $d401
        lda #$08
        sta $d402
        lda #$08
        sta $d403
        lda #$41                    ; gate + pulse
        sta $d404
Music_NoBass:

        ; Voice 2: cracktro arp/stab voice, pulse/saw alternation from LeadCtl.
        lda #$40
        sta $d40b
        lda LeadLo,x
        cmp #$ff
        beq Music_NoLead
        sta $d407
        lda LeadHi,x
        sta $d408
        lda LeadPwLo,x
        sta $d409
        lda LeadPwHi,x
        sta $d40a
        lda LeadCtl,x
        sta $d40b
Music_NoLead:

        ; Voice 3: kick / hat / clap-noise. Always gate-off first; zero pattern stays silent.
        lda #$80
        sta $d412
        lda DrumPat,x
        beq Music_NoDrum
        lda DrumPat,x
        cmp #1
        beq Music_Kick
        cmp #2
        beq Music_Hat
Music_Clap:
        lda #$18
        sta $d40e
        lda #$24
        sta $d40f
        lda #$81                    ; noise gate
        bne Music_DrumGo
Music_Kick:
        lda #$14                    ; F#1-ish main thump lo
        sta $d40e
        lda #$03
        sta $d40f
        lda #$81                    ; noise click gate for distorted gabber attack
        bne Music_DrumGo
Music_Hat:
        ; row symbol k = short ghost/pitch-drop kick tail.
        lda #$8a                    ; F#0-ish tail click lo
        sta $d40e
        lda #$01
        sta $d40f
        lda #$11                    ; triangle gate, short tail
Music_DrumGo:
        sta $d412
Music_NoDrum:
        lda FilterCutHi,x
        sta $d416
        lda FilterRes,x
        sta $d417
        inx
        txa
        and #$3f
        sta MusicStep
        rts

InitLo: !byte <TV_Init,<CO_Init,<BR_Init,<WG_Init,<GT_Init,<QS_Init,<PL_Init,<NE_Init,<HF_Init,<FI_Init,<RT_Init,<OD_Init,<MR_Init,<SC_Init,<BM_Init,<BS_Init
InitHi: !byte >TV_Init,>CO_Init,>BR_Init,>WG_Init,>GT_Init,>QS_Init,>PL_Init,>NE_Init,>HF_Init,>FI_Init,>RT_Init,>OD_Init,>MR_Init,>SC_Init,>BM_Init,>BS_Init
UpdLo:  !byte <TV_Update,<CO_Update,<BR_Update,<WG_Update,<GT_Update,<QS_Update,<PL_Update,<NE_Update,<HF_Update,<FI_Update,<RT_Update,<OD_Update,<MR_Update,<SC_Update,<BM_Update,<BS_Update
UpdHi:  !byte >TV_Update,>CO_Update,>BR_Update,>WG_Update,>GT_Update,>QS_Update,>PL_Update,>NE_Update,>HF_Update,>FI_Update,>RT_Update,>OD_Update,>MR_Update,>SC_Update,>BM_Update,>BS_Update
DurLo:  !byte <640,<560,<480,<520,<520,<480,<560,<520,<500,<500,<520,<520,<520,<520,<420,<420
DurHi:  !byte >640,>560,>480,>520,>520,>480,>560,>520,>500,>500,>520,>520,>520,>520,>420,>420
; matching phrase starts for SPACE skip. Sixteen effects map to Atlantis phrases.
; intro/build/drop/arp/acid/riser/neon/finale/hyper/fire/raster/ocean/mirror/city/risky-drop/risky-finale
MusicStart: !byte $00,$10,$20,$30,$00,$10,$20,$30,$28,$38,$08,$18,$28,$38,$00,$20

; ================================================================
; State variables
; ================================================================
Part        !byte 0
TimerLo     !byte 0
TimerHi     !byte 0
Frame       !byte 0
FrameReady  !byte 0
LocalTick   !byte 0
MusicStep   !byte 0
MusicSub    !byte 0
SkipLatch   !byte 0
PlotX       !byte 0
PlotY       !byte 0
PlotChar    !byte 0
PlotColor   !byte 0
LineX1      !byte 0
LineX2      !byte 0
LineY       !byte 0
LineY1      !byte 0
LineY2      !byte 0
LineChar    !byte 0
LineColor   !byte 0
RectL       !byte 0
RectR       !byte 0
RectT       !byte 0
RectB       !byte 0
ClearRow    !byte 0
GatePhase   !byte 0
EffectIndex !byte 0
WGCol       !byte 0
StarIndex   !byte 0
Count       !byte 0
BMByte     !byte 0        ; bitmap pattern scratch byte
BMColorTmp  !byte 0        ; bitmap color scratch
VICMode     !byte VICMODE_DIRTY ; cached VIC mode, dirty at boot
VICRefreshCtr !byte 0      ; periodic hard VIC refresh divider
StarX       !fill 32,0
StarY       !fill 32,0
StarSpeed   !fill 32,1
StarColor   !fill 32,1

; ================================================================
; Data tables from/adapted from uploaded source material
; ================================================================
BM_Title: !scr "risky bank2 hires bitmap plasma"
BM_TitleLen = *-BM_Title
BS_Title: !scr "risky live bitmap bank switch"
BS_TitleLen = *-BS_Title
PL_Title: !scr "quantum plasma / deepseek palette"
PL_TitleLen = *-PL_Title
NE_Title: !scr "neon lightning / moire source"
NE_TitleLen = *-NE_Title
HF_Title: !scr "hyper warp field / quantum source"
HF_TitleLen = *-HF_Title
FI_Title: !scr "fire ice moire / palette source"
FI_TitleLen = *-FI_Title
RT_Title: !scr "raster temple bars"
RT_TitleLen = *-RT_Title
OD_Title: !scr "ocean depth sonar rings"
OD_TitleLen = *-OD_Title
MR_Title: !scr "mirror rune tunnel"
MR_TitleLen = *-MR_Title
SC_Title: !scr "sine city scanner"
SC_TitleLen = *-SC_Title
RowLo:
        !byte <(SCREEN+0*40),<(SCREEN+1*40),<(SCREEN+2*40),<(SCREEN+3*40),<(SCREEN+4*40)
        !byte <(SCREEN+5*40),<(SCREEN+6*40),<(SCREEN+7*40),<(SCREEN+8*40),<(SCREEN+9*40)
        !byte <(SCREEN+10*40),<(SCREEN+11*40),<(SCREEN+12*40),<(SCREEN+13*40),<(SCREEN+14*40)
        !byte <(SCREEN+15*40),<(SCREEN+16*40),<(SCREEN+17*40),<(SCREEN+18*40),<(SCREEN+19*40)
        !byte <(SCREEN+20*40),<(SCREEN+21*40),<(SCREEN+22*40),<(SCREEN+23*40),<(SCREEN+24*40)
RowHi:
        !byte >(SCREEN+0*40),>(SCREEN+1*40),>(SCREEN+2*40),>(SCREEN+3*40),>(SCREEN+4*40)
        !byte >(SCREEN+5*40),>(SCREEN+6*40),>(SCREEN+7*40),>(SCREEN+8*40),>(SCREEN+9*40)
        !byte >(SCREEN+10*40),>(SCREEN+11*40),>(SCREEN+12*40),>(SCREEN+13*40),>(SCREEN+14*40)
        !byte >(SCREEN+15*40),>(SCREEN+16*40),>(SCREEN+17*40),>(SCREEN+18*40),>(SCREEN+19*40)
        !byte >(SCREEN+20*40),>(SCREEN+21*40),>(SCREEN+22*40),>(SCREEN+23*40),>(SCREEN+24*40)
CRowLo:
        !byte <(COLOR+0*40),<(COLOR+1*40),<(COLOR+2*40),<(COLOR+3*40),<(COLOR+4*40)
        !byte <(COLOR+5*40),<(COLOR+6*40),<(COLOR+7*40),<(COLOR+8*40),<(COLOR+9*40)
        !byte <(COLOR+10*40),<(COLOR+11*40),<(COLOR+12*40),<(COLOR+13*40),<(COLOR+14*40)
        !byte <(COLOR+15*40),<(COLOR+16*40),<(COLOR+17*40),<(COLOR+18*40),<(COLOR+19*40)
        !byte <(COLOR+20*40),<(COLOR+21*40),<(COLOR+22*40),<(COLOR+23*40),<(COLOR+24*40)
CRowHi:
        !byte >(COLOR+0*40),>(COLOR+1*40),>(COLOR+2*40),>(COLOR+3*40),>(COLOR+4*40)
        !byte >(COLOR+5*40),>(COLOR+6*40),>(COLOR+7*40),>(COLOR+8*40),>(COLOR+9*40)
        !byte >(COLOR+10*40),>(COLOR+11*40),>(COLOR+12*40),>(COLOR+13*40),>(COLOR+14*40)
        !byte >(COLOR+15*40),>(COLOR+16*40),>(COLOR+17*40),>(COLOR+18*40),>(COLOR+19*40)
        !byte >(COLOR+20*40),>(COLOR+21*40),>(COLOR+22*40),>(COLOR+23*40),>(COLOR+24*40)

ScaleTable:
        !byte 8,8,7,7,6,6,5,5,4,4,3,3,2,2,1,1,1,1,1,1,1,1,1,1,1
RowBase1:
        !byte 0,1,3,6,10,15,21,28,36,45,55,66,78,91,105,120,136,153,171,190,210,231,253,20,48
WidthTable:
        !byte 2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,12,13,14,15,16,17,18
VolumetricPalette:
        !byte $00,$00,$00,$00,$06,$06,$06,$06,$0e,$0e,$0e,$0e,$03,$03,$03,$03
        !byte $01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01
ColWarp1:
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ColWarp2:
        !byte 0,0,0,0,0,0,0,0,0,0,1,1,2,2,2,3,3,3,3,3
        !byte 0,253,253,252,252,252,253,253,255,0,0,0,0,0,0,0,0,0,0,0
ColWarp3:
        !byte 0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,6,6,6
        !byte 0,250,250,250,250,250,250,251,251,252,253,254,254,255,255,0,0,0,0,0
ColWarp4:
        !byte 0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,13,13,13,13,13
        !byte 0,243,243,243,243,243,243,244,245,246,247,248,249,250,251,252,253,254,255,0
WarpTableLo: !byte <ColWarp1,<ColWarp2,<ColWarp3,<ColWarp4
WarpTableHi: !byte >ColWarp1,>ColWarp2,>ColWarp3,>ColWarp4

CorridorW: !byte 2,4,6,9,12,15,18
CorridorH: !byte 1,2,3,5,7,9,10
CorridorColor: !byte $0b,$0c,$0f,$01,$0f,$0c,$0b
TunnelRowColor:
        !byte $00,$00,$0b,$0b,$0c,$0c,$0f,$0f,$01,$01,$0f,$0f,$0c,$0c,$0b,$0b,$06,$06,$0e,$0e,$03,$03,$01,$01,$00
BR_X1: !byte 4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19
BR_Y1: !byte 20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5
BR_X2: !byte 20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35
BR_Y2: !byte 5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20

LogoColors: !byte $00,$06,$0b,$0c,$0f,$01,$0f,$0c,$0b,$06,$03,$0e,$03,$06,$0b,$00
NeonColors16: !byte $00,$05,$0d,$03,$0b,$0c,$0f,$01,$0f,$0c,$0b,$03,$0d,$05,$06,$00
; quantum plasma tables required by PL_Update.
; Screen chars are from the safe custom charset built at $2000.
PlasmaChars:
        !byte G_SPACE,G_DOT,G_SHADE1,G_PLUS,G_DIAMOND,G_BLOCK,G_DIAMOND,G_PLUS
        !byte G_SHADE2,G_DOT,G_SPACE,G_BSLASH,G_VLINE,G_SLASH,G_VLINE,G_BLOCK
QuantumColors16:
        !byte $00,$0b,$0c,$0f,$01,$0f,$0c,$0b,$03,$0d,$07,$05,$07,$0d,$03,$00
LightningX: !byte 14,17,13,18,15,20,16,21,17,19,14,22,16,20,12,18,15,21,13,19,16,22,14,18,15
StarXInit: !byte 2,8,14,20,26,32,38,5,11,17,23,29,35,3,9,15,21,27,33,39,6,12,18,24,30,36,4,10,16,22,28,34
StarYInit: !byte 4,6,8,10,12,14,16,18,20,22,5,7,9,11,13,15,17,19,21,23,3,5,7,9,11,13,15,17,19,21,23,6
StarSpeedInit: !byte 1,2,1,3,1,2,1,3,1,2,1,3,1,2,1,3,1,2,1,3,1,2,1,3,1,2,1,3,1,2,1,3
StarColorInit: !byte 1,1,7,7,1,1,7,7,1,1,7,7,1,1,7,7,1,1,7,7,1,1,7,7,1,1,7,7,1,1,7,7

FireIceColors16:
        !byte $00,$09,$02,$08,$0a,$07,$0f,$01,$0f,$07,$0a,$08,$02,$09,$0b,$00
FireIceChars16:
        !byte G_SPACE,G_DOT,G_SHADE1,G_SHADE1,G_SHADE2,G_SHADE2,G_PLUS,G_DIAMOND
        !byte G_BLOCK,G_DIAMOND,G_PLUS,G_SHADE2,G_SHADE1,G_DOT,G_SPACE,G_DOT

RT_CharTable:
        !byte G_HLINE,G_SHADE1,G_SHADE2,G_BLOCK
SineCityHeight16:
        !byte 2,4,6,8,10,12,14,11,9,7,5,3,6,10,13,7

; ATLANTIS GABBER / SUNKEN TEMPLE HARDCORE music tables
; 64 rows, F# minor/Phrygian color: F# G A B C# D E.
; Voice 1 bass/kick hybrid, Voice 2 Atlantis lead, Voice 3 K/k gabber transient.
BassLo:
        !byte $14,$ff,$27,$ff,$14,$ff,$42,$14,$14,$ff,$27,$ff,$14,$ff,$42,$14
        !byte $71,$ff,$e2,$ff,$71,$ff,$be,$71,$a9,$ff,$51,$ff,$a9,$ff,$1b,$a9
        !byte $be,$ff,$7b,$ff,$be,$ff,$42,$be,$14,$ff,$27,$ff,$14,$ff,$42,$14
        !byte $71,$ff,$e2,$ff,$71,$ff,$be,$71,$14,$ff,$27,$ff,$14,$ff,$42,$14
BassHi:
        !byte $03,$00,$06,$00,$03,$00,$03,$03,$03,$00,$06,$00,$03,$00,$03,$03
        !byte $02,$00,$04,$00,$02,$00,$02,$02,$03,$00,$07,$00,$03,$00,$04,$03
        !byte $02,$00,$05,$00,$02,$00,$03,$02,$03,$00,$06,$00,$03,$00,$03,$03
        !byte $02,$00,$04,$00,$02,$00,$02,$02,$03,$00,$06,$00,$03,$00,$03,$03
LeadLo:
        !byte $9c,$ff,$e0,$ff,$da,$11,$e0,$45,$9c,$ff,$45,$ff,$e0,$da,$39,$da
        !byte $11,$ff,$e0,$ff,$45,$13,$9c,$13,$da,$ff,$11,$ff,$e0,$da,$45,$13
        !byte $9c,$ff,$e0,$ff,$da,$11,$e0,$da,$45,$ff,$13,$ff,$9c,$13,$45,$e0
        !byte $da,$ff,$11,$ff,$e0,$da,$45,$13,$9c,$ff,$9c,$ff,$39,$da,$e0,$9c
LeadHi:
        !byte $18,$00,$24,$00,$2b,$27,$24,$1d,$18,$00,$1d,$00,$24,$2b,$31,$2b
        !byte $27,$00,$24,$00,$1d,$1a,$18,$1a,$2b,$00,$27,$00,$24,$20,$1d,$1a
        !byte $18,$00,$24,$00,$2b,$27,$24,$20,$1d,$00,$1a,$00,$18,$1a,$1d,$24
        !byte $2b,$00,$27,$00,$24,$20,$1d,$1a,$18,$00,$18,$00,$31,$2b,$24,$18
LeadCtl:
        !byte $21,$40,$41,$40,$21,$41,$41,$41,$21,$40,$41,$40,$21,$41,$41,$41
        !byte $21,$40,$41,$40,$21,$41,$41,$41,$21,$40,$41,$40,$21,$41,$41,$41
        !byte $21,$40,$41,$40,$21,$41,$41,$41,$21,$40,$41,$40,$21,$41,$41,$41
        !byte $21,$40,$41,$40,$21,$41,$41,$41,$21,$40,$41,$40,$21,$41,$41,$41
LeadPwLo:
        !byte $80,$2e,$d6,$71,$f9,$68,$bb,$ee,$00,$ee,$bb,$68,$f9,$71,$d6,$2e
        !byte $80,$d1,$29,$8e,$06,$97,$44,$11,$00,$11,$44,$97,$06,$8e,$29,$d1
        !byte $7f,$2e,$d6,$71,$f9,$68,$bb,$ee,$00,$ee,$bb,$68,$f9,$71,$d6,$2e
        !byte $80,$d1,$29,$8e,$06,$97,$44,$11,$00,$11,$44,$97,$06,$8e,$29,$d1
LeadPwHi:
        !byte $07,$08,$08,$09,$09,$0a,$0a,$0a,$0b,$0a,$0a,$0a,$09,$09,$08,$08
        !byte $07,$06,$06,$05,$05,$04,$04,$04,$04,$04,$04,$04,$05,$05,$06,$06
        !byte $07,$08,$08,$09,$09,$0a,$0a,$0a,$0b,$0a,$0a,$0a,$09,$09,$08,$08
        !byte $07,$06,$06,$05,$05,$04,$04,$04,$04,$04,$04,$04,$05,$05,$06,$06
DrumPat:
        !byte 1,0,0,0,1,0,2,0,1,0,0,0,1,0,2,0
        !byte 1,0,0,0,1,0,2,0,1,0,0,0,1,0,2,0
        !byte 1,0,0,0,1,0,2,0,1,0,0,0,1,0,2,0
        !byte 1,0,0,0,1,0,2,0,1,0,0,0,1,0,2,0
FilterCutHi:
        !byte $18,$20,$28,$32,$3c,$48,$56,$64,$72,$84,$98,$b0,$cc,$e0,$f4,$d8
        !byte $18,$20,$28,$32,$3c,$48,$56,$64,$72,$84,$98,$b0,$cc,$e0,$f4,$d8
        !byte $18,$20,$28,$32,$3c,$48,$56,$64,$72,$84,$98,$b0,$cc,$e0,$f4,$d8
        !byte $18,$20,$28,$32,$3c,$48,$56,$64,$72,$84,$98,$b0,$cc,$e0,$f4,$d8
FilterRes:
        !byte $f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3,$f3
        !byte $e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3,$e3
        !byte $d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3,$d3
        !byte $c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3,$c3
DemoGfxCharData:
        !byte %00000000,%00000000,%00011000,%00011000,%00000000,%00000000,%00000000,%00000000
        !byte %11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111
        !byte %00000000,%00000000,%11111111,%11111111,%00000000,%00000000,%00000000,%00000000
        !byte %00011000,%00011000,%00011000,%00011000,%00011000,%00011000,%00011000,%00011000
        !byte %00000011,%00000110,%00001100,%00011000,%00110000,%01100000,%11000000,%10000000
        !byte %11000000,%01100000,%00110000,%00011000,%00001100,%00000110,%00000011,%00000001
        !byte %00011000,%00011000,%00011000,%11111111,%11111111,%00011000,%00011000,%00011000
        !byte %10001000,%00100010,%10001000,%00100010,%10001000,%00100010,%10001000,%00100010
        !byte %10101010,%01010101,%10101010,%01010101,%10101010,%01010101,%10101010,%01010101
        !byte %11101110,%10111011,%11101110,%10111011,%11101110,%10111011,%11101110,%10111011
        !byte %00011000,%00111100,%01111110,%11111111,%11111111,%01111110,%00111100,%00011000

BitmapColorNibbles:
        !byte $10,$30,$60,$e0,$f0,$70,$10,$f0,$e0,$60,$30,$10,$b0,$c0,$f0,$10

BitmapPattern:
        !byte $00,$18,$3c,$7e,$ff,$7e,$3c,$18,$00,$81,$42,$24,$18,$24,$42,$81
        !byte $11,$33,$77,$ff,$ee,$cc,$88,$00,$88,$cc,$ee,$ff,$77,$33,$11,$00
        !byte $0f,$1e,$3c,$78,$f0,$e1,$c3,$87,$0f,$87,$c3,$e1,$f0,$78,$3c,$1e
        !byte $55,$aa,$55,$aa,$99,$66,$99,$66,$f0,$0f,$f0,$0f,$cc,$33,$cc,$33
        !byte $00,$01,$03,$07,$0f,$1f,$3f,$7f,$ff,$7f,$3f,$1f,$0f,$07,$03,$01
        !byte $80,$c0,$e0,$f0,$f8,$fc,$fe,$ff,$fe,$fc,$f8,$f0,$e0,$c0,$80,$00
        !byte $18,$18,$3c,$3c,$7e,$7e,$ff,$ff,$e7,$c3,$81,$00,$81,$c3,$e7,$ff
        !byte $24,$66,$ff,$66,$24,$00,$24,$66,$ff,$66,$24,$00,$3c,$42,$81,$42
        !byte $00,$18,$3c,$7e,$ff,$7e,$3c,$18,$00,$81,$42,$24,$18,$24,$42,$81
        !byte $11,$33,$77,$ff,$ee,$cc,$88,$00,$88,$cc,$ee,$ff,$77,$33,$11,$00
        !byte $0f,$1e,$3c,$78,$f0,$e1,$c3,$87,$0f,$87,$c3,$e1,$f0,$78,$3c,$1e
        !byte $55,$aa,$55,$aa,$99,$66,$99,$66,$f0,$0f,$f0,$0f,$cc,$33,$cc,$33
        !byte $00,$01,$03,$07,$0f,$1f,$3f,$7f,$ff,$7f,$3f,$1f,$0f,$07,$03,$01
        !byte $80,$c0,$e0,$f0,$f8,$fc,$fe,$ff,$fe,$fc,$f8,$f0,$e0,$c0,$80,$00
        !byte $18,$18,$3c,$3c,$7e,$7e,$ff,$ff,$e7,$c3,$81,$00,$81,$c3,$e7,$ff
        !byte $24,$66,$ff,$66,$24,$00,$24,$66,$ff,$66,$24,$00,$3c,$42,$81,$42
BitmapRingPattern:
        !byte $00,$00,$18,$18,$3c,$3c,$7e,$7e,$ff,$ff,$7e,$7e,$3c,$3c,$18,$18
        !byte $81,$c3,$e7,$ff,$7e,$3c,$18,$00,$18,$3c,$7e,$ff,$e7,$c3,$81,$00
        !byte $aa,$55,$aa,$55,$cc,$33,$cc,$33,$f0,$0f,$f0,$0f,$99,$66,$99,$66
        !byte $0f,$0f,$1f,$1f,$3f,$3f,$7f,$7f,$ff,$ff,$fe,$fe,$fc,$fc,$f8,$f8
        !byte $00,$00,$18,$18,$3c,$3c,$7e,$7e,$ff,$ff,$7e,$7e,$3c,$3c,$18,$18
        !byte $81,$c3,$e7,$ff,$7e,$3c,$18,$00,$18,$3c,$7e,$ff,$e7,$c3,$81,$00
        !byte $aa,$55,$aa,$55,$cc,$33,$cc,$33,$f0,$0f,$f0,$0f,$99,$66,$99,$66
        !byte $0f,$0f,$1f,$1f,$3f,$3f,$7f,$7f,$ff,$ff,$fe,$fe,$fc,$fc,$f8,$f8
        !byte $00,$00,$18,$18,$3c,$3c,$7e,$7e,$ff,$ff,$7e,$7e,$3c,$3c,$18,$18
        !byte $81,$c3,$e7,$ff,$7e,$3c,$18,$00,$18,$3c,$7e,$ff,$e7,$c3,$81,$00
        !byte $aa,$55,$aa,$55,$cc,$33,$cc,$33,$f0,$0f,$f0,$0f,$99,$66,$99,$66
        !byte $0f,$0f,$1f,$1f,$3f,$3f,$7f,$7f,$ff,$ff,$fe,$fe,$fc,$fc,$f8,$f8
        !byte $00,$00,$18,$18,$3c,$3c,$7e,$7e,$ff,$ff,$7e,$7e,$3c,$3c,$18,$18
        !byte $81,$c3,$e7,$ff,$7e,$3c,$18,$00,$18,$3c,$7e,$ff,$e7,$c3,$81,$00
        !byte $aa,$55,$aa,$55,$cc,$33,$cc,$33,$f0,$0f,$f0,$0f,$99,$66,$99,$66
        !byte $0f,$0f,$1f,$1f,$3f,$3f,$7f,$7f,$ff,$ff,$fe,$fe,$fc,$fc,$f8,$f8

TV_Title: !scr "deepseek tunnelvoyager 4-way"
TV_TitleLen = *-TV_Title
CO_Title: !scr "proper perspective corridor"
CO_TitleLen = *-CO_Title
BR_Title: !scr "safe vector starburst"
BR_TitleLen = *-BR_Title
WG_Title: !scr "warp-grid colwarp tables"
WG_TitleLen = *-WG_Title
GT_Title: !scr "gate runner fixed buffers"
GT_TitleLen = *-GT_Title
QS_Title: !scr "quantum stars particles"
QS_TitleLen = *-QS_Title

!if * > $8000 {
    !error "Demo code and tables must remain below VIC bank 2 at $8000"
}
