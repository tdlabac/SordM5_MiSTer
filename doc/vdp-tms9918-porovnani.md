# VDP (rtl/VDP) vs. dokumentace TMS9918A — rozdíly

Stav: 2026-09-26, revize `4223ad9` (větev `verilog`).
Referenční dokument: <https://www.unige.ch/medecine/nouspikel/ti99/tms9918a.htm>
(Thierry Nouspikel, TI-99/4A Tech Pages).

Implementace: `rtl/VDP/vdp18_*.sv` — převod VHDL jádra vdp18 (Arnim Laeuger,
2006) do SystemVerilogu. VRAM je 16 KiB BRAM (`spram` v `rtl/sordm5_core.sv`),
ne DRAM.

Testovací ROM pro vizuální ověření na HW a FPGA: [tools/vdptest](../tools/vdptest/README.md).

Legenda dopadu na výsledek (obraz / chování pro software):

- **[CHYBA]** — výsledek se liší od originálu, opravit.
- **[ODCHYLKA]** — výsledek se liší, ale vědomě nebo s malým dopadem.
- **[SHODA]** — ověřeno, výsledek odpovídá.
- **[NEŘEŠÍ SE]** — rozdíl daný jiným HW (BRAM, digitální RGB výstup), na výsledek
  nemá vliv.

---

## 1. Shrnutí

| Oblast | Stav |
|---|---|
| Graphic I, Text, Multicolor | shoda |
| Bitmap (Graphic II) s plnými maskami (VR3=`FF`, VR4=`03`, i `9F`/`00`) | shoda |
| Bitmap s částečnými maskami (hybridní režimy) | **chyba — prohozené bity masky** |
| Nedokumentované režimy (bitmap text, bitmap multicolor, nelegální) | neimplementováno — zobrazí se běžný Text mode |
| Sprity (velikost, zvětšení, early clock, D0, 4/řádek, 5. sprite, kolize) | shoda |
| Stavový registr, přerušení, CPU rozhraní, read-ahead | shoda |
| Časování CPU oken | shoda (CPU dostane i nevyužité sprite sloty) |
| Horizontální časování, Graphic režimy | shoda ±1 px |
| Horizontální časování, Text mode | obraz posunutý cca o 5 px doleva |
| Vertikální časování NTSC/PAL | 262 / 313 řádků, horní okraj o 1 řádek kratší |
| Barvy | RGB paleta z MAME místo Y/R-Y/B-Y |
| DRAM, 4K/16K, EXTVID, CPUCLK/GROMCLK | neřeší se |

---

## 2. Chyby, které mění výsledek

### 2.1 [CHYBA] Bitmap mode — prohozené bity výběru třetiny (VR3 i VR4)

`vdp18_addr_mux.sv:51` a `:77`

```systemverilog
vram_a_o[12:11] = num_line_v[7:6] & {reg_ctb_i[5], reg_ctb_i[6]};   // barvy
vram_a_o[12:11] = num_line_v[7:6] & {reg_pgb_i[0], reg_pgb_i[1]};   // vzory
```

- Dokument: maska barev = `(VR3 & 7F) << 6 | 3F`, maska vzorů =
  `(VR4 & 03) << 11 | 7FF`. Adresový bit 12 tedy maskuje VR3 bit `>40` / VR4
  bit `>02`, bit 11 maskuje VR3 `>20` / VR4 `>01`.
- Implementace to má obráceně (adresa 12 ← VR3 `>20` / VR4 `>01`).
- Správně: `{reg_ctb_i[6], reg_ctb_i[5]}` a `{reg_pgb_i[1], reg_pgb_i[0]}`.
  Vznikla nejspíš při převodu z VHDL (tam `std_logic_vector(0 to 7)`,
  bit 0 = MSB).
