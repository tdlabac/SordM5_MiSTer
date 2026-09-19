"""Test nástrojů z80dbg proti modelu jádra (rtl/CPU/tb/run_uart.sh).

Model je skutečný dbg_link.sv (UART + protokol) + tv80_dbg_regs + tv80_dbg
s programem z tb_uart.cpp, UART vystavený na TCP. Test prochází knihovnu
(Z80Debugger) a GDB stub (RSP) tak, jak by je použil nástroj na PC.
"""

import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from z80dbg import open_link, Z80Debugger, BP_EXEC, BP_MWR  # noqa: E402
from z80dbg.gdbstub import GdbStub, _cs                      # noqa: E402

PORT = int(os.environ.get("UART_PORT", "5557"))
fails = 0


def check(name, ok, detail=""):
    global fails
    print("  %-52s %s %s" % (name, "OK  " if ok else "CHYBA", detail))
    if not ok:
        fails += 1


# program z tb_uart.cpp
PROG = {0x0000: [0xC3, 0x00, 0x01], 0x0038: [0xFB, 0xC9],
        0x0100: [0x31, 0x00, 0xF0, 0xED, 0x56, 0xFB, 0x0E, 0x00,
                 0x21, 0x00, 0x80, 0x3E, 0x11, 0x77, 0x3C, 0x77, 0x3C, 0x77,
                 0x46, 0xD3, 0x40, 0xDB, 0x41, 0x32, 0x01, 0x80,
                 0x3A, 0x00, 0x90, 0xD3, 0x42, 0x0C, 0xC3, 0x08, 0x01]}
R1, O1, I1, W4, W2, INC2 = 0x0112, 0x0113, 0x0115, 0x0117, 0x010F, 0x0110


