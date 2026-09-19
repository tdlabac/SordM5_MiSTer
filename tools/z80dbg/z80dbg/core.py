"""Debugger Z80 v jádře Sord M5 — knihovna pro nástroje.

Mluví protokolem z doc/z80-debugger-protokol.md (příkazy P R W B M N) nad
registrovým prostorem rtl/CPU/tv80_dbg_regs.sv.

    from z80dbg import open_link, Z80Debugger
    d = Z80Debugger(open_link("/dev/ttyS1"))
    d.stop(); print(d.regs()); d.step(); d.run()
"""

import time

# --- registrový prostor (rtl/CPU/tv80_dbg_regs.sv)
R_CMD, R_OPT, R_ID, R_NBP = 0x00, 0x01, 0x02, 0x03
R_HIT_ADDR, R_HIT_DATA, R_HIT_PC, R_HIT = 0x04, 0x06, 0x08, 0x0A
R_TSTAMP = 0x18        # čas počítače, 6 B: takty CPU od resetu (rtl/tstamp.sv)
R_REGS, R_BP = 0x20, 0x40
REGB = 27
CMD_STOP, CMD_RUN, CMD_STEP, CMD_COMMIT, CMD_SNAP = 0x01, 0x02, 0x04, 0x08, 0x10

REASONS = {0: "běží", 1: "stop", 2: "krok", 3: "breakpoint (provedení)", 4: "breakpoint (přístup)"}

# typy breakpointů (bitová maska)
BP_EXEC, BP_MRD, BP_MWR, BP_IORD, BP_IOWR = 1, 2, 4, 8, 16
BP_NAMES = {"x": BP_EXEC, "r": BP_MRD, "w": BP_MWR, "ir": BP_IORD, "iw": BP_IOWR}

# 16bitové registry ve snímku REG: jméno -> bitová pozice (tv80.sv)
REG16 = [("sp", 48), ("pc", 64), ("bc", 80), ("de", 96), ("hl", 112),
         ("bc'", 128), ("de'", 144), ("hl'", 160), ("ix", 176), ("iy", 192)]
REG8 = [("a", 0), ("f", 1), ("a'", 2), ("f'", 3), ("i", 4), ("r", 5)]


class DebuggerError(Exception):
    pass


