# Debugger Z80 — návrh

Stav: návrh, 2026-09-19. Implementace začíná testy (viz „Postup“).

Cíl: debugger procesoru Z80 (TV80) v jádře Sord M5, který funguje v FPGA
i v simulaci Verilatorem, s co nejmenším zásahem do TV80.

## Požadavky

- HW breakpointy, cca 9 slotů:
  - zastavení na adrese při execute, read, write,
  - podmínka na hodnotu při read/write,
  - zastavení při I/O na konkrétním portu (read/write).
- Úplný stav procesoru při zastavení.
- Krokování po instrukcích.
- Změna registrů procesoru.
- Čtení a úprava RAM, čtení ROM.
- **Zastavení zmrazí celý počítač, ne jen CPU.** Všechny periferie (VDP, CTC,
  SGC, klávesnice, rozšiřující sběrnice) stojí spolu s CPU. Debugování nesmí
  vnést stavy, které by při běžném chodu nenastaly: CTC nesmí dál počítat
  a hromadit přerušení, VDP nesmí posunout snímek, zvuk nesmí běžet dál.

## Architektura

```
                       clock.sv  ◄── freeze ───────────────┐
                    (všechny CE = 0)                       │
                           │ ce_*                          │
            ┌──────────────┼────────── tv80_dbg ───────────┼──────────────┐
            │              ▼                               │              │
            │           TV80a ──► A/DO/MREQ/RD/WR/IORQ/M1 ──► MUX ─────────┼─► sběrnice M5
            │            ▲ │                                ▲             │
            │   REG/DIR  │ │ MC/TS/IntCycle/prefix           │ přístup     │
            │   ┌────────┴─▼─────────────────┐               │ k paměti    │
            │   │ jádro debuggeru: BP ×9,    ├───────────────┘             │
            │   │ krok, stav, mailbox        │◄── DI (AND sběrnice)        │
            │   └────────────┬───────────────┘                             │
            └────────────────┼─────────────────────────────────────────────┘
                     registrový prostor debuggeru
                  ┌──────────┼──────────┐
                UART        DDR        DPI (Verilator)
```

- **`tv80_dbg`** je obálka kolem `TV80a` se stejnými porty sběrnice a navíc
  debug rozhraním. V `SordM5.sv` nahradí `TV80a`.
- Parametr `DEBUG` na obálce: `generate` buď s debuggerem, nebo jen holé
  `TV80a` (produkční build bez debuggeru). Porty TV80 se makry neřídí.

## Zmrazení celého počítače

Zastavení nedělá brána na CE jen do CPU, ale **zastavení zdroje taktu**:

- `clock.sv` dostane vstup `freeze`. Při `freeze = 1` stojí děliče (`div4`,
  `div6`) a všechny `ce_*` jsou 0. Každá periferie, která pracuje přes
  `ce_*`, tak stojí ve stejném taktu jako CPU. Po uvolnění se děliče rozběhnou
  ze stejné fáze a stav je stejný, jako by zastavení nebylo.
- Proč ne WAIT_n: vzorkuje se jen v T2 paměťového nebo I/O cyklu, CPU stojí
  s aktivním MREQ/RD a periferie běží dál.
- Paměti (bram) běží na `clk_sys` bez CE, takže čtení a zápis debuggerem
  funguje i při zmrazení.

Co je potřeba ohlídat:

- **Audit periferií na logiku bez CE.** Všechno, co se mění v čase jen
  s `clk_sys`, zmrazení poruší. Známé případy:
  - CTC: detektory hran triggerů a `wr_pulse` běží na `clk_sys`. Při
    zmrazení jsou vstupy statické, takže nevadí, ale debugger nesmí na
    sběrnici vyrobit I/O cyklus na CTC.
  - jt89: `last_csn` na `clk_sys`, stejné pravidlo.
  - VDP: ověřit, že vše běží na `clk_en_10m7`.
