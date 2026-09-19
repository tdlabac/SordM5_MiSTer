"""Transport k debuggeru Z80 v jádře: sériový port nebo TCP.

SerialLink  /dev/ttyS1 na MiSTeru (UART jádra), nebo jiný sériový port.
            Na Linuxu přes termios (bez závislostí), jinde přes pyserial.
TcpLink     TCP spojení na most (mister/z80dbg_bridge.py na MiSTeru, nebo
            testovací model jádra rtl/CPU/tb/run_uart.sh).

Obě třídy mají write(data) a read(n, timeout) -> bytes (kratší = timeout).
"""

import os
import select
import socket
import time

DEFAULT_BAUD = 230400


class LinkError(Exception):
    pass


class SerialLink:
    def __init__(self, path="/dev/ttyS1", baud=DEFAULT_BAUD):
        self.path = path
        try:
            import termios
            import tty
        except ImportError:
            termios = None
        if termios is not None:
            self._fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            tty.setraw(self._fd)
            attr = termios.tcgetattr(self._fd)
            speed = getattr(termios, "B%d" % baud, None)
            if speed is None:
                raise LinkError("termios nezná rychlost %d" % baud)
            attr[4] = attr[5] = speed                      # ispeed, ospeed
            attr[2] &= ~(termios.CRTSCTS | termios.CSTOPB | termios.PARENB)
            attr[2] |= termios.CLOCAL | termios.CREAD | termios.CS8
            termios.tcsetattr(self._fd, termios.TCSANOW, attr)
            termios.tcflush(self._fd, termios.TCIOFLUSH)
            self._ser = None
        else:
            import serial                                  # pyserial (Windows)
            self._ser = serial.Serial(path, baud, timeout=0)
            self._fd = None

    def write(self, data):
        if self._ser:
            self._ser.write(data)
            return
        view = memoryview(bytes(data))
        while view:
            try:
                n = os.write(self._fd, view)
                view = view[n:]
            except BlockingIOError:
                select.select([], [self._fd], [], 0.1)

    def read(self, n, timeout=1.0):
        out = bytearray()
        end = time.monotonic() + timeout
        while len(out) < n:
            left = end - time.monotonic()
            if left <= 0:
                break
            if self._ser:
                out += self._ser.read(n - len(out))
                if len(out) < n:
                    time.sleep(0.001)
                continue
            r, _, _ = select.select([self._fd], [], [], left)
            if r:
                try:
                    out += os.read(self._fd, n - len(out))
                except BlockingIOError:
                    pass
        return bytes(out)

    def close(self):
        if self._ser:
            self._ser.close()
        elif self._fd is not None:
            os.close(self._fd)
            self._fd = None


class TcpLink:
    def __init__(self, host="127.0.0.1", port=5555, timeout=5.0):
        self._s = socket.create_connection((host, port), timeout=timeout)
        self._s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def write(self, data):
        self._s.sendall(bytes(data))

    def read(self, n, timeout=1.0):
        out = bytearray()
        end = time.monotonic() + timeout
        while len(out) < n:
            left = end - time.monotonic()
            if left <= 0:
                break
            self._s.settimeout(left)
            try:
                chunk = self._s.recv(n - len(out))
            except socket.timeout:
                break
            if not chunk:
                raise LinkError("spojení ukončeno")
            out += chunk
        return bytes(out)

    def close(self):
        self._s.close()


def open_link(spec, baud=DEFAULT_BAUD):
    """'tcp:host:port', 'host:port' nebo cesta k sériovému portu."""
    if spec.startswith("tcp:"):
        spec = spec[4:]
    if ":" in spec and not spec.startswith("/") and not spec.upper().startswith("COM"):
        host, port = spec.rsplit(":", 1)
        return TcpLink(host or "127.0.0.1", int(port))
    return SerialLink(spec, baud)
