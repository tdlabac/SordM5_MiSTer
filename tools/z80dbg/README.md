# z80dbg — nástroje pro debugger Z80 v jádře Sord M5

Knihovna, příkazová řádka, GDB stub a most TCP ↔ `/dev/ttyS1` pro MiSTer.
Python 3, jen standardní knihovna.

```
python3 -m z80dbg.cli     --link /dev/ttyS1            # na MiSTeru
python3 -m z80dbg.gdbstub --link /dev/ttyS1 --port 5555
python3 mister/z80dbg_bridge.py                        # na MiSTeru, pak z PC --link mister:5556
```

Popis cesty, protokolu a použití: [doc/z80-debugger-protokol.md](../../doc/z80-debugger-protokol.md).
Test proti modelu jádra: `rtl/CPU/tb/run_uart.sh`.