- **Vnější vstupy během zmrazení:**
  - klávesnice (PS/2 z HPS): stisk se zapíše hned. Zvážit frontu nebo CE
    i pro `keyboard`, aby se změna projevila až po rozběhu;
  - ioctl (nahrávání ROM): při zmrazení zakázat, nebo brát jako reset.
- **Video:** zmrazené VDP negeneruje synchronizaci. Na HDMI použít
  `HDMI_FREEZE = 1` (framework drží poslední snímek). Analogový výstup
  synchronizaci ztratí, to je přijatelné.
- **Zvuk:** jt89 drží poslední vzorek, jde o stejnosměrnou složku. Při
  zmrazení ztlumit, aby nebylo slyšet cvaknutí.
- **Přístupy debuggeru na sběrnici:** pro paměť jen MREQ, nikdy IORQ, a
  M1_n = 1. I/O přístup debuggerem vnáší stav (stavový registr VDP,
  klávesnice, CTC), proto jen jako výslovný příkaz s varováním.

## Hranice instrukce a místo zastavení

Z80 překrývá dokončení instrukce s fetchem další. Výsledek ALU a čtení do
registru (`Save_ALU_r`, `Read_To_Reg_r`) se zapíše až na CE_p na konci T1
prvního M1 následující instrukce. Zastavovat se proto bude:

- v **M1, TState = 2** (po CE_p, která ukončila T1), kdy:
  - všechny zápisy předchozí instrukce jsou hotové,
  - `PC` = adresa nové instrukce, `A` = `PC`,
  - opkód ještě není načtený (`IR` se plní na konci T2),
  - `R` ještě není inkrementované;
- jen když nejde o pokračování prefixu: `ISet == 0 && XY_State == 0`
  (po `CB`/`ED`/`DD`/`FD` se hranice přeskakuje);
- M1 potvrzení přerušení (`IntCycle`) a NMI hranice **není** (viz krok 5a),
  krok do přerušení skončí na první instrukci obsluhy;
- během HALT je každý M1 hranice.

MREQ/RD/M1 jsou v tu chvíli aktivní (fetch probíhá). To nevadí, paměť jen
čte, a při přístupu debuggeru je sběrnice přepnutá multiplexorem.

**Ověřeno** (`rtl/CPU/tb/run_regs.sh`): v tomto bodě jsou dopsané všechny
registry u ALU, INC/DEC, 16bit, EX, EXX, POP AF, SCF/CPL, LD A,I/R, LD R,A,
LDI/LDIR, DJNZ, CALL/RET, JP (HL), IN, NEG, DD/FD a DDCB. PC na hranici je
vždy adresa začátku instrukce, prefixy se přeskakují.

Jediná výjimka je **EI**: TV80 nastaví IFF až v T2 následujícího M1
(`SetEI` se dekóduje z IR, kde je ještě FB), takhle dělá zpoždění přijetí
přerušení. `REG` proto hlásí `IFF | SetEI`, což odpovídá Z80. Omezení:
`DIRSet` s IFF = 0 hned po EI odložené EI stejně nastaví na 1.

## Breakpointy

9 slotů + 1 interní pro krok. Každý slot:

| pole | význam |
|---|---|
| `en`, `type` | EXEC / MEM_RD / MEM_WR / IO_RD / IO_WR, bitová maska |
| `addr`, `addr_mask` | adresa, maskou rozsah; u I/O jen A[7:0] |
| `data`, `data_mask` | podmínka na hodnotu, maska 0 = nerozhoduje |

- **EXEC**: shoda `A` na hranici instrukce, zastaví se před provedením.
- **MEM/IO**: vyhodnotí se na konci cyklu (čtení z DI, zápis z DO). M1 fetch
  a refresh se u MEM vynechají. Zásah se poznačí a zastaví se na nejbližší
  hranici instrukce, instrukce se dokončí.
- Hlášení: slot, adresa a data zásahu, PC instrukce, která zásah způsobila,
  aktuální PC.
- **Krok**: rozběh a zastavení na další hranici, volitelně s maskovaným INT.
  Periferie během kroku běží přesně o délku instrukce, takže krokování
  nevnáší rozdíly proti běžnému chodu.

