;==============================================================================
; VDPTEST - test rezimu VDP TMS9918A/TMS9929A pro Sord M5
;
; Preklad:  pasmo --bin vdptest.asm vdptest.bin
; Spusteni: ROM cartridge od 2000h (FPGA: Cartridge None, "Load to ROM").
;
; Obrazovky se prepinaji MEZERNIKEM (dalsi) a ENTEREM (predchozi).
; Klavesa E prepina R0 bit 0 (EXTVID) na vsech obrazovkach (diagnostika
; synchronizace na realnem HW); vychozi hodnota je EVDEF.
; Klavesa B prepina barvu okraje (backdrop, R7 dolni nibble) mezi barvou
; obrazovky a cernou. Okraj jako takovy TMS9918 vypnout neumi; backdrop je
; videt i pod pruhlednymi body obrazu.
; Ocekavane vysledky jednotlivych obrazovek jsou v README.md.
;
; Obrazovky:
;    1  Graphic I - paleta, ramecek (poloha obrazu)
;    2  Text mode - ramecek (posun textu), znakova sada, ignorovane bity 1,0
;    3  Multicolor - barevne bloky 4x4 + sprite 16x16
;    4  Bitmap (Graphic II) - plne tabulky R3=FF R4=03
;    5-9  Bitmap - masky tretin (chyba 2.1 v doc/vdp-tms9918-porovnani.md)
;   10  Bitmap - maska cisla znaku (chyba 2.2)
;   11  Bitmap text (nedokumentovany)
;   12  Bitmap multicolor (nedokumentovany)
;   13  Nelegalni rezim M1+M2
;   14  Sprity 8x8 - priorita, early clock, okraje
;   15  Sprity 16x16 - kvadranty, early clock, okraj
;   16  Sprity 16x16 zvetsene
;   17  Paty sprite na radku, ukonceni Y=D0
;   18  Kolize s pruhlednym spritem
;   19  Sprity na neviditelnem radku 192 (Y=BF)
;
; Veskery zapis do VRAM pri sestaveni obrazovky probiha pri vypnutem
; zobrazeni (R1 bit 6 = 0), takze na originalu neni treba cekat na okna
; pristupu CPU. Za behu se zapisuje jen radek se stavem spritu, a to hned
; po zacatku zpetneho behu (status bit 7).
;
; Preruseni jsou zakazana, status VDP se cte dotazovanim.
;==============================================================================

VDPD            EQU     10h             ; VDP data (MODE = 0)
VDPC            EQU     11h             ; VDP rizeni / status (MODE = 1)
SGC             EQU     20h             ; SN76489
KBROW0          EQU     30h             ; klavesnice: bit 6 SPACE, bit 7 ENTER
KBROW2          EQU     32h             ; klavesnice: bit 2 E
KBROW4          EQU     34h             ; klavesnice: bit 4 B

; Vychozi hodnota R0 bit 0 (EXTVID). Klavesa E ji za behu prepina.
; Realny Sord M5 (TMS9929A) potrebuje 1, s 0 je obraz rozsynchronizovany
; (overeno 2026-09-26). FPGA bit ignoruje.
EVDEF           EQU     1

; Promenne v RAM (7000h-7FFFh, monitor se uz nevola)
CUR             EQU     7F00h           ; cislo obrazovky 0..NSCR-1
ACC             EQU     7F01h           ; OR bitu 5S a C statusu za snimek
FIFTH           EQU     7F02h           ; cislo 5. spritu (FFh = nebyl)
KEYOLD          EQU     7F03h           ; predchozi stav klaves
STPOS           EQU     7F04h           ; adresa radku stavu ve VRAM (0 = neni)
BOXC            EQU     7F06h           ; znak ramecku
SRCPTR          EQU     7F08h           ; zdroj kopie (SPRSCR)
EVBIT           EQU     7F0Ah           ; R0 bit 0 pridavany ke vsem obrazovkam
R0SH            EQU     7F0Bh           ; R0 aktualni obrazovky (bez EVBIT)
KEYOLD2         EQU     7F0Ch           ; predchozi stav klavesy E
BDOFF           EQU     7F0Dh           ; 1 = okraj (backdrop) cerny
R7SH            EQU     7F0Eh           ; R7 aktualni obrazovky
KEYOLD4         EQU     7F0Fh           ; predchozi stav klavesy B

; Rozlozeni VRAM pro Graphic I, Text, Multicolor
G1NT            EQU     1800h           ; jmena        R2 = 06h
G1CT            EQU     2000h           ; barvy        R3 = 80h
G1PT            EQU     0000h           ; vzory        R4 = 00h
G1SA            EQU     1B00h           ; atributy spritu  R5 = 36h
G1SP            EQU     3800h           ; vzory spritu     R6 = 07h

; Rozlozeni VRAM pro Bitmap
BMNT            EQU     3800h           ; jmena        R2 = 0Eh
BMCT            EQU     2000h           ; barvy        R3 = 80h | maska
BMPT            EQU     0000h           ; vzory        R4 = maska
BMSA            EQU     3B00h           ; atributy spritu  R5 = 76h
                                        ; vzory spritu 1800h, R6 = 03h

;------------------------------------------------------------------------------
; Hlavicka ROM cartridge (stejna jako flexicard/tools/menu/menu.asm)
;------------------------------------------------------------------------------
        ORG     2000h
        DB      00                      ; ROM TYPE
        DW      BEGIN                   ; ROM START
        DW      BEGIN                   ; ROM LOADER
        DB      0C3h                    ; 2005
        DW      TO_RET                  ; 2006 N/A
        DB      0C3h                    ; 2008
        DW      0                       ; 2009 AUTOSTART
        DB      00                      ; 200B FLAG
        DW      0000                    ; 200C HEADER
        DW      0000                    ; 200E LENGTH

BEGIN:
        DI
        LD      SP, 8000h
        CALL    FAKE_RETI
        IN      A, (VDPC)               ; zrusi pripadny pozadavek preruseni VDP
        LD      A, 9Fh                  ; umlceni vsech kanalu zvuku
        OUT     (SGC), A
        LD      A, 0BFh
        OUT     (SGC), A
        LD      A, 0DFh
        OUT     (SGC), A
        LD      A, 0FFh
        OUT     (SGC), A
        XOR     A
        LD      (CUR), A
        LD      A, 0C0h                 ; klavesy drzene pri startu neprepinaji
        LD      (KEYOLD), A
        LD      A, 04h
        LD      (KEYOLD2), A
        LD      A, 10h
        LD      (KEYOLD4), A
        XOR     A
        LD      (BDOFF), A
        LD      A, EVDEF
        LD      (EVBIT), A