- Dopad: VR3=`FF`/VR4=`03` (standard) i VR3=`9F`/VR4=`00` (jedna tabulka)
  fungují, protože oba bity mají stejnou hodnotu. Liší se konfigurace z tabulky
  v dokumentu:

  | VR3 | VR4 | dokument (třetiny) | implementace |
  |---|---|---|---|
  | `3F` | `01` | 0000 / 0800 / 0000 | 0000 / 0000 / 1000 |
  | `BF` | `05` | 2000 / 2800 / 2000 | 2000 / 2000 / 3000 |
  | `5F` | `02` | 0000 / 0000 / 1000 | 0000 / 0800 / 0000 |
  | `DF` | `06` | 2000 / 2000 / 3000 | 2000 / 2800 / 2000 |

### 2.2 [CHYBA] Bitmap mode — maska čísla znaku na špatných bitech

`vdp18_addr_mux.sv:52` a `:78`

```systemverilog
vram_a_o[10:3] = pat_name_i & {3'b111, reg_ctb_i[4:0]};
```

- Dokument: bity VR3 `>1F` maskují adresové bity 10..6, tj. **horních 5 bitů**
  čísla znaku (`name[7:3]`); dolní 3 bity (`name[2:0]`) se nemaskují.
- Implementace maskuje dolních 5 bitů (`name[4:0]`) a horní 3 nechává.
- Správně: `{reg_ctb_i[4:0], 3'b111}` (v obou řádcích).
- Dopad: jen když VR3 bity `>1F` nejsou všechny 1. Příklad VR3=`0F`
  (dokument: znaky `80–FF` = `00–7F`): implementace místo toho sloučí znaky
  `n` a `n^10`. Skupiny z tabulky „Character grouping“ v dokumentu nesedí pro
  žádnou hodnotu kromě `1F`.

### 2.3 [ODCHYLKA] Nedokumentované a nelegální režimy → Text mode

`vdp18_cpuio.sv:299-310` — kombinace M1/M2/M3 mimo 4 standardní padají do
`default: OPMODE_TEXTM`.

| VR0 bit `>02` / VR1 `>10` / VR1 `>08` | Dokument | Implementace |
|---|---|---|
| 1 / 1 / 0 — bitmap text | 40 sloupců, 3 tabulky vzorů podle VR4, maska `7FF` | obyčejný Text mode (bez třetin, VR4 jen bity 2..0 jako báze) |
| 1 / 0 / 1 — bitmap multicolor | multicolor, 3 tabulky vzorů podle VR4 | **Text mode** — úplně jiný obraz |
| x / 1 / 1 — nelegální | pevný obraz: 40 sloupců × (4 px popředí + 2 px pozadí) z VR7, bez spritů, nezávisí na VRAM | Text mode z VRAM |

Dopad: jen software, který tyto režimy záměrně používá (demo efekty, testy VDP).

### 2.4 [ODCHYLKA] Text mode — obraz posunutý doleva

`vdp18_pack-p.sv` (`hv_first_pix_text_c = -102`, `hv_last_pix_text_c = 239`),
`vdp18_hor_vert.sv:113-122`

- Délka řádku 342 px sedí, hsync (26 px) a blanking (58 px) sedí.
- Aktivní oblast začíná v obou režimech na stejném místě za hsync.
- Dokument: levý okraj Text 19 px, ostatní 13 px (text začíná o 6 px později).

| Režim | Levý okraj dok. / impl. | Pravý okraj dok. / impl. |
|---|---|---|
| Graphic, Multicolor | 13 / 14 | 15 / 14 |
| Text | 19 / 14 | 25 / 30 |

Dopad: v Text mode je obraz o cca 5 px vlevo vůči hsync. Při zobrazení
s okrajem je text nesouměrný, na LCD s automatickým centrováním se to ztratí.

### 2.5 [ODCHYLKA] Vertikální časování — rozdělení horního okraje

`vdp18_pack-p.sv` (NTSC −40..222, PAL −65..248), `vdp18_hor_vert.sv:105-134`