## Registry: zásah do TV80

Jediný zásah do procesoru. Rozhraní podle T80 v MiSTer jádrech (save state):

```systemverilog
output logic [211:0] REG,     // snímek registrů
input               DIRSet,   // 1 takt: nahrát DIR
input        [211:0] DIR
```

Implementováno. Rozložení `REG`/`DIR` (bit 0 = LSB):

| bity | registr | bity | registr |
|---|---|---|---|
| 7:0 | A | 111:96 | DE |
| 15:8 | F | 127:112 | HL |
| 23:16 | A' | 143:128 | BC' |
| 31:24 | F' | 159:144 | DE' |
| 39:32 | I | 175:160 | HL' |
| 47:40 | R | 191:176 | IX |
| 63:48 | SP | 207:192 | IY |
| 79:64 | PC | 208 / 209 | IFF1 / IFF2 |
| 95:80 | BC | 211:210 | IM |

- `tv80.sv`: `REG` je architektonický pohled. Banka je fyzicky
  `{Alternate, pár}` (0 = BC, 1 = DE, 2 = HL, IX na 3, IY na 7) a `EXX`
  jen přepíná `Alternate`. `DIRSet` přepíše ACC/F/Ap/Fp/I/R/SP/PC/IStatus/IFF
  a zároveň `A <= PC`, aby rozběhnutý fetch šel z nové adresy.
- `DIRSet` **nemění `Alternate`**: adresy banky (`RegAddrA_r/B_r/C`) jsou
  registrované s jeho dnešní hodnotou a po přepnutí by první takt četl ze
  špatné sady (našel lockstep v režimu 2). Sady se místo toho zapisují na
  fyzické indexy podle `Alternate`.
- `tv80_reg.sv`: zápis celé banky při `DIRSet` (má přednost, nezávisí na
  `CEN`) a výstup `REGS` s celou bankou. Banka se tím syntetizuje z
  klopných obvodů místo paměti (16 B).
- `tv80a.sv`: protahuje REG/DIRSet/DIR a výstupy `DbgMCycle`, `DbgTState`,
  `DbgPrefix`, `DbgIntCycle`, `DbgNMICycle`.
- `DIRSet` smí přijít jen při zastaveném CE.
- Nepokryté: `WZ` (MEMPTR, ovlivňuje nedokumentované příznaky `BIT n,(HL)`)
  a stav „po EI“ (drží ho IR, `DIRSet` ho nemění).

## Paměť

- Při zmrazení obálka převezme sběrnici (multiplexor A/DO/MREQ/RD/WR,
  IORQ_n = 1, M1_n = 1) a automat „nastav, počkej 2–3 takty clk_sys,
  vzorkuj DI“. Funguje na ROM, RAM, cartridge a `ext_bus`.
- Omezení: ROM přes sběrnici nejde zapsat, VRAM je za VDP.
- Později: přímý debug port do jednotlivých pamětí (jako port B
  v `rom_ioctl`).

## Registrový prostor a přenos

Jádro debuggeru má registrový prostor (adresa + data), přenos je jen adaptér:

```
0x00 CTRL    run/stop/step, mask_int_on_step
0x01 STATUS  stopped, hit_mask[9], důvod
0x02..       HIT_ADDR, HIT_DATA, HIT_PC
0x10..       BP[0..8] {cfg, addr, addr_mask, data, data_mask}
0x40..       REG snímek, zápis + REG_COMMIT → DIRSet
0x60..       MEM mailbox {addr, data, cmd: rd/wr/io_rd/io_wr, busy}
```

| přenos | poznámka |
|---|---|
| DPI (Verilator) | první krok, ladění debuggeru v simulaci |
| UART přes HPS (`/dev/ttyS1`) | bez dalšího HW, na Linuxu `socat` → TCP |
| UART na USER port | potřebuje USB-serial převodník |
| DDR sdílená s ARM | propustnost pro trace buffer, arbitráž DDRAM + daemon |

Na PC most na GDB Remote Serial Protocol (Python). Ve FPGA se RSP neřeší.