def main():
    link = open_link("127.0.0.1:%d" % PORT)
    t0 = time.monotonic()
    d = Z80Debugger(link, timeout=5.0)
    print("=== knihovna ===")
    check("ping a identifikace, počet breakpointů", d.nbp == 9, "(NBP %d)" % d.nbp)

    d.stop()
    r = d.regs()
    check("stop, registry", d.is_stopped() and r["sp"] in (0, 0xF000), "(PC %04X SP %04X)" % (r["pc"], r["sp"]))

    d.set_bp(0, BP_EXEC, R1)
    d.run()
    ok = d.wait_stopped()
    st, r = d.status(), d.regs()
    check("breakpoint EXEC", ok and st["reason"] == 3 and r["pc"] == R1 and r["a"] == 0x13 and r["hl"] == 0x8000,
          "(důvod %d PC %04X A %02X)" % (st["reason"], r["pc"], r["a"]))

    d.clear_bp(0)
    d.set_bp(1, BP_MWR, 0x8000, data=0x12, dmask=0xFF)
    d.run()
    ok = d.wait_stopped()
    st, r = d.status(), d.regs()
    check("breakpoint MWR 8000h = 12h", ok and st["reason"] == 4 and st["hit_pc"] == W2 and r["pc"] == INC2
          and st["hit_data"] == 0x12, "(hit_pc %04X PC %04X data %02X)" % (st["hit_pc"], r["pc"], st["hit_data"]))
    d.clear_bp(1)

    code = d.read_mem(0x0100, len(PROG[0x0100]))
    check("čtení paměti (kód)", list(code) == PROG[0x0100])

    d.write_mem(0x9000, b"\xA5\x5A\x01\x02")
    check("zápis a čtení paměti", d.read_mem(0x9000, 4) == b"\xA5\x5A\x01\x02")

    r = d.regs()
    r["de"] = 0xBEEF
    d.set_regs(r)
    check("zápis registrů", d.regs()["de"] == 0xBEEF)

    pcs = []
    for _ in range(3):
        d.step()
        pcs.append(d.regs()["pc"])
    check("krok ×3", pcs == [0x0111, R1, O1], "(%s)" % " ".join("%04X" % p for p in pcs))

    t1 = d.tstamp()
    time.sleep(0.05)
    t2 = d.tstamp()
    d.run()
    time.sleep(0.05)
    t3 = d.tstamp()
    d.stop()
    check("čas počítače: při zastavení stojí, za běhu roste", t1 == t2 and t3 > t2 > 0,
          "(%d, %d, %d)" % (t1, t2, t3))

    t = time.monotonic()
    blk = d.read_mem(0x0000, 4096)
    check("čtení 4 kB paměti", len(blk) == 4096 and list(blk[0x100:0x100 + 8]) == PROG[0x0100][:8],
          "(%.2f s v modelu)" % (time.monotonic() - t))

    # --- GDB stub přes TCP
    print("=== GDB stub (RSP) ===")
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    gport = srv.getsockname()[1]

    def serve():
        conn, _ = srv.accept()
        GdbStub(d).serve(conn)

    th = threading.Thread(target=serve, daemon=True)
    d.run()                                  # stub musí při připojení zastavit sám
    time.sleep(0.05)
    th.start()
    g = socket.create_connection(("127.0.0.1", gport))
    g.settimeout(20)
    buf = b""

    def rsp(cmd):
        nonlocal buf
        g.sendall(("$%s#%s" % (cmd, _cs(cmd))).encode())
        while True:
            i = buf.find(b"$")
            j = buf.find(b"#", i)
            if i >= 0 and j >= 0 and len(buf) >= j + 3:
                data = buf[i + 1:j].decode("latin-1")
                buf = buf[j + 3:]
                g.sendall(b"+")
                return data
            buf += g.recv(4096)

    check("qSupported", "qXfer:features:read+" in rsp("qSupported:multiprocess+"))
    check("target.xml", "mame.z80" in rsp("qXfer:features:read:target.xml:0,fff"))
    check("po připojení stojí (jako MAME)", d.is_stopped())
    check("? (stav)", rsp("?").startswith("T05"))
    regs = rsp("g")
    pc = int(regs[46:48] + regs[44:46], 16)
    check("g (registry, PC na pozici 11)", len(regs) == 48 and pc == d.regs()["pc"], "(PC %04X)" % pc)
    check("m (paměť)", rsp("m0100,8") == bytes(PROG[0x0100][:8]).hex())
    check("M (zápis paměti)", rsp("M9010,2:1234") == "OK" and rsp("m9010,2") == "1234")
    check("Z1 (hw breakpoint)", rsp("Z1,%x,1" % R1) == "OK")
    rep = rsp("c")
    regs = rsp("g")
    pc = int(regs[46:48] + regs[44:46], 16)
    check("c -> zastaví na breakpointu (T05, PC, hwbreak)",
          rep.startswith("T050b:%02x%02x;" % (R1 & 0xFF, R1 >> 8)) and "hwbreak" in rep and pc == R1,
          "(%s, PC %04X)" % (rep, pc))
    check("z1", rsp("z1,%x,1" % R1) == "OK")
    check("Z2 (watch zápisu 8001h)", rsp("Z2,8001,1") == "OK")
    rep = rsp("c")
    check("c -> watchpoint", rep.startswith("T05") and "watch:8001;" in rep, "(%s)" % rep)
    rsp("z2,8001,1")
    rep = rsp("s")
    check("s (krok)", rep.startswith("T05"), "(%s)" % rep)
    g.sendall(("$c#%s" % _cs("c")).encode())
    time.sleep(0.1)
    g.sendall(b"\x03")
    while True:                                   # odpověď na c po přerušení
        i = buf.find(b"$"); j = buf.find(b"#", i)
        if i >= 0 and j >= 0 and len(buf) >= j + 3:
            rep = buf[i + 1:j].decode(); buf = buf[j + 3:]; g.sendall(b"+"); break
        buf += g.recv(4096)
    check("c + Ctrl-C -> T05 s PC (ne T02)", rep.startswith("T050b:") and d.is_stopped(), "(%s)" % rep)

    # breakpoint nastavený za běhu (tak to dělá DeZog) a opakované zastavení
    def reply():
        nonlocal buf
        while True:
            i = buf.find(b"$"); j = buf.find(b"#", i)
            if i >= 0 and j >= 0 and len(buf) >= j + 3:
                r_ = buf[i + 1:j].decode(); buf = buf[j + 3:]; g.sendall(b"+"); return r_
            buf += g.recv(4096)
    cpkt = ("$c#%s" % _cs("c")).encode()
    g.sendall(cpkt)
    time.sleep(0.05)
    ok_z = rsp("Z1,%x,1" % R1)                    # za běhu: odpověď OK hned
    hits = []
    for k in range(3):
        hits.append(reply())
        if k < 2:
            g.sendall(cpkt)
    all_hit = all(h.startswith("T050b:%02x%02x;" % (R1 & 0xFF, R1 >> 8)) and "hwbreak" in h for h in hits)
    check("Z1 za běhu -> OK, pak 3× zastavení na něm", ok_z == "OK" and all_hit, "(%s; %s)" % (ok_z, " ".join(hits)))
    rsp("z1,%x,1" % R1)
    check("P (zápis PC)", rsp("P%x=%02x%02x" % (11, R1 & 0xFF, R1 >> 8)) == "OK" and d.regs()["pc"] == R1)
    rsp("D")
    th.join(5)
    check("D (odpojení, jádro běží)", not d.is_stopped())

    link.close()
    print("\n%s (%d chyb), %.1f s" % ("VSE PROSLO" if not fails else "NEPROSLO", fails, time.monotonic() - t0))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
