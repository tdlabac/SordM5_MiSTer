"""GDB Remote Serial Protocol pro debugger Z80 v jádře Sord M5.

Umožňuje připojit nástroje, které mluví gdb protokolem: gdb s podporou Z80,
z88dk-gdb, VS Code s DeZog (vzdálený cíl typu MAME). Rozložení registrů je
stejné jako u gdbstubu v MAME pro Z80:

    AF BC DE HL AF' BC' DE' HL' IX IY SP PC    (16 bitů, little-endian)

Breakpointy Z0/Z1 (software i hardware) se mapují na hardwarové sloty EXEC,
watchpointy Z2/Z3/Z4 na sloty MWR/MRD/MRD|MWR. Slotů je 9 (tv80_dbg_pkg::NBP).
Zastavení na watchpointu je až po dokončení instrukce (jako u gdb).

Chování jako u MAME (kvůli DeZog):
- při připojení klienta se počítač zastaví (DeZog neposílá '?', počítá
  se zastaveným cílem),
- každé zastavení se hlásí jako T05 (i pauza Ctrl-C; T02 bere DeZog jako
  konec) a nese PC: "T050b:<pc>;".
Paměť jde číst a zapisovat jen při zastavení; za běhu vrátí m/M chybu E0E
místo nesmyslů.

Spuštění:  python3 -m z80dbg.gdbstub --link /dev/ttyS1 --port 5555
"""

import argparse
import socket
import select
import sys
import time

from .core import Z80Debugger, BP_EXEC, BP_MRD, BP_MWR, DebuggerError
from .link import open_link, DEFAULT_BAUD

GDB_REGS = ["af", "bc", "de", "hl", "af'", "bc'", "de'", "hl'", "ix", "iy", "sp", "pc"]

TARGET_XML = """<?xml version="1.0"?>
<!DOCTYPE target SYSTEM "gdb-target.dtd">
<target version="1.0">
<architecture>z80</architecture>
<feature name="mame.z80">
""" + "".join(
    '<reg name="%s" bitsize="16" type="%s"/>\n' % (
        n, "data_ptr" if n == "sp" else "code_ptr" if n == "pc" else "int")
    for n in GDB_REGS) + """</feature>
</target>
"""


def _cs(data):
    return "%02x" % (sum(data.encode("latin-1")) & 0xFF)


