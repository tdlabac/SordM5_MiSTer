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
- M1 potvrzení přerušení (`IntCycle`) je hranice. Hlásí se jako
  „přerušení“ a při krokování jde INT maskovat;
- během HALT je každý M1 hranice.

MREQ/RD/M1 jsou v tu chvíli aktivní (fetch probíhá). To nevadí, paměť jen
čte, a při přístupu debuggeru je sběrnice přepnutá multiplexorem.

**Otevřené:** ověřit testem, že v tomto bodě jsou opravdu všechny zápisy
hotové pro všechny instrukce (hlavně `EX`, `EXX`, blokové instrukce,
`LD A,I/R`, `POP AF`).

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

- Obsah: AF, BC, DE, HL, AF', BC', DE', HL', IX, IY, SP, PC, I, R, IFF1,
  IFF2, IM (přesné rozložení se určí při implementaci a zdokumentuje).
- `tv80.sv`: `assign REG`; při `DIRSet` přepsat ACC/F/Ap/Fp/SP/PC/I/R/IFF/
  IStatus a zároveň `A <= PC`.
- `tv80_reg.sv`: zápis celé banky při `DIRSet`, nezávisle na `CEN`.
- `tv80a.sv`: protáhnout REG/DIRSet/DIR a výstupy MC, TS, IntCycle_n, prefix.
- Rozsah 40–60 řádků, bez vlivu na chování při `DIRSet = 0`.

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

1. **Testy TV80 před změnou.** Zmrazená kopie dnešního TV80 (`rtl/CPU/tb/ref`,
   moduly s předponou `REF_`) a lockstep test: dnešní/upravený TV80 proti
   kopii, náhodný program, náhodné INT/NMI/WAIT/BUSRQ, porovnání všech
   výstupů v každém taktu. Stávající `tb_tv80` (IM0/1/2) zůstává.
2. **Obálka `tv80_dbg`** jako průchozí, lockstep proti kopii.
3. `REG/DIRSet` v TV80 + test (snímek registrů na hranicích, zápis a ověření
   přes PUSH na sběrnici). Lockstep musí dál projít.
4. `freeze` v `clock.sv`, místo zastavení, krok. Test: běh se zastaveními
   musí dát stejný průběh jako běh bez nich (lockstep s posunem času).
5. Breakpointy, přístup k paměti, registrový prostor, DPI přenos, GUI
   v simulaci.
6. UART, případně DDR.