- Čítač se nuluje hned při dosažení posledního řádku (kontrola na každý pixel),
  takže řádek 222 / 248 trvá 1 px a splývá s prvním → **262 (NTSC) /
  313 (PAL) řádků**, odpovídá dokumentu.
- NTSC rozdělení:

  | | dokument | implementace |
  |---|---|---|
  | aktivní | 192 | 192 |
  | spodní okraj | 24 | 24 |
  | spodní blanking | 3 | 3 |
  | vsync | 3 | 3 |
  | horní blanking | 13 | 14 |
  | horní okraj | 27 | 26 |

- PAL: dokument rozpis neuvádí; implementace: okraj dole 50, blanking 3,
  vsync 3, blanking nahoře 14, okraj nahoře 51.
- Dopad: obraz o 1 řádek výš vůči vsync. Prakticky neviditelné.

### 2.6 [ODCHYLKA] Barvy

`vdp18_col_pack-p.sv`, `vdp18_col_mux.sv`

- Dokument popisuje analogové úrovně Y / R-Y / B-Y (resp. luminance + fáze
  chrominance u 9918A).
- Implementace používá pevnou RGB tabulku; `sordm5_core.sv` volí
  `compat_rgb_g(0)` = paleta z MAME (`tms9928a.c`). Alternativa
  `compat_rgb_g=1` je hrubší paleta (V9938 kompatibilita).
- Pořadí jasů z dokumentu (1 < 4 < 6,C < 2,5,8,D < 3,9 < 7,A < B,E < F)
  paleta z MAME zhruba zachovává; přesné odstíny neodpovídají žádnému
  konkrétnímu monitoru.
- Barva 0 (průhledná) na úrovni backdropu = černá — shoda s dokumentem pro
  vypnuté EXTVID.

---

## 3. Oblasti bez rozdílu ve výsledku

### 3.1 [SHODA] Registry

- VR0 `>02` = M3 (bitmap), VR1 `>40` = zobrazení zapnuto, `>20` = INT,
  `>10` = M1 (text), `>08` = M2 (multicolor), `>02` = sprity 16×16,
  `>01` = zvětšení. Reset nuluje všechny registry.
- VR2 `& 0F` × `400`, VR3 × `40`, VR4 `& 07` × `800`, VR5 `& 7F` × `80`,
  VR6 `& 07` × `800`, VR7 = popředí textu / backdrop.
- Zápis do registru: 2. bajt `10xxxrrr`; `11xxxxxx` je také zápis do registru
  (bit 6 se ignoruje), registry 8–15 zrcadlí 0–7.
- Nepoužité bity (VR0 kromě `>02`, VR1 `>04`) se ignorují.

### 3.2 [SHODA] Standardní režimy

- Graphic I: jméno `VR2 + řádek*32 + sloupec`, barva `VR3*40 + (znak>>3)`,
  vzor `VR4*800 + znak*8 + řádek_ve_znaku`. Barva 0 → backdrop.
- Text: 40×24, `řádek*40 + sloupec`, 6 px na znak (bity 1,0 vzoru se
  ignorují), barvy z VR7, pozadí je fakticky backdrop. Sprity se nečtou.
- Multicolor: bajt vzoru `(řádek_znaku mod 4)*2 + horní/dolní půlka`
  (`num_line[4:2]`), levý box = horní nibble, pravý = dolní. Tabulka barev se
  nečte.
- Bitmap: třetina z `num_line[7:6]`, `VR3 & 80` → `2000`, `VR4 & 04` →
  `2000`, vzory maskované maskou z VR3 (standardní bitmap) — kromě chyb 2.1
  a 2.2.
- Zatemnění (VR1 `>40` = 0): celá obrazovka v barvě backdropu, žádné sprity,
  VRAM volná pro CPU. Projeví se od dalšího řádku.

### 3.3 [SHODA] Sprity

