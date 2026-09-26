# VDPTEST — test režimů VDP pro Sord M5

Testovací ROM pro vizuální porovnání VDP na reálném Sord M5 (TMS9929A)
a v FPGA jádře (`rtl/VDP`). Pokrývá všechny režimy, sprity a hlavně
rozdíly popsané v [doc/vdp-tms9918-porovnani.md](../../doc/vdp-tms9918-porovnani.md).

## Překlad a spuštění

```
pasmo --bin vdptest.asm vdptest.bin
```

- Výsledek je ROM cartridge od `2000h` (hlavička stejná jako u
  `flexicard/tools/menu/menu.asm`), zhruba 4,4 kB.
- FPGA: Cartridge = None, menu „Load to ROM“.
- Ovládání: **mezerník** = další obrazovka, **ENTER** = předchozí (dokola),
  **E** = přepne R0 bit 0 (EXTVID) na všech obrazovkách,
  **B** = přepne barvu okraje mezi barvou obrazovky a černou (platí pro
  všechny obrazovky, dokud se znovu nestiskne). TMS9918 okraj vypnout
  neumí, mění se barva pozadí (R7 dolní nibble), takže se mění i
  průhledná místa uvnitř obrazu. Ořez okraje na FPGA řídí OSD „Border“.
- R0 bit 0 je ve výchozím stavu **1** (`EVDEF` na začátku `vdptest.asm`).
  Reálný Sord M5 s TMS9929A ho potřebuje, s 0 je obraz
  rozsynchronizovaný (ověřeno na HW 2026-09-26). FPGA bit ignoruje.
- Na FPGA zapni v OSD zobrazení okraje (border), jinak nejde porovnat
  polohu obrazu (obrazovky 1 a 2).

## Referenční obrázky

`expected/NN_hw.png` a `expected/NN_fpga.png` vykreslil `render.py`:
program běží v emulátoru Z80 a model VDP z výsledné VRAM a registrů
vykreslí obraz.

- `hw` — chování podle dokumentace (Nouspikel). Pro obrazovku 19
  dokumentace nic neříká, model tam předpokládá, že se řádek 192
  nevyhodnocuje.
- `fpga` — chování `rtl/VDP` podle analýzy kódu (revize `4223ad9`).
- Obrázky mají jen aktivní oblast 256×192 (text mode je 240 px od x=8).
  Okraje, poloha obrazu vůči synchronizaci a přesné odstíny se
  nemodelují, barvy jsou z palety MAME, kterou používá jádro.

Přegenerování (`pip install z80 pillow`):

```
python render.py vdptest.bin expected
```

## Obrazovky a co na nich sledovat

„Shoda“ znamená, že HW i FPGA mají vypadat stejně. Rozdíl je jen tam, kde
je uvedený.