;------------------------------------------------------------------------------
; Sestaveni obrazovky CUR a hlavni smycka
;------------------------------------------------------------------------------
SHOW:
        LD      SP, 8000h
        LD      A, (CUR)
        ADD     A, A
        LD      E, A
        LD      D, 0
        LD      HL, SCRTAB
        ADD     HL, DE
        LD      E, (HL)
        INC     HL
        LD      D, (HL)
        EX      DE, HL
        LD      DE, SHOW2
        PUSH    DE
        JP      (HL)
SHOW2:
        XOR     A
        LD      (ACC), A
        DEC     A
        LD      (FIFTH), A
        IN      A, (VDPC)               ; zahodit status z doby sestavovani

LOOP:
        IN      A, (VDPC)
        LD      B, A
        AND     60h                     ; 5S, C
        LD      HL, ACC
        OR      (HL)
        LD      (HL), A
        BIT     6, B
        JR      Z, LOOP1
        LD      A, B
        AND     1Fh
        LD      (FIFTH), A
LOOP1:
        BIT     7, B                    ; konec aktivni oblasti?
        JR      Z, LOOP

        CALL    SHOWST                  ; jednou za snimek: stav spritu
        XOR     A
        LD      (ACC), A
        DEC     A
        LD      (FIFTH), A

        IN      A, (KBROW0)             ; jednou za snimek: klavesy (bez zakmitu)
        AND     0C0h
        LD      HL, KEYOLD
        LD      C, (HL)
        LD      (HL), A
        LD      B, A
        LD      A, C
        CPL
        AND     B                       ; nove stisknute
        BIT     6, A
        JR      NZ, NEXT
        BIT     7, A
        JR      NZ, PREV

        IN      A, (KBROW2)             ; E: prepnuti R0 bit 0 (EXTVID)
        AND     04h
        LD      HL, KEYOLD2
        LD      C, (HL)
        LD      (HL), A
        LD      B, A
        LD      A, C
        CPL
        AND     B
        JR      Z, LOOP4
        LD      A, (EVBIT)
        XOR     1
        LD      (EVBIT), A
        CALL    WR0

LOOP4:
        IN      A, (KBROW4)             ; B: okraj cerny / barva obrazovky
        AND     10h
        LD      HL, KEYOLD4
        LD      C, (HL)
        LD      (HL), A
        LD      B, A
        LD      A, C
        CPL
        AND     B
        JP      Z, LOOP
        LD      A, (BDOFF)
        XOR     1
        LD      (BDOFF), A
        CALL    WR7
        JP      LOOP

NEXT:
        LD      A, (CUR)
        INC     A
        CP      NSCR
        JR      C, NEXT1
        XOR     A
NEXT1:
        LD      (CUR), A
        JP      SHOW

PREV:
        LD      A, (CUR)
        OR      A
        JR      NZ, PREV1
        LD      A, NSCR
PREV1:
        DEC     A
        LD      (CUR), A
        JP      SHOW

FAKE_RETI:
        RETI

TO_RET:
        RET

SCRTAB:
        DW      SCR1, SCR2, SCR3, SCR4, SCR5, SCR6, SCR7, SCR8, SCR9, SCR10
        DW      SCR11, SCR12, SCR13, SCR14, SCR15, SCR16, SCR17, SCR18, SCR19
NSCR            EQU     ($ - SCRTAB) / 2

;------------------------------------------------------------------------------
; Radek stavu spritu: "5S=x C=x N=xx"
;------------------------------------------------------------------------------
SHOWST:
        LD      HL, (STPOS)
        LD      A, H
        OR      L
        RET     Z
        CALL    SETW
        LD      HL, STR5S
        CALL    OUTS
        LD      A, (ACC)
        RLCA                            ; bit 6 -> bit 0
        RLCA
        AND     1
        ADD     A, '0'
        OUT     (VDPD), A
        LD      HL, STRC
        CALL    OUTS
        LD      A, (ACC)
        RLCA                            ; bit 5 -> bit 0
        RLCA
        RLCA
        AND     1
        ADD     A, '0'
        OUT     (VDPD), A
        LD      HL, STRN
        CALL    OUTS
        LD      A, (FIFTH)
        CP      0FFh
        JR      Z, SHOWST1
        PUSH    AF
        RRCA
        RRCA
        RRCA
        RRCA
        CALL    HEXD
        POP     AF
        JP      HEXD
SHOWST1:
        LD      A, '-'
        OUT     (VDPD), A
        OUT     (VDPD), A
        RET

STR5S:  DB      "5S=", 0
STRC:   DB      " C=", 0
STRN:   DB      " N=", 0

; Vypise retezec HL (ukonceny 0) na aktualni adresu VRAM
OUTS:
        LD      A, (HL)
        OR      A
        RET     Z
        OUT     (VDPD), A
        INC     HL
        JR      OUTS

; Vypise dolni nibble A jako hex cislici
HEXD:
        AND     0Fh
        ADD     A, 90h
        DAA
        ADC     A, 40h
        DAA
        OUT     (VDPD), A
        RET

;------------------------------------------------------------------------------
; Zakladni rutiny VDP
;------------------------------------------------------------------------------

; Zapis registru: A = hodnota, E = cislo registru. Zachova HL, E.
WREG:
        OUT     (VDPC), A
        LD      A, E
        OR      80h
        OUT     (VDPC), A
        RET

; Nastaveni adresy VRAM pro zapis: HL. Zachova HL, BC, DE.
SETW:
        LD      A, L
        OUT     (VDPC), A
        LD      A, H
        AND     3Fh
        OR      40h
        OUT     (VDPC), A
        RET

; Vyplneni: HL = adresa VRAM, BC = pocet (> 0), E = hodnota. Zachova HL.
FILL:
        CALL    SETW
FILL1:
        LD      A, E
        OUT     (VDPD), A
        DEC     BC
        LD      A, B
        OR      C
        JR      NZ, FILL1
        RET

; Kopie do VRAM: HL = zdroj, DE = adresa VRAM, BC = pocet (> 0). Zachova DE.
COPY:
        EX      DE, HL
        CALL    SETW
        EX      DE, HL
COPY1:
        LD      A, (HL)
        OUT     (VDPD), A
        INC     HL
        DEC     BC
        LD      A, B
        OR      C
        JR      NZ, COPY1
        RET

; Tabulka vyplneni: HL -> { DW adresa, DW pocet, DB hodnota }..., DW 0FFFFh
FILLT:
        LD      E, (HL)
        INC     HL
        LD      D, (HL)
        INC     HL
        LD      A, D
        CP      0FFh
        RET     Z
        LD      C, (HL)
        INC     HL
        LD      B, (HL)
        INC     HL
        LD      A, (HL)
        INC     HL
        PUSH    HL
        EX      DE, HL
        LD      E, A
        CALL    FILL
        POP     HL
        JR      FILLT

; Seznam textu: HL -> { DW adresa, DB "text", 0 }..., DW 0FFFFh
; C = hodnota ORovana ke kazdemu znaku (0 nebo 80h).
PLIST:
        LD      E, (HL)
        INC     HL
        LD      D, (HL)
        INC     HL
        LD      A, D
        CP      0FFh
        RET     Z
        EX      DE, HL
        CALL    SETW
