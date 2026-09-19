#!/usr/bin/env python3
"""Most TCP <-> /dev/ttyS1 na MiSTeru pro debugger Z80 v jádře Sord M5.

Na MiSTeru:   python3 z80dbg_bridge.py            (poslouchá na portu 5556)
Na PC:        python3 -m z80dbg.cli --link mister:5556
              python3 -m z80dbg.gdbstub --link mister:5556 --port 5555

Most jen přeposílá bajty, protokol řeší nástroje na PC. Bez závislostí
(jen standardní knihovna), jeden klient najednou.

Pozor: /dev/ttyS1 nesmí mít otevřený nikdo jiný (UART mód v menu MiSTeru
musí být None). Pokud chcete gdb stub pustit rovnou na MiSTeru, most
nepotřebujete: python3 -m z80dbg.gdbstub --link /dev/ttyS1.
"""

import argparse
import os
import select
import socket
import sys
import termios
import tty


def open_serial(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)
    attr = termios.tcgetattr(fd)
    speed = getattr(termios, "B%d" % baud)
    attr[4] = attr[5] = speed
    attr[2] &= ~(termios.CRTSCTS | termios.CSTOPB | termios.PARENB)
    attr[2] |= termios.CLOCAL | termios.CREAD | termios.CS8
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--serial", default="/dev/ttyS1")
    ap.add_argument("--baud", type=int, default=230400)
    ap.add_argument("--port", type=int, default=5556)
    ap.add_argument("--bind", default="0.0.0.0")
    a = ap.parse_args()

    fd = open_serial(a.serial, a.baud)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.bind, a.port))
    srv.listen(1)
    print("most %s (%d Bd) <-> tcp %s:%d" % (a.serial, a.baud, a.bind, a.port), file=sys.stderr)
    while True:
        conn, peer = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print("připojen %s:%d" % peer, file=sys.stderr)
        termios.tcflush(fd, termios.TCIFLUSH)
        try:
            while True:
                r, _, _ = select.select([conn, fd], [], [])
                if conn in r:
                    data = conn.recv(4096)
                    if not data:
                        break
                    while data:
                        try:
                            n = os.write(fd, data)
                            data = data[n:]
                        except BlockingIOError:
                            select.select([], [fd], [], 0.1)
                if fd in r:
                    try:
                        data = os.read(fd, 4096)
                    except BlockingIOError:
                        data = b""
                    if data:
                        conn.sendall(data)
        except OSError as e:
            print("chyba: %s" % e, file=sys.stderr)
        conn.close()
        print("odpojen", file=sys.stderr)


if __name__ == "__main__":
    main()