class GdbStub:
    def __init__(self, dbg, log=None):
        self.dbg = dbg
        self.log = log or (lambda *a: None)
        self.noack = False
        self.slots = {}                     # (typ, adresa, délka) -> slot
        self.sock = None
        self.buf = b""

    # --- rámce RSP
    def send(self, data):
        pkt = "$%s#%s" % (data, _cs(data))
        self.log("-> " + pkt[:120])
        self.sock.sendall(pkt.encode("latin-1"))

    def recv_packet(self, timeout=None):
        """Vrátí obsah paketu, '\\x03' pro přerušení, nebo None při timeoutu."""
        end = None if timeout is None else time.monotonic() + timeout
        while True:
            while self.buf:
                c = self.buf[:1]
                if c == b"\x03":
                    self.buf = self.buf[1:]
                    return "\x03"
                if c in (b"+", b"-"):
                    self.buf = self.buf[1:]
                    continue
                if c == b"$":
                    i = self.buf.find(b"#")
                    if i >= 0 and len(self.buf) >= i + 3:
                        data = self.buf[1:i].decode("latin-1")
                        self.buf = self.buf[i + 3:]
                        if not self.noack:
                            self.sock.sendall(b"+")
                        self.log("<- " + data[:120])
                        return data
                    break
                self.buf = self.buf[1:]                   # smetí mezi pakety
            left = None if end is None else max(0.0, end - time.monotonic())
            r, _, _ = select.select([self.sock], [], [], left)
            if not r:
                return None
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("gdb se odpojil")
            self.buf += chunk

    # --- registry
    def regs_hex(self):
        r = self.dbg.regs()
        return "".join("%02x%02x" % (r[n] & 0xFF, r[n] >> 8) for n in GDB_REGS)

    def set_regs_hex(self, h):
        r = self.dbg.regs()
        for k, n in enumerate(GDB_REGS):
            if len(h) >= 4 * k + 4:
                r[n] = int(h[4 * k + 2:4 * k + 4] + h[4 * k:4 * k + 2], 16)
        self.dbg.set_regs(r)

    # --- breakpointy
    def set_break(self, typ, addr, length, on):
        key = (typ, addr, length)
        if not on:
            slot = self.slots.pop(key, None)
            if slot is not None:
                self.dbg.clear_bp(slot)
            return "OK"
        if key in self.slots:
            return "OK"
        free = [i for i in range(self.dbg.nbp) if i not in self.slots.values()]
        if not free:
            return "E28"                                   # došly sloty
        kind = {0: BP_EXEC, 1: BP_EXEC, 2: BP_MWR, 3: BP_MRD, 4: BP_MRD | BP_MWR}[typ]
        amask = 0xFFFF
        if typ >= 2 and length > 1 and (length & (length - 1)) == 0 and addr % length == 0:
            amask = 0xFFFF & ~(length - 1)                  # zarovnaný rozsah
        self.dbg.set_bp(free[0], kind, addr, amask)
        self.slots[key] = free[0]
        return "OK"

    def stop_reply(self, interrupted=False):
        """Odpověď na zastavení: vždy T05 (i pauza, jako MAME) + PC (registr 0b)."""
        st = self.dbg.status()
        pc = self.dbg.regs()["pc"]
        reply = "T050b:%02x%02x;" % (pc & 0xFF, pc >> 8)
        if st["reason"] == 3:
            return reply + "hwbreak:;"
        if st["reason"] == 4:
            for (typ, addr, length), slot in self.slots.items():
                if st["hit"] & (1 << slot) and typ >= 2:
                    name = {2: "watch", 3: "rwatch", 4: "awatch"}[typ]
                    return reply + "%s:%x;" % (name, st["hit_addr"])
        return reply

    def resume(self, step):
        if step:
            self.dbg.step()
            return self.stop_reply()
        self.dbg.run()
        while True:
            pkt = self.recv_packet(timeout=0.02)
            if pkt == "\x03":
                self.dbg.stop()
                return self.stop_reply(interrupted=True)
            if pkt is not None:
                # Pakety za běhu (DeZog u MAME tak posílá hlavně Z/z, když
                # se breakpointy mění za běhu). Nesmí se zahodit: breakpoint
                # by se do jádra nedostal. c/s za běhu nemají smysl, D/k
                # ukončí spojení (výjimka z handle), zbytek se obslouží
                # normálně (paměť za běhu vrátí E0E, registry jsou živé).
                if pkt[0] in "cs" or pkt == "?":
                    self.log("za běhu ignoruji " + pkt)
                else:
                    reply = self.handle(pkt)
                    if reply is not None:
                        self.send(reply)
            if self.dbg.is_stopped():
                return self.stop_reply()

    # --- zpracování paketu
    def handle(self, p):
        if p == "\x03":
            if not self.dbg.is_stopped():
                self.dbg.stop()
            return self.stop_reply(interrupted=True)
        if p.startswith("qSupported"):
            return "PacketSize=4000;qXfer:features:read+;QStartNoAckMode+;hwbreak+;swbreak+"
        if p == "QStartNoAckMode":
            self.send("OK")
            self.noack = True
            return None
        if p.startswith("qXfer:features:read:target.xml:"):
            off, ln = (int(x, 16) for x in p.split(":")[4].split(","))
            part = TARGET_XML[off:off + ln]
            return ("l" if off + ln >= len(TARGET_XML) else "m") + part
        if p == "qAttached":
            return "1"
        if p == "qfThreadInfo":
            return "m1"
        if p == "qsThreadInfo":
            return "l"
        if p == "qC":
            return "QC1"
        if p.startswith("H") or p.startswith("T"):
            return "OK"
        if p == "?":
            if not self.dbg.is_stopped():
                self.dbg.stop()
            return self.stop_reply()
        if p == "g":
            return self.regs_hex()
        if p.startswith("G"):
            self.set_regs_hex(p[1:])
            return "OK"
        if p.startswith("p"):
            n = int(p[1:], 16)
            if n >= len(GDB_REGS):
                return "E01"
            return self.regs_hex()[4 * n:4 * n + 4]
        if p.startswith("P"):
            n, v = p[1:].split("=")
            n = int(n, 16)
            if n >= len(GDB_REGS):
                return "E01"
            r = self.dbg.regs()
            r[GDB_REGS[n]] = int(v[2:4] + v[0:2], 16)
            self.dbg.set_regs(r)
            return "OK"
        if p.startswith("m"):
            if not self.dbg.is_stopped():
                return "E0E"                               # paměť jen při zastavení
            addr, ln = (int(x, 16) for x in p[1:].split(","))
            return self.dbg.read_mem(addr, ln).hex()
        if p.startswith("M"):
            if not self.dbg.is_stopped():
                return "E0E"
            head, data = p[1:].split(":")
            addr, ln = (int(x, 16) for x in head.split(","))
            self.dbg.write_mem(addr, bytes.fromhex(data)[:ln])
            return "OK"
        if p[0] in "Zz" and len(p) > 1 and p[1] in "01234":
            typ, addr, length = p[1:].split(",")[:3]
            return self.set_break(int(typ), int(addr, 16), int(length, 16), p[0] == "Z")
        if p[0] in "cs":
            if len(p) > 1:                                  # c addr / s addr: nastav PC
                r = self.dbg.regs()
                r["pc"] = int(p[1:], 16)
                self.dbg.set_regs(r)
            return self.resume(step=p[0] == "s")
        if p in ("D", "k"):
            for slot in list(self.slots.values()):
                self.dbg.clear_bp(slot)
            self.slots.clear()
            if self.dbg.is_stopped():
                self.dbg.run()
            self.send("OK")
            raise ConnectionAbortedError()
        if p.startswith("qRcmd,"):
            cmd = bytes.fromhex(p[6:]).decode(errors="replace").strip()
            if cmd == "time":                              # monitor time
                return ("%d\n" % self.dbg.tstamp()).encode().hex()
            if cmd == "reset-bps":
                for i in range(self.dbg.nbp):
                    self.dbg.clear_bp(i)
                self.slots.clear()
                return "OK"
            return ""
        return ""                                           # nepodporováno

    def serve(self, conn):
        self.sock = conn
        self.noack = False
        self.buf = b""
        # jako MAME: s připojeným klientem je cíl zastavený
        if not self.dbg.is_stopped():
            self.dbg.stop()
            self.log("počítač zastaven (připojení klienta)")
        try:
            while True:
                p = self.recv_packet()
                try:
                    reply = self.handle(p)
                except DebuggerError as e:
                    self.log("chyba debuggeru: %s" % e)
                    reply = "E05"
                if reply is not None:
                    self.send(reply)
        except (ConnectionError, ConnectionAbortedError):
            pass
        finally:
            conn.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description="GDB stub pro debugger Z80 v jádře Sord M5")
    ap.add_argument("--link", default="/dev/ttyS1", help="sériový port nebo host:port (výchozí /dev/ttyS1)")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("--port", type=int, default=5555, help="TCP port pro gdb (výchozí 5555)")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)

    log = (lambda m: print(m, file=sys.stderr)) if a.verbose else None
    dbg = Z80Debugger(open_link(a.link, a.baud))
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.bind, a.port))
    srv.listen(1)
    print("gdb stub: čekám na %s:%d" % (a.bind, a.port), file=sys.stderr)
    while True:
        conn, peer = srv.accept()
        print("gdb připojen z %s:%d" % peer, file=sys.stderr)
        GdbStub(dbg, log).serve(conn)
        print("gdb odpojen", file=sys.stderr)


if __name__ == "__main__":
    main()