PLIST1:
        LD      A, (DE)
        INC     DE
        OR      A
        JR      Z, PLIST2
        OR      C
        OUT     (VDPD), A
        JR      PLIST1
PLIST2:
        EX      DE, HL
        JR      PLIST

; Registry R0..R7 z tabulky HL; R1 (zapnuti zobrazeni) se zapisuje posledni.
; K R0 se pridava EVBIT, R7 respektuje BDOFF.
SETREGS:
        LD      A, (HL)
        LD      (R0SH), A
        CALL    WR0
        PUSH    HL
        INC     HL
        LD      E, 2
SETREGS1:
        INC     HL
        LD      A, (HL)
        CALL    WREG
        INC     E
        LD      A, E
        CP      7
        JR      NZ, SETREGS1
        INC     HL
        LD      A, (HL)
        LD      (R7SH), A
        CALL    WR7
        POP     HL
        INC     HL
        LD      A, (HL)
        LD      E, 1
        JP      WREG

; Zapis R7 = R7SH, pri BDOFF s pozadim 1 (cerna). Barva textu zustava.
WR7:
        LD      A, (R7SH)
        LD      E, A
        LD      A, (BDOFF)
        OR      A
        LD      A, E
        JR      Z, WR7A
        AND     0F0h
        OR      01h
WR7A:
        LD      E, 7
        JP      WREG

; Zapis R0 = R0SH | EVBIT
WR0:
        LD      A, (EVBIT)
        LD      E, A
        LD      A, (R0SH)
        OR      E
        LD      E, 0
        JP      WREG

; Vypnuti zobrazeni, vymazani cele VRAM, zruseni radku stavu.
PREP:
        LD      A, 80h                  ; 16K, zobrazeni vypnuto, bez preruseni
        LD      E, 1
        CALL    WREG
        LD      HL, 0
        LD      BC, 4000h
        LD      E, 0
        CALL    FILL
        LD      HL, 0
        LD      (STPOS), HL
        RET

; Font (znaky 20h-5Fh) do tabulky vzoru s bazi DE.
LDFONT:
        LD      HL, 100h
        ADD     HL, DE
        EX      DE, HL
        LD      HL, FONT
        LD      BC, 512
        JP      COPY

; Glyf znaku A (20h-5Fh) na adresu VRAM DE. Zachova DE.
GLYPH:
        SUB     20h
        LD      L, A
        LD      H, 0
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        LD      BC, FONT
        ADD     HL, BC
        LD      BC, 8
        JP      COPY

; Znak 80h v blocich vzoru 0000h, 0800h, 1000h, 1800h = cislice 0, 1, 2, 3
DIGITS:
        LD      DE, 0400h
        LD      A, '0'
DIGITS1:
        PUSH    AF
        CALL    GLYPH
        LD      HL, 0800h
        ADD     HL, DE
        EX      DE, HL
        POP     AF
        INC     A
        CP      '4'
        JR      NZ, DIGITS1
        RET

; Ramecek: HL = baze tabulky jmen, DE = sirka radku, A = znak; 24 radku
BOX:
        LD      (BOXC), A
        PUSH    HL
        PUSH    DE
        LD      B, D
        LD      C, E
        LD      E, A
        CALL    FILL                    ; horni radek
        POP     DE
        POP     HL
        LD      B, 22
BOX1:
        ADD     HL, DE                  ; zacatek dalsiho radku
        PUSH    BC
        CALL    SETW
        LD      A, (BOXC)
        OUT     (VDPD), A
        PUSH    HL
        ADD     HL, DE
        DEC     HL                      ; konec radku
        CALL    SETW
        LD      A, (BOXC)
        OUT     (VDPD), A
        POP     HL
        POP     BC
        DJNZ    BOX1
        ADD     HL, DE                  ; dolni radek
        LD      B, D
        LD      C, E
        LD      A, (BOXC)
        LD      E, A
        JP      FILL

; Text do bitmapy: HL = retezec, kresli do bunek 0.. prvni tretiny
; (vzor 0000h + n*8, barva 2000h + n*8 = bila na cerne).
BMTEXT:
        LD      DE, 0
BMTEXT1:
        LD      A, (HL)
        OR      A
        RET     Z
        PUSH    HL
        PUSH    DE
        CALL    GLYPH
        LD      HL, BMCT
        ADD     HL, DE
        LD      BC, 8
        LD      E, 0F1h
        CALL    FILL
        POP     DE
        LD      HL, 8
        ADD     HL, DE
        EX      DE, HL
        POP     HL
        INC     HL
        JR      BMTEXT1

; Spolecny zaklad Graphic I: font, znaky 80h-FFh plne, barvy:
;   znaky 00h-7Fh bila na pruhledne, skupina 80h+8k barva k; sprity vypnute.
G1BASE:
        CALL    PREP
        LD      DE, G1PT
        CALL    LDFONT
        LD      HL, G1PT + 400h
        LD      BC, 400h
        LD      E, 0FFh
        CALL    FILL
        LD      HL, G1CT
        LD      BC, 16
        LD      E, 0F0h
        CALL    FILL
        LD      HL, G1CT + 16
        CALL    SETW
        XOR     A
G1BASE1:
        OUT     (VDPD), A               ; 00h, 11h, 22h ... FFh
        ADD     A, 11h
        JR      NC, G1BASE1
        LD      HL, G1SA
        CALL    SETW
        LD      A, 0D0h
        OUT     (VDPD), A
        RET

;==============================================================================
; 1  Graphic I - paleta a ramecek
;==============================================================================
SCR1:
        CALL    G1BASE
        LD      HL, G1NT
        LD      DE, 32
        LD      A, 0F8h                 ; plny znak barvy F (bila)
        CALL    BOX
        LD      HL, G1NT + 4*32 + 17    ; pruhy barev 0..F
        LD      C, 80h
        LD      B, 16
SCR1A:
        PUSH    BC
        PUSH    HL
        LD      E, C
        LD      BC, 12
        CALL    FILL
        POP     HL
        LD      DE, 32
        ADD     HL, DE
        POP     BC
        LD      A, C
        ADD     A, 8
        LD      C, A
        DJNZ    SCR1A
        LD      HL, TXT1
        LD      C, 0
        CALL    PLIST
        LD      HL, REG_G1
        JP      SETREGS

REG_G1: DB      00h, 0C0h, 06h, 80h, 00h, 36h, 07h, 01h