- 32 spritů, priorita 0 nejvyšší, barva 0 průhledná (bod ale kolidovat může).
- Y = pozice − 1 (vyhodnocení na řádku N, zobrazení na N+1), Y `FF` = řádek 0,
  hodnoty kolem `E0–FF` dovolují vysunutí shora.
- Y = `D0` (208) ukončí seznam.
- 8×8 / 16×16 (kvadranty `1 3 / 2 4`, číslo vzoru `& FC`), zvětšení 2× v obou
  osách.
- Early clock (barva `>80`) posune sprite o 32 px doleva; pravý okraj ořezává.
- Max. 4 sprity na řádek, u 5. se nastaví status `>40` a jeho číslo; číslo
  se zamrzne na první výskyt ve snímku (nejvýš na obrazovce). Bez příznaku
  obsahuje číslo naposledy testovaného spritu (dokument: „no guaranty“).
- Kolize (`>20`) se detekuje na úrovni pixelů mezi 4 zobrazenými sprity,
  příznak drží do čtení statusu. Dokument uvádí kontrolu „jednou za snímek“ —
  výsledek pro software je stejný (příznak je lepkavý).
- Drobnost (neověřeno proti HW): sprity se vyhodnocují i na řádku −1 → 0 a
  na řádku 191 → 192. Neviditelný řádek 192 tak může nastavit příznak kolize
  nebo 5. spritu (sprite s Y = `BF`).

### 3.4 [SHODA] CPU rozhraní

- MODE = `A[0]` (Sord M5 porty `10h` data, `11h` řízení).
- 1bajtový read-ahead buffer: nastavení adresy pro čtení hned načte bajt,
  každé čtení vrátí buffer a načte další. Nastavení adresy pro zápis jen
  nastaví ukazatel.
- Zápis dat přepíše i read-ahead buffer (sdílený registr) — shodné se
  skutečným čipem.
- Jeden 14bitový ukazatel pro čtení i zápis, inkrementace po každém přístupu.
- Příznak „první bajt přijat“ nuluje libovolný přístup na datový port nebo
  čtení statusu.
- Čtení statusu vrátí `INT, 5S, C, číslo 5. spritu` a po skončení čtení
  vynuluje horní 3 bity a INT.
- INT = status bit 7 AND VR1 `>20` (kombinačně) → vypnutí a zapnutí povolení
  při nastaveném bitu hned vyvolá přerušení, jak píše dokument.
- Status bit 7 se nastaví na konci řádku 191 (před spodním okrajem).

### 3.5 [SHODA] Časování přístupu CPU k VRAM

- Paměťový cyklus = 2 pixely = 372 ns (`clk_en_acc` na liché pixely).
- Graphic/Bitmap: během aktivního řádku 1 CPU slot na 16 cyklů (5,95 µs),
  Text 1 z 3 cyklů (1,1 µs), Multicolor zhruba 1 ze 4 (1,5 µs) — shoda.
- Vertikální zpětný běh a zatemnění: VRAM celá pro CPU.
- Rozdíl bez dopadu na správný software: sloty pro testování spritů, které
  se po ukončení (D0, 4 sprity, sprite 31) už nevyužijí, dostane CPU. Software
  „příliš rychlý“ pro originál tak může fungovat tady a ne na HW — ne naopak.
- VDP nedrží CPU ve wait — shodně s originálem. Příliš rychlý zápis ztrácí
  data podobně jako originál (buffer se přepíše, adresa se zvýší jen jednou).
- Příkazové bajty se zpracují ihned (takt 10,7 MHz), dvě rychlé instrukce
  za sebou nevadí — tolerantnější než originál.

### 3.6 [SHODA] Hodiny a snímková frekvence

- `ce_10m7_p` = `clk_sys/2` = 10,738635 MHz, pixel = /2 = 5,37 MHz,
  342 px/řádek.