## Postup

1. ✅ **Testy TV80 před změnou.** Zmrazená kopie TV80 (`rtl/CPU/tb/ref`,
   moduly `REF_*`, generuje `make_ref.sh`) a lockstep test
   (`run_lockstep.sh`): upravený TV80 proti kopii, náhodný program, náhodné
   INT/NMI/WAIT/BUSRQ, porovnání A, DO a všech řídicích výstupů v každém
   taktu. Režimy `LS_MODE`: 0 bez zásahu, 1 zmrazení CE na každé hranici,
   2 zmrazení + `DIRSet` s vlastním `REG`. Stávající `tb_tv80` (IM0/1/2)
   zůstává.
2. ✅ **Obálka `tv80_dbg`** jako průchozí, lockstep proti kopii (`DUT_DBG=1`).
3. ✅ `REG/DIRSet` v TV80 + test `run_regs.sh` (REG na každé hranici proti
   očekávanému stavu, DIRSet v Alternate = 1, výpis PUSH na zásobník, IM/IFF
   z DIRSet přes INT). Lockstep ve všech režimech prochází.
4. ✅ `freeze` v `clock.sv`, zastavení na hranici a krok v `tv80_dbg`
   (`DEBUG = 1`, porty `dbg_stop/step/dirset/dir/stopped/reg` vyvedené ze
   `SordM5`, v kořeni zatím uzemněné, `HDMI_FREEZE = dbg_stopped`).
   `freeze` naskočí takt clk_sys po hraně CE_p, která hranici vytvořila.
   Test `rtl/tb/run_freeze.sh`: dvě instance celého `SordM5` z monitor ROM
   a BASIC-I, instance a se náhodně zastavuje, krokuje a dostává DIRSet,
   instance b dostává takt jen když a nestojí. Video, zvuk, sběrnice CPU
   a registry se shodují v každém taktu, RAM a VRAM na konci. Samotest:
   `clock.sv`, jehož freeze nezastaví VDP, test shodí v prvním zmrazeném
   taktu. Audit periferií na logiku bez CE tím prošel (CTC, jt89, VDP,
   klávesnice bez vstupu).
5a. ✅ Breakpointy, krok s maskou INT, přístup do paměti. Rozhraní je
   `tv80_dbg_pkg::dbg_in_t` / `dbg_out_t` (`rtl/CPU/tv80_dbg_pkg.sv`), ze
   `SordM5` vede ven jako `dbg_i` / `dbg_o`. Ovládání pulzy `stop`, `run`,
   `step` (zastavení drží, dokud nepřijde `run`/`step`, i když ho způsobil
   breakpoint). Rozhodnutí při implementaci:
   - M1 potvrzení INT/NMI **není** hranice (zastavení uprostřed potvrzení
     a převzetí sběrnice by rozbilo vektor). Krok do přerušení skončí na
     první instrukci obsluhy; `step_noint` INT během kroku maskuje.
   - Přístup debuggeru jen do paměti (I/O ne: periferie s CE by při
     zmrazení stejně neodpověděly a čtení I/O má vedlejší účinky).
   - **CTC: detekce RETI vzorkuje jen na `ce_3m58_p`** (jako skutečný
     Z80-CTC). Na každém taktu clk_sys by při převzetí sběrnice uprostřed
     fetche `ED` viděla opkód dvakrát a RETI ztratila. Samotest: se starou
     detekcí `tb_freeze` selže.
   Testy: `rtl/CPU/tb/run_dbg.sh` (všechny typy BP, podmínka na data,
   rozsah, fetch není MRD, krok, INT při kroku, čtení/zápis paměti) a
   `rtl/tb/run_freeze.sh` rozšířený o breakpointy, čtení paměti (kontrola
   proti ROM a RAM) a zápis přečtené hodnoty zpět; 3 semínka × 6 M taktů,
   každé ~11 000 zastavení breakpointem a ~45 000 čtení, bez rozdílu.
5b. Registrový prostor, DPI přenos, ovládání v simulaci.
6. UART, případně DDR.
