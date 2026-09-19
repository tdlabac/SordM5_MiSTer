"""Nástroje pro debugger Z80 v jádře Sord M5 (doc/z80-debugger.md)."""

from .link import SerialLink, TcpLink, open_link, LinkError, DEFAULT_BAUD
from .core import (Z80Debugger, DebuggerError, BP_EXEC, BP_MRD, BP_MWR, BP_IORD,
                   BP_IOWR, BP_NAMES, REASONS)
