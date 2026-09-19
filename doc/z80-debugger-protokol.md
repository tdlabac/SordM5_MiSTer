# Debugger Z80 — přenos přes HPS a nástroje

Jak se k debuggeru v jádře (návrh v [z80-debugger.md](z80-debugger.md))
dostat zvenku: fyzická cesta, protokol a nástroje v `tools/z80dbg`.

## Cesta

```
PC (gdb, DeZog, CLI)                      MiSTer (Linux na HPS)                 FPGA
─────────────────────                     ─────────────────────                 ────
z80dbg.gdbstub / cli ──TCP──► z80dbg_bridge.py ──► /dev/ttyS1 ──UART──► dbg_link ─► tv80_dbg_regs ─► tv80_dbg
                              (nebo gdbstub / cli přímo na MiSTeru nad /dev/ttyS1)
```

- UART jádra (`UART_TXD`/`UART_RXD` v `emu`) vede framework `sys/sys_top.v`
  na UART periferii HPS. V Linuxu na MiSTeru je to **`/dev/ttyS1`**.
- **230 400 Bd, 8N1**, bez řízení toku. HPS UART má takt 100 MHz a vyšší
  standardní rychlosti z něj vycházejí s chybou 3–4 %. `clk_sys` jádra je
  21,477272 MHz, dělitel 93 (chyba 0,2 %).
- Port nesmí mít otevřený nikdo jiný. V menu MiSTeru musí být UART mód
  **None** (jádro UART do menu neohlašuje, takže by tam měl být).
- Na HW to zatím **není ověřené**. Ověřené je to na modelu jádra
  (`rtl/CPU/tb/run_uart.sh`), viz Testy.

## Protokol

Binární, host posílá příkaz a čeká na odpověď (kromě `W`). Argumenty jsou
bajty, 16bitové hodnoty little-endian.

| příkaz | bajty | odpověď |
|---|---|---|
| ping | `P` | `5Ah` |
| čtení registru | `R a` | 1 B |
| zápis registru | `W a d` | — |
| čtení bloku registrů | `B a n` (n = 0 → 256) | n B |
| čtení paměti | `M lo hi nlo nhi` (n = 0 → 65 536) | n B |
| zápis paměti | `N lo hi nlo nhi d…` | `5Ah` po posledním bajtu |

- Paměť se čte a zapisuje **jen při zastavení** (převzetím sběrnice). Za běhu
  vrátí `M` nesmysly a `N` nic nezapíše.
- Když argument nepřijde do 20 ms, jádro rozpracovaný příkaz zahodí. Host
  se tak dostane do známého stavu: počkat 50 ms a poslat `P`.
- Propustnost čtení paměti je zhruba 20 kB/s (1 B odpovědi = 1 znak UART).

Registry (`a`) jsou registrový prostor `rtl/CPU/tv80_dbg_regs.sv`:

| adresa | čtení | zápis |
|---|---|---|
| 00h | stav: b0 stojí, b1 přístup do paměti, b4:2 důvod | příkaz: b0 stop, b1 run, b2 step, b3 commit registrů, b4 snap |
| 01h | volby | b0 maskovat INT při kroku |
| 02h | 5Ah | |
| 03h | počet breakpointů (9) | |
| 04h–06h | adresa a data zásahu | |
| 08h–09h | PC instrukce se zásahem | |
| 0Ah–0Bh | maska zasažených breakpointů | |
| 10h–12h | adresa a data pro přístup do paměti | |
| 13h | přečtená data | 1 = čtení, 2 = zápis |
| 18h–1Dh | čas počítače: takty CPU od resetu, 48 bitů LE (zachytí se při vstupu adresy do rozsahu) | |
| 20h–3Ah | registry CPU (27 B, rozložení v `tv80.sv`) | staging, platí po commit |
| 40h + 8·i | breakpoint i: typ, adresa, maska, data, dmaska | totéž |