| # | Režim | Na HW (podle dokumentace) | FPGA |
|---|---|---|---|
| 1 | Graphic I | Paleta 0–F jako pruhy. 0 (průhledná) a 1 (černá) splývají s černým pozadím. Bílý rámeček kolem celé plochy 256×192. | Shoda. Rámeček asi o 1 px posunutý (okraje vlevo/vpravo 14/14 místo 13/15). |
| 2 | Text 40×24 | Bílý rámeček kolem plochy 240×192 na modrém pozadí, levý okraj **19 px**, pravý **25 px**. Mezi `[ ]` nic (bity 1,0 vzoru se nezobrazí). | Rámeček asi **o 5 px vlevo** (okraj 14 / 30 px) — odchylka 2.4. |
| 3 | Multicolor | Diagonální barevné pruhy z bloků 4×4, uprostřed bílý sprite 16×16. Bez textu. | Shoda. |
| 4 | Bitmap R3=FF R4=03 | Vzor X v každé buňce, barva se mění po řádcích, nahoře popisek. | Shoda. |
| 5 | Bitmap R3=FF R4=03 | Třetiny modrá/červená/zelená, vzor P0/P1/P2. | Shoda. |
| 6 | Bitmap R3=9F R4=00 | Všechny třetiny modré, P0. | Shoda. |
| 7 | Bitmap R3=BF R4=01 | modrá P0 / **červená P1** / modrá P0 | modrá P0 / modrá P0 / **zelená P2** — chyba 2.1 |
| 8 | Bitmap R3=DF R4=02 | modrá P0 / modrá P0 / **zelená P2** | modrá P0 / **červená P1** / modrá P0 — chyba 2.1 |
| 9 | Bitmap R3=BF R4=02 | modrá P0 / **červená P0** / **modrá P2** | modrá P0 / **modrá P1** / **zelená P0** — chyba 2.1 |
| 10 | Bitmap R3=EF (maska 3FFh) | Všechny 4 řádky abecedy a číslic čitelné (znaky 80h–FFh = 00h–7Fh). | Písmena P–Z → @A–J, číslice → mezera a `!"#…`, řádky s bitem 7 = **šachovnice**; zkomolené jsou i popisky — chyba 2.2 |
| 11 | Bitmap text (R0=02, R1=D0) | Třetiny ukazují VZOR **0, 1, 2**. | VZOR **3, 3, 3** (obyčejný text mode) — odchylka 2.3 |
| 12 | Bitmap multicolor (R0=02, R1=C8) | Tři vodorovné pásy: červená, zelená, modrá (střídají se sloupce 4 px). Bez textu. | **Text** „12 BITMAP MULTICOLOR…“ na černém — odchylka 2.3 |
| 13 | Nelegální M1+M2 (R1=D8) | Svislé pruhy: 4 px bílá + 2 px modrá, 40 sloupců, žádný text. | **Text** „13 NELEGALNI REZIM…“ — odchylka 2.3 |
| 14 | Sprity 8×8 | Bílý rámeček (sprite 0) nad červeným čtvercem (1). Vlevo 4 px žlutého (early clock, X=28), pod ním celý čtverec u levého okraje (X=0), vpravo 4 px (X=252). Nahoře šedý (Y=FC, 5 řádků) a zelený rámeček (Y=FF, řádky 0–7), dole šedý (Y=BC, 3 řádky). Stav `5S=0 C=1 N=--`. | Shoda. |
| 15 | Sprity 16×16 | Sprity jako „13 / 24“ (pořadí kvadrantů). Vlevo nahoře useknutý early clock (vidět „3/4“), vpravo useknutý „1/2“. Stav `5S=0 C=0`. | Shoda. |
| 16 | 16×16 zvětšené | Totéž dvakrát větší. | Shoda. |
| 17 | 5. sprite, Y=D0 | Na řádku 80 čtyři čtverce, pátý (žlutý) chybí. Na řádku 120 jen purpurový, bílý za koncem seznamu (Y=D0) chybí. Stav `5S=1 C=0 N=04`. | Shoda. |
| 18 | Kolize | Jen bílý čtverec; průhledný sprite pod ním není vidět, ale kolize se počítá: `5S=0 C=1`. | Shoda. |
| 19 | Sprity na řádku 192 (Y=BF) | Nic není vidět. **Stav zapiš** — dokumentace nic neuvádí, model předpokládá `5S=0 C=0 N=--`. | `5S=1 C=1 N=04` (řádek 192 se vyhodnocuje) — neověřená drobnost ze 3.3 |

Stavový řádek („5S=x C=x N=xx“ na obrazovkách 14–19) se obnovuje
každý snímek. 5S a C jsou OR všech čtení statusu za snímek, N je číslo
5. spritu (`--` = žádný).

## Poznámky k programu

- Při sestavení obrazovky je zobrazení vypnuté (R1 bit 6 = 0), takže
  zápisy do VRAM na originálu nepotřebují čekání na okno přístupu CPU.
  Za běhu se zapisuje jen stavový řádek, a to hned po začátku
  zpětného běhu.
- Přerušení jsou zakázaná, status se čte dotazováním (klávesy také
  jednou za snímek, takže nevadí zákmity).
- R1 má vždy nastavený bit 16K (`80h`).
- Pozor na pasmo: `EQU` s dopřednou referencí na návěští se vyhodnotí už
  v 1. průchodu (návěští = 0) a výsledek se použije i tam, kde je
  symbol použitý dřív. Proto je adresa vzoru spritů 16×16 zapsaná
  přímo v `DW FONT + 11h*8`.