TXT1:
        DW      G1NT + 1*32 + 2
        DB      "VDP TEST TMS9918A  SORD M5", 0
        DW      G1NT + 2*32 + 2
        DB      "1 GRAPHIC I - PALETA", 0
        DW      G1NT + 4*32 + 2
        DB      "0 PRUHLEDNA", 0
        DW      G1NT + 5*32 + 2
        DB      "1 CERNA", 0
        DW      G1NT + 6*32 + 2
        DB      "2 ZELENA", 0
        DW      G1NT + 7*32 + 2
        DB      "3 SV.ZELENA", 0
        DW      G1NT + 8*32 + 2
        DB      "4 TM.MODRA", 0
        DW      G1NT + 9*32 + 2
        DB      "5 SV.MODRA", 0
        DW      G1NT + 10*32 + 2
        DB      "6 TM.CERVENA", 0
        DW      G1NT + 11*32 + 2
        DB      "7 AZUROVA", 0
        DW      G1NT + 12*32 + 2
        DB      "8 CERVENA", 0
        DW      G1NT + 13*32 + 2
        DB      "9 SV.CERVENA", 0
        DW      G1NT + 14*32 + 2
        DB      "A TM.ZLUTA", 0
        DW      G1NT + 15*32 + 2
        DB      "B SV.ZLUTA", 0
        DW      G1NT + 16*32 + 2
        DB      "C TM.ZELENA", 0
        DW      G1NT + 17*32 + 2
        DB      "D PURPUROVA", 0
        DW      G1NT + 18*32 + 2
        DB      "E SEDA", 0
        DW      G1NT + 19*32 + 2
        DB      "F BILA", 0
        DW      G1NT + 21*32 + 2
        DB      "MEZERNIK DALSI, ENTER ZPET", 0
        DW      0FFFFh

;==============================================================================
; 2  Text mode
;==============================================================================
SCR2:
        CALL    PREP
        LD      DE, G1PT
        CALL    LDFONT
        LD      HL, FT_TX
        CALL    FILLT
        LD      HL, G1NT
        LD      DE, 40
        LD      A, 80h
        CALL    BOX
        LD      HL, G1NT + 8*40 + 4     ; znakova sada 20h-3Fh
        CALL    SETW
        LD      A, 20h
SCR2A:
        OUT     (VDPD), A
        INC     A
        CP      40h
        JR      NZ, SCR2A
        LD      HL, G1NT + 9*40 + 4     ; 40h-5Fh
        CALL    SETW
        LD      A, 40h
SCR2B:
        OUT     (VDPD), A
        INC     A
        CP      60h
        JR      NZ, SCR2B
        LD      HL, TXT2
        LD      C, 0
        CALL    PLIST
        LD      HL, REG_TX
        JP      SETREGS

REG_TX: DB      00h, 0D0h, 06h, 00h, 00h, 00h, 00h, 0F4h

FT_TX:
        DW      G1PT + 80h*8, 8         ; znak 80h plny
        DB      0FFh
        DW      G1PT + 81h*8, 8         ; znak 81h jen bity 1,0
        DB      03h
        DW      0FFFFh

TXT2:
        DW      G1NT + 1*40 + 2
        DB      "2 TEXT MODE 40X24, BARVY Z R7=F4", 0
        DW      G1NT + 3*40 + 2
        DB      "BILY RAMECEK = HRANICE TEXTOVE PLOCHY", 0
        DW      G1NT + 4*40 + 2
        DB      "HW OKRAJ: VLEVO 19 PX, VPRAVO 25 PX", 0
        DW      G1NT + 5*40 + 2
        DB      "FPGA:     VLEVO 14 PX, VPRAVO 30 PX", 0
        DW      G1NT + 7*40 + 2
        DB      "ZNAKOVA SADA 20-5F:", 0
        DW      G1NT + 11*40 + 2
        DB      "BITY 1,0 VZORU SE IGNORUJI: [", 81h, 81h, 81h, 81h, "]", 0
        DW      G1NT + 13*40 + 2
        DB      "POROVNEJ RAMECEK S OBRAZOVKOU 1", 0
        DW      0FFFFh

;==============================================================================
; 3  Multicolor
;    Box (bx, by): barva = (sloupec znaku + by) & 15, pravy box o 1 vyssi.
;    Jmena podle dokumentace: radek y ma znaky (y/4)*32 + sloupec.
;==============================================================================
SCR3:
        CALL    PREP
        LD      HL, G1PT                ; vzory znaku 0..191 (0000h-05FFh)
        CALL    SETW
        LD      HL, 0                   ; i = znak*8 + bajt
SCR3A:
        LD      A, L                    ; sloupec = (i >> 3) & 31
        RRCA
        RRCA
        RRCA
        AND     1Fh
        LD      B, A
        LD      A, L                    ; + bajt (0..7)
        AND     7
        ADD     A, B
        LD      B, A
        LD      A, H                    ; + skupina radku * 8 = (i >> 8) * 8
        ADD     A, A
        ADD     A, A
        ADD     A, A
        ADD     A, B                    ; v = sloupec + by
        LD      B, A
        AND     0Fh
        RLCA
        RLCA
        RLCA
        RLCA
        LD      C, A                    ; levy box = v
        LD      A, B
        INC     A
        AND     0Fh                     ; pravy box = v + 1
        OR      C
        OUT     (VDPD), A
        INC     HL
        LD      A, H
        CP      06h
        JR      NZ, SCR3A

        LD      HL, G1NT                ; jmena
        CALL    SETW
        LD      HL, 0
SCR3B:
        LD      A, L
        RLA                             ; CY = bit 7 L
        LD      A, H
        RLA                             ; A = i >> 7 = radek / 4
        RRCA                            ; << 5
        RRCA
        RRCA
        AND     0E0h
        LD      B, A
        LD      A, L
        AND     1Fh
        OR      B
        OUT     (VDPD), A
        INC     HL
        LD      A, H
        CP      03h
        JR      NZ, SCR3B

        LD      HL, G1SP                ; sprite 16x16 plny
        LD      BC, 32
        LD      E, 0FFh
        CALL    FILL
        LD      HL, SA3
        LD      DE, G1SA
        LD      BC, SA3_END - SA3
        CALL    COPY
        LD      HL, REG_MC
        JP      SETREGS

REG_MC: DB      00h, 0CAh, 06h, 00h, 00h, 36h, 07h, 01h
SA3:    DB      87, 120, 0, 15, 0D0h
SA3_END:

;==============================================================================
; 4  Bitmap (Graphic II), plne tabulky
;    Vzor: X v kazde bunce. Barva radku: ((i >> 3) + (i & 7) + (i >> 8)) & 15
;    na cerne. Radek 0 = popisek.
;==============================================================================
SCR4:
        CALL    PREP
        LD      HL, BMPT
        CALL    SETW
        LD      HL, 0
SCR4A:
        LD      A, L
        AND     7
        LD      C, A
        LD      B, 0
        PUSH    HL
        LD      HL, XPAT
        ADD     HL, BC
        LD      A, (HL)
        POP     HL
        OUT     (VDPD), A
        INC     HL
        LD      A, H
        CP      18h
        JR      NZ, SCR4A

        LD      HL, BMCT
        CALL    SETW
        LD      HL, 0