Důvod zastavení: 0 běží, 1 stop, 2 krok, 3 breakpoint provedení,
4 breakpoint přístupu. Typ breakpointu je bitová maska: 1 provedení,
2 čtení paměti, 4 zápis paměti, 8 čtení I/O, 16 zápis I/O.

Příklad „zastav a přečti registry“: `W 00 01`, opakovat `R 00` dokud b0 = 0,
pak `B 20 1B`.

## Nástroje (`tools/z80dbg`)

Python 3, jen standardní knihovna (na Windows se sériovým portem pyserial).
Na MiSTer stačí adresář `tools/z80dbg` zkopírovat, třeba do `/media/fat/z80dbg`.

| co | jak |
|---|---|
| knihovna | `from z80dbg import open_link, Z80Debugger` |
| příkazová řádka | `python3 -m z80dbg.cli --link /dev/ttyS1` |
| GDB stub | `python3 -m z80dbg.gdbstub --link /dev/ttyS1 --port 5555` |
| most TCP ↔ UART | `python3 mister/z80dbg_bridge.py` (na MiSTeru, port 5556) |

`--link` je buď sériový port, nebo `host:port` (TCP na most nebo na model).

### Příkazová řádka

```
python3 -m z80dbg.cli --link mister:5556
z80> stop                  zastavit, vypsat registry
z80> step 5 noint          5 instrukcí, INT maskované
z80> bp 0 x 1A2B           breakpoint na provedení
z80> bp 1 w 7000 f000      zápis kamkoli do 7000h-7FFFh
z80> bp 2 r+w 7010 ffff 3C ff   čtení/zápis 7010h s hodnotou 3Ch
z80> run
z80> wait                  počkat na breakpoint, vypsat zásah
z80> set hl=1234 a=42      změna registrů
z80> mem 7000 40 / wmem 7000 01 02 / save f.bin 7000 1000 / load f.bin 7000
z80> time                  čas počítače (značka pro simulaci, doc/z80-debugger.md)
```

Neinteraktivně: `-c "stop" -c "regs" -c "run"`.

### GDB stub

Rozložení registrů je stejné jako u gdbstubu v MAME pro Z80
(`AF BC DE HL AF' BC' DE' HL' IX IY SP PC`, 16 bitů, `target.xml`
s `mame.z80`). Breakpointy `Z0`/`Z1` jdou na hardwarové sloty EXEC,
watchpointy `Z2`/`Z3`/`Z4` na sloty zápisu, čtení a přístupu. Všech 9
slotů je sdílených. Watchpoint zastaví po dokončení instrukce. Ctrl-C
v gdb zastaví jádro.

- **gdb** s podporou Z80: `target remote mister:5555`.
- **VS Code + DeZog**: DeZog umí vzdálený cíl MAME (gdb protokol). Stub
  pustit na MiSTeru (`--link /dev/ttyS1 --port 5555`) a v `launch.json`
  nastavit remote MAME na adresu MiSTeru a port 5555. **Neověřeno**:
  shodu s tím, co DeZog od MAME čeká, je potřeba vyzkoušet. Kdyby chtěl
  jiné pořadí registrů, stačí upravit `GDB_REGS` v `gdbstub.py`.

### Testy

`rtl/CPU/tb/run_uart.sh` přeloží model: skutečný `dbg_link.sv` (UART +
protokol), `tv80_dbg_regs`, `tv80_dbg` a program. UART vystaví po bitech
na TCP a pustí `tools/z80dbg/tests/test_model.py`, který projde knihovnu
i GDB stub (RSP klient). `UART_ONLY=1` pustí jen model, a nástroje pak jde
zkoušet ručně (`--link 127.0.0.1:5557`).

## Simulace

V sim appce `dbg_link` nahrazuje DPI most (`verilator/rtl/dbg_link_dpi.sv`)
a debugger ovládá panel „Z80 debugger“. Protokol ani nástroje tam
nejsou. Kdyby byly potřeba i proti simulaci, stačí v sim appce TCP server,
který protokol přeloží na frontu `Z80Dbg` (tatáž sběrnice registrů).
