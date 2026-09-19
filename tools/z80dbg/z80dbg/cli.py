"""Příkazová řádka pro debugger Z80 v jádře Sord M5.

    python3 -m z80dbg.cli --link /dev/ttyS1          (na MiSTeru)
    python3 -m z80dbg.cli --link mister:5555         (z PC přes most)
    python3 -m z80dbg.cli --link ... -c "stop" -c "regs"   (neinteraktivně)

Čísla se zadávají hexadecimálně (bez předpony, nebo 0x...).
"""

import argparse
import cmd
import shlex
import sys

from .core import Z80Debugger, BP_NAMES, DebuggerError
from .link import open_link, DEFAULT_BAUD


def num(s):
    s = s.lower()
    if s.startswith("0x"):
        s = s[2:]
    if s.endswith("h"):
        s = s[:-1]
    return int(s, 16)


class Cli(cmd.Cmd):
    intro = "Debugger Z80 (Sord M5). help = příkazy, quit = konec."
    prompt = "z80> "

    def __init__(self, dbg):
        super().__init__()
        self.d = dbg

    def onecmd(self, line):
        try:
            return super().onecmd(line)
        except (DebuggerError, ValueError, IndexError) as e:
            print("chyba:", e)

    def emptyline(self):
        pass

    def do_quit(self, arg):
        "quit — konec (jádro nechá, jak je)"
        return True

    do_exit = do_quit

    def do_status(self, arg):
        "status — běží/stojí, důvod zastavení, zásah breakpointu"
        s = self.d.status()
        if not s["stopped"]:
            print("běží, čas %d" % s["tstamp"])
            return
        print("stojí: %s, čas %d (takty CPU od resetu)" % (s["reason_name"], s["tstamp"]))
        if s["reason"] in (3, 4):
            bps = [str(i) for i in range(16) if s["hit"] & (1 << i)]
            print("  breakpoint %s, adresa %04X data %02X, instrukce na %04X"
                  % (",".join(bps), s["hit_addr"], s["hit_data"], s["hit_pc"]))

    def do_time(self, arg):
        "time — čas počítače: takty CPU od resetu (značka pro simulaci)"
        print(self.d.tstamp())

    def do_stop(self, arg):
        "stop — zastavit na nejbližší hranici instrukce"
        self.d.stop()
        self.do_regs("")

    def do_run(self, arg):
        "run — rozběhnout"
        self.d.run()

    def do_step(self, arg):
        "step [n] [noint] — n instrukcí (výchozí 1); noint = maskovat INT"
        args = arg.split()
        noint = "noint" in args
        args = [a for a in args if a != "noint"]
        n = int(args[0]) if args else 1
        for _ in range(n):
            self.d.step(noint)
        self.do_regs("")

    def do_wait(self, arg):
        "wait [sekundy] — počkat na zastavení (breakpoint)"
        ok = self.d.wait_stopped(float(arg) if arg else 10.0)
        print("stojí" if ok else "pořád běží")
        if ok:
            self.do_status("")

    def do_regs(self, arg):
        "regs — registry (jen při zastavení)"
        r = self.d.regs()
        f = "".join(c if r["f"] & (0x80 >> k) else "." for k, c in enumerate("SZYHXPNC"))
        print("AF=%04X BC=%04X DE=%04X HL=%04X  AF'=%04X BC'=%04X DE'=%04X HL'=%04X"
              % (r["af"], r["bc"], r["de"], r["hl"], r["af'"], r["bc'"], r["de'"], r["hl'"]))
        print("IX=%04X IY=%04X SP=%04X PC=%04X  I=%02X R=%02X IFF1=%d IFF2=%d IM=%d  F=%s"
              % (r["ix"], r["iy"], r["sp"], r["pc"], r["i"], r["r"], r["iff1"], r["iff2"], r["im"], f))

    def do_set(self, arg):
        "set REG=hodnota ... — změna registrů (af bc de hl af' ... ix iy sp pc i r iff1 iff2 im)"
        r = self.d.regs()
        for item in shlex.split(arg):
            name, val = item.split("=")
            name = name.lower()
            if name not in r:
                raise ValueError("neznámý registr %s" % name)
            r[name] = num(val) if name not in ("iff1", "iff2", "im") else int(val)
            if name == "af":
                r["a"], r["f"] = r["af"] >> 8, r["af"] & 0xFF
            if name == "af'":
                r["a'"], r["f'"] = r["af'"] >> 8, r["af'"] & 0xFF
        self.d.set_regs(r)
        self.do_regs("")

    def do_bp(self, arg):
        """bp — výpis; bp i typ adresa [maska] [data dmaska]
        typ: x (provedení), r, w (paměť), ir, iw (I/O), kombinace přes +, např. r+w"""
        a = arg.split()
        if not a:
            for i in range(self.d.nbp):
                b = self.d.get_bp(i)
                if b["kind"]:
                    kinds = "+".join(k for k, v in BP_NAMES.items() if b["kind"] & v)
                    print("%d: %-6s %04X maska %04X data %02X dmaska %02X"
                          % (i, kinds, b["addr"], b["amask"], b["data"], b["dmask"]))
            return
        i = int(a[0])
        kind = 0
        for k in a[1].lower().split("+"):
            kind |= BP_NAMES[k]
        addr = num(a[2])
        amask = num(a[3]) if len(a) > 3 else 0xFFFF
        data = num(a[4]) if len(a) > 4 else 0
        dmask = num(a[5]) if len(a) > 5 else (0xFF if len(a) > 4 else 0)
        self.d.set_bp(i, kind, addr, amask, data, dmask)

    def do_bpclr(self, arg):
        "bpclr [i] — smazat breakpoint i, bez argumentu všechny"
        for i in ([int(arg)] if arg else range(self.d.nbp)):
            self.d.clear_bp(i)

    def do_mem(self, arg):
        "mem adresa [délka] — výpis paměti (jen při zastavení), výchozí délka 100h"
        a = arg.split()
        addr = num(a[0])
        n = num(a[1]) if len(a) > 1 else 0x100
        data = self.d.read_mem(addr, n)
        for off in range(0, len(data), 16):
            row = data[off:off + 16]
            txt = "".join(chr(c) if 32 <= c < 127 else "." for c in row)
            print("%04X  %-48s %s" % ((addr + off) & 0xFFFF, " ".join("%02X" % c for c in row), txt))

    def do_wmem(self, arg):
        "wmem adresa bajt [bajt ...] — zápis do paměti (jen při zastavení)"
        a = arg.split()
        self.d.write_mem(num(a[0]), bytes(num(x) for x in a[1:]))

    def do_save(self, arg):
        "save soubor adresa délka — uložit paměť do souboru"
        f, addr, n = arg.split()
        with open(f, "wb") as fh:
            fh.write(self.d.read_mem(num(addr), num(n)))

    def do_load(self, arg):
        "load soubor adresa — nahrát soubor do paměti (RAM)"
        f, addr = arg.split()
        with open(f, "rb") as fh:
            self.d.write_mem(num(addr), fh.read())


def main(argv=None):
    ap = argparse.ArgumentParser(description="Debugger Z80 v jádře Sord M5")
    ap.add_argument("--link", default="/dev/ttyS1", help="sériový port nebo host:port")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("-c", action="append", default=[], help="příkaz (lze opakovat), pak konec")
    a = ap.parse_args(argv)
    cli = Cli(Z80Debugger(open_link(a.link, a.baud)))
    if a.c:
        for c in a.c:
            cli.onecmd(c)
    else:
        cli.cmdloop()


if __name__ == "__main__":
    main()