def regs_from_bytes(b):
    r = {n: b[i] for n, i in REG8}
    for n, bit in REG16:
        r[n] = b[bit // 8] | (b[bit // 8 + 1] << 8)
    r["iff1"] = b[26] & 1
    r["iff2"] = (b[26] >> 1) & 1
    r["im"] = (b[26] >> 2) & 3
    r["af"] = (r["a"] << 8) | r["f"]
    r["af'"] = (r["a'"] << 8) | r["f'"]
    r["_orig"] = {"af": r["af"], "af'": r["af'"]}      # pro regs_to_bytes
    return r


def _pair(r, hi, lo, pair, orig):
    """AF z a/f nebo z af: platí to, co se proti snímku orig změnilo."""
    if r.get(pair) is not None and r[pair] != orig.get(pair):
        return r[pair] >> 8, r[pair] & 0xFF
    return r[hi] & 0xFF, r[lo] & 0xFF


def regs_to_bytes(r):
    """r: slovník jako z regs_from_bytes(); u A/F lze měnit af, nebo a a f."""
    orig = r.get("_orig", {})
    b = bytearray(REGB)
    a, f = _pair(r, "a", "f", "af", orig)
    a_, f_ = _pair(r, "a'", "f'", "af'", orig)
    b[0], b[1], b[2], b[3], b[4], b[5] = a, f, a_, f_, r["i"] & 0xFF, r["r"] & 0xFF
    for n, bit in REG16:
        v = r[n] & 0xFFFF
        b[bit // 8], b[bit // 8 + 1] = v & 0xFF, v >> 8
    b[26] = (r["iff1"] & 1) | ((r["iff2"] & 1) << 1) | ((r["im"] & 3) << 2)
    return bytes(b)


class Z80Debugger:
    def __init__(self, link, timeout=2.0):
        self.link = link
        self.timeout = timeout
        self.sync()

    # --- protokol
    def _read(self, n):
        data = self.link.read(n, self.timeout)
        if len(data) != n:
            raise DebuggerError("odpověď nepřišla (%d/%d B)" % (len(data), n))
        return data

    def sync(self):
        """Dostane protokol do známého stavu: počká na timeout jádra a pošle ping."""
        for attempt in range(3):
            self.link.read(4096, 0.05)                    # zahodit zbytky
            self.link.write(b"P")
            if self.link.read(1, 0.5) == b"\x5a":
                self.link.read(4096, 0.02)
                if self.read_reg(R_ID) != 0x5A:
                    raise DebuggerError("registrový prostor debuggeru neodpovídá (ID)")
                self.nbp = self.read_reg(R_NBP)
                return
            time.sleep(0.05)                               # timeout rozpracovaného příkazu v jádře
        raise DebuggerError("jádro neodpovídá na ping (most obsazený jiným klientem, např. běžícím "
                            "gdb stubem? jádro bez debuggeru?)")

    def read_reg(self, a):
        self.link.write(bytes([ord("R"), a]))
        return self._read(1)[0]

    def read_regs_block(self, a, n):
        self.link.write(bytes([ord("B"), a, n & 0xFF]))
        return self._read(n)

    def write_reg(self, a, d):
        self.link.write(bytes([ord("W"), a, d & 0xFF]))

    # --- stav a běh
    def status(self):
        s = self.read_reg(R_CMD)
        st = {"stopped": bool(s & 1), "mem_busy": bool(s & 2), "reason": (s >> 2) & 7}
        st["reason_name"] = REASONS.get(st["reason"], "?")
        if st["stopped"]:
            b = self.read_regs_block(R_HIT_ADDR, 8)
            st["hit_addr"] = b[0] | (b[1] << 8)
            st["hit_data"] = b[2]
            st["hit_pc"] = b[4] | (b[5] << 8)
            st["hit"] = b[6] | (b[7] << 8)
        st["tstamp"] = self.tstamp()
        return st

    def tstamp(self):
        """Čas počítače: takty CPU od resetu. Při zastavení stojí; za běhu je
        to okamžik čtení. V simulaci se na něm dá zastavit (časová značka)."""
        return int.from_bytes(self.read_regs_block(R_TSTAMP, 6), "little")

    def is_stopped(self):
        return bool(self.read_reg(R_CMD) & 1)

    def wait_stopped(self, timeout=5.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if self.is_stopped():
                return True
            time.sleep(0.005)
        return False

    def stop(self, wait=True):
        self.write_reg(R_CMD, CMD_STOP)
        if wait and not self.wait_stopped():
            raise DebuggerError("nezastavil")

    def run(self):
        self.write_reg(R_CMD, CMD_RUN)

    def step(self, noint=False, wait=True):
        self.write_reg(R_OPT, 1 if noint else 0)
        self.write_reg(R_CMD, CMD_STEP)
        if wait:
            # krok trvá desítky taktů, stav se po zápisu přečte až po něm
            if not self.wait_stopped():
                raise DebuggerError("krok neskončil")

    # --- registry
    def regs(self):
        return regs_from_bytes(self.read_regs_block(R_REGS, REGB))

    def set_regs(self, r):
        """r: slovník jako z regs(), stačí změnit hodnoty. Jen při zastavení."""
        b = regs_to_bytes(r)
        self.write_reg(R_CMD, CMD_SNAP)
        for k, v in enumerate(b):
            self.write_reg(R_REGS + k, v)
        self.write_reg(R_CMD, CMD_COMMIT)

    # --- breakpointy
    def set_bp(self, i, kind, addr, amask=0xFFFF, data=0, dmask=0):
        # Registry se zapisují po bajtech a breakpoint porovnává hned. Druh se
        # proto zapisuje až nakonec a předtím se breakpoint vypne: jinak by
        # mezi zápisy platil nový druh se starou adresou/maskou (po resetu
        # maska 0000 = každá adresa) a počítač by se zastavil kdekoli.
        base = R_BP + 8 * i
        self.write_reg(base, 0)
        for k, v in enumerate([addr & 0xFF, addr >> 8, amask & 0xFF, amask >> 8, data, dmask], 1):
            self.write_reg(base + k, v)
        self.write_reg(base, kind)

    def clear_bp(self, i):
        self.write_reg(R_BP + 8 * i, 0)

    def get_bp(self, i):
        b = self.read_regs_block(R_BP + 8 * i, 7)
        return {"kind": b[0], "addr": b[1] | (b[2] << 8), "amask": b[3] | (b[4] << 8),
                "data": b[5], "dmask": b[6]}

    # --- paměť (jen při zastavení)
    def read_mem(self, addr, n):
        out = bytearray()
        while n > 0:
            chunk = min(n, 4096)
            self.link.write(bytes([ord("M"), addr & 0xFF, (addr >> 8) & 0xFF, chunk & 0xFF, chunk >> 8]))
            data = self.link.read(chunk, self.timeout + chunk * 50e-6)
            if len(data) != chunk:
                raise DebuggerError("čtení paměti nedoběhlo (%d/%d B)" % (len(data), chunk))
            out += data
            addr = (addr + chunk) & 0xFFFF
            n -= chunk
        return bytes(out)

    def write_mem(self, addr, data):
        data = bytes(data)
        pos = 0
        while pos < len(data):
            chunk = data[pos:pos + 4096]
            n = len(chunk)
            self.link.write(bytes([ord("N"), addr & 0xFF, (addr >> 8) & 0xFF, n & 0xFF, n >> 8]) + chunk)
            if self.link.read(1, self.timeout + n * 50e-6) != b"\x5a":
                raise DebuggerError("zápis paměti nepotvrzen")
            addr = (addr + n) & 0xFFFF
            pos += n