SCR4B:
        LD      A, L
        RRCA
        RRCA
        RRCA
        AND     1Fh
        LD      B, A
        LD      A, L
        AND     7
        ADD     A, B
        ADD     A, H
        AND     0Fh
        RLCA
        RLCA
        RLCA
        RLCA
        OR      01h
        OUT     (VDPD), A
        INC     HL
        LD      A, H
        CP      18h
        JR      NZ, SCR4B

        LD      HL, BMNT                ; jmena 3x 00h-FFh
        CALL    SETW
        LD      B, 3
SCR4C:
        XOR     A
SCR4D:
        OUT     (VDPD), A
        INC     A
        JR      NZ, SCR4D
        DJNZ    SCR4C

        LD      HL, BMSA
        CALL    SETW
        LD      A, 0D0h
        OUT     (VDPD), A
        LD      HL, TXT4
        CALL    BMTEXT
        LD      HL, REG_BM
        JP      SETREGS

REG_BM: DB      02h, 0C0h, 0Eh, 0FFh, 03h, 76h, 03h, 04h
XPAT:   DB      81h, 42h, 24h, 18h, 18h, 24h, 42h, 81h
TXT4:   DB      "4 BITMAP R3=FF R4=03", 0

;==============================================================================
; 5-9  Bitmap - masky tretin
;    Vzory: bloky P0 0000h, P1 0800h, P2 1000h - stejny font, znak 80h =
;    cislice bloku. Barvy: bloky C0 2000h (bila/modra), C1 2800h
;    (bila/cervena), C2 3000h (bila/zelena).
;    V kazde tretine je vypsano "VZOR P" + znak 80h -> cislo pouziteho bloku
;    vzoru; barva pozadi tretiny = pouzity blok barev.
;==============================================================================
BMTHIRD:
        PUSH    HL                      ; registry
        PUSH    DE                      ; texty
        CALL    PREP
        LD      DE, 0000h
        CALL    LDFONT
        LD      DE, 0800h
        CALL    LDFONT
        LD      DE, 1000h
        CALL    LDFONT
        CALL    DIGITS
        LD      HL, FT_THIRD
        CALL    FILLT
        POP     HL
        LD      C, 0
        CALL    PLIST
        LD      HL, TXT_THIRDS
        CALL    PLIST
        POP     HL
        JP      SETREGS

FT_THIRD:
        DW      2000h, 800h
        DB      0F4h
        DW      2800h, 800h
        DB      0F6h
        DW      3000h, 800h
        DB      0FCh
        DW      BMSA, 1
        DB      0D0h
        DW      0FFFFh

SCR5:
        LD      HL, REG5
        LD      DE, TXT5
        JP      BMTHIRD
SCR6:
        LD      HL, REG6
        LD      DE, TXT6
        JP      BMTHIRD
SCR7:
        LD      HL, REG7
        LD      DE, TXT7
        JP      BMTHIRD
SCR8:
        LD      HL, REG8
        LD      DE, TXT8
        JP      BMTHIRD
SCR9:
        LD      HL, REG9
        LD      DE, TXT9
        JP      BMTHIRD

REG5:   DB      02h, 0C0h, 0Eh, 0FFh, 03h, 76h, 03h, 01h
REG6:   DB      02h, 0C0h, 0Eh, 09Fh, 00h, 76h, 03h, 01h
REG7:   DB      02h, 0C0h, 0Eh, 0BFh, 01h, 76h, 03h, 01h
REG8:   DB      02h, 0C0h, 0Eh, 0DFh, 02h, 76h, 03h, 01h
REG9:   DB      02h, 0C0h, 0Eh, 0BFh, 02h, 76h, 03h, 01h

TXT5:
        DW      BMNT + 0*32
        DB      "5 MASKY TRETIN R3=FF R4=03", 0
        DW      BMNT + 1*32
        DB      "OCEK: P0C0 P1C1 P2C2", 0
        DW      BMNT + 2*32
        DB      "FPGA: STEJNE", 0
        DW      0FFFFh
TXT6:
        DW      BMNT + 0*32
        DB      "6 MASKY TRETIN R3=9F R4=00", 0
        DW      BMNT + 1*32
        DB      "OCEK: P0C0 P0C0 P0C0", 0
        DW      BMNT + 2*32
        DB      "FPGA: STEJNE", 0
        DW      0FFFFh
TXT7:
        DW      BMNT + 0*32
        DB      "7 MASKY TRETIN R3=BF R4=01", 0
        DW      BMNT + 1*32
        DB      "OCEK: P0C0 P1C1 P0C0", 0
        DW      BMNT + 2*32
        DB      "FPGA: P0C0 P0C0 P2C2 (CHYBA)", 0
        DW      0FFFFh
TXT8:
        DW      BMNT + 0*32
        DB      "8 MASKY TRETIN R3=DF R4=02", 0
        DW      BMNT + 1*32
        DB      "OCEK: P0C0 P0C0 P2C2", 0
        DW      BMNT + 2*32
        DB      "FPGA: P0C0 P1C1 P0C0 (CHYBA)", 0
        DW      0FFFFh
TXT9:
        DW      BMNT + 0*32
        DB      "9 MASKY TRETIN R3=BF R4=02", 0
        DW      BMNT + 1*32
        DB      "OCEK: P0C0 P0C1 P2C0", 0
        DW      BMNT + 2*32
        DB      "FPGA: P0C0 P1C0 P0C2 (CHYBA)", 0
        DW      0FFFFh

; Spolecne radky obrazovek 5-9
TXT_THIRDS:
        DW      BMNT + 3*32
        DB      "C0 MODRA C1 CERVENA C2 ZELENA", 0
        DW      BMNT + 5*32 + 2
        DB      "TRETINA 1  VZOR P", 80h, 0
        DW      BMNT + 13*32 + 2
        DB      "TRETINA 2  VZOR P", 80h, 0
        DW      BMNT + 21*32 + 2
        DB      "TRETINA 3  VZOR P", 80h, 0
        DW      0FFFFh

;==============================================================================
; 10  Bitmap - maska cisla znaku, R3=EF (maska 03FFh), R4=03
;    Znaky 00h-7Fh: font, bila na modre. Znaky 80h-FFh: sachovnice,
;    sv. cervena na sv. zlute. Na originalu jsou znaky 80h-FFh kopii 00h-7Fh.
;==============================================================================
SCR10:
        CALL    PREP
        LD      DE, 0000h
        CALL    LDFONT
        LD      DE, 0800h
        CALL    LDFONT
        LD      DE, 1000h
        CALL    LDFONT
        LD      HL, 0400h
        CALL    CHECKER
        LD      HL, 0C00h
        CALL    CHECKER
        LD      HL, 1400h
        CALL    CHECKER
        LD      HL, FT_10
        CALL    FILLT
        LD      HL, TXT10
        LD      C, 0
        CALL    PLIST
        LD      HL, TXT10H
        LD      C, 80h                  ; stejne znaky s bitem 7
        CALL    PLIST
        LD      HL, REG10
        JP      SETREGS

