#!/usr/bin/env python3
"""Spusti vdptest.bin v emulatoru Z80 s modelem VDP a vykresli ocekavane
obrazovky do PNG.

Dve varianty modelu:
  hw    - chovani podle dokumentace TMS9918A (Nouspikel), vcetne hybridnich,
          nedokumentovanych a nelegalnich rezimu,
  fpga  - chovani rtl/VDP ve stavu revize 4223ad9 (chyby 2.1, 2.2, 2.3 z
          doc/vdp-tms9918-porovnani.md a vyhodnoceni spritu i pro radek 192).

Obrazky zobrazuji jen aktivni oblast 256x192 (text mode 240 px od x=8),
okraje a posuny obrazu nejsou modelovane.

Pouziti:  python render.py vdptest.bin vystupni_adresar
Zavislosti: pip install z80 pillow
"""
import sys
import os
import z80
from PIL import Image

# Paleta z rtl/VDP/vdp18_col_pack-p.sv (full_rgb_table_c, MAME)
PALETTE = [
    (0, 0, 0), (0, 0, 0), (33, 200, 66), (94, 220, 120),
    (84, 85, 237), (125, 118, 252), (212, 82, 77), (66, 235, 245),
    (252, 85, 84), (255, 121, 120), (212, 193, 84), (230, 206, 128),
    (33, 176, 59), (201, 91, 186), (204, 204, 204), (255, 255, 255),
]

NSCR = 19                # pocet obrazovek ve vdptest.asm
FRAMES_PER_SCREEN = 6
SNAP_FRAME = 4           # snimek, po kterem se obrazovka ulozi
KEY_FRAME = 5            # snimek, ve kterem je stisknuty mezernik
READS_PER_FRAME = 400    # cteni statusu mezi dvema snimky


class VDP:
    def __init__(self, fpga):
        self.fpga = fpga
        self.vram = bytearray(0x4000)
        self.reg = [0] * 8
        self.addr = 0
        self.latch = None
        self.readbuf = 0
        self.status = 0

    # --- CPU rozhrani --------------------------------------------------
    def write_ctrl(self, v):
        if self.latch is None:
            self.latch = v
            return
        lo, self.latch = self.latch, None
        if v & 0x80:
            self.reg[v & 7] = lo
        else:
            self.addr = ((v & 0x3F) << 8) | lo
            if not v & 0x40:
                self.readbuf = self.vram[self.addr]
                self.addr = (self.addr + 1) & 0x3FFF

    def write_data(self, v):
        self.latch = None
        self.vram[self.addr] = v
        self.readbuf = v
        self.addr = (self.addr + 1) & 0x3FFF

    def read_status(self):
        self.latch = None
        s = self.status
        self.status = s & 0x1F          # priznaky 7..5 se ctenim nuluji
        return s

    # --- rezim ---------------------------------------------------------
    def mode(self):
        m1 = bool(self.reg[1] & 0x10)
        m2 = bool(self.reg[1] & 0x08)
        m3 = bool(self.reg[0] & 0x02)
        if self.fpga:
            # vdp18_cpuio.sv: {m1, m2, m3} mimo 4 standardni -> TEXTM
            return {(0, 0, 0): 'g1', (0, 0, 1): 'g2', (0, 1, 0): 'mc',
                    (1, 0, 0): 'text'}.get((m1, m2, m3), 'text')
        if m1 and m2:
            return 'illegal'
        if m1:
            return 'btext' if m3 else 'text'
        if m2:
            return 'bmc' if m3 else 'mc'
        return 'g2' if m3 else 'g1'

    # --- adresy bitmap -------------------------------------------------
    def bm_addr(self, line, name, table):
        r3, r4 = self.reg[3], self.reg[4]
        third = line >> 6
        if self.fpga:
            l7, l6 = (line >> 7) & 1, (line >> 6) & 1
            name_m = name & (0xE0 | (r3 & 0x1F))
            if table == 'c':
                a13 = (r3 >> 7) & 1
                a12 = l7 & ((r3 >> 5) & 1)       # prohozene bity (chyba 2.1)
                a11 = l6 & ((r3 >> 6) & 1)
            else:
                a13 = (r4 >> 2) & 1
                a12 = l7 & (r4 & 1)
                a11 = l6 & ((r4 >> 1) & 1)
            return (a13 << 13) | (a12 << 12) | (a11 << 11) | (name_m << 3) | (line & 7)
        raw = (third << 11) | (name << 3) | (line & 7)
        cmask = ((r3 & 0x7F) << 6) | 0x3F
        if table == 'c':
            return ((r3 & 0x80) << 6) | (raw & cmask)
        pmask = ((r4 & 3) << 11) | (cmask & 0x7FF)
        return ((r4 & 4) << 11) | (raw & pmask)

    # --- vykresleni ----------------------------------------------------
    def render(self):
        """Vrati (pole 256x192 cisel barev, priznaky statusu)."""
        backdrop = self.reg[7] & 15
        img = [[backdrop] * 256 for _ in range(192)]
        flags = 0
        if not self.reg[1] & 0x40:
            return img, flags
        mode = self.mode()
        vr = self.vram
        nt = (self.reg[2] & 15) << 10
        fg7, bg7 = self.reg[7] >> 4, self.reg[7] & 15

        def put(x, y, c):
            if c:
                img[y][x] = c

        for y in range(192):
            row, ln = y >> 3, y & 7
            if mode in ('text', 'btext', 'illegal'):
                for col in range(40):
                    if mode == 'illegal':
                        bits = 0xF0
                    else:
                        name = vr[nt + row * 40 + col]
                        if mode == 'btext':
                            r4 = self.reg[4]
                            raw = ((y >> 6) << 11) | (name << 3) | ln
                            a = ((r4 & 4) << 11) | (raw & (((r4 & 3) << 11) | 0x7FF))
                        else:
                            a = ((self.reg[4] & 7) << 11) | (name << 3) | ln
                        bits = vr[a]
                    for b in range(6):
                        put(8 + col * 6 + b, y, fg7 if bits & (0x80 >> b) else bg7)
                continue
            for col in range(32):
                name = vr[nt + row * 32 + col]
                if mode in ('mc', 'bmc'):
                    sub = ((row & 3) << 1) | (ln >> 2)
                    if mode == 'bmc':
                        r4 = self.reg[4]
                        raw = ((y >> 6) << 11) | (name << 3) | sub
                        a = ((r4 & 4) << 11) | (raw & (((r4 & 3) << 11) | 0x7FF))
                    else:
                        a = ((self.reg[4] & 7) << 11) | (name << 3) | sub
                    c = vr[a]
                    for b in range(8):
                        put(col * 8 + b, y, (c >> 4) if b < 4 else (c & 15))
                    continue
                if mode == 'g1':
                    bits = vr[((self.reg[4] & 7) << 11) | (name << 3) | ln]
                    c = vr[(self.reg[3] << 6) | (name >> 3)]
                else:
                    bits = vr[self.bm_addr(y, name, 'p')]
                    c = vr[self.bm_addr(y, name, 'c')]
                for b in range(8):
                    put(col * 8 + b, y, (c >> 4) if bits & (0x80 >> b) else (c & 15))
        if mode in ('g1', 'g2', 'mc', 'bmc'):
            flags = self.sprites(img)
        return img, flags

    def sprites(self, img):
        vr = self.vram
        sat = (self.reg[5] & 0x7F) << 7
        spt = (self.reg[6] & 7) << 11
        size = 16 if self.reg[1] & 2 else 8
        mag = self.reg[1] & 1
        h = size << mag
        flags = 0
        fifth = None
        # FPGA vyhodnocuje sprity i pro radek 192 (neviditelny)
        last = 193 if self.fpga else 192
        for y in range(last):
            found = []
            for i in range(32):
                sy = vr[sat + i * 4]
                if sy == 0xD0:
                    break
                top = (sy - 256 if sy >= 0xE0 else sy) + 1
                if 0 <= y - top < h:
                    if len(found) == 4:
                        if fifth is None:
                            fifth = i
                        break
                    found.append((i, y - top))
            cover = [0] * 256
            for i, r in reversed(found):
                a = sat + i * 4
                x0 = vr[a + 1]
                name = vr[a + 2]
                col = vr[a + 3]
                if col & 0x80:
                    x0 -= 32
                if size == 16:
                    name &= 0xFC
                r >>= mag
                for px in range(size << mag):
                    x = x0 + px
                    if x < 0 or x > 255:
                        continue
                    p = px >> mag
                    byte = vr[spt + name * 8 + r + (16 if p >= 8 else 0)]
                    if byte & (0x80 >> (p & 7)):
                        cover[x] += 1
                        if col & 15 and y < 192:
                            img[y][x] = col & 15
            if max(cover) > 1:
                flags |= 0x20
        if fifth is not None:
            flags |= 0x40 | fifth
        return flags