- NTSC 262 řádků → 59,92 Hz, PAL 313 řádků → 50,16 Hz. Volba přes OSD
  (`status[10]`, `vdp_pal`), Sord M5 měl TMS9929A (PAL).

---

## 4. Rozdíly dané jinou technologií (bez vlivu na výsledek)

- **[NEŘEŠÍ SE] DRAM rozhraní (RAS/CAS, AD0–7, RD0–7, refresh).** Místo toho
  `vram_a_o[13:0]`, `vram_d_o`, `vram_d_i`, `vram_we_o` → synchronní BRAM
  (`altsyncram`, čtení s latencí 1 takt `clk_sys`). Adresa je stabilní min.
  4 takty `clk_sys` před vzorkováním dat, takže latence nevadí.
  `vram_we_o` je aktivní po celý CPU slot (opakovaný zápis stejných dat).
- **[NEŘEŠÍ SE] Bit 4K/16K (VR1 `>80`).** Ignorován (`reg_16k_o` nezapojen),
  adresa je vždy lineární 14bitová. Na originálu by 4K režim na 16K
  paměti přeházel adresy (jiné mapování řádek/sloupec DRAM). Software, který
  omylem nechá bit na 0, zde běží, na HW by ne.
- **[NEŘEŠÍ SE] Reset a obsah VRAM.** Originál při RESET neobnovuje DRAM
  a data se mohou ztratit; BRAM obsah přes reset drží. Po zapnutí je BRAM
  vynulovaná, originál má náhodný obsah.
- **[NEŘEŠÍ SE] EXTVID / VR0 `>01`.** Externí video není (`reg_ev_o`
  nezapojen); průhledný backdrop = černá, což je chování originálu bez
  externího videa.
  Pozor: reálný Sord M5 (TMS9929A) **potřebuje R0 bit 0 = 1**, s 0 je
  obraz rozsynchronizovaný (ověřeno testem `tools/vdptest`, 2026-09-26;
  stejný jev mají hry portované z jiné oblasti). FPGA synchronizuje vždy,
  takže software se špatnou hodnotou na FPGA běží a na HW ne.
- **[NEŘEŠÍ SE] Video výstup.** Digitální RGB 8:8:8 + HSync/VSync/HBlank/
  VBlank místo COMVID nebo Y/R-Y/B-Y. Color burst se negeneruje.
  `border_i` (OSD `status[9]`) volí, zda HBlank/VBlank ořízne okraj
  (`window_h/v`) nebo ho ukáže.
- **[NEŘEŠÍ SE] CPUCLK, GROMCLK.** Nevyvedeny (`clk_gen` je generuje,
  výstupy nezapojené); Sord M5 je nepotřebuje.
- **[NEŘEŠÍ SE] Elektrické časování CSR/CSW.** Strobe se vzorkuje na
  10,7 MHz, přístup se dokončí až po návratu strobe do klidu — musí trvat
  aspoň 1 takt 10,7 MHz (Z80 na 3,58 MHz splňuje s rezervou).

---

## 5. Nepřesnosti v referenčním dokumentu

Aby se při dalším porovnávání neopakovaly omyly:

- Popis režimů používá „bit 7 of register 0“ pro bitmap; správně je bit 6
  (`>02`) jako v popisu VR0. Bit 7 (`>01`) je EXTVID.
- Souhrnná tabulka registrů má prohozené `Multic` a `Text`; platí text
  (VR1 `>10` = Text, `>08` = Multicolor).
- „Bitmap text mode … Bit 4 in register 1 should be 1“ — myšlen text bit
  (`>10`); u „Bitmap multicolor“ obráceně.
- „Sprite attributes table is pointed at by VDP register 6“ — správně VR5.
- Status „Bit 1 (weight >20) is the coincidence bit“ — správně bit 2.
- Vertikální tabulka „Total 362“ — správně 262.
- Popis 16×16 spritu: „bytes 17-23 define the lower right quadrant“ —
  správně 24–31.