; Sachovnice AAh/55h do 400h bajtu od HL
CHECKER:
        CALL    SETW
        LD      BC, 200h
CHECKER1:
        LD      A, 0AAh
        OUT     (VDPD), A
        LD      A, 55h
        OUT     (VDPD), A
        DEC     BC
        LD      A, B
        OR      C
        JR      NZ, CHECKER1
        RET

REG10:  DB      02h, 0C0h, 0Eh, 0EFh, 03h, 76h, 03h, 01h

FT_10:
        DW      2000h, 400h
        DB      0F4h
        DW      2400h, 400h
        DB      09Bh
        DW      2800h, 400h
        DB      0F4h
        DW      2C00h, 400h
        DB      09Bh
        DW      3000h, 400h
        DB      0F4h
        DW      3400h, 400h
        DB      09Bh
        DW      BMSA, 1
        DB      0D0h
        DW      0FFFFh

TXT10:
        DW      BMNT + 0*32
        DB      "10 MASKA ZNAKU R3=EF R4=03", 0
        DW      BMNT + 2*32
        DB      "HW: 4 RADKY ABC A 012 CITELNE", 0
        DW      BMNT + 3*32
        DB      "FPGA: P-Z A CISLICE CHYBNE,", 0
        DW      BMNT + 4*32
        DB      "RADKY 3,4 SACHOVNICE", 0
        DW      BMNT + 6*32 + 2
        DB      "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 0
        DW      BMNT + 7*32 + 2
        DB      "0123456789", 0
        DW      0FFFFh
TXT10H:
        DW      BMNT + 9*32 + 2
        DB      "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 0
        DW      BMNT + 10*32 + 2
        DB      "0123456789", 0
        DW      0FFFFh

;==============================================================================
; 11  Bitmap text (R0=02, R1=D0), R4=03
;    Bloky vzoru 0000h, 0800h, 1000h, 1800h: font + znak 80h = cislice 0-3.
;    Originalni text mode by pouzil jen blok R4*800h = 1800h (cislice 3).
;==============================================================================
SCR11:
        CALL    PREP
        CALL    FONT4
        LD      HL, TXT11
        LD      C, 0
        CALL    PLIST
        LD      HL, REG11
        JP      SETREGS

; Font do vsech 4 bloku vzoru a cislice bloku do znaku 80h
FONT4:
        LD      DE, 0000h
        CALL    LDFONT
        LD      DE, 0800h
        CALL    LDFONT
        LD      DE, 1000h
        CALL    LDFONT
        LD      DE, 1800h
        CALL    LDFONT
        JP      DIGITS

REG11:  DB      02h, 0D0h, 0Eh, 0FFh, 03h, 00h, 00h, 0F4h

TXT11:
        DW      BMNT + 0*40
        DB      "11 BITMAP TEXT (NEDOKUMENTOVANY) R4=03", 0
        DW      BMNT + 1*40
        DB      "HW: VZORY TRETIN 0,1,2   FPGA: 3,3,3", 0
        DW      BMNT + 5*40 + 2
        DB      "TRETINA 1  VZOR ", 80h, 0
        DW      BMNT + 13*40 + 2
        DB      "TRETINA 2  VZOR ", 80h, 0
        DW      BMNT + 21*40 + 2
        DB      "TRETINA 3  VZOR ", 80h, 0
        DW      0FFFFh

;==============================================================================
; 12  Bitmap multicolor (R0=02, R1=C8), R4=03
;    Bloky vzoru 0-2 vyplnene barvami (68h, 2Ch, 45h) -> na originalu 3
;    vodorovne pasy s boxy 4x4. Blok 3 (1800h) = font pro pripad, ze se
;    zobrazi text mode.
;==============================================================================
SCR12:
        CALL    PREP
        LD      DE, 1800h
        CALL    LDFONT
        LD      HL, FT_12
        CALL    FILLT
        LD      HL, TXT12
        LD      C, 0
        CALL    PLIST
        LD      HL, BMSA
        CALL    SETW
        LD      A, 0D0h
        OUT     (VDPD), A
        LD      HL, REG12
        JP      SETREGS

REG12:  DB      02h, 0C8h, 0Eh, 0FFh, 03h, 76h, 03h, 0F1h

FT_12:
        DW      0000h, 800h
        DB      68h
        DW      0800h, 800h
        DB      2Ch
        DW      1000h, 800h
        DB      45h
        DW      0FFFFh

TXT12:
        DW      BMNT + 0*40
        DB      "12 BITMAP MULTICOLOR (NEDOKUMENTOVANY)", 0
        DW      BMNT + 2*40
        DB      "HW: 3 PASY CERVENA, ZELENA, MODRA", 0
        DW      BMNT + 3*40
        DB      "FPGA: TENTO TEXT (TEXT MODE)", 0
        DW      0FFFFh

;==============================================================================
; 13  Nelegalni rezim M1+M2 (R1=D8)
;==============================================================================
SCR13:
        CALL    PREP
        LD      DE, G1PT
        CALL    LDFONT
        LD      HL, TXT13
        LD      C, 0
        CALL    PLIST
        LD      HL, REG13
        JP      SETREGS

REG13:  DB      00h, 0D8h, 06h, 00h, 00h, 00h, 00h, 0F4h

TXT13:
        DW      G1NT + 0*40
        DB      "13 NELEGALNI REZIM M1+M2, R1=D8", 0
        DW      G1NT + 2*40
        DB      "HW: SVISLE PRUHY 4 PX BILA, 2 PX MODRA", 0
        DW      G1NT + 3*40
        DB      "FPGA: TENTO TEXT (TEXT MODE)", 0
        DW      0FFFFh

;==============================================================================
; 14-19  Sprity (Graphic I, pozadi tmave modre, stav na radku 22)
;
; Popis obrazovky: DW vzory, DW delka vzoru, DW atributy, DW delka atributu,
;                  DW texty, DW registry
;==============================================================================
SPRSCR:
        PUSH    HL
        CALL    G1BASE
        POP     HL
        CALL    SPRCOPY                 ; vzory spritu
        LD      DE, G1SP
        CALL    SPRCOPY2
        CALL    SPRCOPY                 ; atributy
        LD      DE, G1SA
        CALL    SPRCOPY2
        LD      E, (HL)                 ; texty
        INC     HL
        LD      D, (HL)
        INC     HL
        PUSH    HL
        EX      DE, HL
        LD      C, 0
        CALL    PLIST
        POP     HL
        LD      E, (HL)                 ; registry
        INC     HL
        LD      D, (HL)
        PUSH    DE
        LD      HL, G1NT + 22*32 + 1
        LD      (STPOS), HL
        POP     HL
        JP      SETREGS