def run(binfile, fpga):
    rom = open(binfile, 'rb').read()
    m = z80.Z80Machine()
    m.set_memory_block(0x2000, rom)
    vdp = VDP(fpga)
    st = {'reads': 0, 'frame': 0, 'shots': []}

    def on_in(port):
        p = port & 0xFF
        if p == 0x11:
            st['reads'] += 1
            if st['reads'] % READS_PER_FRAME == 0:
                img, flags = vdp.render()
                vdp.status = 0x80 | flags
                f = st['frame']
                if f % FRAMES_PER_SCREEN == SNAP_FRAME:
                    st['shots'].append(img)
                st['frame'] += 1
            return vdp.read_status()
        if p == 0x10:
            v = vdp.readbuf
            vdp.readbuf = vdp.vram[vdp.addr]
            vdp.addr = (vdp.addr + 1) & 0x3FFF
            vdp.latch = None
            return v
        if p == 0x30:
            return 0x40 if st['frame'] % FRAMES_PER_SCREEN == KEY_FRAME else 0
        if 0x31 <= p <= 0x37:
            return 0
        return 0xFF

    def on_out(port, value):
        p = port & 0xFF
        if p == 0x11:
            vdp.write_ctrl(value)
        elif p == 0x10:
            vdp.write_data(value)

    m.set_input_callback(on_in)
    m.set_output_callback(on_out)
    m.pc = rom[1] | (rom[2] << 8)
    while len(st['shots']) < NSCR:
        m.ticks_to_stop = 100000
        m.run()
        if st['frame'] > FRAMES_PER_SCREEN * (NSCR + 2):
            raise RuntimeError('program nedobehl')
    return st['shots']


def save(img, path):
    im = Image.new('RGB', (256, 192))
    im.putdata([PALETTE[c] for row in img for c in row])
    im.resize((512, 384), Image.NEAREST).save(path)


def main():
    binfile, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    for variant in ('hw', 'fpga'):
        shots = run(binfile, variant == 'fpga')
        for n, img in enumerate(shots, 1):
            save(img, os.path.join(outdir, '%02d_%s.png' % (n, variant)))
    print('hotovo:', outdir)


if __name__ == '__main__':
    main()