; Nacte z popisu (HL) zdroj do SRC a delku do BC; HL ukazuje za ne
SPRCOPY:
        LD      E, (HL)
        INC     HL
        LD      D, (HL)
        INC     HL
        LD      (SRCPTR), DE
        LD      C, (HL)
        INC     HL
        LD      B, (HL)
        INC     HL
        RET

; Kopie SRC -> VRAM DE, BC bajtu; zachova HL
SPRCOPY2:
        PUSH    HL
        LD      HL, (SRCPTR)
        CALL    COPY
        POP     HL
        RET

SCR14:
        LD      HL, D14
        JP      SPRSCR
SCR15:
        LD      HL, D15
        JP      SPRSCR
SCR16:
        LD      HL, D16
        JP      SPRSCR
SCR17:
        LD      HL, D17
        JP      SPRSCR
SCR18:
        LD      HL, D18
        JP      SPRSCR
SCR19:
        LD      HL, D19
        JP      SPRSCR

D14:    DW      SP8, SP8_END - SP8, SA14, SA14_END - SA14, TXT14, REG_S8
D15:    DW      FONT + 11h*8, 32, SA15, SA15_END - SA15, TXT15, REG_S16
D16:    DW      FONT + 11h*8, 32, SA15, SA15_END - SA15, TXT16, REG_S16M
D17:    DW      SP8, SP8_END - SP8, SA17, SA17_END - SA17, TXT17, REG_S8
D18:    DW      SP8, SP8_END - SP8, SA18, SA18_END - SA18, TXT18, REG_S8
D19:    DW      SP8, SP8_END - SP8, SA19, SA19_END - SA19, TXT19, REG_S8

REG_S8:   DB    00h, 0C0h, 06h, 80h, 00h, 36h, 07h, 04h
REG_S16:  DB    00h, 0C2h, 06h, 80h, 00h, 36h, 07h, 04h
REG_S16M: DB    00h, 0C3h, 06h, 80h, 00h, 36h, 07h, 04h

; Vzory 8x8: 0 = plny, 1 = ramecek
SP8:    DB      0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh
        DB      0FFh, 81h, 81h, 81h, 81h, 81h, 81h, 0FFh
SP8_END:

; Vzor 16x16 = glyfy "1234" z fontu (znak '1' = 31h, font od 20h)
; -> kvadranty 1 3 / 2 4. Adresa je primo v D15/D16: EQU s doprednou
; referenci na FONT by pasmo vyhodnotil uz v 1. pruchodu (FONT = 0).

; Atributy: Y, X, vzor, barva (+80h early clock)
SA14:
        DB      39, 40, 1, 15           ; 0 bily ramecek - nahore
        DB      43, 44, 0, 8            ; 1 cerveny plny - pod nim
        DB      79, 28, 0, 8Bh          ; 2 EC: X-32 = -4 -> vlevo 4 px
        DB      95, 0, 0, 11            ; 3 X=0 cely u leveho okraje
        DB      111, 252, 0, 11         ; 4 X=252 -> vpravo 4 px
        DB      0FCh, 160, 1, 14        ; 5 Y=-4 -> nahore 5 radku
        DB      188, 200, 1, 14         ; 6 Y=188 -> dole 3 radky
        DB      0FFh, 120, 1, 12        ; 7 Y=FF -> radky 0..7
        DB      0D0h
SA14_END:

SA15:
        DB      39, 40, 0, 15           ; 0 kvadranty
        DB      39, 24, 0, 8Fh          ; 1 EC: X-32 = -8
        DB      99, 248, 0, 9           ; 2 X=248 -> vpravo 8 px
        DB      99, 100, 0, 11          ; 3
        DB      0D0h
SA15_END:

SA17:
        DB      79, 20, 0, 15           ; 0-3 viditelne na radcich 80-87
        DB      79, 50, 0, 9
        DB      79, 80, 0, 3
        DB      79, 110, 0, 7
        DB      79, 140, 0, 11          ; 4 paty - nezobrazi se
        DB      119, 60, 0, 13          ; 5 viditelny
        DB      0D0h, 0, 0, 0           ; 6 konec seznamu
        DB      119, 120, 0, 15         ; 7 za koncem - nezobrazi se
SA17_END:

SA18:
        DB      99, 100, 0, 0           ; 0 pruhledny
        DB      103, 104, 0, 15         ; 1 bily, prekryva se s 0
        DB      0D0h
SA18_END:

SA19:
        DB      0BFh, 100, 0, 15        ; radek 0 spritu = radek 192
        DB      0BFh, 104, 0, 9         ; prekryv s 0
        DB      0BFh, 20, 0, 3
        DB      0BFh, 50, 0, 7
        DB      0BFh, 150, 0, 11        ; paty
        DB      0D0h
SA19_END:

TXT14:
        DW      G1NT + 3*32 + 1
        DB      "14 SPRITY 8X8", 0
        DW      G1NT + 10*32 + 2
        DB      "EC, X=28: VLEVO 4 PX", 0
        DW      G1NT + 12*32 + 2
        DB      "X=0: CELY", 0
        DW      G1NT + 14*32 + 10
        DB      "X=252: VPRAVO 4 PX", 0
        DW      G1NT + 20*32 + 1
        DB      "OCEK 5S=0 C=1 N=--", 0
        DW      0FFFFh
TXT15:
        DW      G1NT + 0*32 + 1
        DB      "15 SPRITY 16X16", 0
        DW      G1NT + 1*32 + 1
        DB      "KVADRANTY 1 3 / 2 4", 0
        DW      G1NT + 20*32 + 1
        DB      "OCEK 5S=0 C=0 N=--", 0
        DW      0FFFFh
TXT16:
        DW      G1NT + 0*32 + 1
        DB      "16 SPRITY 16X16 ZVETSENE", 0
        DW      G1NT + 1*32 + 1
        DB      "KVADRANTY 1 3 / 2 4", 0
        DW      G1NT + 20*32 + 1
        DB      "OCEK 5S=0 C=0 N=--", 0
        DW      0FFFFh
TXT17:
        DW      G1NT + 0*32 + 1
        DB      "17 PATY SPRITE, KONEC Y=D0", 0
        DW      G1NT + 1*32 + 1
        DB      "RADEK 80: 4 VIDET, PATY NE", 0
        DW      G1NT + 2*32 + 1
        DB      "RADEK 120: JEN 1 SPRITE", 0
        DW      G1NT + 20*32 + 1
        DB      "OCEK 5S=1 C=0 N=04", 0
        DW      0FFFFh
TXT18:
        DW      G1NT + 0*32 + 1
        DB      "18 KOLIZE S PRUHLEDNYM", 0
        DW      G1NT + 1*32 + 1
        DB      "VIDET JEN BILY SPRITE", 0
        DW      G1NT + 20*32 + 1
        DB      "OCEK 5S=0 C=1 N=--", 0
        DW      0FFFFh
TXT19:
        DW      G1NT + 0*32 + 1
        DB      "19 SPRITY NA RADKU 192, Y=BF", 0
        DW      G1NT + 1*32 + 1
        DB      "NIC NENI VIDET", 0
        DW      G1NT + 20*32 + 1
        DB      "FPGA? 5S=1 C=1 N=04", 0
        DW      G1NT + 21*32 + 1
        DB      "HW: ZAPSAT VYSLEDEK", 0
        DW      0FFFFh

;==============================================================================
; Font 5x7 pro znaky 20h-5Fh (bity 7..3, bity 2..0 a radek 7 prazdne,
; takze funguje i v text mode se 6 px sirokymi znaky)
;==============================================================================
FONT:
        DB      000h,000h,000h,000h,000h,000h,000h,000h  ; 20 mezera
        DB      020h,020h,020h,020h,020h,000h,020h,000h  ; 21 !
        DB      050h,050h,000h,000h,000h,000h,000h,000h  ; 22 "
        DB      050h,050h,0F8h,050h,0F8h,050h,050h,000h  ; 23 #
        DB      020h,078h,0A0h,070h,028h,0F0h,020h,000h  ; 24 $
        DB      0C0h,0C8h,010h,020h,040h,098h,018h,000h  ; 25 %
        DB      060h,090h,0A0h,040h,0A8h,090h,068h,000h  ; 26 &
        DB      020h,020h,040h,000h,000h,000h,000h,000h  ; 27 apostrof
        DB      010h,020h,040h,040h,040h,020h,010h,000h  ; 28 (
        DB      040h,020h,010h,010h,010h,020h,040h,000h  ; 29 )
        DB      000h,020h,0A8h,070h,0A8h,020h,000h,000h  ; 2A *
        DB      000h,020h,020h,0F8h,020h,020h,000h,000h  ; 2B +
        DB      000h,000h,000h,000h,060h,020h,040h,000h  ; 2C ,
        DB      000h,000h,000h,0F8h,000h,000h,000h,000h  ; 2D -
        DB      000h,000h,000h,000h,000h,060h,060h,000h  ; 2E .
        DB      000h,008h,010h,020h,040h,080h,000h,000h  ; 2F /
        DB      070h,088h,098h,0A8h,0C8h,088h,070h,000h  ; 30 0
        DB      020h,060h,020h,020h,020h,020h,070h,000h  ; 31 1
        DB      070h,088h,008h,010h,020h,040h,0F8h,000h  ; 32 2
        DB      0F8h,010h,020h,010h,008h,088h,070h,000h  ; 33 3
        DB      010h,030h,050h,090h,0F8h,010h,010h,000h  ; 34 4
        DB      0F8h,080h,0F0h,008h,008h,088h,070h,000h  ; 35 5
        DB      030h,040h,080h,0F0h,088h,088h,070h,000h  ; 36 6
        DB      0F8h,008h,010h,020h,040h,040h,040h,000h  ; 37 7
        DB      070h,088h,088h,070h,088h,088h,070h,000h  ; 38 8
        DB      070h,088h,088h,078h,008h,010h,060h,000h  ; 39 9
        DB      000h,060h,060h,000h,060h,060h,000h,000h  ; 3A :
        DB      000h,060h,060h,000h,060h,020h,040h,000h  ; 3B strednik
        DB      010h,020h,040h,080h,040h,020h,010h,000h  ; 3C <
        DB      000h,000h,0F8h,000h,0F8h,000h,000h,000h  ; 3D =
        DB      040h,020h,010h,008h,010h,020h,040h,000h  ; 3E >
        DB      070h,088h,008h,010h,020h,000h,020h,000h  ; 3F ?
        DB      070h,088h,008h,068h,0A8h,0A8h,070h,000h  ; 40 @
        DB      070h,088h,088h,0F8h,088h,088h,088h,000h  ; 41 A
        DB      0F0h,088h,088h,0F0h,088h,088h,0F0h,000h  ; 42 B
        DB      070h,088h,080h,080h,080h,088h,070h,000h  ; 43 C
        DB      0E0h,090h,088h,088h,088h,090h,0E0h,000h  ; 44 D
        DB      0F8h,080h,080h,0F0h,080h,080h,0F8h,000h  ; 45 E
        DB      0F8h,080h,080h,0F0h,080h,080h,080h,000h  ; 46 F
        DB      070h,088h,080h,0B8h,088h,088h,078h,000h  ; 47 G
        DB      088h,088h,088h,0F8h,088h,088h,088h,000h  ; 48 H
        DB      070h,020h,020h,020h,020h,020h,070h,000h  ; 49 I
        DB      038h,010h,010h,010h,010h,090h,060h,000h  ; 4A J
        DB      088h,090h,0A0h,0C0h,0A0h,090h,088h,000h  ; 4B K
        DB      080h,080h,080h,080h,080h,080h,0F8h,000h  ; 4C L
        DB      088h,0D8h,0A8h,0A8h,088h,088h,088h,000h  ; 4D M
        DB      088h,088h,0C8h,0A8h,098h,088h,088h,000h  ; 4E N
        DB      070h,088h,088h,088h,088h,088h,070h,000h  ; 4F O
        DB      0F0h,088h,088h,0F0h,080h,080h,080h,000h  ; 50 P
        DB      070h,088h,088h,088h,0A8h,090h,068h,000h  ; 51 Q
        DB      0F0h,088h,088h,0F0h,0A0h,090h,088h,000h  ; 52 R
        DB      078h,080h,080h,070h,008h,008h,0F0h,000h  ; 53 S
        DB      0F8h,020h,020h,020h,020h,020h,020h,000h  ; 54 T
        DB      088h,088h,088h,088h,088h,088h,070h,000h  ; 55 U
        DB      088h,088h,088h,088h,088h,050h,020h,000h  ; 56 V
        DB      088h,088h,088h,0A8h,0A8h,0A8h,050h,000h  ; 57 W
        DB      088h,088h,050h,020h,050h,088h,088h,000h  ; 58 X
        DB      088h,088h,050h,020h,020h,020h,020h,000h  ; 59 Y
        DB      0F8h,008h,010h,020h,040h,080h,0F8h,000h  ; 5A Z
        DB      070h,040h,040h,040h,040h,040h,070h,000h  ; 5B [
        DB      000h,080h,040h,020h,010h,008h,000h,000h  ; 5C zpetne lomitko
        DB      070h,010h,010h,010h,010h,010h,070h,000h  ; 5D ]
        DB      020h,050h,088h,000h,000h,000h,000h,000h  ; 5E ^
        DB      000h,000h,000h,000h,000h,000h,0F8h,000h  ; 5F _

END_OF_ROM:
